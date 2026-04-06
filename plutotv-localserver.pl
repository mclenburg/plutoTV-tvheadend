#!/usr/bin/perl

package PlutoTVServer;

use strict;
use warnings;
use utf8;
use Encode qw(encode_utf8 decode_utf8 is_utf8);
use HTTP::Daemon;
use HTTP::Status;
use HTTP::Request::Params;
use DateTime;
use JSON::Parse ':all';
use HTTP::Request ();
use HTTP::Headers;
use LWP::UserAgent;
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use URI;
use UUID::Tiny ':std';
use File::Which;
use Net::Address::IP::Local;
use Try::Tiny;
use Getopt::Long qw(:config no_ignore_case);
use Crypt::CBC;
use IPC::Run qw(run);
use open qw(:std :utf8);
use MIME::Base64 qw(decode_base64);
use File::Temp qw(tempdir tmpnam);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(mkfifo WNOHANG);
use IO::Select;
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(:flock);

my $hostIp = "127.0.0.1";
my $port = "9000";
my $channelsApiUrl = "https://service-channels.clusters.pluto.tv/v2/guide/channels";
my $guideTimelinesApiUrl = "https://service-channels.clusters.pluto.tv/v2/guide/timelines";
my $guideDurationMinutes = 240;
my $guideBatchSize = 25;
my $deviceId = uuid_to_string(create_uuid(UUID_V1));
my $ffmpeg = which 'ffmpeg';
my $streamlink = which 'streamlink';
my $version = "2.3.6";
my $appName = "web";
my $appVersion = "9.20.0-89258290264838515e264f5b051b7c1602a58482";
my $deviceVersion = "148.0.0";
my $deviceModel = "web";
my $deviceMake = "firefox";
my $deviceType = "web";
my $clientModelNumber = "1.0.0";

my %regions = (
    'DE' => { lat => '52.5200', lon => '13.4050', name => 'Germany' },
    'US' => { lat => '40.7128', lon => '-74.0060', name => 'United States' },
    'UK' => { lat => '51.5074', lon => '-0.1278', name => 'United Kingdom' },
    'FR' => { lat => '48.8566', lon => '2.3522', name => 'France' },
    'IT' => { lat => '41.9028', lon => '12.4964', name => 'Italy' },
);

my $localhost = grep { $_ eq '--localonly'} @ARGV;
my $useStreamlink = grep { $_ eq '--usestreamlink'} @ARGV;
my $debug = 0;
my %hybrid_harmonize_channels = ();

my $runtimeStateDir;
my $harmonizeStateFile;
my $activeStreamsStateFile;
my $forceDiscontinuityStateFile;
my $recentLogStateFile;
my $runtimeConfigStateFile;
my $tempFile;

sub detectWritableTempBaseDir {
    for my $candidate (grep { defined $_ && length $_ } ($ENV{TMPDIR}, '/tmp', File::Spec->tmpdir())) {
        next unless -d $candidate;
        next unless -w $candidate;
        return $candidate;
    }
    return File::Spec->tmpdir();
}

sub resolveRuntimeStateDir {
    my ($tempArg) = @_;
    my $baseDir;

    if (defined $tempArg && length $tempArg) {
        if (-d $tempArg) {
            $baseDir = $tempArg;
        } else {
            $baseDir = dirname($tempArg);
        }
    }

    $baseDir ||= detectWritableTempBaseDir();
    return File::Spec->catdir($baseDir, 'plutotv-localserver');
}

sub refreshRuntimeStatePaths {
    $harmonizeStateFile          = File::Spec->catfile($runtimeStateDir, 'harmonize_channels.json');
    $activeStreamsStateFile      = File::Spec->catfile($runtimeStateDir, 'active_streams.json');
    $forceDiscontinuityStateFile = File::Spec->catfile($runtimeStateDir, 'force_discontinuity.json');
    $recentLogStateFile          = File::Spec->catfile($runtimeStateDir, 'recent_logs.json');
    $runtimeConfigStateFile      = File::Spec->catfile($runtimeStateDir, 'runtime_config.json');
}

GetOptions("debug" => \$debug, "tempFile=s" => \$tempFile);
$runtimeStateDir = resolveRuntimeStateDir($tempFile);
refreshRuntimeStatePaths();

sub parseChannelListArg {
    my ($value) = @_;
    return () unless defined $value && length $value;
    my %out;
    for my $id (split /[\s,;]+/, $value) {
        next unless defined $id && length $id;
        $out{$id} = 1;
    }
    return %out;
}

%hybrid_harmonize_channels = (
    parseChannelListArg($ENV{PLUTOTV_HARMONIZE_CHANNELS}),
    parseChannelListArg(getArgsValue("--harmonizechannels")),
);

for my $id (keys %{ loadHarmonizeOverrides() }) {
    $hybrid_harmonize_channels{$id} = 1;
}

our %channel_timestamps = ();
our %session_cache = ();
our %channel_cache = ();
our %master_url_cache = ();


my $sessionRefreshInterval = 25 * 60;
my $sessionRetryCooldown = 30;


sub ensureRuntimeStateDir {
    return 1 if -d $runtimeStateDir;
    eval { make_path($runtimeStateDir) };
    return 0 if $@ || !-d $runtimeStateDir || !-w $runtimeStateDir;
    return 1;
}

sub htmlEscape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    return $value;
}

sub loadJsonFile {
    my ($path, $default) = @_;
    ensureRuntimeStateDir() or return $default;
    return $default unless -e $path;
    open(my $fh, '<', $path) or return $default;
    flock($fh, LOCK_SH);
    local $/;
    my $content = <$fh>;
    close($fh);
    return $default unless defined $content && length $content;
    my $parsed = eval { decode_json($content) };
    return defined $parsed ? $parsed : $default;
}

sub saveJsonFile {
    my ($path, $data) = @_;
    ensureRuntimeStateDir() or return 0;
    my $tmp = $path . '.tmp.' . $$;
    open(my $fh, '>', $tmp) or return 0;
    flock($fh, LOCK_EX);
    print $fh encode_json($data);
    close($fh);
    rename($tmp, $path) or return 0;
    return 1;
}

sub normalizeBoolean {
    my ($value, $default) = @_;
    return $default unless defined $value;
    return $value ? 1 : 0 if ref($value) eq 'JSON::PP::Boolean';
    return 1 if $value =~ /^(1|true|yes|on)$/i;
    return 0 if $value =~ /^(0|false|no|off)$/i;
    return $default;
}

sub loadHarmonizeOverrides {
    my $parsed = loadJsonFile($harmonizeStateFile, {});
    return {} unless ref($parsed) eq 'HASH';
    my %normalized;
    for my $channelId (keys %$parsed) {
        $normalized{$channelId} = normalizeBoolean($parsed->{$channelId}, 0) ? JSON::PP::true : JSON::PP::false;
    }
    return \%normalized;
}

sub saveHarmonizeOverrides {
    my ($hashref) = @_;
    $hashref ||= {};
    my %normalized;
    for my $channelId (keys %$hashref) {
        $normalized{$channelId} = normalizeBoolean($hashref->{$channelId}, 0) ? JSON::PP::true : JSON::PP::false;
    }
    return saveJsonFile($harmonizeStateFile, \%normalized);
}

sub setHarmonizeOverride {
    my ($channelId, $enabled) = @_;
    return 0 unless defined $channelId && length $channelId;
    my $overrides = loadHarmonizeOverrides();
    $overrides->{$channelId} = normalizeBoolean($enabled, 0) ? JSON::PP::true : JSON::PP::false;
    return saveHarmonizeOverrides($overrides);
}

sub getPersistedHarmonizeOverride {
    my ($channelId) = @_;
    return undef unless defined $channelId && length $channelId;
    my $overrides = loadHarmonizeOverrides();
    return undef unless exists $overrides->{$channelId};
    return normalizeBoolean($overrides->{$channelId}, 0) ? 1 : 0;
}

sub loadForceDiscontinuityMap {
    my $parsed = loadJsonFile($forceDiscontinuityStateFile, {});
    return {} unless ref($parsed) eq 'HASH';
    return $parsed;
}

sub queueForcedDiscontinuity {
    my ($channelId) = @_;
    return 0 unless defined $channelId && length $channelId;
    my $map = loadForceDiscontinuityMap();
    $map->{$channelId} = 1;
    return saveJsonFile($forceDiscontinuityStateFile, $map);
}

sub consumeForcedDiscontinuity {
    my ($channelId) = @_;
    return 0 unless defined $channelId && length $channelId;
    my $map = loadForceDiscontinuityMap();
    return 0 unless $map->{$channelId};
    delete $map->{$channelId};
    saveJsonFile($forceDiscontinuityStateFile, $map);
    return 1;
}

sub loadActiveStreams {
    my $parsed = loadJsonFile($activeStreamsStateFile, {});
    return {} unless ref($parsed) eq 'HASH';
    return $parsed;
}

sub saveActiveStreams {
    my ($hashref) = @_;
    $hashref ||= {};
    return saveJsonFile($activeStreamsStateFile, $hashref);
}

sub registerActiveStream {
    my (%info) = @_;
    my $streams = loadActiveStreams();
    my $key = $$ . '-' . int(time() * 1000) . '-' . int(rand(100000));
    $info{pid} = $$;
    $info{startedAt} ||= time();
    $streams->{$key} = \%info;
    saveActiveStreams($streams);
    return $key;
}

sub unregisterActiveStream {
    my ($key) = @_;
    return unless defined $key && length $key;
    my $streams = loadActiveStreams();
    delete $streams->{$key};
    saveActiveStreams($streams);
}

# Reliable cross-platform process liveness check.
# kill(0,$pid) is unreliable for double-forked orphan processes on Linux
# when SIG{CHLD}='IGNORE': the process is alive but kill(0) returns 0
# from sibling processes in some RPi/systemd configurations.
# /proc/$pid is authoritative and permission-independent on Linux.
sub pidIsAlive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return (-d "/proc/$pid") ? 1 : 0 if -d '/proc';
    return kill(0, $pid) ? 1 : 0;  # non-Linux fallback
}

sub cleanupStaleActiveStreams {
    my $streams = loadActiveStreams();
    my $changed = 0;
    for my $key (keys %$streams) {
        my $entry = $streams->{$key};
        my $pid = ref($entry) eq 'HASH' ? $entry->{pid} : undef;
        if (!$pid || !pidIsAlive($pid)) {
            delete $streams->{$key};
            $changed = 1;
        }
    }
    saveActiveStreams($streams) if $changed;
    return $streams;
}

sub readActiveStreamsForDisplay {
    # Read-only: show all registered entries, NEVER write back.
    # No liveness filter here: stale entries are removed by
    # unregisterActiveStream (on stream exit) and cleanupStaleActiveStreams
    # (on admin page load). Filtering here with kill(0,$pid) was the
    # root cause - it silently dropped live orphan processes.
    return loadActiveStreams();
}

sub loadRuntimeConfig {
    my $parsed = loadJsonFile($runtimeConfigStateFile, {});
    return {} unless ref($parsed) eq 'HASH';
    return $parsed;
}

sub saveRuntimeConfig {
    my ($hashref) = @_;
    $hashref ||= {};
    return saveJsonFile($runtimeConfigStateFile, $hashref);
}

sub getConfigValue {
    my ($key, $default) = @_;
    my $cfg = loadRuntimeConfig();
    return (defined $cfg->{$key} && length "$cfg->{$key}") ? $cfg->{$key} : $default;
}

sub updateActiveStream {
    my ($key, %changes) = @_;
    return unless defined $key && length $key;
    my $streams = loadActiveStreams();
    return unless ref($streams->{$key}) eq 'HASH';
    for my $k (keys %changes) {
        $streams->{$key}->{$k} = $changes{$k};
    }
    saveActiveStreams($streams);
}

sub desiredModeByOverride {
    my ($channelId, $request) = @_;
    my $persisted = getPersistedHarmonizeOverride($channelId);
    return $persisted ? 'harmonize' : 'copy' if defined $persisted;
    return 'harmonize' if $hybrid_harmonize_channels{$channelId};

    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    if ($params && defined $params->{mode}) {
        my $mode = lc($params->{mode});
        return 'harmonize' if $mode eq 'harmonize';
        return 'copy' if $mode eq 'copy';
    }
    if ($params && defined $params->{harmonize}) {
        my $flag = lc($params->{harmonize});
        return 'harmonize' if $flag =~ /^(1|true|yes|on)$/;
        return 'copy' if $flag =~ /^(0|false|no|off)$/;
    }
    return 'copy';
}

sub loadRecentLogs {
    my $parsed = loadJsonFile($recentLogStateFile, []);
    return [] unless ref($parsed) eq 'ARRAY';
    return $parsed;
}

sub saveRecentLogs {
    my ($arr) = @_;
    $arr ||= [];
    return saveJsonFile($recentLogStateFile, $arr);
}

sub appendRecentLog {
    my ($message) = @_;
    return unless defined $message && length $message;
    my $logs = loadRecentLogs();
    push @$logs, {
        ts => time(),
        line => "$message",
    };
    my $maxLogs = int(getConfigValue('log_depth', 10));
    $maxLogs = 5 if $maxLogs < 5;
    shift @$logs while @$logs > $maxLogs;
    saveRecentLogs($logs);
}


sub jsonResponse {
    my ($client, $code, $payload) = @_;
    my $response = HTTP::Response->new($code);
    $response->header('content-type' => 'application/json; charset=utf-8');
    $response->content(encode_utf8(encode_json($payload || {})));
    $client->send_response($response);
}

sub sendJsonOk {
    my ($client, %extra) = @_;
    jsonResponse($client, 200, { ok => JSON::PP::true, %extra });
}

sub sendJsonError {
    my ($client, $message, %extra) = @_;
    jsonResponse($client, 400, { ok => JSON::PP::false, error => ($message || 'Fehler'), %extra });
}

sub buildChannelAdminEntries {
    my ($region) = @_;
    $region ||= 'DE';
    my @entries;
    for my $channel (getChannelJson($region)) {
        next unless $channel && ($channel->{id} || '');
        my $channelId = $channel->{id} || $channel->{_id};
        my $persisted = getPersistedHarmonizeOverride($channelId);
        my $effective = desiredModeByOverride($channelId, undef) eq 'harmonize' ? 1 : 0;
        my $source = defined $persisted ? 'persisted' : ($hybrid_harmonize_channels{$channelId} ? 'environment' : 'default');
        push @entries, {
            channelId => $channelId,
            channelName => $channel->{name} || $channelId,
            number => $channel->{number} || 0,
            effectiveHarmonize => $effective ? 1 : 0,
            persistedHarmonize => defined $persisted ? ($persisted ? 1 : 0) : undef,
            source => $source,
        };
    }
    @entries = sort {
        lc($a->{channelName} || '') cmp lc($b->{channelName} || '')
            || ($a->{number} || 0) <=> ($b->{number} || 0)
    } @entries;
    return \@entries;
}

sub handleAdminSetConfig {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params } || {};
    my $stall   = int($params->{stall_timeout}   || 15);
    my $startup = int($params->{startup_timeout} || 45);
    my $fails   = int($params->{max_failures}    || 5);
    my $depth   = int($params->{log_depth}       || 10);

    $stall   = 5   if $stall < 5;
    $stall   = 120 if $stall > 120;
    $startup = 5   if $startup < 5;
    $startup = 180 if $startup > 180;
    $startup = $stall if $startup < $stall;
    $fails   = 1   if $fails < 1;
    $fails   = 20  if $fails > 20;
    $depth   = 5   if $depth < 5;
    $depth   = 100 if $depth > 100;

    saveRuntimeConfig({
        stall_timeout   => $stall,
        startup_timeout => $startup,
        max_failures    => $fails,
        log_depth       => $depth,
    });

    appendRecentLog("Konfiguration gespeichert: stall=${stall}s, startup=${startup}s, fail=${fails}, log=${depth}");
    sendJsonOk($client, msg => 'Konfiguration gespeichert');
}

sub buildAdminSnapshot {
    my ($region, %opts) = @_;
    $region ||= 'DE';
    my $streams  = $opts{readonly} ? readActiveStreamsForDisplay() : cleanupStaleActiveStreams();
    my $channels = buildChannelAdminEntries($region);
    my $logs     = loadRecentLogs();

    my @entries;
    for my $key (sort keys %$streams) {
        my $entry = $streams->{$key};
        next unless ref($entry) eq 'HASH';
        my $channelId = $entry->{channelId} || '';
        my $effectiveMode = desiredModeByOverride($channelId, undef);
        push @entries, {
            key         => $key,
            channelId   => $channelId,
            channelName => $entry->{channelName} || $channelId,
            mode        => $entry->{mode} || 'copy',
            desiredMode => $effectiveMode,
            started     => formatEpochLocal($entry->{startedAt}),
            pid         => $entry->{pid} || 0,
            harmonize   => $effectiveMode eq 'harmonize' ? 1 : 0,
        };
    }

    my @recent = map {
        +{
            ts   => formatEpochLocal($_->{ts}),
            line => $_->{line},
        }
    } @$logs;

    return {
        region   => $region,
        streams  => \@entries,
        channels => $channels,
        logs     => \@recent,
        config   => {
            stall_timeout   => int(getConfigValue('stall_timeout', 15)),
            startup_timeout => int(getConfigValue('startup_timeout', 45)),
            max_failures    => int(getConfigValue('max_failures',  5)),
            log_depth       => int(getConfigValue('log_depth',     10)),
        },
    };
}

sub sendAdminEvents {
    my ($client, $request) = @_;
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};

    eval {
        $client->write("HTTP/1.1 200 OK\n");
        $client->write("Content-Type: text/event-stream; charset=utf-8\n");
        $client->write("Cache-Control: no-cache, no-store, must-revalidate\n");
        $client->write("Connection: close\n\n");
    };
    return if $@;

    my $last_payload = '';
    for (1..3600) {
        my $snapshot = buildAdminSnapshot($region, readonly => 1);
        my $payload = encode_json($snapshot);
        if ($payload ne $last_payload) {
            my $ok = eval {
                $client->write("event: snapshot\n");
                $client->write("data: $payload\n\n");
                $client->flush(); 1
            };
            last unless $ok;
            $last_payload = $payload;
        } else {
            my $ok = eval { $client->write(": keepalive\n\n"); $client->flush(); 1 };
            last unless $ok;
        }
        sleep 1;
    }
}

sub getLatestDiscontinuitySeq {
    my ($playlistContent) = @_;
    return undef unless defined $playlistContent && length $playlistContent;
    my @lines = split /\r?\n/, $playlistContent;
    my $mediaSequence = 0;
    my $segmentIndex = 0;
    my $pendingDisc = 0;
    my $latest;
    for my $line (@lines) {
        if ($line =~ /^#EXT-X-MEDIA-SEQUENCE:(\d+)/) {
            $mediaSequence = $1;
        } elsif ($line =~ /^#EXT-X-DISCONTINUITY$/) {
            $pendingDisc = 1;
        } elsif ($line !~ /^#/ && length $line) {
            if ($pendingDisc) {
                $latest = $mediaSequence + $segmentIndex;
                $pendingDisc = 0;
            }
            $segmentIndex++;
        }
    }
    return $latest;
}

sub detectNewPlaylistDiscontinuity {
    my ($ua, $videoUrl, $audioUrl, $lastSeenRef) = @_;
    my $latest;
    for my $url (grep { defined $_ && length $_ } ($videoUrl, $audioUrl)) {
        my $resp = getResponseFromUrl($url, ua => $ua);
        next unless $resp && $resp->is_success;
        my $seq = getLatestDiscontinuitySeq($resp->decoded_content);
        $latest = $seq if defined $seq && (!defined($latest) || $seq > $latest);
    }
    if (!defined $$lastSeenRef) {
        $$lastSeenRef = $latest;
        return 0;
    }
    if (defined $latest && $latest > $$lastSeenRef) {
        $$lastSeenRef = $latest;
        return 1;
    }
    return 0;
}
sub formatEpochLocal {
    my ($epoch) = @_;
    return '' unless defined $epoch && $epoch =~ /^\d+$/;
    my @lt = localtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0]);
}

sub getArgsValue {
    my ($param) = @_;
    for my $argnum (0 .. $#ARGV) {
        return $ARGV[$argnum+1] if $ARGV[$argnum] eq $param;
    }
    return undef;
}

sub forkProcess {
    my $pid = fork;
    if ($pid) {
        waitpid $pid, 0;
    } else {
        my $pid2 = fork;
        if ($pid2) {
            exit(0);
        } else {
            return 1;
        }
    }
    return 0;
}

sub sortByRunningNumber {
    my @array = @_;
    my @sortedArray = sort { $a->{running} <=> $b->{running} } @array;
    return @sortedArray;
}

sub createUserAgent {
    my (%opts) = @_;
    my $ua = LWP::UserAgent->new(keep_alive => 1, timeout => 20);
    $ua->agent('Mozilla/5.0 (X11; Linux x86_64; rv:148.0) Gecko/20100101 Firefox/148.0');
    my $headers = HTTP::Headers->new;
    $headers->header('Cache-Control'   => 'no-cache');
    $headers->header('Pragma'          => 'no-cache');
    $headers->header('Accept'          => '*/*');
    $headers->header('Accept-Language' => 'de,en-US;q=0.9,en;q=0.8');
    $headers->header('Referer'         => 'https://pluto.tv/');
    $headers->header('Origin'          => 'https://pluto.tv');
    $headers->header('DNT'             => '1');
    $headers->header('Sec-GPC'         => '1');
    $headers->header('Connection'      => 'keep-alive');
    $headers->header('Sec-Fetch-Dest'  => 'empty');
    $headers->header('Sec-Fetch-Mode'  => 'cors');
    $headers->header('Sec-Fetch-Site'  => 'same-site');
    if ($opts{token}) {
        $headers->header('Authorization' => 'Bearer ' . $opts{token});
    }
    $ua->default_headers($headers);
    return $ua;
}

sub getFromUrl {
    my ($url, %opts) = @_;
    my $request = HTTP::Request->new(GET => $url);
    my $ua = $opts{ua} || createUserAgent(%opts);
    my $response = $ua->request($request);
    return $response->is_success ? $response->decoded_content : undef;
}

sub getResponseFromUrl {
    my ($url, %opts) = @_;
    my $request = HTTP::Request->new(GET => $url);
    my $ua = $opts{ua} || createUserAgent(%opts);
    return $ua->request($request);
}

sub pickLogoUrl {
    my ($channel) = @_;
    return undef unless $channel;
    if (ref($channel->{logo}) eq 'HASH' && $channel->{logo}->{path}) {
        return $channel->{logo}->{path};
    }
    my @preferred = qw(logo colorLogoPNG solidLogoPNG colorLogoSVG solidLogoSVG featuredImage hero tileColor tileGrayscale);
    my %imagesByType = map { ($_->{type} || '') => ($_->{url} || '') } @{ $channel->{images} || [] };
    for my $type (@preferred) {
        return $imagesByType{$type} if $imagesByType{$type};
    }
    for my $image (@{ $channel->{images} || [] }) {
        return $image->{url} if $image->{url};
    }
    return undef;
}

sub normalizeChannel {
    my ($channel) = @_;
    return undef unless $channel && ref($channel) eq 'HASH';
    my $id = $channel->{id} || $channel->{_id};
    return undef unless $id;

    my $stitchedPath;
    if (ref($channel->{stitched}) eq 'HASH' && ref($channel->{stitched}->{paths}) eq 'ARRAY') {
        for my $path (@{ $channel->{stitched}->{paths} }) {
            next unless ref($path) eq 'HASH';
            if (($path->{type} || '') eq 'hls' && $path->{path}) {
                $stitchedPath = $path->{path};
                last;
            }
        }
        unless ($stitchedPath) {
            for my $path (@{ $channel->{stitched}->{paths} }) {
                next unless ref($path) eq 'HASH';
                if ($path->{path}) {
                    $stitchedPath = $path->{path};
                    last;
                }
            }
        }
    }

    return {
        %{$channel},
        id           => $id,
        _id          => $id,
        name         => $channel->{name} || '',
        slug         => $channel->{slug} || '',
        number       => $channel->{number} || 0,
        logo_url     => pickLogoUrl($channel),
        stitchedPath => $stitchedPath,
    };
}

sub getBootQueryString {
    my ($region) = @_;
    $region ||= 'DE';
    my $regionData = $regions{$region} || $regions{'DE'};
    my $now = DateTime->now(time_zone => 'UTC');
    my $launchTime = $now->strftime('%Y-%m-%dT%H:%M:%S.000Z');
    my $clientTime = $now->strftime('%Y-%m-%dT%H:%M:%S.001Z');
    return join('&',
        "appName=$appName",
        "appVersion=$appVersion",
        "deviceVersion=$deviceVersion",
        "deviceModel=$deviceModel",
        "deviceMake=$deviceMake",
        "deviceType=$deviceType",
        "clientID=$deviceId",
        "clientModelNumber=$clientModelNumber",
        'serverSideAds=false',
        'drmCapabilities=widevine%3AL3',
        'blockingMode=',
        'notificationVersion=1',
        'appLaunchCount=0',
        'lastAppLaunchDate=' . uri_escape_utf8($launchTime),
        'clientTime=' . uri_escape_utf8($clientTime),
        'deviceLat=' . $regionData->{lat},
        'deviceLon=' . $regionData->{lon}
    );
}

sub getBootFromPlutoRaw {
    my ($region) = @_;
    $region ||= 'DE';
    my $url = 'https://boot.pluto.tv/v4/start?' . getBootQueryString($region);
    my $content = getFromUrl($url);
    return unless $content;
    my $parsed = try { parse_json($content) };
    return unless $parsed && ref($parsed) eq 'HASH';
    $parsed->{_fetchedAt} = time();
    return $parsed;
}

sub sessionNeedsRefresh {
    my ($session) = @_;
    return 1 unless $session && ref($session) eq 'HASH';
    return 1 unless $session->{sessionToken};
    my $fetchedAt = $session->{_fetchedAt} || 0;
    return 1 if (time() - $fetchedAt) >= $sessionRefreshInterval;
    return 0;
}

sub getBootFromPluto {
    my ($region, $forceRefresh) = @_;
    $region ||= 'DE';
    if (!$forceRefresh && exists $session_cache{$region} && !sessionNeedsRefresh($session_cache{$region})) {
        return $session_cache{$region};
    }
    my $fresh = getBootFromPlutoRaw($region);
    if ($fresh && $fresh->{sessionToken}) {
        $session_cache{$region} = $fresh;
        return $fresh;
    }
    return $session_cache{$region} if exists $session_cache{$region};
    return undef;
}

sub parseQueryString {
    my ($query) = @_;
    my %pairs;
    return %pairs unless defined $query && length $query;
    for my $part (split /&/, $query) {
        next unless length $part;
        my ($k, $v) = split /=/, $part, 2;
        $pairs{$k} = defined $v ? $v : '';
    }
    return %pairs;
}

sub buildQueryString {
    my (%pairs) = @_;
    return join('&', map { $_ . '=' . (defined $pairs{$_} ? $pairs{$_} : '') } grep { defined $_ && length $_ && defined $pairs{$_} } sort keys %pairs);
}

sub upgradeStitchedPathToV2 {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    $path =~ s{^/stitch/}{/v2/stitch/};
    return $path;
}

sub extractSessionId {
    my ($bootJson) = @_;
    return undef unless $bootJson;
    return $bootJson->{session}->{sessionID}
        || $bootJson->{sessionID}
        || $bootJson->{sessionId}
        || $bootJson->{sid};
}

sub buildStitchQuery {
    my ($bootJson, $region) = @_;
    $region ||= 'DE';
    return '' unless $bootJson;

    my $regionData = $regions{$region} || $regions{'DE'};
    my $sid = extractSessionId($bootJson) || '';
    my $jwt = $bootJson->{sessionToken} || '';

    my %pairs = (
        advertisingId         => '',
        appName               => $appName,
        appVersion            => $appVersion,
        app_name              => $appName,
        clientDeviceType      => 0,
        clientID              => $deviceId,
        clientModelNumber     => $clientModelNumber,
        country               => $region,
        deviceDNT             => 'false',
        deviceId              => $deviceId,
        deviceLat             => $regionData->{lat},
        deviceLon             => $regionData->{lon},
        deviceMake            => $deviceMake,
        deviceModel           => $deviceModel,
        deviceType            => $deviceType,
        deviceVersion         => $deviceVersion,
        marketingRegion       => $region,
        serverSideAds         => 'false',
        sessionID             => $sid,
        sid                   => $sid,
        userId                => '',
        jwt                   => $jwt,
        masterJWTPassthrough  => 'true',
        includeExtendedEvents => 'true',
        eventVOD              => 'false',
        profilesFromStream    => 'true',
    );

    return buildQueryString(%pairs);
}

sub parseAttributeList {
    my ($attrString) = @_;
    my %attrs;
    return %attrs unless defined $attrString;
    while ($attrString =~ /([A-Z0-9-]+)=((?:"[^"]*")|[^,]*)/g) {
        my ($k, $v) = ($1, $2);
        $v =~ s/^"//;
        $v =~ s/"$//;
        $attrs{$k} = $v;
    }
    return %attrs;
}

sub extractPlaybackUrls {
    my ($masterPlaylist, $masterUrl) = @_;
    my @lines = split /
?
/, ($masterPlaylist || '');
    my %audioGroups;
    my $bestBandwidth = -1;
    my ($bestVideoUrl, $bestAudioGroup);

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if ($line =~ /^#EXT-X-MEDIA:(.+)$/i) {
            my %attrs = parseAttributeList($1);
            next unless (($attrs{'TYPE'} || '') eq 'AUDIO');
            my $group = $attrs{'GROUP-ID'} || next;
            my $uri = $attrs{'URI'} || next;
            my $isDefault = (($attrs{'DEFAULT'} || '') =~ /^YES$/i) ? 1 : 0;
            my $name = $attrs{'NAME'} || '';
            my $lang = $attrs{'LANGUAGE'} || '';
            $audioGroups{$group} ||= [];
            push @{$audioGroups{$group}}, {
                uri => resolvePlaylistUrlPreserveQuery($masterUrl, $uri),
                default => $isDefault,
                name => $name,
                language => $lang,
            };
        }
    }

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        next unless $line =~ /^#EXT-X-STREAM-INF:(.+)$/i;
        my %attrs = parseAttributeList($1);
        my $bandwidth = int($attrs{'BANDWIDTH'} || 0);
        next unless $i + 1 <= $#lines;
        my $urlLine = $lines[$i + 1];
        next if !defined($urlLine) || $urlLine =~ /^#/ || $urlLine eq '';
        if ($bandwidth > $bestBandwidth) {
            $bestBandwidth = $bandwidth;
            $bestVideoUrl = resolvePlaylistUrlPreserveQuery($masterUrl, $urlLine);
            $bestAudioGroup = $attrs{'AUDIO'};
        }
    }

    my $bestAudioUrl;
    if ($bestAudioGroup && $audioGroups{$bestAudioGroup} && @{$audioGroups{$bestAudioGroup}}) {
        my ($default) = grep { $_->{default} } @{$audioGroups{$bestAudioGroup}};
        $default ||= $audioGroups{$bestAudioGroup}[0];
        $bestAudioUrl = $default->{uri};
    }

    return ($bestVideoUrl, $bestAudioUrl, $bestAudioGroup);
}

sub resolvePlaylistUrlPreserveQuery {
    my ($baseUrl, $value) = @_;
    return undef unless defined $value && length $value;
    return $value if $value =~ m{^data:}i;
    return URI->new_abs($value, $baseUrl)->as_string;
}

sub rewriteManifestAttributeLine {
    my ($line, $baseUrl) = @_;
    return $line unless defined $line && defined $baseUrl;
    $line =~ s{URI="([^"]+)"}{'URI="' . resolvePlaylistUrlPreserveQuery($baseUrl, $1) . '"'}eg;
    return $line;
}

sub rewriteManifestForClient {
    my ($manifest, $sourceUrl) = @_;
    return $manifest unless defined $manifest && defined $sourceUrl;
    my @lines = split /
?
/, $manifest;
    my @out;
    for my $line (@lines) {
        if ($line =~ /^#EXT-X-(?:KEY|MAP):/) {
            push @out, rewriteManifestAttributeLine($line, $sourceUrl);
            next;
        }
        if ($line =~ /^#/) {
            push @out, $line;
            next;
        }
        if (!length $line) {
            push @out, $line;
            next;
        }
        my $resolved = resolvePlaylistUrlPreserveQuery($sourceUrl, $line);
        if ($resolved =~ /\.m3u8(?:$|[?#])/i) {
            push @out, 'http://' . $hostIp . ':' . $port . '/proxy.m3u8?src=' . uri_escape_utf8($resolved);
        } else {
            push @out, $resolved;
        }
    }
    return join("
", @out) . "
";
}

sub getChannelJson {
    my ($region, $forceRefresh) = @_;
    $region ||= 'DE';
    my $boot = getBootFromPluto($region, $forceRefresh);
    my @channels;

    if ($boot && ref($boot->{EPG}) eq 'ARRAY' && @{ $boot->{EPG} } >= 10) {
        @channels = map { normalizeChannel($_) } @{ $boot->{EPG} };
        @channels = grep { $_ } @channels;
    }

    if (!@channels) {
        if ($boot && $boot->{servers} && $boot->{sessionToken}) {
            my $url = $channelsApiUrl . '?channelIds=&offset=0&limit=1000&sort=number%3Aasc';
            my $content = getFromUrl($url, token => $boot->{sessionToken});
            if ($content) {
                my $parsed = try { parse_json($content) };
                my $items = ref($parsed) eq 'HASH' ? ($parsed->{data} || $parsed->{channels} || []) : [];
                @channels = map { normalizeChannel($_) } @{ $items || [] };
                @channels = grep { $_ } @channels;
            }
        }
    }

    if (@channels) {
        @channels = sort { lc($a->{name} || '') cmp lc($b->{name} || '') } @channels;
        $channel_cache{$region} = [ @channels ];
        return @channels;
    }

    return @{ $channel_cache{$region} || [] };
}

sub buildDirectMasterUrl {
    my ($bootJson, $channelOrId, $region) = @_;
    return undef unless $bootJson && $bootJson->{servers} && $bootJson->{servers}->{stitcher};
    my $channelId;
    my $stitchedPath;
    if (ref($channelOrId) eq 'HASH') {
        $channelId = $channelOrId->{id} || $channelOrId->{_id};
        $stitchedPath = $channelOrId->{stitchedPath};
    } else {
        $channelId = $channelOrId;
    }
    return undef unless $channelId;
    $stitchedPath ||= "/stitch/hls/channel/$channelId/master.m3u8";
    $stitchedPath = upgradeStitchedPathToV2($stitchedPath);
    my $url = $stitchedPath =~ m{^https?://}
        ? $stitchedPath
        : $bootJson->{servers}->{stitcher} . $stitchedPath;
    my $query = buildStitchQuery($bootJson, $region);
    if ($query) {
        $url .= ($url =~ /\?/) ? '&' : '?';
        $url .= $query;
    }
    return $url;
}

sub buildMasterUrlCandidates {
    my ($bootJson, $channel, $channelId, $region) = @_;
    my @candidates;

    push @candidates, $master_url_cache{$channelId} if $master_url_cache{$channelId};

    if ($channel) {
        my $direct = buildDirectMasterUrl($bootJson, $channel, $region);
        push @candidates, $direct if $direct;

        if (($channel->{stitchedPath} || '') =~ m{/channel/([^/]+)/master\.m3u8$}) {
            my $id_in_path = $1;
            my $live_path = $channel->{stitchedPath};
            $live_path =~ s{/channel/[^/]+/master\.m3u8$}{/channel/${id_in_path}livestitch/master.m3u8};
            my $live = buildDirectMasterUrl($bootJson, { %$channel, stitchedPath => $live_path }, $region);
            push @candidates, $live if $live;
        }
    }

    my $fallback = buildDirectMasterUrl($bootJson, $channelId, $region);
    push @candidates, $fallback if $fallback;

    my $live_fallback = buildDirectMasterUrl(
        $bootJson,
        { id => $channelId, stitchedPath => "/stitch/hls/channel/${channelId}livestitch/master.m3u8" },
        $region,
    );
    push @candidates, $live_fallback if $live_fallback;

    my %seen;
    return grep { defined $_ && length $_ && !$seen{$_}++ } @candidates;
}

sub fetchMasterPlaylistForChannel {
    my ($bootJson, $channel, $channelId, $region) = @_;
    my @candidates = buildMasterUrlCandidates($bootJson, $channel, $channelId, $region);
    for my $masterUrl (@candidates) {
        my $master = getFromUrl($masterUrl, token => $bootJson->{sessionToken});
        next unless $master;
        $master_url_cache{$channelId} = $masterUrl;
        return ($masterUrl, $master);
    }
    return;
}

sub getChannelById {
    my ($channelId, $region) = @_;
    $region ||= 'DE';
    for my $channel (getChannelJson($region)) {
        return $channel if ($channel->{id} || '') eq $channelId;
    }
    return undef;
}

sub getMasterPlaylistForChannel {
    my ($channelId, $region, $forceRefresh) = @_;
    $region ||= 'DE';
    my $bootJson = getBootFromPluto($region, $forceRefresh);
    return unless $bootJson && $bootJson->{servers};
    my $channel = getChannelById($channelId, $region);
    my ($masterUrl, $master) = fetchMasterPlaylistForChannel($bootJson, $channel, $channelId, $region);
    return unless $masterUrl && $master;
    return ($bootJson, $channel, $masterUrl, $master);
}

sub getPlaylistUrlForChannel {
    my ($channelId, $region, $forceRefresh) = @_;
    $region ||= 'DE';
    my ($bootJson, $channel, $masterUrl, $master) = getMasterPlaylistForChannel($channelId, $region, $forceRefresh);
    return unless $bootJson && $master;
    my $playlistUrl = extractBestPlaylistUrl($master, $bootJson->{servers}->{stitcher}, $channelId, $masterUrl);
    return unless $playlistUrl;
    return ($bootJson, $channel, $masterUrl, $playlistUrl, $master);
}

sub getPlaybackUrlsForChannel {
    my ($channelId, $region, $forceRefresh) = @_;
    $region ||= 'DE';
    my ($bootJson, $channel, $masterUrl, $master) = getMasterPlaylistForChannel($channelId, $region, $forceRefresh);
    return unless $bootJson && $master;
    my ($videoUrl, $audioUrl, $audioGroup) = extractPlaybackUrls($master, $masterUrl);
    return ($bootJson, $channel, $masterUrl, $master, $videoUrl, $audioUrl, $audioGroup);
}

sub buildM3uLegacy {
    my ($session, @channels) = @_;
    my $m3u = "#EXTM3U
";
    my $activeRegion = $session && $session->{session} && $session->{session}->{activeRegion}
        ? lc($session->{session}->{activeRegion}) : 'de';
    my $channelNumber = 1000;
    for my $channel (@channels) {
        next unless ($channel->{number} || 0) > 0 && ($channel->{number} || 0) != 2000;
        my $logo = $channel->{logo_url} || '';
        my $name = $channel->{name};
        my $id = $channel->{id};
        $m3u .= '#EXTINF:-1 tvg-chno="' . $channelNumber . '" tvg-id="' . uri_escape_utf8($name) .
            '" tvg-name="' . $name . '" tvg-logo="' . $logo . '" group-title="PlutoTV",' . $name . "
";
        if ($useStreamlink) {
            my $url = 'https://pluto.tv/' . $activeRegion . '/live-tv/' . $channel->{slug};
            $m3u .= 'pipe://' . $streamlink . ' --stdout --quiet --default-stream best ' .
                '--hls-live-restart --url "' . $url . '"' . "
";
        } else {
            $m3u .= 'pipe://' . $ffmpeg . ' -loglevel fatal -threads 0 -nostdin -re ' .
                '-i "http://' . $hostIp . ':' . $port . '/master3u8?id=' . $id . '" ' .
                '-c copy -vcodec copy -acodec copy -mpegts_copyts 1 -f mpegts ' .
                '-tune zerolatency -mpegts_service_type advanced_codec_digital_hdtv ' .
                '-metadata service_name="' . $name . '" pipe:1' . "
";
        }
        $channelNumber++;
    }
    return $m3u;
}

sub buildM3uDirect {
    my (@channels) = @_;
    my $m3u = "#EXTM3U
";
    my $channelNumber = 1000;
    for my $channel (@channels) {
        next unless ($channel->{number} || 0) > 0 && ($channel->{number} || 0) != 2000;
        my $logo = $channel->{logo_url} || '';
        my $name = $channel->{name};
        my $id = $channel->{id};
        $m3u .= '#EXTINF:-1 tvg-chno="' . $channelNumber . '" tvg-id="' . uri_escape_utf8($name) .
            '" tvg-name="' . $name . '" tvg-logo="' . $logo . '" group-title="PlutoTV",' . $name . "
";
        $m3u .= 'http://' . $hostIp . ':' . $port . '/stream/' . $id . ".m3u8
";
        $channelNumber++;
    }
    return $m3u;
}

sub sendMasterAlias {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $channelId = $params && $params->{id} ? $params->{id} : undef;
    unless ($channelId) {
        $client->send_error(RC_BAD_REQUEST, "Missing id parameter");
        return;
    }
    my $fakeRequest = HTTP::Request->new(GET => "/stream/$channelId.m3u8");
    sendDirectStream($client, $fakeRequest);
}

sub sendHelp {
    my ($client, $request) = @_;
    my $response = HTTP::Response->new();
    $response->code(200);
    $response->message("OK");
    $response->content("Following endpoints are available:\n" .
        "\t/playlist?region=REGION\tfor full m3u8-file (legacy pipes)\n" .
        "\t/tvheadend?region=REGION\tfor direct streams (tvheadend optimized)\n" .
        "\t/stream/{id}.m3u8\tfor direct HLS stream\n" .
        "\t/master3u8?id=ID\tlegacy alias for ffmpeg pipe input\n" .
        "\t/epg\t\tfor xmltv-epg-file\n" .
        "\t/admin\t\tfor runtime configuration UI\n\n" .
        "Available regions: " . join(", ", sort keys %regions) . "\n" .
        "Example: /tvheadend?region=US\n");
    $client->send_response($response);
}

sub xmltvTimestampFromIso {
    my ($iso) = @_;
    return undef unless defined $iso && length $iso;
    if ($iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        return "$1$2$3$4$5$6 +0000";
    }
    return undef;
}

sub buildGuideStartIso {
    my $now = DateTime->now(time_zone => 'UTC');
    my $minute = $now->minute;
    my $roundedMinute = int($minute / 30) * 30;
    $now->set(minute => $roundedMinute, second => 0, nanosecond => 0);
    return $now->strftime('%Y-%m-%dT%H:%M:%S.000Z');
}

sub buildGuideUrl {
    my ($region, $channelIdsRef) = @_;
    $region ||= 'DE';
    my @channelIds = grep { defined $_ && length $_ } @{ $channelIdsRef || [] };
    return undef unless @channelIds;
    return $guideTimelinesApiUrl . '?start=' . uri_escape_utf8(buildGuideStartIso()) .
        '&channelIds=' . uri_escape_utf8(join(',', @channelIds)) .
        '&duration=' . $guideDurationMinutes;
}

sub extractGuideChannels {
    my ($parsed) = @_;
    return () unless $parsed;
    return @{ $parsed->{data} } if ref($parsed->{data}) eq 'ARRAY';
    return @{ $parsed } if ref($parsed) eq 'ARRAY';
    return @{ $parsed->{channels} } if ref($parsed->{channels}) eq 'ARRAY';
    return @{ $parsed->{guides} } if ref($parsed->{guides}) eq 'ARRAY';
    return @{ $parsed->{EPG} } if ref($parsed->{EPG}) eq 'ARRAY';
    return ();
}

sub getGuideChannelJson {
    my ($region) = @_;
    $region ||= 'DE';
    my $boot = getBootFromPluto($region);
    return () unless $boot && $boot->{sessionToken};

    my @channels = getChannelJson($region);
    my @channelIds = map { $_->{id} || $_->{_id} } grep { ($_->{id} || $_->{_id}) } @channels;
    return () unless @channelIds;

    my @guideChannels;
    while (@channelIds) {
        my @batch = splice(@channelIds, 0, $guideBatchSize);
        my $url = buildGuideUrl($region, \@batch);
        next unless $url;
        my $content = getFromUrl($url, token => $boot->{sessionToken});
        next unless $content;
        my $parsed = try { parse_json($content) };
        next unless $parsed;
        for my $entry (extractGuideChannels($parsed)) {
            next unless ref($entry) eq 'HASH';
            my $id = $entry->{channelId} || $entry->{id} || $entry->{_id};
            next unless $id;
            push @guideChannels, {
                id => $id,
                _id => $id,
                slug => $entry->{channelSlug} || '',
                timelines => (ref($entry->{timelines}) eq 'ARRAY' ? $entry->{timelines} : []),
            };
        }
    }

    return @guideChannels;
}

sub mergeChannelsWithGuide {
    my ($channelsRef, $guideChannelsRef) = @_;
    my %byId = map { (($_->{id} || $_->{_id}) => { %$_ }) } @{ $channelsRef || [] };
    for my $guide (@{ $guideChannelsRef || [] }) {
        my $id = $guide->{id} || $guide->{_id} || next;
        my $base = $byId{$id} || {};
        my %merged = (%$base, %$guide);
        $merged{id} = $id;
        $merged{_id} = $id;
        $merged{timelines} = $guide->{timelines} if ref($guide->{timelines}) eq 'ARRAY';
        $merged{logo_url} ||= pickLogoUrl(\%merged);
        $byId{$id} = \%merged;
    }
    return values %byId;
}


sub forceUtf8 {
    my ($value) = @_;
    return '' unless defined $value;
    return $value if ref($value);
    return $value if is_utf8($value);
    my $decoded = eval { decode_utf8($value, 1) };
    return defined($decoded) ? $decoded : $value;
}

sub xmlCdata {
    my ($value) = @_;
    $value = forceUtf8($value);
    $value =~ s/\]\]>/]]]]><![CDATA[>/g;
    return '<![CDATA[' . $value . ']]>';
}

sub sendXmltvEpgFile {
    my ($client, $request) = @_;
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};

    my @channels = getChannelJson($region);
    unless (@channels) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel list from pluto.tv-api.");
        return;
    }

    my @guideChannels = getGuideChannelJson($region);
    @channels = mergeChannelsWithGuide(\@channels, \@guideChannels) if @guideChannels;

    my $langcode = "de";
    my $epg = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<tv>\n";
    for my $channel (sort { ($a->{number} || 0) <=> ($b->{number} || 0) } @channels) {
        next unless ($channel->{number} || 0) > 0;
        my $channelName = forceUtf8($channel->{name} || "");
        my $channelId = uri_escape_utf8($channelName);
        $epg .= "<channel id=\"$channelId\">\n";
        $epg .= "<display-name lang=\"$langcode\"><![CDATA[$channelName]]></display-name>\n";
        if (my $logoPath = $channel->{logo_url}) {
            $logoPath = substr($logoPath, 0, index($logoPath, "?")) if index($logoPath, "?") >= 0;
            $epg .= "<icon src=\"$logoPath\" />\n";
        }
        $epg .= "</channel>\n";
    }

    for my $channel (sort { ($a->{number} || 0) <=> ($b->{number} || 0) } @channels) {
        next unless ($channel->{number} || 0) > 0;
        my $channelId = uri_escape_utf8(forceUtf8($channel->{name} || ""));
        for my $programme (@{ $channel->{timelines} || [] }) {
            my $start = xmltvTimestampFromIso($programme->{start});
            my $stop  = xmltvTimestampFromIso($programme->{stop});
            next unless $start && $stop;

            my $episode = $programme->{episode} || {};
            my $title = forceUtf8($programme->{title} || $episode->{name} || $channel->{name} || '');
            my $subtitle = forceUtf8($episode->{name} || '');
            my $desc = forceUtf8($episode->{description} || '');
            my $genre = forceUtf8($episode->{genre} || '');
            my $rating = forceUtf8($episode->{rating} || '');

            $epg .= "<programme start=\"$start\" stop=\"$stop\" channel=\"$channelId\">\n";
            $epg .= "<title lang=\"$langcode\"><![CDATA[$title]]></title>\n";
            $epg .= "<sub-title lang=\"$langcode\"><![CDATA[$subtitle]]></sub-title>\n" if length $subtitle;
            $epg .= "<desc lang=\"$langcode\"><![CDATA[$desc]]></desc>\n" if length $desc;
            $epg .= "<category lang=\"$langcode\"><![CDATA[$genre]]></category>\n" if length $genre;
            if (length $rating) {
                $epg .= "<rating><value>" . xmlCdata($rating) . "</value></rating>\n";
            }
            $epg .= "</programme>\n";
        }
    }

    $epg .= "\n</tv>\n";
    my $response = HTTP::Response->new();
    $response->header("content-type", "application/xml; charset=utf-8");
    $response->header("content-disposition", "filename=\"plutotv-epg.xml\"");
    $response->code(200);
    $response->message("OK");
    $response->content(encode_utf8($epg));
    $client->send_response($response);
}

sub sendM3uFile {
    my ($client, $useDirectStreams, $request) = @_;
    my $region = 'DE';
    if ($request) {
        my $params = try { HTTP::Request::Params->new({ req => $request })->params };
        $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};
    }
    my @channels = getChannelJson($region);
    unless (@channels) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel list from pluto.tv-api.");
        return;
    }
    my $session = getBootFromPluto($region);
    my $m3uContent = $useDirectStreams ? buildM3uDirect(@channels) : buildM3uLegacy($session, @channels);
    my $response = HTTP::Response->new();
    $response->header("content-type", "audio/x-mpegurl; charset=utf-8");
    $response->header("content-disposition", "filename=\"plutotv.m3u8\"");
    $response->code(200);
    $response->message("OK");
    $response->content(encode_utf8($m3uContent));
    $client->send_response($response);
}

sub sendDirectStream {
    my ($client, $request) = @_;
    my $path = $request->uri->path;
    my ($channelId) = $path =~ m{/stream/([^/]+)\.m3u8$};
    unless ($channelId) {
        $client->send_error(RC_BAD_REQUEST, "Invalid stream path");
        return;
    }
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};

    my (undef, undef, $masterUrl, $master) = getMasterPlaylistForChannel($channelId, $region, 1);
    unless ($master && $masterUrl) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream");
        return;
    }

    my $dynamicPlaylist = createDynamicPlaylist($master, $channelId, $masterUrl);
    my $response = HTTP::Response->new();
    $response->code(200);
    $response->message("OK");
    $response->header("content-type", "application/vnd.apple.mpegurl; charset=utf-8");
    $response->header("cache-control", "no-cache, no-store, must-revalidate");
    $response->header("pragma", "no-cache");
    $response->header("expires", "0");
    $response->content(encode_utf8($dynamicPlaylist));
    $client->send_response($response);
}
sub sendPlaylistProxy {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $src = $params && $params->{src} ? $params->{src} : undef;
    unless ($src) {
        $client->send_error(RC_BAD_REQUEST, "Missing src parameter");
        return;
    }
    my $content = getFromUrl($src);
    unless ($content) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch proxied playlist");
        return;
    }
    my $rewritten = rewriteManifestForClient($content, $src);
    my $response = HTTP::Response->new();
    $response->code(200);
    $response->message("OK");
    $response->header("content-type", "application/vnd.apple.mpegurl; charset=utf-8");
    $response->header("cache-control", "no-cache, no-store, must-revalidate");
    $response->header("pragma", "no-cache");
    $response->header("expires", "0");
    $response->content(encode_utf8($rewritten));
    $client->send_response($response);
}

sub createDynamicPlaylist {
    my ($masterPlaylist, $channelId, $baseUrl) = @_;
    my $injectDiscontinuity = consumeForcedDiscontinuity($channelId);
    my @lines = split /\r?\n/, $masterPlaylist;
    my $bestStreamUrl;
    my $bestBandwidth = 0;
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if ($line =~ /^#EXT-X-STREAM-INF:.*BANDWIDTH=(\d+)/i) {
            my $bandwidth = $1;
            if ($bandwidth > $bestBandwidth && $i + 1 <= $#lines) {
                my $urlLine = $lines[$i + 1];
                if ($urlLine && $urlLine !~ /^#/) {
                    $bestBandwidth = $bandwidth;
                    $bestStreamUrl = $urlLine;
                }
            }
        }
    }
    return $masterPlaylist unless $bestStreamUrl;
    unless ($bestStreamUrl =~ /^https?:\/\//) {
        $bestStreamUrl = resolvePlaylistUrlPreserveQuery($baseUrl, $bestStreamUrl);
    }
    my $dynamicPlaylist = "#EXTM3U\n";
    $dynamicPlaylist .= "#EXT-X-VERSION:3\n";
    $dynamicPlaylist .= "#EXT-X-TARGETDURATION:10\n";
    $dynamicPlaylist .= "#EXT-X-MEDIA-SEQUENCE:0\n";
    $dynamicPlaylist .= "#EXT-X-PLAYLIST-TYPE:EVENT\n";
    $dynamicPlaylist .= "#EXT-X-DISCONTINUITY\n" if $injectDiscontinuity;
    $dynamicPlaylist .= "#EXTINF:86400.0,\n";
    $dynamicPlaylist .= "http://$hostIp:$port/dynamic_stream/$channelId.ts\n";
    $dynamicPlaylist .= "#EXT-X-ENDLIST\n";
    return $dynamicPlaylist;
}

sub buildLocalChildStreamUrl {
    my ($channelId, $region, $kind) = @_;
    my $path = ($kind && $kind eq 'audio') ? 'dynamic_audio_stream' : 'dynamic_video_stream';
    my $url = 'http://' . $hostIp . ':' . $port . '/' . $path . '/' . $channelId . '.ts';
    $url .= '?region=' . uri_escape_utf8($region) if defined $region && length $region;
    return $url;
}

sub streamPlaylistToHandle {
    my ($fh, $channelId, $region, $playlistUrl, $kind) = @_;
    $region ||= 'DE';
    my $ua = createUserAgent();
    my %processedSegments = ();
    my %processedMaps = ();
    my $runningNumber = 1;
    my $lastRefreshAt = $playlistUrl ? time() : 0;
    my $consecutiveFailures = 0;

    while (1) {
        if (!$playlistUrl || (time() - $lastRefreshAt) >= $sessionRefreshInterval) {
            my (undef, undef, undef, undef, $videoUrl, $audioUrl) = getPlaybackUrlsForChannel($channelId, $region, 1);
            my $refreshedPlaylistUrl = ($kind && $kind eq 'audio') ? $audioUrl : $videoUrl;
            if ($refreshedPlaylistUrl) {
                $playlistUrl = $refreshedPlaylistUrl;
                $lastRefreshAt = time();
                if ($debug) {
                    printf("Refreshed %s session/playlist for %s\n", ($kind || 'video'), $channelId);
                }
            }
        }

        my $playlistResponse = getResponseFromUrl($playlistUrl, ua => $ua);
        my $playlistContent = $playlistResponse && $playlistResponse->is_success
            ? $playlistResponse->decoded_content
            : undef;
        unless ($playlistContent) {
            $consecutiveFailures++;
            if ($debug) {
                my $status = $playlistResponse ? $playlistResponse->status_line : 'no response';
                printf("Failed to fetch %s playlist for %s (attempt %d): %s\nURL: %s\n", ($kind || 'video'), $channelId, $consecutiveFailures, $status, ($playlistUrl || ''));
            }
            my (undef, undef, undef, undef, $videoUrl, $audioUrl) = getPlaybackUrlsForChannel($channelId, $region, 1);
            my $refreshedPlaylistUrl = ($kind && $kind eq 'audio') ? $audioUrl : $videoUrl;
            $playlistUrl = $refreshedPlaylistUrl if $refreshedPlaylistUrl;
            last if $consecutiveFailures >= 5;
            sleep(1);
            next;
        }
        $consecutiveFailures = 0;

        my $playlistInfo = parsePlaylistInfo($playlistContent);
        my @allSegments = extractSegmentsFromPlaylist($playlistContent, $playlistUrl, $playlistInfo, \$runningNumber);
        my @newSegments = filterNewSegments(\@allSegments, \%processedSegments);
        if ($debug && @allSegments == 0) {
            printf("No %s segments found for %s
Playlist URL: %s
", ($kind || 'video'), $channelId, ($playlistUrl || ''));
        }
        if (@newSegments == 0) {
            sleep(1);
            next;
        }
        if ($debug) {
            printf("Processing %d new %s segments for channel %s\n", scalar(@newSegments), ($kind || 'video'), $channelId);
        }
        my $streamOk = 1;
        for my $segment (@newSegments) {
            my $success = streamSegment($fh, $ua, $segment, $channelId . '-' . ($kind || 'video'), \%processedMaps);
            unless ($success) {
                if ($segment->{isDiscontinuity}) {
                    if ($debug) {
                        printf("Failed to stream %s discontinuity segment, refreshing playlist for %s\n", ($kind || 'video'), $channelId);
                    }
                    $lastRefreshAt = 0;
                    next;
                }
                $streamOk = 0;
                if ($debug) {
                    printf("Failed to stream %s segment, ending stream for %s\n", ($kind || 'video'), $channelId);
                }
                last;
            }
            $processedSegments{$segment->{url}} = time();
            $processedMaps{$segment->{mapUrl}} = 1 if $segment->{mapUrl};
        }
        last unless $streamOk;
        cleanupOldSegments(\%processedSegments);
        sleep(2);
    }

    return 1;
}

sub streamMuxedFromLocalChildStreams {
    my ($client, $channelId, $region, $videoUrl, $audioUrl, $headersSentRef, $activeStreamKey, $request) = @_;
    return 0 unless $ffmpeg;
    return 0 unless $videoUrl && $audioUrl;

    if (!$headersSentRef || !$$headersSentRef) {
        eval {
            $client->write("HTTP/1.1 200 OK
");
            $client->write("Content-Type: video/mp2t
");
            $client->write("Cache-Control: no-cache, no-store, must-revalidate
");
            $client->write("Connection: close
");
            $client->write("
");
        };
        if ($@) {
            printf("Failed to send headers - client disconnected: %s
", $@);
            return 0;
        }
        $$headersSentRef = 1 if $headersSentRef;
    }

    my $maxFailures = 5;
    my $failures = 0;

    while ($failures < $maxFailures) {
        updateActiveStream($activeStreamKey, mode => 'copy', desiredMode => desiredModeByOverride($channelId, $request)) if $activeStreamKey;

        if ($failures > 0) {
            if ($debug) {
                printf("Restarting mux for %s (attempt %d/%d)
", $channelId, $failures + 1, $maxFailures);
            }
            sleep(2);
            my (undef, undef, undef, undef, $freshVideo, $freshAudio) = getPlaybackUrlsForChannel($channelId, $region, 1);
            $videoUrl = $freshVideo if $freshVideo;
            $audioUrl = $freshAudio if $freshAudio;
        }

        my $tmpdir = tempdir('plutotv-mux-XXXXXX', TMPDIR => 1, CLEANUP => 1);
        my $videoFifo = "$tmpdir/video.ts";
        my $audioFifo = "$tmpdir/audio.ts";

        unless (mkfifo($videoFifo, 0700)) { warn "Failed to create video fifo: $!
"; $failures++; next; }
        unless (mkfifo($audioFifo, 0700)) { warn "Failed to create audio fifo: $!
"; unlink $videoFifo; $failures++; next; }

        if ($debug) { printf("Muxing separate video/audio for %s using FIFOs
", $channelId); }

        my @children;
        for my $spec (
            { kind => 'video', fifo => $videoFifo, url => $videoUrl },
            { kind => 'audio', fifo => $audioFifo, url => $audioUrl },
        ) {
            my $pid = fork();
            if (!defined $pid) { warn "Failed to fork $spec->{kind} worker: $!
"; next; }
            if ($pid == 0) {
                local $SIG{PIPE} = 'DEFAULT';
                open(my $fh, '>', $spec->{fifo}) or do { warn "Failed to open $spec->{kind} fifo for writing: $!
"; exit(1); };
                binmode($fh);
                eval { streamPlaylistToHandle($fh, $channelId, $region, $spec->{url}, $spec->{kind}); };
                close($fh);
                exit(0);
            }
            push @children, $pid;
        }

        my @cmd = (
            $ffmpeg, '-hide_banner', '-loglevel', 'warning', '-nostdin',
            '-thread_queue_size', '512', '-fflags', '+genpts+discardcorrupt', '-i', $videoFifo,
            '-thread_queue_size', '512', '-fflags', '+genpts+discardcorrupt', '-i', $audioFifo,
            '-map', '0:v:0', '-map', '1:a:0',
            '-c', 'copy',
            '-muxdelay', '0', '-muxpreload', '0',
            '-mpegts_flags', '+resend_headers',
            '-avoid_negative_ts', 'make_zero',
            '-max_interleave_delta', '1000000',
            '-flush_packets', '1',
            '-f', 'mpegts', 'pipe:1'
        );

        my $ffh;
        my $ffpid = open($ffh, '-|', @cmd);
        unless ($ffpid) {
            warn "Failed to start ffmpeg for muxing: $!
";
            for my $pid (@children) { kill 'TERM', $pid if $pid; }
            unlink $videoFifo; unlink $audioFifo;
            $failures++; next;
        }
        binmode($ffh);

        my $client_alive = 1;
        my $mode_switch_requested = 0;
        my $buffer = '';
        while (1) {
            if (desiredModeByOverride($channelId, $request) eq 'harmonize') {
                $mode_switch_requested = 1;
                last;
            }
            my $read = sysread($ffh, $buffer, 1316);
            last unless defined $read && $read > 0;
            my $ok = eval { $client->write($buffer); 1 };
            unless ($ok) { $client_alive = 0; last; }
        }

        if ($mode_switch_requested) {
            appendRecentLog('Live-Umschaltung auf harmonize: ' . $channelId);
            kill 'TERM', $ffpid if $ffpid;
        }
        close($ffh);

        for my $pid (@children) {
            kill 'TERM', $pid if $pid;
            waitpid($pid, 0);
        }
        unlink $videoFifo if -p $videoFifo || -e $videoFifo;
        unlink $audioFifo if -p $audioFifo || -e $audioFifo;

        return 'switch' if $mode_switch_requested;
        last unless $client_alive;
        $failures++;
    }

    return 1;
}

sub sendElementaryDynamicStream {
    my ($client, $request, $kind) = @_;
    my $path = $request->uri->path;
    my ($channelId) = $path =~ m{/dynamic_(?:video|audio)_stream/([^/]+)\.ts$};
    unless ($channelId) {
        $client->send_error(RC_BAD_REQUEST, "Invalid dynamic stream path");
        return;
    }
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};

    my (undef, undef, undef, undef, $videoUrl, $audioUrl) = getPlaybackUrlsForChannel($channelId, $region);
    my $playlistUrl = ($kind && $kind eq 'audio') ? $audioUrl : $videoUrl;
    unless ($playlistUrl) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch playlist URL");
        return;
    }
    streamWithDiscontinuityRestart($client, $channelId . '-' . ($kind || 'video'), $region, $playlistUrl);
}

our $selected_h264_encoder;
sub selectH264Encoder {
    return $selected_h264_encoder if defined $selected_h264_encoder;
    $selected_h264_encoder = 'libx264';
    return $selected_h264_encoder unless $ffmpeg;
    my $output = qx{$ffmpeg -hide_banner -encoders 2>/dev/null};
    if (defined $output && $output =~ /(?:^|\n)\s*[A-Z\.]+\s+h264_v4l2m2m\s/s) {
        $selected_h264_encoder = 'h264_v4l2m2m';
    }
    return $selected_h264_encoder;
}

sub collectPlaylistWindows {
    my ($playlistContent, $playlistUrl) = @_;
    my $playlistInfo = parsePlaylistInfo($playlistContent);
    my $running = 1;
    my @segments = extractSegmentsFromPlaylist($playlistContent, $playlistUrl, $playlistInfo, \$running);
    my @windows;
    my @current;
    my $windowIndex = 0;

    my $pushWindow = sub {
        my ($segmentsRef, $startsAfterDiscontinuity) = @_;
        return unless $segmentsRef && ref($segmentsRef) eq 'ARRAY' && @$segmentsRef;
        my $startSeq = $segmentsRef->[0]->{sequence};
        my $endSeq   = $segmentsRef->[-1]->{sequence};
        my $startUrl = $segmentsRef->[0]->{url} || '';
        my $endUrl   = $segmentsRef->[-1]->{url} || '';
        my $signature = join('|',
            defined $startSeq ? $startSeq : '',
            defined $endSeq   ? $endSeq   : '',
            $startUrl,
            $endUrl,
            scalar(@$segmentsRef),
        );
        push @windows, {
            id => $windowIndex++,
            signature => $signature,
            startSequence => $startSeq,
            endSequence => $endSeq,
            segments => [ @$segmentsRef ],
            startsAfterDiscontinuity => $startsAfterDiscontinuity ? 1 : 0,
        };
    };

    for my $segment (@segments) {
        if ($segment->{isDiscontinuity} && @current) {
            $pushWindow->(\@current, ($windowIndex > 0 ? 1 : 0));
            @current = ();
        }
        push @current, $segment;
    }

    $pushWindow->(\@current, ($windowIndex > 0 && @windows ? 1 : 0)) if @current;

    return \@windows;
}

sub buildLocalWindowPlaylistFile {
    my ($segments, $path) = @_;
    return 0 unless $segments && ref($segments) eq 'ARRAY' && @$segments;
    open(my $fh, '>:utf8', $path) or return 0;
    my $targetDuration = 1;
    my $lastKeyFingerprint = '';
    my $lastMapUrl = '';

    print {$fh} "#EXTM3U\n";
    print {$fh} "#EXT-X-VERSION:3\n";
    print {$fh} "#EXT-X-PLAYLIST-TYPE:VOD\n";
    print {$fh} "#EXT-X-MEDIA-SEQUENCE:0\n";

    for my $segment (@$segments) {
        my $dur = $segment->{duration} || 1;
        my $rounded = int($dur + 0.999999);
        $targetDuration = $rounded if $rounded > $targetDuration;
    }
    print {$fh} "#EXT-X-TARGETDURATION:$targetDuration\n";

    for my $segment (@$segments) {
        my $method = $segment->{method} || 'NONE';
        my $keyUri = $segment->{keyUri} || '';
        my $iv     = $segment->{iv} || '';
        my $finger = join('|', $method, $keyUri, $iv);
        if ($finger ne $lastKeyFingerprint) {
            if ($method eq 'AES-128' && $keyUri) {
                print {$fh} '#EXT-X-KEY:METHOD=AES-128,URI="' . $keyUri . '"';
                print {$fh} ',IV=0x' . $iv if length $iv;
                print {$fh} "\n";
            } else {
                print {$fh} "#EXT-X-KEY:METHOD=NONE\n";
            }
            $lastKeyFingerprint = $finger;
        }

        if (($segment->{mapUrl} || '') ne $lastMapUrl && $segment->{mapUrl}) {
            print {$fh} '#EXT-X-MAP:URI="' . $segment->{mapUrl} . '"' . "\n";
            $lastMapUrl = $segment->{mapUrl};
        }

        print {$fh} '#EXTINF:' . ($segment->{duration} || 1) . ",\n";
        print {$fh} $segment->{url} . "\n";
    }

    print {$fh} "#EXT-X-ENDLIST\n";
    close($fh);
    return 1;
}

sub findMatchingWindow {
    my ($windows, $processedWindowSignatures) = @_;
    return undef unless $windows && ref($windows) eq 'ARRAY';
    for my $window (@$windows) {
        next unless $window && ref($window) eq 'HASH';
        next unless ref($window->{segments}) eq 'ARRAY' && @{ $window->{segments} };
        my $signature = $window->{signature} || '';
        next if length($signature) && $processedWindowSignatures->{$signature};
        return $window;
    }
    return undef;
}

sub findBestAudioWindowForVideoWindow {
    my ($audioWindows, $videoWindow, $processedWindowSignatures) = @_;
    return undef unless $audioWindows && ref($audioWindows) eq 'ARRAY' && $videoWindow && ref($videoWindow) eq 'HASH';

    my $videoStart = $videoWindow->{startSequence};
    my $videoEnd   = $videoWindow->{endSequence};
    my ($best, $bestOverlap, $bestDistance);

    for my $window (@$audioWindows) {
        next unless $window && ref($window) eq 'HASH';
        next unless ref($window->{segments}) eq 'ARRAY' && @{ $window->{segments} };
        my $signature = $window->{signature} || '';
        next if length($signature) && $processedWindowSignatures->{$signature};

        my $start = $window->{startSequence};
        my $end   = $window->{endSequence};
        my $overlap = 0;
        if (defined $videoStart && defined $videoEnd && defined $start && defined $end) {
            my $left  = $videoStart > $start ? $videoStart : $start;
            my $right = $videoEnd   < $end   ? $videoEnd   : $end;
            $overlap = ($right >= $left) ? ($right - $left + 1) : 0;
        }

        my $distance = 0;
        $distance += abs(($start // 0) - ($videoStart // 0));
        $distance += abs(($end   // 0) - ($videoEnd   // 0));

        if (!defined($best)
            || $overlap > $bestOverlap
            || ($overlap == $bestOverlap && $distance < $bestDistance)) {
            $best = $window;
            $bestOverlap = $overlap;
            $bestDistance = $distance;
        }
    }

    return $best;
}

sub buildAudioSegmentSliceForVideoWindow {
    my ($audioContent, $audioUrl, $videoWindow) = @_;
    return [] unless $audioContent && $audioUrl && $videoWindow && ref($videoWindow) eq 'HASH';

    my $playlistInfo = parsePlaylistInfo($audioContent);
    my $running = 1;
    my @segments = extractSegmentsFromPlaylist($audioContent, $audioUrl, $playlistInfo, \$running);
    return [] unless @segments;

    my $videoStart = $videoWindow->{startSequence};
    my $videoEnd   = $videoWindow->{endSequence};
    my @matching;
    if (defined $videoStart && defined $videoEnd) {
        @matching = grep {
            defined($_->{sequence}) && $_->{sequence} >= $videoStart && $_->{sequence} <= $videoEnd
        } @segments;
    }
    return \@matching if @matching;

    my $wanted = scalar(@{ $videoWindow->{segments} || [] });
    $wanted = 1 if $wanted < 1;
    @matching = @segments[-$wanted .. -1] if @segments >= $wanted;
    @matching = @segments if @segments < $wanted;
    return \@matching;
}

sub buildReencodeFfmpegCommand {
    my (%args) = @_;
    my $encoder       = $args{encoder}       || 'libx264';
    my $videoPlaylist = $args{videoPlaylist} or return;
    my $audioPlaylist = $args{audioPlaylist};
    my $channelName   = $args{channelName}   || 'PlutoTV';
    my $hasAudio      = $args{hasAudio} ? 1 : 0;

    my @cmd = (
        $ffmpeg, '-hide_banner', '-loglevel', 'warning', '-nostdin',
        '-protocol_whitelist', 'file,http,https,tcp,tls,crypto,data',
        '-fflags', '+genpts+discardcorrupt',
        '-analyzeduration', '2000000',
        '-probesize', '2000000',
        '-i', $videoPlaylist,
    );

    if ($hasAudio) {
        push @cmd,
            '-protocol_whitelist', 'file,http,https,tcp,tls,crypto,data',
            '-fflags', '+genpts+discardcorrupt',
            '-analyzeduration', '2000000',
            '-probesize', '2000000',
            '-i', $audioPlaylist,
            '-map', '0:v:0', '-map', '1:a:0?';
    } else {
        push @cmd,
            '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
            '-map', '0:v:0', '-map', '1:a:0';
    }

    push @cmd,
        '-vf', 'scale=1280:720',
        '-pix_fmt', 'yuv420p',
        '-c:v', $encoder,
        ($encoder eq 'libx264' ? ('-preset', 'veryfast', '-tune', 'zerolatency') : ()),
        '-c:a', 'aac',
        '-ar', '48000',
        '-b:a', '160k',
        '-ac', '2',
        '-shortest',
        '-muxdelay', '0',
        '-muxpreload', '0',
        '-mpegts_flags', '+resend_headers',
        '-avoid_negative_ts', 'make_zero',
        '-flush_packets', '1',
        '-metadata', 'service_provider=PlutoTV',
        '-metadata', 'service_name=' . $channelName,
        '-f', 'mpegts', 'pipe:1';

    return @cmd;
}

sub shellQuote {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/'/'\\''/g;
    return "'" . $value . "'";
}

sub streamReencodedWindow {
    my (%args) = @_;
    my $client          = $args{client}          or return 0;
    my $channelId       = $args{channelId}       || 'unknown';
    my $channelName     = $args{channelName}     || $channelId;
    my $window          = $args{window}          or return 0;
    my $headersSentRef  = $args{headersSentRef};
    my $request         = $args{request};

    my $tmpdir = tempdir('plutotv-harmonize-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $videoPlaylist = "$tmpdir/video.m3u8";
    my $audioPlaylist = "$tmpdir/audio.m3u8";
    my $stderrFile    = "$tmpdir/ffmpeg.stderr.log";

    buildLocalWindowPlaylistFile($window->{videoSegments}, $videoPlaylist) or return 0;
    my $hasAudio = $window->{audioSegments} && ref($window->{audioSegments}) eq 'ARRAY' && @{ $window->{audioSegments} };
    buildLocalWindowPlaylistFile($window->{audioSegments}, $audioPlaylist) if $hasAudio;

    if (!$headersSentRef || !$$headersSentRef) {
        eval {
            $client->write("HTTP/1.1 200 OK
");
            $client->write("Content-Type: video/mp2t
");
            $client->write("Cache-Control: no-cache, no-store, must-revalidate
");
            $client->write("Connection: close

");
        };
        return 0 if $@;
        $$headersSentRef = 1 if $headersSentRef;
    }

    my @encoders = (selectH264Encoder());
    push @encoders, 'libx264' if $encoders[0] ne 'libx264';

    ENCODER:
    for my $encoder (@encoders) {
        unlink $stderrFile if -e $stderrFile;

        my @cmd = buildReencodeFfmpegCommand(
            encoder       => $encoder,
            videoPlaylist => $videoPlaylist,
            audioPlaylist => $audioPlaylist,
            hasAudio      => $hasAudio,
            channelName   => $channelName,
        );
        my $cmdline = join(' ', map { shellQuote($_) } @cmd)
            . ' 2> >(tee -a ' . shellQuote($stderrFile) . ' >&2)';

        my $ffh;
        my $ffpid = open($ffh, '-|', 'bash', '-lc', $cmdline);
        unless ($ffpid) {
            appendRecentLog('ffmpeg-Start fehlgeschlagen [' . $encoder . ']: ' . $channelId);
            next ENCODER;
        }
        binmode($ffh);

        my $client_alive = 1;
        my $buffer = '';
        my $sel = IO::Select->new($ffh);
        my $started_at = time();
        my $last_output_at = $started_at;
        my $stall_timeout = int(getConfigValue('stall_timeout', 15));
        my $startup_timeout = int(getConfigValue('startup_timeout', 45));
        $startup_timeout = $stall_timeout if $startup_timeout < $stall_timeout;
        my $firstChunk = 1;
        my $has_output = 0;
        my $aborted_for_timeout = 0;

        while (1) {
            my $desired = desiredModeByOverride($channelId, $request);
            if ($desired ne 'harmonize') {
                kill 'TERM', $ffpid;
                close($ffh);
                return 'switch';
            }

            my @ready = $sel->can_read(0.5);
            if (@ready) {
                my $read = sysread($ffh, $buffer, 1316);
                last unless defined $read && $read > 0;
                $last_output_at = time();
                $has_output = 1;
                $buffer = correctMpegTsTimestamps($buffer, $channelId, ($firstChunk && $window->{startsAfterDiscontinuity}) ? 1 : 0);
                $firstChunk = 0;
                my $ok = eval { $client->write($buffer); 1 };
                unless ($ok) {
                    $client_alive = 0;
                    last;
                }
                next;
            }

            my $child_done = waitpid($ffpid, WNOHANG);
            if (defined $child_done && $child_done == $ffpid) {
                last;
            }

            if (!$has_output) {
                if (time() - $started_at >= $startup_timeout) {
                    appendRecentLog('ffmpeg-Fenster-Starttimeout [' . $encoder . '], Neustart: ' . $channelId);
                    $aborted_for_timeout = 1;
                    kill 'TERM', $ffpid;
                    close($ffh);
                    last;
                }
                next;
            }

            if (time() - $last_output_at >= $stall_timeout) {
                appendRecentLog('ffmpeg-Fenster-Stall [' . $encoder . '], Neustart: ' . $channelId);
                $aborted_for_timeout = 1;
                kill 'TERM', $ffpid;
                close($ffh);
                last;
            }
        }

        close($ffh);

        if ($client_alive && $has_output) {
            return 1;
        }

        my $stderr = '';
        if (open(my $efh, '<', $stderrFile)) {
            local $/;
            $stderr = <$efh> // '';
            close($efh);
            $stderr =~ s/\s+/ /g;
            $stderr = substr($stderr, 0, 240);
        }

        if (!$has_output && $encoder ne 'libx264') {
            appendRecentLog('ffmpeg ohne Output [' . $encoder . '], Fallback auf libx264: ' . $channelId . ($stderr ? ' | ' . $stderr : ''));
            next ENCODER;
        }

        if ($stderr) {
            appendRecentLog('ffmpeg-Fehler [' . $encoder . ']: ' . $channelId . ' | ' . $stderr);
        }

        return 0 if $aborted_for_timeout;
        return ($client_alive && $has_output) ? 1 : 0;
    }

    return 0;
}

sub streamHlsViaFfmpeg {
    my ($client, $channelId, $region, $videoUrl, $audioUrl, $channelName, $headersSentRef, $activeStreamKey, $request) = @_;
    return 0 unless $ffmpeg;
    return 0 unless $videoUrl;

    my $ua = createUserAgent();
    my %processedVideoWindows;
    my %processedAudioWindows;
    my $idleLoops = 0;
    my $maxFailures = int(getConfigValue('max_failures', 5));
    my $failures = 0;

    while ($failures < $maxFailures) {
        updateActiveStream($activeStreamKey, mode => 'harmonize', desiredMode => desiredModeByOverride($channelId, $request)) if $activeStreamKey;

        my $videoResponse = getResponseFromUrl($videoUrl, ua => $ua);
        my $audioResponse = $audioUrl ? getResponseFromUrl($audioUrl, ua => $ua) : undef;
        my $videoContent = $videoResponse && $videoResponse->is_success ? $videoResponse->decoded_content : undef;
        my $audioContent = $audioResponse && $audioResponse->is_success ? $audioResponse->decoded_content : undef;

        if ($audioUrl && !$audioContent) {
            my $status = $audioResponse ? $audioResponse->status_line : 'no response';
            appendRecentLog('Audio-Playlist nicht lesbar: ' . $channelId . ' | ' . $status);
        }

        unless ($videoContent) {
            $failures++;
            my (undef, undef, undef, undef, $freshVideo, $freshAudio) = getPlaybackUrlsForChannel($channelId, $region, 1);
            $videoUrl = $freshVideo if $freshVideo;
            $audioUrl = $freshAudio if $freshAudio;
            sleep(1);
            next;
        }

        my $videoWindows = collectPlaylistWindows($videoContent, $videoUrl);
        my $audioWindows = $audioContent ? collectPlaylistWindows($audioContent, $audioUrl) : [];
        my $videoWindow  = findMatchingWindow($videoWindows, \%processedVideoWindows);

        unless ($videoWindow) {
            $idleLoops++;
            if ($idleLoops % 5 == 0) {
                appendRecentLog('Kein neues Harmonize-Fenster verfuegbar: ' . $channelId);
                my (undef, undef, undef, undef, $freshVideo, $freshAudio) = getPlaybackUrlsForChannel($channelId, $region, 1);
                $videoUrl = $freshVideo if $freshVideo;
                $audioUrl = $freshAudio if $freshAudio;
            }
            sleep(1);
            next;
        }
        $idleLoops = 0;

        my $audioWindow = $audioContent ? findBestAudioWindowForVideoWindow($audioWindows, $videoWindow, \%processedAudioWindows) : undef;
        my $audioSegments = [];
        my $audioLogLabel = ' audio=silent-fallback';
        if ($audioWindow && ref($audioWindow->{segments}) eq 'ARRAY' && @{ $audioWindow->{segments} }) {
            $audioSegments = $audioWindow->{segments};
            $audioLogLabel = ' a=' . ($audioWindow->{startSequence}//'?') . '-' . ($audioWindow->{endSequence}//'?')
                . ' aseg=' . scalar(@{ $audioWindow->{segments} || [] })
                . ' av-sync=window';
        } elsif ($audioContent && $audioUrl) {
            $audioSegments = buildAudioSegmentSliceForVideoWindow($audioContent, $audioUrl, $videoWindow);
            if ($audioSegments && ref($audioSegments) eq 'ARRAY' && @$audioSegments) {
                $audioLogLabel = ' aseg=' . scalar(@$audioSegments) . ' av-sync=slice';
            }
        }
        appendRecentLog('Harmonize-Fenster: ' . $channelId
            . ' v=' . ($videoWindow->{startSequence}//'?') . '-' . ($videoWindow->{endSequence}//'?')
            . ' seg=' . scalar(@{ $videoWindow->{segments} || [] })
            . $audioLogLabel);

        my %window = (
            id => $videoWindow->{id},
            videoSegments => $videoWindow->{segments},
            audioSegments => $audioSegments,
            startsAfterDiscontinuity => $videoWindow->{startsAfterDiscontinuity} ? 1 : 0,
        );

        my $result = streamReencodedWindow(
            client => $client,
            channelId => $channelId,
            channelName => ($channelName || $channelId),
            window => \%window,
            headersSentRef => $headersSentRef,
            request => $request,
        );

        return 'switch' if defined $result && $result eq 'switch';
        unless ($result) {
            $failures++;
            appendRecentLog('Harmonize-Fenster ohne Output beendet: ' . $channelId . ' (Versuch ' . $failures . '/' . $maxFailures . ')');
            my (undef, undef, undef, undef, $freshVideo, $freshAudio) = getPlaybackUrlsForChannel($channelId, $region, 1);
            $videoUrl = $freshVideo if $freshVideo;
            $audioUrl = $freshAudio if $freshAudio;
            next;
        }

        $processedVideoWindows{$videoWindow->{signature} || $videoWindow->{id}} = 1;
        $processedAudioWindows{$audioWindow->{signature} || $audioWindow->{id}} = 1 if $audioWindow;
        $failures = 0;
    }

    appendRecentLog('Harmonize-Stream nach Max-Fehlversuchen beendet: ' . $channelId);
    return 0;
}

sub shouldUseHlsHarmonizer {
    my ($channelId, $request) = @_;
    return 0 unless $ffmpeg;
    return desiredModeByOverride($channelId, $request) eq 'harmonize' ? 1 : 0;
}

sub sendDynamicStream {
    my ($client, $request) = @_;
    my $activeStreamKey;
    my $path = $request->uri->path;
    my ($channelId) = $path =~ m{/dynamic_stream/([^/]+)\.ts$};
    unless ($channelId) {
        $client->send_error(RC_BAD_REQUEST, "Invalid dynamic stream path");
        return;
    }
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};

    my (undef, $channel, undef, undef, $videoUrl, $audioUrl) = getPlaybackUrlsForChannel($channelId, $region);
    unless ($videoUrl) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch playlist URL");
        return;
    }

    my $headersSent = 0;
    my $mode = desiredModeByOverride($channelId, $request);
    $activeStreamKey = registerActiveStream(
        channelId => $channelId,
        channelName => ($channel ? ($channel->{name} || $channelId) : $channelId),
        mode => $mode,
        desiredMode => $mode,
    );
    appendRecentLog('Stream gestartet: ' . $channelId . ' [' . $mode . ']');

    # Local handlers ensure cleanup even on unexpected disconnect (SIGPIPE)
    # or admin-triggered restart (SIGTERM via restart_stream endpoint).
    my $cleanup = sub {
        unregisterActiveStream($activeStreamKey) if $activeStreamKey;
        appendRecentLog('Stream unterbrochen: ' . $channelId);
        exit(0);
    };
    local $SIG{PIPE} = $cleanup;
    local $SIG{TERM} = $cleanup;

    if ($debug) {
        printf("Dynamic stream mode for %s: %s\n", $channelId, $mode);
    }

    while (1) {
        $mode = desiredModeByOverride($channelId, $request);
        updateActiveStream($activeStreamKey, mode => $mode, desiredMode => $mode) if $activeStreamKey;

        my $result;
        if ($mode eq 'harmonize') {
            $result = streamHlsViaFfmpeg($client, $channelId, $region, $videoUrl, $audioUrl, ($channel ? $channel->{name} : undef), \$headersSent, $activeStreamKey, $request);
        } elsif ($audioUrl && $ffmpeg) {
            $result = streamMuxedFromLocalChildStreams($client, $channelId, $region, $videoUrl, $audioUrl, \$headersSent, $activeStreamKey, $request);
        } else {
            $result = streamWithDiscontinuityRestart($client, $channelId, $region, $videoUrl);
        }

        if (defined $result && $result eq 'switch') {
            my (undef, undef, undef, undef, $freshVideo, $freshAudio) = getPlaybackUrlsForChannel($channelId, $region, 1);
            $videoUrl = $freshVideo if $freshVideo;
            $audioUrl = $freshAudio if $freshAudio;
            next;
        }
        last;
    }

    unregisterActiveStream($activeStreamKey);
    appendRecentLog('Stream beendet: ' . $channelId);
}
sub extractBestPlaylistUrl {
    my ($masterPlaylist, $baseUrl, $channelId, $masterUrl) = @_;
    my @lines = split /
?
/, $masterPlaylist;
    my $bestStreamUrl;
    my $bestBandwidth = 0;
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if ($line =~ /^#EXT-X-STREAM-INF:.*BANDWIDTH=(\d+)/i) {
            my $bandwidth = $1;
            if ($bandwidth > $bestBandwidth && $i + 1 <= $#lines) {
                my $urlLine = $lines[$i + 1];
                if ($urlLine && $urlLine !~ /^#/) {
                    $bestBandwidth = $bandwidth;
                    $bestStreamUrl = $urlLine;
                }
            }
        }
    }
    return unless $bestStreamUrl;
    my $resolverBase = $masterUrl || $baseUrl;
    return resolvePlaylistUrl($resolverBase, $bestStreamUrl);
}
sub streamWithDiscontinuityRestart {
    my ($client, $channelId, $region, $playlistUrl) = @_;
    $region ||= 'DE';
    $client->timeout(5);
    eval {
        $client->write("HTTP/1.1 200 OK
");
        $client->write("Content-Type: video/mp2t
");
        $client->write("Cache-Control: no-cache, no-store, must-revalidate
");
        $client->write("Connection: close
");
        $client->write("
");
    };
    if ($@) {
        printf("Failed to send headers - client disconnected: %s
", $@);
        return;
    }
    my $ua = createUserAgent();
    my %processedSegments = ();
    my %processedMaps = ();
    my $runningNumber = 1;
    my $lastRefreshAt = $playlistUrl ? time() : 0;
    my $consecutiveFailures = 0;
    if ($debug) {
        printf("Starting stream for channel $channelId
");
    }
    while (1) {
        if (!$playlistUrl || (time() - $lastRefreshAt) >= $sessionRefreshInterval) {
            my (undef, undef, undef, $refreshedPlaylistUrl) = getPlaylistUrlForChannel($channelId, $region, 1);
            if ($refreshedPlaylistUrl) {
                $playlistUrl = $refreshedPlaylistUrl;
                $lastRefreshAt = time();
                if ($debug) {
                    printf("Refreshed session/playlist for %s
", $channelId);
                }
            }
        }

        my $playlistResponse = getResponseFromUrl($playlistUrl, ua => $ua);
        my $playlistContent = $playlistResponse && $playlistResponse->is_success
            ? $playlistResponse->decoded_content
            : undef;
        unless ($playlistContent) {
            $consecutiveFailures++;
            if ($debug) {
                my $status = $playlistResponse ? $playlistResponse->status_line : 'no response';
                printf("Failed to fetch playlist for %s (attempt %d): %s\nURL: %s
", $channelId, $consecutiveFailures, $status, $playlistUrl);
            }
            my (undef, undef, undef, $refreshedPlaylistUrl) = getPlaylistUrlForChannel($channelId, $region, 1);
            $playlistUrl = $refreshedPlaylistUrl if $refreshedPlaylistUrl;
            last if $consecutiveFailures >= 5;
            sleep(1);
            next;
        }
        $consecutiveFailures = 0;

        my $playlistInfo = parsePlaylistInfo($playlistContent);
        my @allSegments = extractSegmentsFromPlaylist($playlistContent, $playlistUrl, $playlistInfo, \$runningNumber);
        my @newSegments = filterNewSegments(\@allSegments, \%processedSegments);
        if ($debug && @allSegments == 0) {
            printf("No segments found for channel %s
Playlist URL: %s
", $channelId, ($playlistUrl || ''));
        }
        if (@newSegments == 0) {
            sleep(1);
            next;
        }
        if ($debug) {
            printf("Processing %d new segments for channel %s
", scalar(@newSegments), $channelId);
        }
        my $streamOk = 1;
        for my $segment (@newSegments) {
            if ($segment->{isDiscontinuity} && $segment->{mapUrl}) {
                delete $processedMaps{$segment->{mapUrl}};
            }
            my $success = streamSegment($client, $ua, $segment, $channelId, \%processedMaps);
            unless ($success) {
                if ($segment->{isDiscontinuity}) {
                    if ($debug) {
                        printf("Failed to stream discontinuity segment, refreshing playlist for %s\n", $channelId);
                    }
                    $lastRefreshAt = 0;
                    next;
                }
                $streamOk = 0;
                if ($debug) {
                    printf("Failed to stream segment, ending stream for %s\n", $channelId);
                }
                last;
            }
            $processedSegments{$segment->{url}} = time();
            $processedMaps{$segment->{mapUrl}} = 1 if $segment->{mapUrl};
        }
        last unless $streamOk;
        cleanupOldSegments(\%processedSegments);
        sleep(2);
    }
}
sub parsePlaylistInfo {
    my ($playlistContent) = @_;
    my @lines = split /\r?\n/, $playlistContent;
    my %info = (
        mediaSequence => 0,
        hasDiscontinuity => 0,
        targetDuration => 10,
    );
    for my $line (@lines) {
        if ($line =~ /^#EXT-X-MEDIA-SEQUENCE:(\d+)/) {
            $info{mediaSequence} = $1;
        }
        elsif ($line =~ /^#EXT-X-TARGETDURATION:(\d+)/) {
            $info{targetDuration} = $1;
        }
        elsif ($line =~ /^#EXT-X-DISCONTINUITY$/) {
            $info{hasDiscontinuity} = 1;
        }
    }
    return \%info;
}

sub resolvePlaylistUrl {
    my ($baseUrl, $value) = @_;
    return undef unless defined $value && length $value;
    return $value if $value =~ m{^(?:https?://|data:)}i;
    return URI->new_abs($value, $baseUrl)->as_string;
}

sub extractSegmentsFromPlaylist {
    my ($playlistContent, $baseUrl, $playlistInfo, $runningNumberRef) = @_;
    my @lines = split /\r?\n/, $playlistContent;
    my @segments = ();
    my %currentSegment;
    my $sequenceNumber = $playlistInfo->{mediaSequence} || 0;
    my $inDiscontinuityBlock = 0;
    my %currentKey = (method => 'NONE');
    my $currentMapUrl;

    $$runningNumberRef = 1;

    for my $line (@lines) {
        if ($line =~ /^#EXT-X-DISCONTINUITY$/) {
            $inDiscontinuityBlock = 1;
        }
        elsif ($line =~ /^#EXT-X-MAP:(.+)$/) {
            my $attrString = $1;
            my %attrs;
            while ($attrString =~ /([A-Z0-9-]+)=((?:"[^"]*")|[^,]*)/g) {
                my ($k, $v) = ($1, $2);
                $v =~ s/^"//;
                $v =~ s/"$//;
                $attrs{$k} = $v;
            }
            $currentMapUrl = resolvePlaylistUrlPreserveQuery($baseUrl, $attrs{URI}) if $attrs{URI};
        }
        elsif ($line =~ /^#EXT-X-KEY:(.+)$/) {
            my $attrString = $1;
            my %attrs;
            while ($attrString =~ /([A-Z0-9-]+)=((?:"[^"]*")|[^,]*)/g) {
                my ($k, $v) = ($1, $2);
                $v =~ s/^"//;
                $v =~ s/"$//;
                $attrs{$k} = $v;
            }
            my $method = $attrs{METHOD} || 'NONE';
            if ($method eq 'NONE') {
                %currentKey = (method => 'NONE');
            } else {
                %currentKey = (
                    method => $method,
                    keyUri => resolvePlaylistUrlPreserveQuery($baseUrl, $attrs{URI}),
                    iv     => $attrs{IV},
                );
                $currentKey{iv} =~ s/^0x//i if defined $currentKey{iv};
            }
        }
        elsif ($line =~ /^#EXTINF:([0-9.]+),/) {
            $currentSegment{duration} = $1;
        }
        elsif ($line !~ /^#/ && length $line) {
            next unless exists $currentSegment{duration} || $currentMapUrl;
            $currentSegment{url} = resolvePlaylistUrlPreserveQuery($baseUrl, $line);
            $currentSegment{sequence} = $sequenceNumber;
            $currentSegment{running} = $$runningNumberRef;
            $currentSegment{isDiscontinuity} = $inDiscontinuityBlock;
            $currentSegment{mapUrl} = $currentMapUrl if $currentMapUrl;
            $currentSegment{container} = ($currentSegment{url} =~ /\.m4s(?:\?.*)?$/i) ? 'fmp4' : 'ts';
            $currentSegment{method} = $currentKey{method} || 'NONE';
            if (($currentKey{method} || 'NONE') eq 'AES-128' && $currentKey{keyUri}) {
                $currentSegment{keyUri} = $currentKey{keyUri};
                $currentSegment{iv} = defined $currentKey{iv} && length $currentKey{iv}
                    ? $currentKey{iv}
                    : sprintf('%032x', $sequenceNumber);
            }
            push @segments, { %currentSegment };
            %currentSegment = ();
            $inDiscontinuityBlock = 0;
            $sequenceNumber++;
            $$runningNumberRef++;
            if ($$runningNumberRef > 1000000) {
                $$runningNumberRef = 1;
            }
        }
    }
    @segments = sortByRunningNumber(@segments);
    return @segments;
}
sub filterNewSegments {
    my ($segments, $processedSegmentsRef) = @_;
    my @newSegments;
    for my $segment (@$segments) {
        next if exists $processedSegmentsRef->{$segment->{url}};
        push @newSegments, $segment;
    }
    return sortByRunningNumber(@newSegments);
}

sub decodeDataUri {
    my ($uri) = @_;
    return undef unless defined $uri && $uri =~ m{^data:}i;
    my ($meta, $payload) = split /,/, $uri, 2;
    return undef unless defined $payload;
    if ($meta =~ /;base64/i) {
        return decode_base64($payload);
    }
    $payload =~ s/\+/ /g;
    return uri_unescape($payload);
}

sub streamSegment {
    my ($client, $ua, $segment, $channelId, $processedMapsRef) = @_;
    $processedMapsRef ||= {};
    my $is_discontinuity = $segment->{isDiscontinuity} || 0;

    if ($segment->{mapUrl} && !$processedMapsRef->{$segment->{mapUrl}}) {
        my $mapPayload;
        if ($segment->{mapUrl} =~ m{^data:}i) {
            $mapPayload = decodeDataUri($segment->{mapUrl});
            unless (defined $mapPayload) {
                if ($debug) {
                    printf("Failed to decode init data URI for %s
", $channelId);
                }
                return 0;
            }
        } else {
            my $mapReq = HTTP::Request->new(GET => $segment->{mapUrl});
            my $mapRes = $ua->request($mapReq);
            unless ($mapRes->is_success) {
                if ($debug) {
                    printf("Failed to fetch init segment %s: %s
", $segment->{mapUrl}, $mapRes->status_line);
                }
                return 0;
            }
            $mapPayload = $mapRes->content;
        }
        eval {
            print $client $mapPayload;
            $client->flush();
        };
        if ($@) {
            printf("Failed to send init segment to client: %s
", $@);
            return 0;
        }
        $processedMapsRef->{$segment->{mapUrl}} = 1;
    }

    my $req = HTTP::Request->new(GET => $segment->{url});
    my $res = $ua->request($req);
    unless ($res->is_success) {
        if ($debug) {
            printf("Failed to fetch segment %s: %s
", $segment->{url}, $res->status_line);
        }
        return 0;
    }

    my $chunk = $res->content;
    my $decryptedData = $chunk;

    if (($segment->{keyUri} || '') ne '' && ($segment->{method} || 'NONE') eq 'AES-128') {
        my $keyRes = $ua->get($segment->{keyUri});
        unless ($keyRes->is_success) {
            if ($debug) {
                printf("Failed to fetch key %s: %s
", $segment->{keyUri}, $keyRes->status_line);
            }
            return 0;
        }
        my $encryptionKey = $keyRes->content;
        if (length($encryptionKey) != 16) {
            if ($debug) {
                printf("Invalid key length: %d bytes (expected 16)
", length($encryptionKey));
            }
            return 0;
        }

        my $iv = $segment->{iv};
        $iv = sprintf('%032x', $segment->{sequence} || 0) unless defined $iv && length $iv;
        my $hexKey = unpack('H*', $encryptionKey);

        if (which('openssl')) {
            my $opensslStderr = '';
            my $ok = eval {
                run(
                    ["openssl", "aes-128-cbc", "-d", "-in", "-", "-out", "-", "-K", $hexKey, "-iv", $iv],
                    "<", \$chunk,
                    ">", \$decryptedData,
                    "2>", \$opensslStderr
                );
                1;
            };
            unless ($ok && defined $decryptedData && length $decryptedData) {
                if ($debug) {
                    printf("OpenSSL decrypt failed for %s%s
", $segment->{url}, length($opensslStderr) ? ": $opensslStderr" : '');
                }
                return 0;
            }
        } else {
            my $ivBin = pack 'H*', $iv;
            my $cipher = Crypt::CBC->new(
                -key     => $encryptionKey,
                -cipher  => 'Rijndael',
                -iv      => $ivBin,
                -header  => 'none',
                -padding => 'standard',
            );
            $decryptedData = $cipher->decrypt($chunk);
        }
    }

    my $payload = $decryptedData;
    my $isTsPayload = ($segment->{container} || 'ts') eq 'ts';
    if (length($decryptedData) > 0) {
        my $firstByte = unpack('C', substr($decryptedData, 0, 1));
        if ($firstByte != 0x47) {
            $isTsPayload = 0;
            if ($debug) {
                printf("Info: Non-TS segment detected (first byte 0x%02X) for %s
", $firstByte, $segment->{url});
            }
        }
    }
    if ($isTsPayload) {
        $payload = correctMpegTsTimestamps($decryptedData, $channelId, $is_discontinuity);
    }

    eval {
        print $client $payload;
        $client->flush();
    };
    if ($@) {
        printf("Failed to send data to client: %s
", $@);
        return 0;
    }
    return 1;
}
sub correctMpegTsTimestamps {
    my ($data, $channelId, $is_discontinuity) = @_;
    unless (exists $channel_timestamps{$channelId}) {
        $channel_timestamps{$channelId} = {
            last_pcr => undef,
            last_pts => undef,
            last_dts => undef,
            pcr_offset => 0,
            pts_offset => 0,
            dts_offset => 0,
            cc_counters => {},
            discontinuity_reset => 0,
            pcr_calculated => 0,
            pts_calculated => 0,
            dts_calculated => 0
        };
    }
    my $ts_info = $channel_timestamps{$channelId};
    if ($is_discontinuity) {
        if ($debug) {
            printf("DISCONTINUITY detected for channel %s\n", $channelId);
        }
        $ts_info->{discontinuity_reset} = 1;
        $ts_info->{pending_discontinuity_indicator} = 1;
        $ts_info->{pcr_calculated} = 0;
        $ts_info->{pts_calculated} = 0;
        $ts_info->{dts_calculated} = 0;
        $ts_info->{cc_counters} = {};
    }
    my $output = '';
    my $packet_size = 188;
    my $data_length = length($data);
    for (my $pos = 0; $pos < $data_length; $pos += $packet_size) {
        my $packet_data = substr($data, $pos, $packet_size);
        last if length($packet_data) < $packet_size;
        my $sync_byte = unpack('C', substr($packet_data, 0, 1));
        if ($sync_byte != 0x47) {
            my $found_sync = 0;
            for (my $i = 1; $i < $packet_size && ($pos + $i) < $data_length; $i++) {
                my $test_byte = unpack('C', substr($data, $pos + $i, 1));
                if ($test_byte == 0x47) {
                    $pos += $i - $packet_size;
                    $found_sync = 1;
                    last;
                }
            }
            next unless $found_sync;
        }
        $packet_data = correctContinuityCounter($packet_data, $ts_info);
        $packet_data = processTimestampsInPacket($packet_data, $ts_info);
        $output .= $packet_data;
    }
    return $output;
}

sub correctContinuityCounter {
    my ($packet_data, $ts_info) = @_;
    my @header = unpack('C4', substr($packet_data, 0, 4));
    my $pid = (($header[1] & 0x1F) << 8) | $header[2];
    unless (exists $ts_info->{cc_counters}->{$pid}) {
        $ts_info->{cc_counters}->{$pid} = -1;
    }
    my $cc = ($ts_info->{cc_counters}->{$pid} + 1) % 16;
    my $header_byte_4 = $header[3];
    my $adaptation_control = $header_byte_4 & 0x30;
    my $corrected_header_byte_4 = $adaptation_control | $cc;
    substr($packet_data, 3, 1) = pack('C', $corrected_header_byte_4);
    $ts_info->{cc_counters}->{$pid} = $cc;
    return $packet_data;
}

sub markDiscontinuityIndicator {
    my ($packet_data, $offset, $adaptation_length, $ts_info) = @_;
    return $packet_data unless $ts_info->{pending_discontinuity_indicator};
    return $packet_data unless $adaptation_length && $adaptation_length >= 1;
    my $flags = unpack('C', substr($packet_data, $offset, 1));
    $flags |= 0x80;
    substr($packet_data, $offset, 1) = pack('C', $flags);
    $ts_info->{pending_discontinuity_indicator} = 0;
    return $packet_data;
}

sub processTimestampsInPacket {
    my ($packet_data, $ts_info) = @_;
    my $pos = 4;
    my @header = unpack('C4', substr($packet_data, 0, 4));
    my $payload_start = ($header[1] & 0x40) >> 6;
    my $adaptation_field = ($header[3] & 0x30) >> 4;
    if ($adaptation_field == 2 || $adaptation_field == 3) {
        my $adaptation_length = unpack('C', substr($packet_data, $pos, 1));
        $pos++;
        if ($adaptation_length > 0) {
            $packet_data = markDiscontinuityIndicator($packet_data, $pos, $adaptation_length, $ts_info);
            $packet_data = processPcr($packet_data, $pos, $adaptation_length, $ts_info);
        }
        $pos += $adaptation_length;
    }
    if (($adaptation_field == 1 || $adaptation_field == 3) && $payload_start && $pos < 188) {
        $packet_data = processPesTimestamps($packet_data, $pos, $ts_info);
    }
    return $packet_data;
}

sub processPcr {
    my ($packet_data, $offset, $adaptation_length, $ts_info) = @_;
    my $pcr_ext;
    return $packet_data if $adaptation_length < 1;
    my $flags = unpack('C', substr($packet_data, $offset, 1));
    my $pcr_flag = ($flags & 0x10) >> 4;
    if ($pcr_flag && $adaptation_length >= 6) {
        my @pcr_bytes = unpack('C6', substr($packet_data, $offset + 1, 6));
        my $pcr_base = ($pcr_bytes[0] << 25) | ($pcr_bytes[1] << 17) |
            ($pcr_bytes[2] << 9) | ($pcr_bytes[3] << 1) |
            (($pcr_bytes[4] & 0x80) >> 7);
        $pcr_ext = (($pcr_bytes[4] & 0x01) << 8) | $pcr_bytes[5];

        if ($ts_info->{discontinuity_reset} && !$ts_info->{pcr_calculated} && defined $ts_info->{last_pcr}) {
            # +9000 ticks = 100ms at 90kHz: ensures PCR moves forward, never stagnates
            $ts_info->{pcr_offset} = $ts_info->{last_pcr} + 9000 - $pcr_base;
            $ts_info->{pcr_calculated} = 1;
            $ts_info->{discontinuity_reset} = 0;
        }
        my $corrected_pcr_base = $pcr_base + $ts_info->{pcr_offset};

        $ts_info->{last_pcr} = $corrected_pcr_base;
        $corrected_pcr_base = $corrected_pcr_base & (2**33 - 1);
        $pcr_bytes[0] = ($corrected_pcr_base >> 25) & 0xFF;
        $pcr_bytes[1] = ($corrected_pcr_base >> 17) & 0xFF;
        $pcr_bytes[2] = ($corrected_pcr_base >> 9) & 0xFF;
        $pcr_bytes[3] = ($corrected_pcr_base >> 1) & 0xFF;
        $pcr_bytes[4] = (($corrected_pcr_base & 0x01) << 7) | (($pcr_ext >> 8) & 0x01);
        $pcr_bytes[5] = $pcr_ext & 0xFF;
        substr($packet_data, $offset + 1, 6) = pack('C6', @pcr_bytes);
    }
    return $packet_data;
}

sub processPesTimestamps {
    my ($packet_data, $offset, $ts_info) = @_;
    return $packet_data if $offset + 9 >= 188;
    my @pes_start = unpack('C3', substr($packet_data, $offset, 3));
    return $packet_data unless ($pes_start[0] == 0x00 && $pes_start[1] == 0x00 && $pes_start[2] == 0x01);
    my $stream_id = unpack('C', substr($packet_data, $offset + 3, 1));
    return $packet_data unless (($stream_id >= 0xC0 && $stream_id <= 0xDF) ||
        ($stream_id >= 0xE0 && $stream_id <= 0xEF));
    return $packet_data if $offset + 8 >= 188;
    my $pes_flags = unpack('C', substr($packet_data, $offset + 7, 1));
    my $pts_dts_flags = ($pes_flags & 0xC0) >> 6;
    my $header_length = unpack('C', substr($packet_data, $offset + 8, 1));
    return $packet_data unless $pts_dts_flags > 0;
    return $packet_data if $offset + 9 + $header_length >= 188;
    my $pts_offset = $offset + 9;
    if ($pts_dts_flags >= 2 && $pts_offset + 4 < 188) {
        $packet_data = correctPts($packet_data, $pts_offset, $ts_info);
    }
    if ($pts_dts_flags == 3 && $pts_offset + 9 < 188) {
        $packet_data = correctDts($packet_data, $pts_offset + 5, $ts_info);
    }
    return $packet_data;
}

sub correctPts {
    my ($packet_data, $pts_offset, $ts_info) = @_;
    my @pts_bytes = unpack('C5', substr($packet_data, $pts_offset, 5));
    my $pts = (($pts_bytes[0] & 0x0E) << 29) | ($pts_bytes[1] << 22) |
        (($pts_bytes[2] & 0xFE) << 14) | ($pts_bytes[3] << 7) |
        (($pts_bytes[4] & 0xFE) >> 1);

    my $corrected_pts = $pts;
    if (defined $ts_info->{pcr_offset}) {
        $corrected_pts = $pts + $ts_info->{pcr_offset};
    }

    $ts_info->{last_pts} = $corrected_pts;
    $corrected_pts = $corrected_pts & (2**33 - 1);
    $pts_bytes[0] = ($pts_bytes[0] & 0xF1) | (($corrected_pts >> 29) & 0x0E);
    $pts_bytes[1] = ($corrected_pts >> 22) & 0xFF;
    $pts_bytes[2] = (($corrected_pts >> 14) & 0xFE) | 0x01;
    $pts_bytes[3] = ($corrected_pts >> 7) & 0xFF;
    $pts_bytes[4] = (($corrected_pts << 1) & 0xFE) | 0x01;
    substr($packet_data, $pts_offset, 5) = pack('C5', @pts_bytes);
    return $packet_data;
}

sub correctDts {
    my ($packet_data, $dts_offset, $ts_info) = @_;
    my @dts_bytes = unpack('C5', substr($packet_data, $dts_offset, 5));
    my $dts = (($dts_bytes[0] & 0x0E) << 29) | ($dts_bytes[1] << 22) |
        (($dts_bytes[2] & 0xFE) << 14) | ($dts_bytes[3] << 7) |
        (($dts_bytes[4] & 0xFE) >> 1);

    my $corrected_dts = $dts;
    if (defined $ts_info->{pcr_offset}) {
        $corrected_dts = $dts + $ts_info->{pcr_offset};
    }

    $ts_info->{last_dts} = $corrected_dts;
    $corrected_dts = $corrected_dts & (2**33 - 1);
    $dts_bytes[0] = ($dts_bytes[0] & 0xF1) | (($corrected_dts >> 29) & 0x0E);
    $dts_bytes[1] = ($corrected_dts >> 22) & 0xFF;
    $dts_bytes[2] = (($corrected_dts >> 14) & 0xFE) | 0x01;
    $dts_bytes[3] = ($corrected_dts >> 7) & 0xFF;
    $dts_bytes[4] = (($corrected_dts << 1) & 0xFE) | 0x01;
    substr($packet_data, $dts_offset, 5) = pack('C5', @dts_bytes);
    return $packet_data;
}

sub cleanupOldSegments {
    my ($processedSegmentsRef) = @_;
    my $now = time();
    my $cutoffTime = $now - (15 * 60);
    my $removedCount = 0;
    for my $url (keys %$processedSegmentsRef) {
        my $segmentTime = $processedSegmentsRef->{$url};
        if ($segmentTime < $cutoffTime) {
            delete $processedSegmentsRef->{$url};
            $removedCount++;
        }
    }
    if ($debug && $removedCount > 0) {
        printf("Removed %d old segments.\n", $removedCount);
    }
}


sub findChannelMetaById {
    my ($channelId, $region) = @_;
    $region ||= 'DE';
    for my $channel (getChannelJson($region)) {
        return $channel if ($channel->{id} || '') eq $channelId;
    }
    return undef;
}

sub sendAdminPage {
    my ($client, $request) = @_;
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};
    my $snapshot     = buildAdminSnapshot($region);
    my $snapshotJson = encode_json($snapshot);

    my $regionOptions = '';
    for my $r (sort keys %regions) {
        my $sel = ($r eq $region) ? ' selected' : '';
        $regionOptions .= "<option value=\"$r\"$sel>$r</option>\n";
    }

    my $html = <<'HTML';
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>PlutoTV Admin</title>
    <style>
        *{box-sizing:border-box}body{margin:0;font-family:system-ui,Arial,sans-serif;background:#f3f4f6;color:#111827}
        header{display:flex;align-items:center;gap:12px;padding:16px 20px;background:#111827;color:#fff;flex-wrap:wrap}
        header h1{font-size:18px;margin:0}.region-sel,.search{padding:8px 10px;border-radius:8px;border:1px solid #cbd5e1;font:inherit}
        main{max-width:1400px;margin:0 auto;padding:20px;display:grid;gap:18px}
        .card{background:#fff;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden}
        .card-head{padding:12px 16px;border-bottom:1px solid #e5e7eb;display:flex;align-items:center;gap:12px}
        .card-head h2{margin:0;font-size:14px}.card-body{padding:16px}
        .grid-top{display:grid;grid-template-columns:1.25fr .9fr;gap:18px}
        table{width:100%;border-collapse:collapse}th,td{padding:10px 8px;border-bottom:1px solid #f1f5f9;text-align:left;vertical-align:middle}
        th{font-size:12px;color:#64748b;text-transform:uppercase;letter-spacing:.04em}
        .badge{display:inline-block;padding:3px 8px;border-radius:999px;font-size:11px;font-weight:700}
        .badge-on{background:#dcfce7;color:#166534}.badge-off{background:#fee2e2;color:#991b1b}.badge-env{background:#e0f2fe;color:#075985}.badge-persisted{background:#ede9fe;color:#5b21b6}.badge-default{background:#f3f4f6;color:#4b5563}
        .muted{color:#6b7280;font-size:12px}.empty{padding:18px;color:#9ca3af;font-style:italic;text-align:center}
        .switch{position:relative;display:inline-block;width:46px;height:26px}.switch input{opacity:0;width:0;height:0}
        .slider{position:absolute;cursor:pointer;top:0;left:0;right:0;bottom:0;background:#cbd5e1;transition:.2s;border-radius:999px}
        .slider:before{position:absolute;content:"";height:20px;width:20px;left:3px;top:3px;background:white;transition:.2s;border-radius:50%}
        input:checked + .slider{background:#2563eb}input:checked + .slider:before{transform:translateX(20px)}
        .cfg-row{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid #f1f5f9}.cfg-row:last-child{border-bottom:none}
        .cfg-row label{min-width:180px}.cfg-row input{width:90px;padding:8px;border:1px solid #cbd5e1;border-radius:8px}
        .btn{padding:8px 12px;border-radius:8px;border:1px solid #cbd5e1;background:#fff;cursor:pointer;font:inherit}.btn-primary{background:#111827;color:#fff;border-color:#111827}
        pre{margin:0;white-space:pre-wrap;max-height:240px;overflow:auto;font-size:12px;line-height:1.5}
        .count{margin-left:auto;font-size:12px;color:#6b7280}.toast{position:fixed;right:20px;bottom:20px;background:#111827;color:#fff;padding:10px 14px;border-radius:8px;opacity:0;transform:translateY(6px);transition:.2s}.toast.show{opacity:1;transform:none}.toast.err{background:#b91c1c}
        @media (max-width:1000px){.grid-top{grid-template-columns:1fr}}
    </style>
</head>
<body>
<header>
    <h1>PlutoTV Admin</h1>
    <select class="region-sel" id="regionSel">__REGION_OPTIONS__</select>
    <input class="search" id="channelFilter" type="search" placeholder="Sender filtern ...">
    <div class="muted" id="liveStatus">Live verbunden</div>
</header>
<main>
    <div class="grid-top">
        <div class="card">
            <div class="card-head"><h2>Sender-Harmonize</h2><div class="count" id="channelCount"></div></div>
            <div class="card-body">
                <div class="muted" style="margin-bottom:10px">Persistente Schalter haben Vorrang vor PLUTOTV_HARMONIZE_CHANNELS und --harmonizechannels.</div>
                <table>
                    <thead><tr><th>Sender</th><th>ID</th><th>Quelle</th><th>Effektiv</th><th>Persistent</th></tr></thead>
                    <tbody id="channelsTbody"><tr><td colspan="5" class="empty">Keine Sender geladen.</td></tr></tbody>
                </table>
            </div>
        </div>

        <div class="card">
            <div class="card-head"><h2>Aktive Streams</h2><div class="count" id="streamCount"></div></div>
            <div class="card-body">
                <table>
                    <thead><tr><th>Sender</th><th>Modus</th><th>Gewünscht</th><th>Start</th><th>PID</th></tr></thead>
                    <tbody id="streamsTbody"><tr><td colspan="5" class="empty">Keine aktiven Streams.</td></tr></tbody>
                </table>
            </div>
        </div>
    </div>

    <div class="card">
        <div class="card-head"><h2>Konfiguration</h2></div>
        <div class="card-body">
            <div class="cfg-row"><label>Stall-Timeout</label><input type="number" id="cfgStall" min="5" max="120"><span class="muted">Sekunden ohne ffmpeg-Output nach erstem Datenpaket</span></div>
            <div class="cfg-row"><label>Startup-Timeout</label><input type="number" id="cfgStartup" min="5" max="180"><span class="muted">Sekunden bis zum ersten ffmpeg-Output</span></div>
            <div class="cfg-row"><label>Max. Fehlversuche</label><input type="number" id="cfgFail" min="1" max="20"><span class="muted">Neustarts pro Stream</span></div>
            <div class="cfg-row"><label>Log-Tiefe</label><input type="number" id="cfgLogDepth" min="5" max="100"><span class="muted">Gespeicherte Logzeilen</span></div>
            <div style="margin-top:12px"><button class="btn btn-primary" onclick="saveConfig()">Speichern</button></div>
        </div>
    </div>

    <div class="card">
        <div class="card-head"><h2>Log</h2></div>
        <div class="card-body"><pre id="logPre">Keine Einträge.</pre></div>
    </div>
</main>
<div class="toast" id="toast"></div>
<script>
    (function(){
        const initial = __SNAPSHOT__;
        let current = initial;
        const region = initial.region;

        document.getElementById('regionSel').onchange = function(){
            location.href = '/admin?region=' + encodeURIComponent(this.value);
        };
        document.getElementById('channelFilter').addEventListener('input', renderChannels);

        function esc(v){
            return String(v == null ? '' : v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        }
        function toast(msg, err){
            const el = document.getElementById('toast');
            el.textContent = msg;
            el.className = 'toast show' + (err ? ' err' : '');
            clearTimeout(el._t);
            el._t = setTimeout(()=>el.className='toast',2600);
        }
        function api(path, params){
            return new Promise((resolve,reject)=>{
                const body = Object.keys(params).map(k=>encodeURIComponent(k)+'='+encodeURIComponent(params[k])).join('&');
                const xhr = new XMLHttpRequest();
                xhr.open('POST', path);
                xhr.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
                xhr.onload = function(){
                    try {
                        const data = JSON.parse(xhr.responseText || '{}');
                        if (data.ok) { toast(data.msg || 'OK'); resolve(data); }
                        else { toast(data.error || 'Fehler', true); reject(data); }
                    } catch (e) { toast('Antwortfehler', true); reject(e); }
                };
                xhr.onerror = function(){ toast('Netzwerkfehler', true); reject(new Error('network')); };
                xhr.send(body);
            });
        }
        window.saveConfig = function(){
            api('/admin/set_config', {
                stall_timeout: document.getElementById('cfgStall').value,
                startup_timeout: document.getElementById('cfgStartup').value,
                max_failures: document.getElementById('cfgFail').value,
                log_depth: document.getElementById('cfgLogDepth').value
            }).catch(()=>{});
        };
        window.setHarmonize = function(channelId, enabled){
            api('/admin/toggle_harmonize', { channelId, enabled: enabled ? 1 : 0, region }).catch(()=>{});
        };
        function renderChannels(){
            const tbody = document.getElementById('channelsTbody');
            const q = document.getElementById('channelFilter').value.trim().toLowerCase();
            const rows = (current.channels || []).filter(ch => !q || (ch.channelName||'').toLowerCase().includes(q) || (ch.channelId||'').toLowerCase().includes(q));
            document.getElementById('channelCount').textContent = rows.length + ' sichtbar';
            if (!rows.length) {
                tbody.innerHTML = '<tr><td colspan="5" class="empty">Keine Treffer.</td></tr>';
                return;
            }
            tbody.innerHTML = rows.map(ch => {
                const srcClass = ch.source === 'persisted' ? 'badge-persisted' : (ch.source === 'environment' ? 'badge-env' : 'badge-default');
                const persistent = ch.persistedHarmonize === null || ch.persistedHarmonize === undefined ? 'nicht gesetzt' : (ch.persistedHarmonize ? 'ja' : 'nein');
                return '<tr>' +
                    '<td><strong>' + esc(ch.channelName) + '</strong></td>' +
                    '<td><code>' + esc(ch.channelId) + '</code></td>' +
                    '<td><span class="badge ' + srcClass + '">' + esc(ch.source) + '</span></td>' +
                    '<td><span class="badge ' + (ch.effectiveHarmonize ? 'badge-on' : 'badge-off') + '">' + (ch.effectiveHarmonize ? 'harmonize' : 'copy') + '</span></td>' +
                    '<td><label class="switch"><input type="checkbox" class="harmonize-toggle" data-channel-id="' + esc(ch.channelId) + '" ' + (ch.effectiveHarmonize ? 'checked' : '') + '><span class="slider"></span></label><div class="muted">' + esc(persistent) + '</div></td>' +
                    '</tr>';
            }).join('');
        }

        document.getElementById('channelsTbody').addEventListener('change', function(ev){
            const target = ev.target;
            if (!target || !target.classList || !target.classList.contains('harmonize-toggle')) return;
            const channelId = target.getAttribute('data-channel-id') || '';
            const checked = !!target.checked;
            if (!channelId) {
                toast('Fehlende channelId', true);
                return;
            }
            target.disabled = true;
            api('/admin/toggle_harmonize', { channelId: channelId, enabled: checked ? 1 : 0, region: region })
                .then(function(data){
                    if (Array.isArray(current.channels)) {
                        current.channels = current.channels.map(function(ch){
                            if (ch.channelId === channelId) {
                                if (data && data.channel) return data.channel;
                                ch.persistedHarmonize = checked;
                                ch.effectiveHarmonize = checked;
                                ch.source = 'persisted';
                            }
                            return ch;
                        });
                        renderChannels();
                    }
                })
                .catch(function(){
                    target.checked = !checked;
                })
                .finally(function(){
                    target.disabled = false;
                });
        });
        function renderStreams(){
            const tbody = document.getElementById('streamsTbody');
            const rows = current.streams || [];
            document.getElementById('streamCount').textContent = rows.length ? rows.length + ' aktiv' : '0 aktiv';
            if (!rows.length) {
                tbody.innerHTML = '<tr><td colspan="5" class="empty">Keine aktiven Streams.</td></tr>';
                return;
            }
            tbody.innerHTML = rows.map(st => '<tr>' +
                '<td><strong>' + esc(st.channelName) + '</strong><div class="muted"><code>' + esc(st.channelId) + '</code></div></td>' +
                '<td>' + esc(st.mode) + '</td>' +
                '<td>' + esc(st.desiredMode) + '</td>' +
                '<td>' + esc(st.started) + '</td>' +
                '<td>' + esc(st.pid) + '</td>' +
                '</tr>').join('');
        }
        function renderConfig(){
            const cfg = current.config || {};
            document.getElementById('cfgStall').value = cfg.stall_timeout || 15;
            document.getElementById('cfgStartup').value = cfg.startup_timeout || 45;
            document.getElementById('cfgFail').value = cfg.max_failures || 5;
            document.getElementById('cfgLogDepth').value = cfg.log_depth || 10;
        }
        function renderLogs(){
            const logs = current.logs || [];
            document.getElementById('logPre').textContent = logs.map(l => '[' + l.ts + '] ' + l.line).join('\n') || 'Keine Einträge.';
        }
        function renderAll(){ renderChannels(); renderStreams(); renderConfig(); renderLogs(); }
        renderAll();

        let es;
        function connect(){
            if (es) { try { es.close(); } catch(e){} }
            es = new EventSource('/admin/events?region=' + encodeURIComponent(region));
            es.addEventListener('snapshot', ev => {
                try { current = JSON.parse(ev.data); renderAll(); document.getElementById('liveStatus').textContent = 'Live verbunden'; } catch(e){}
            });
            es.onerror = function(){
                document.getElementById('liveStatus').textContent = 'Verbindung getrennt';
                try { es.close(); } catch(e){}
                setTimeout(connect, 3000);
            };
        }
        connect();
    })();
</script>
</body>
</html>
HTML

    $html =~ s/__SNAPSHOT__/$snapshotJson/;
    $html =~ s/__REGION_OPTIONS__/$regionOptions/;

    my $response = HTTP::Response->new();
    $response->header('content-type' => 'text/html; charset=utf-8');
    $response->code(200);
    $response->message('OK');
    $response->content(encode_utf8($html));
    $client->send_response($response);
}

sub sendRedirect {
    my ($client, $location) = @_;
    my $response = HTTP::Response->new(303);
    $response->header('Location' => $location);
    $response->content('');
    $client->send_response($response);
}

sub handleAdminToggleHarmonize {
    my ($client, $request) = @_;
    my $params    = try { HTTP::Request::Params->new({ req => $request })->params };
    my $channelId = ($params && $params->{channelId}) ? $params->{channelId} : '';
    my $enabled   = ($params && defined $params->{enabled}) ? $params->{enabled} : 0;
    my $region    = ($params && $params->{region} && exists $regions{$params->{region}}) ? $params->{region} : 'DE';
    unless ($channelId) { sendJsonError($client, 'Fehlende channelId'); return; }

    unless (ensureRuntimeStateDir()) {
        appendRecentLog('Runtime-State-Verzeichnis nicht beschreibbar: ' . ($runtimeStateDir || 'unbekannt'));
        sendJsonError($client, 'Temp-Verzeichnis nicht beschreibbar', runtimeStateDir => $runtimeStateDir);
        return;
    }

    my $on = ($enabled =~ /^(1|true|yes|on)$/i) ? 1 : 0;
    my $saved = setHarmonizeOverride($channelId, $on);
    unless ($saved) {
        appendRecentLog('Persistentes Harmonize konnte nicht gespeichert werden: ' . $channelId);
        sendJsonError($client, 'Persistenz fehlgeschlagen', channelId => $channelId);
        return;
    }

    my $persisted = getPersistedHarmonizeOverride($channelId);
    unless (defined $persisted && $persisted == $on) {
        appendRecentLog('Persistentes Harmonize verifiziert abweichend: ' . $channelId);
        sendJsonError($client, 'Persistenz konnte nicht verifiziert werden', channelId => $channelId);
        return;
    }

    appendRecentLog(($on ? 'Persistentes Harmonize an: ' : 'Persistentes Harmonize aus: ') . $channelId);

    my ($channelEntry) = grep { ($_->{channelId} || '') eq $channelId } @{ buildChannelAdminEntries($region) || [] };
    sendJsonOk(
        $client,
        msg       => ($on ? 'Persistentes Harmonize aktiviert' : 'Persistentes Harmonize deaktiviert'),
        channelId => $channelId,
        channel   => $channelEntry,
    );
}

sub handleAdminForceDiscontinuity {
    my ($client, $request) = @_;
    my $params    = try { HTTP::Request::Params->new({ req => $request })->params };
    my $channelId = ($params && $params->{channelId}) ? $params->{channelId} : '';
    unless ($channelId) { sendJsonError($client, 'Fehlende channelId'); return; }
    queueForcedDiscontinuity($channelId);
    appendRecentLog('DISCONTINUITY vorgemerkt: ' . $channelId);
    sendJsonOk($client, msg => 'DISCONTINUITY vorgemerkt');
}


sub handleAdminRestartStream {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $key = ($params && $params->{key}) ? $params->{key} : '';
    unless ($key) { sendJsonError($client, 'Fehlender key'); return; }
    my $streams = loadActiveStreams();
    my $entry   = $streams->{$key};
    unless (ref($entry) eq 'HASH' && $entry->{pid}) {
        sendJsonError($client, 'Stream nicht gefunden'); return;
    }
    kill('TERM', $entry->{pid});
    appendRecentLog('Neustart: ' . ($entry->{channelId} || $key));
    sendJsonOk($client);
}

sub processRequest {
    my ($client) = @_;
    my $request = $client->get_request() or die("could not get Client-Request.\n");
    $client->autoflush(1);
    my $path = $request->uri->path;
    if ($debug) {
        printf("Request received for path $path\n");
    }
    if ($path eq "/playlist") {
        sendM3uFile($client, 0, $request);
    } elsif ($path eq "/tvheadend") {
        sendM3uFile($client, 1, $request);
    } elsif ($path =~ m{^/stream/}) {
        sendDirectStream($client, $request);
    } elsif ($path eq "/proxy.m3u8") {
        sendPlaylistProxy($client, $request);
    } elsif ($path eq "/master3u8") {
        sendMasterAlias($client, $request);
    } elsif ($path eq "/epg") {
        sendXmltvEpgFile($client, $request);
    } elsif ($path =~ m{^/dynamic_stream/}) {
        sendDynamicStream($client, $request);
    } elsif ($path =~ m{^/dynamic_video_stream/}) {
        sendElementaryDynamicStream($client, $request, 'video');
    } elsif ($path =~ m{^/dynamic_audio_stream/}) {
        sendElementaryDynamicStream($client, $request, 'audio');
    } elsif ($path eq "/admin") {
        sendAdminPage($client, $request);
    } elsif ($path eq "/admin/events") {
        sendAdminEvents($client, $request);
    } elsif ($path eq "/admin/toggle_harmonize") {
        handleAdminToggleHarmonize($client, $request);
    } elsif ($path eq "/admin/force_discontinuity") {
        handleAdminForceDiscontinuity($client, $request);
    } elsif ($path eq "/admin/set_config") {
        handleAdminSetConfig($client, $request);
    } elsif ($path eq "/admin/restart_stream") {
        handleAdminRestartStream($client, $request);
    } elsif ($path eq "/favicon.ico") {
        my $response = HTTP::Response->new(204);
        $client->send_response($response);
    } elsif ($path eq "/") {
        sendHelp($client, $request);
    } else {
        $client->send_error(RC_NOT_FOUND, "No such path available: $path");
    }
}

if (!$localhost) {
    $hostIp = Net::Address::IP::Local->public_ipv4;
}

if (defined(getArgsValue("--port"))) {
    $port = getArgsValue("--port");
}

my $daemon = HTTP::Daemon->new(
    LocalAddr => $hostIp,
    LocalPort => $port,
    Reuse => 1,
    ReuseAddr => 1,
    ReusePort => $port,
) or die "Server could not be started.\n\n";

$SIG{PIPE} = sub {
    if ($debug) {
        printf("SIGPIPE received - client disconnected\n");
    }
    exit(0);
};
$SIG{CHLD} = 'IGNORE';

printf("PlutoTVServer started in version $version listening on $hostIp using port $port.\n");
appendRecentLog("Serverstart auf $hostIp:$port");

while (my $client = $daemon->accept) {
    if (forkProcess() == 1) {
        try {
            processRequest($client);
        } catch {
            warn "Error processing request: $_\n";
        };
        exit(0);
    }
}