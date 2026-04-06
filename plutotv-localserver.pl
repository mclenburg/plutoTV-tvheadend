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
use File::Temp qw(tempdir);
use POSIX qw(mkfifo WNOHANG);
use IO::Select;
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::Spec;

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

sub defaultRuntimeStateDir {
    return '/dev/shm/plutotv-localserver' if -d '/dev/shm';
    return File::Spec->catdir(File::Spec->tmpdir(), 'plutotv-localserver');
}

sub resolveRuntimeStateDir {
    my ($value) = @_;
    return defaultRuntimeStateDir() unless defined $value && length $value;

    require File::Basename;
    my $candidate;
    if (-d $value || $value =~ m{[\/]$}) {
        $candidate = $value;
    } else {
        $candidate = File::Basename::dirname($value);
        # A path like /dev/foo.json is not a writable temp area for our state files.
        # In that case fall back to the normal temp location.
        return defaultRuntimeStateDir() if !defined($candidate) || $candidate eq '' || $candidate eq '/' || $candidate eq '/dev';
    }

    return $candidate;
}

my $runtimeStateDir = defaultRuntimeStateDir();
my $harmonizeStateFile = $runtimeStateDir . '/harmonize_channels.json';
my $activeStreamsStateFile = $runtimeStateDir . '/active_streams.json';
my $forceDiscontinuityStateFile = $runtimeStateDir . '/force_discontinuity.json';
my $recentLogStateFile = $runtimeStateDir . '/recent_logs.json';
my $runtimeConfigStateFile = $runtimeStateDir . '/runtime_config.json';
my $tempFile;
my $lastStateIoError = '';

GetOptions("debug" => \$debug, "tempFile=s" => \$tempFile);
if (defined $tempFile && length $tempFile) {
    $runtimeStateDir = resolveRuntimeStateDir($tempFile);
    $harmonizeStateFile = $runtimeStateDir . '/harmonize_channels.json';
    $activeStreamsStateFile = $runtimeStateDir . '/active_streams.json';
    $forceDiscontinuityStateFile = $runtimeStateDir . '/force_discontinuity.json';
    $recentLogStateFile = $runtimeStateDir . '/recent_logs.json';
    $runtimeConfigStateFile = $runtimeStateDir . '/runtime_config.json';
}

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

my $startup_overrides = loadHarmonizeOverrides();
for my $id (keys %{$startup_overrides}) {
    $hybrid_harmonize_channels{$id} = 1 if $startup_overrides->{$id};
}

our %channel_timestamps = ();
our %session_cache = ();
our %channel_cache = ();
our %master_url_cache = ();


my $sessionRefreshInterval = 25 * 60;
my $sessionRetryCooldown = 30;


# -----------------------------------------------------------------------------
# Request and response helpers
# -----------------------------------------------------------------------------

sub getRequestParams {
    my ($request) = @_;
    return try { HTTP::Request::Params->new({ req => $request })->params } || {};
}

sub getRequestRegion {
    my ($request, $params) = @_;
    $params ||= getRequestParams($request);
    return ($params->{region} && exists $regions{$params->{region}}) ? $params->{region} : 'DE';
}

sub isTruthy {
    my ($value) = @_;
    return 0 unless defined $value;
    return $value =~ /^(1|true|yes|on)$/i ? 1 : 0;
}

sub isFalsy {
    my ($value) = @_;
    return 0 unless defined $value;
    return $value =~ /^(0|false|no|off)$/i ? 1 : 0;
}

sub sendMpegTsHeaders {
    my ($client) = @_;
    $client->write("HTTP/1.1 200 OK\n");
    $client->write("Content-Type: video/mp2t\n");
    $client->write("Cache-Control: no-cache, no-store, must-revalidate\n");
    $client->write("Connection: close\n\n");
}


sub setLastStateIoError {
    my ($msg) = @_;
    $lastStateIoError = defined $msg ? "$msg" : '';
}

sub getLastStateIoError {
    return $lastStateIoError || '';
}

sub ensureRuntimeStateDir {
    return 1 if -d $runtimeStateDir;
    eval { make_path($runtimeStateDir) };
    if ($@ || !-d $runtimeStateDir) {
        setLastStateIoError('Konnte Runtime-Verzeichnis nicht anlegen: ' . $runtimeStateDir . ($! ? ' (' . $! . ')' : ''));
        return 0;
    }
    return 1;
}


sub loadJsonFile {
    my ($path, $default) = @_;
    return $default unless ensureRuntimeStateDir();
    return $default unless -e $path;
    open(my $fh, '<', $path) or do {
        setLastStateIoError('Konnte Datei nicht lesen: ' . $path . ' (' . $! . ')');
        return $default;
    };
    flock($fh, LOCK_SH);
    local $/;
    my $content = <$fh>;
    close($fh);
    return $default unless defined $content && length $content;
    my $parsed = eval { decode_json($content) };
    if ($@) {
        setLastStateIoError('Ungueltiges JSON in ' . $path . ': ' . $@);
        return $default;
    }
    setLastStateIoError('');
    return defined $parsed ? $parsed : $default;
}

sub saveJsonFile {
    my ($path, $data) = @_;
    return 0 unless ensureRuntimeStateDir();
    my $tmp = $path . '.tmp.' . $$;
    open(my $fh, '>', $tmp) or do {
        setLastStateIoError('Konnte Temp-Datei nicht schreiben: ' . $tmp . ' (' . $! . ')');
        return 0;
    };
    flock($fh, LOCK_EX);
    my $json = eval { encode_json($data) };
    if ($@) {
        close($fh);
        unlink $tmp;
        setLastStateIoError('Konnte JSON nicht serialisieren: ' . $@);
        return 0;
    }
    print $fh $json or do {
        my $err = $!;
        close($fh);
        unlink $tmp;
        setLastStateIoError('Konnte Temp-Datei nicht schreiben: ' . $tmp . ' (' . $err . ')');
        return 0;
    };
    close($fh) or do {
        my $err = $!;
        unlink $tmp;
        setLastStateIoError('Konnte Temp-Datei nicht schliessen: ' . $tmp . ' (' . $err . ')');
        return 0;
    };
    rename($tmp, $path) or do {
        my $err = $!;
        unlink $tmp;
        setLastStateIoError('Konnte Datei nicht ersetzen: ' . $path . ' (' . $err . ')');
        return 0;
    };
    setLastStateIoError('');
    return 1;
}

sub modifyJsonFile {
    my ($path, $default, $callback) = @_;
    return $default unless ensureRuntimeStateDir();
    my $fh;
    if (-e $path) {
        open($fh, '+<', $path) or do {
            setLastStateIoError('Konnte Datei nicht zum Schreiben oeffnen: ' . $path . ' (' . $! . ')');
            return $default;
        };
    } else {
        open($fh, '+>', $path) or do {
            setLastStateIoError('Konnte Datei nicht anlegen: ' . $path . ' (' . $! . ')');
            return $default;
        };
    }
    flock($fh, LOCK_EX);
    local $/;
    my $content = <$fh>;
    my $data = $default;
    if (defined $content && length $content) {
        my $parsed = eval { decode_json($content) };
        if ($@) {
            close($fh);
            setLastStateIoError('Ungueltiges JSON in ' . $path . ': ' . $@);
            return $default;
        }
        $data = defined $parsed ? $parsed : $default;
    }
    $data = $callback->($data);
    my $json = eval { encode_json($data) };
    if ($@) {
        close($fh);
        setLastStateIoError('Konnte JSON nicht serialisieren: ' . $@);
        return $default;
    }
    seek($fh, 0, 0);
    truncate($fh, 0);
    print $fh $json or do {
        my $err = $!;
        close($fh);
        setLastStateIoError('Konnte Datei nicht schreiben: ' . $path . ' (' . $err . ')');
        return $default;
    };
    close($fh);
    setLastStateIoError('');
    return $data;
}

# -----------------------------------------------------------------------------
# Persistent runtime state
# -----------------------------------------------------------------------------

sub loadHarmonizeOverrides {
    my $parsed = loadJsonFile($harmonizeStateFile, {});
    return {} unless ref($parsed) eq 'HASH';
    return $parsed;
}

sub saveHarmonizeOverrides {
    my ($hashref) = @_;
    $hashref ||= {};
    return saveJsonFile($harmonizeStateFile, $hashref);
}

sub setHarmonizeOverride {
    my ($channelId, $enabled) = @_;
    return 0 unless defined $channelId && length $channelId;
    my $overrides = loadHarmonizeOverrides();
    # Persist explicit on/off so the Web-UI behaves like a durable channel list
    # and can also override channels coming from environment/CLI defaults.
    $overrides->{$channelId} = $enabled ? JSON::PP::true : JSON::PP::false;
    return saveHarmonizeOverrides($overrides);
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


sub registerActiveStream {
    my (%info) = @_;
    my $key;
    my $now = time();
    modifyJsonFile($activeStreamsStateFile, {}, sub {
        my ($streams) = @_;
        $streams = {} unless ref($streams) eq 'HASH';

        if ($info{is_direct}) {
            my $channelId = $info{channelId} || 'unknown';
            $key = 'direct-' . $channelId;
            my $existing = (ref($streams->{$key}) eq 'HASH') ? $streams->{$key} : {};
            $info{pid} = 0;
            $info{startedAt} = $existing->{startedAt} || $now;
            $info{lastSeenAt} = $now;
            $info{ttl} ||= 20;
            $streams->{$key} = { %$existing, %info };
        } else {
            $key = $$ . '-' . int($now * 1000) . '-' . int(rand(100000));
            $info{pid} = $$ unless defined $info{pid};
            $info{startedAt} ||= $now;
            $info{lastSeenAt} ||= $now;
            $streams->{$key} = \%info;
        }
        return $streams;
    });
    return $key;
}

sub unregisterActiveStream {
    my ($key) = @_;
    return unless defined $key && length $key;
    modifyJsonFile($activeStreamsStateFile, {}, sub {
        my ($streams) = @_;
        $streams = {} unless ref($streams) eq 'HASH';
        delete $streams->{$key};
        return $streams;
    });
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
    my $now = time();
    my $streams = modifyJsonFile($activeStreamsStateFile, {}, sub {
        my ($streams) = @_;
        $streams = {} unless ref($streams) eq 'HASH';
        for my $key (keys %$streams) {
            my $entry = $streams->{$key};
            next unless ref($entry) eq 'HASH';

            if ($entry->{is_direct}) {
                my $ttl = int($entry->{ttl} || 20);
                my $lastSeenAt = int($entry->{lastSeenAt} || $entry->{startedAt} || 0);
                if (!$lastSeenAt || ($now - $lastSeenAt) > $ttl) {
                    delete $streams->{$key};
                }
                next;
            }

            my $pid = $entry->{pid};
            if (!$pid || !pidIsAlive($pid)) {
                delete $streams->{$key};
            }
        }
        return $streams;
    });
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
    modifyJsonFile($activeStreamsStateFile, {}, sub {
        my ($streams) = @_;
        $streams = {} unless ref($streams) eq 'HASH';
        return $streams unless ref($streams->{$key}) eq 'HASH';
        for my $k (keys %changes) {
            $streams->{$key}->{$k} = $changes{$k};
        }
        $streams->{$key}->{lastSeenAt} = time() unless exists $changes{lastSeenAt};
        return $streams;
    });
}

sub desiredModeByOverride {
    my ($channelId, $request) = @_;
    my $overrides = loadHarmonizeOverrides();
    if (exists $overrides->{$channelId}) {
        return $overrides->{$channelId} ? 'harmonize' : 'copy';
    }
    return 'harmonize' if $hybrid_harmonize_channels{$channelId};

    my $params = getRequestParams($request);
    if (defined $params->{mode}) {
        my $mode = lc($params->{mode});
        return 'harmonize' if $mode eq 'harmonize';
        return 'copy' if $mode eq 'copy';
    }
    if (defined $params->{harmonize}) {
        return 'harmonize' if isTruthy($params->{harmonize});
        return 'copy' if isFalsy($params->{harmonize});
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

sub buildAdminSnapshot {
    my ($region, %opts) = @_;
    $region ||= 'DE';
    # readonly=1: SSE loop - never writes to active_streams.json
    # readonly=0: page load  - cleans up stale entries once
    my $streams = $opts{readonly} ? readActiveStreamsForDisplay() : cleanupStaleActiveStreams();
    my $harmonize = loadHarmonizeOverrides();
    my $logs = loadRecentLogs();

    my @entries;
    for my $key (sort keys %$streams) {
        my $entry = $streams->{$key};
        next unless ref($entry) eq 'HASH';
        my $channelId = $entry->{channelId} || '';
        push @entries, {
            key         => $key,
            channelId   => $channelId,
            channelName => $entry->{channelName} || $channelId,
            mode        => $entry->{mode} || ($entry->{is_direct} ? 'direct' : 'copy'),
            desiredMode => $entry->{desiredMode} || ($harmonize->{$channelId} ? 'harmonize' : 'copy'),
            started     => formatEpochLocal($entry->{startedAt}),
            pid         => $entry->{pid} || 0,
            isDirect    => ($entry->{is_direct} || 0) ? 1 : 0,
            harmonize   => ($harmonize->{$channelId} || 0) ? 1 : 0,
        };
    }

    my @harm;
    for my $channelId (sort keys %$harmonize) {
        next unless $harmonize->{$channelId};
        my $channel = findChannelMetaById($channelId, $region);
        my $name = $channel ? ($channel->{name} || $channelId) : $channelId;
        push @harm, { channelId => $channelId, channelName => $name };
    }

    my @recent = map {
        +{
            ts   => formatEpochLocal($_->{ts}),
            line => $_->{line},
        }
    } @$logs;

    my %activeByChannel;
    for my $entry (@entries) {
        my $cid = $entry->{channelId} || next;
        if (!$activeByChannel{$cid}) {
            $activeByChannel{$cid} = $entry;
            next;
        }
        if (($entry->{isDirect} || 0) < ($activeByChannel{$cid}->{isDirect} || 0)) {
            $activeByChannel{$cid} = $entry;
        }
    }

    my @channels;
    for my $channel (sort { lc($a->{name} || '') cmp lc($b->{name} || '') || (($a->{number} || 0) <=> ($b->{number} || 0)) } getChannelJson($region)) {
        next unless ref($channel) eq 'HASH';
        my $channelId = $channel->{id} || $channel->{_id} || '';
        next unless length $channelId;
        my $active = $activeByChannel{$channelId};
        push @channels, {
            channelId   => $channelId,
            channelName => $channel->{name} || $channelId,
            active      => $active ? JSON::PP::true : JSON::PP::false,
            activeKey   => $active ? ($active->{key} || '') : '',
            activeMode  => $active ? ($active->{mode} || '') : '',
            started     => $active ? ($active->{started} || '') : '',
            harmonize   => ($harmonize->{$channelId} || 0) ? 1 : 0,
        };
    }

    return {
        region        => $region,
        streams       => \@entries,
        channels      => \@channels,
        harmonizeList => \@harm,
        logs          => \@recent,
        config        => {
            stall_timeout => int(getConfigValue('stall_timeout', 15)),
            max_failures  => int(getConfigValue('max_failures',  5)),
            log_depth     => int(getConfigValue('log_depth',     10)),
        },
    };
}

sub sendAdminEvents {
    my ($client, $request) = @_;
    my $params = getRequestParams($request);
    my $region = getRequestRegion($request, $params);

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

# -----------------------------------------------------------------------------
# Playlist and discontinuity handling
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# Process helpers and Pluto API access
# -----------------------------------------------------------------------------

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
    my $params = getRequestParams($request);
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

# -----------------------------------------------------------------------------
# Public endpoints: playlist, stream and EPG
# -----------------------------------------------------------------------------

sub sendXmltvEpgFile {
    my ($client, $request) = @_;
    my $params = getRequestParams($request);
    my $region = getRequestRegion($request, $params);

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
    my $region = $request ? getRequestRegion($request) : 'DE';
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
    my $params = getRequestParams($request);
    my $region = getRequestRegion($request, $params);

    my $channel = getChannelById($channelId, $region);
    registerActiveStream(
        channelId   => $channelId,
        channelName => ($channel ? ($channel->{name} || $channelId) : $channelId),
        mode        => 'direct',
        desiredMode => 'direct',
        is_direct   => 1,
        ttl         => 20,
    );

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
        eval { sendMpegTsHeaders($client); };
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
            $ffmpeg, '-loglevel', 'error', '-nostdin',
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


sub buildPanzerEncodeCommand {
    my (%args) = @_;
    my $inputSource = $args{inputSource} || 'pipe:0';
    my $channelName = $args{channelName} || $args{channelId} || 'Harmonized';
    my $videoCodec = $args{videoCodec} || 'h264_v4l2m2m';

    return (
        $ffmpeg,
        '-loglevel', 'error',
        '-nostdin',
        '-threads', '1',
        '-thread_queue_size', '512',
        '-fflags', '+genpts+discardcorrupt',
        '-i', $inputSource,
        '-map', '0:v:0?',
        '-map', '0:a:0?',
        '-vf', 'fps=25,scale=1280:720:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p',
        '-c:v', $videoCodec,
        '-b:v', '1800k',
        '-maxrate', '2200k',
        '-bufsize', '3600k',
        '-g', '50',
        '-c:a', 'aac',
        '-ar', '48000',
        '-ac', '2',
        '-b:a', '96k',
        '-muxdelay', '0',
        '-muxpreload', '0',
        '-mpegts_flags', '+resend_headers',
        '-avoid_negative_ts', 'make_zero',
        '-max_interleave_delta', '1000000',
        '-flush_packets', '1',
        '-metadata', 'service_provider=PlutoTV',
        '-metadata', 'service_name=' . $channelName,
        '-f', 'mpegts',
        'pipe:1'
    );
}

sub buildSegmentMuxCommand {
    my (%args) = @_;
    my $videoInput = $args{videoInput} || return;
    my $audioInput = $args{audioInput} || return;

    return (
        $ffmpeg,
        '-loglevel', 'error',
        '-nostdin',
        '-thread_queue_size', '512', '-fflags', '+genpts+discardcorrupt', '-i', $videoInput,
        '-thread_queue_size', '512', '-fflags', '+genpts+discardcorrupt', '-i', $audioInput,
        '-map', '0:v:0?', '-map', '1:a:0?',
        '-c', 'copy',
        '-muxdelay', '0',
        '-muxpreload', '0',
        '-mpegts_flags', '+resend_headers',
        '-avoid_negative_ts', 'make_zero',
        '-max_interleave_delta', '1000000',
        '-flush_packets', '1',
        '-f', 'mpegts',
        'pipe:1'
    );
}

sub stopChildProcesses {
    my (@pids) = @_;
    for my $pid (@pids) {
        next unless $pid;
        kill 'TERM', $pid;
        waitpid($pid, 0);
    }
}

sub spawnSegmentWorker {
    my (%args) = @_;
    my $fifo = $args{fifo} || return;
    my $channelId = $args{channelId} || return;
    my $region = $args{region} || 'DE';
    my $playlistUrl = $args{playlistUrl} || return;
    my $kind = $args{kind} || 'video';

    my $pid = fork();
    if (!defined $pid) {
        warn "Failed to fork $kind worker: $!\n";
        return;
    }
    if ($pid == 0) {
        local $SIG{PIPE} = 'DEFAULT';
        open(my $fh, '>', $fifo) or do { warn "Failed to open $kind fifo for writing: $!\n"; exit(1); };
        binmode($fh);
        eval { streamPlaylistToHandle($fh, $channelId, $region, $playlistUrl, $kind); };
        close($fh);
        exit(0);
    }
    return $pid;
}

sub spawnExecProcess {
    my (%args) = @_;
    my $cmd = $args{cmd} || return;
    my $stdin_fh = $args{stdin_fh};
    my $stdout_fh = $args{stdout_fh};
    my $stderr_path = $args{stderr_path} || '/dev/null';

    my $pid = fork();
    if (!defined $pid) {
        warn "Failed to fork external process: $!\n";
        return;
    }
    if ($pid == 0) {
        local $SIG{PIPE} = 'DEFAULT';
        if ($stdin_fh) {
            open(STDIN, '<&', fileno($stdin_fh)) or exit(1);
        } else {
            open(STDIN, '<', '/dev/null') or exit(1);
        }
        if ($stdout_fh) {
            open(STDOUT, '>&', fileno($stdout_fh)) or exit(1);
        } else {
            open(STDOUT, '>', '/dev/null') or exit(1);
        }
        open(STDERR, '>>', $stderr_path) or open(STDERR, '>', '/dev/null');
        exec { $cmd->[0] } @$cmd;
        exit(1);
    }
    return $pid;
}

sub streamHlsViaFfmpeg {
    my ($client, $channelId, $region, $videoUrl, $audioUrl, $channelName, $headersSentRef, $activeStreamKey, $request) = @_;
    return 0 unless $ffmpeg;
    return 0 unless $videoUrl && $audioUrl;

    $client->timeout(5);
    if (!$headersSentRef || !$$headersSentRef) {
        eval { sendMpegTsHeaders($client); };
        if ($@) {
            if ($debug) { printf("Failed to send headers - client disconnected: %s\n", $@); }
            return 0;
        }
        $$headersSentRef = 1 if $headersSentRef;
    }

    my $maxFailures   = int(getConfigValue('max_failures',  5));
    my $stall_timeout = int(getConfigValue('stall_timeout', 15));
    my $failures = 0;

    while ($failures < $maxFailures) {
        updateActiveStream($activeStreamKey, mode => 'harmonize', desiredMode => desiredModeByOverride($channelId, $request)) if $activeStreamKey;

        if ($failures > 0) {
            if ($debug) { printf("Restarting hybrid harmonizer for %s (attempt %d/%d)\n", $channelId, $failures + 1, $maxFailures); }
            sleep(2);
            my (undef, undef, undef, undef, $freshVideo, $freshAudio) = getPlaybackUrlsForChannel($channelId, $region, 1);
            $videoUrl = $freshVideo if $freshVideo;
            $audioUrl = $freshAudio if $freshAudio;
            last unless $videoUrl && $audioUrl;
        }

        my $tmpdir = tempdir('plutotv-harmonize-XXXXXX', TMPDIR => 1, CLEANUP => 1);
        my $videoFifo = "$tmpdir/video.ts";
        my $audioFifo = "$tmpdir/audio.ts";
        my $ffmpegErr = "$tmpdir/ffmpeg.err";

        unless (mkfifo($videoFifo, 0700)) { warn "Failed to create video fifo: $!\n"; $failures++; next; }
        unless (mkfifo($audioFifo, 0700)) { warn "Failed to create audio fifo: $!\n"; unlink $videoFifo; $failures++; next; }

        my @children;
        my $videoPid = spawnSegmentWorker(
            fifo => $videoFifo,
            channelId => $channelId,
            region => $region,
            playlistUrl => $videoUrl,
            kind => 'video',
        );
        push @children, $videoPid if $videoPid;

        my $audioPid = spawnSegmentWorker(
            fifo => $audioFifo,
            channelId => $channelId,
            region => $region,
            playlistUrl => $audioUrl,
            kind => 'audio',
        );
        push @children, $audioPid if $audioPid;

        my ($mux_read, $mux_write);
        pipe($mux_read, $mux_write) or do {
            warn "Failed to create mux pipe: $!\n";
            stopChildProcesses(@children);
            unlink $videoFifo if -p $videoFifo || -e $videoFifo;
            unlink $audioFifo if -p $audioFifo || -e $audioFifo;
            $failures++;
            next;
        };
        binmode($mux_read);
        binmode($mux_write);

        my ($enc_read, $enc_write);
        pipe($enc_read, $enc_write) or do {
            warn "Failed to create encoder pipe: $!\n";
            close($mux_read);
            close($mux_write);
            stopChildProcesses(@children);
            unlink $videoFifo if -p $videoFifo || -e $videoFifo;
            unlink $audioFifo if -p $audioFifo || -e $audioFifo;
            $failures++;
            next;
        };
        binmode($enc_read);
        binmode($enc_write);

        my $muxPid = spawnExecProcess(
            cmd => [ buildSegmentMuxCommand(videoInput => $videoFifo, audioInput => $audioFifo) ],
            stdout_fh => $mux_write,
            stderr_path => $ffmpegErr,
        );
        close($mux_write);

        my @codec_candidates = ('h264_v4l2m2m', 'libx264');
        my ($encPid, $codec_used);
        for my $codec (@codec_candidates) {
            $encPid = spawnExecProcess(
                cmd => [ buildPanzerEncodeCommand(
                    inputSource => 'pipe:0',
                    channelId => $channelId,
                    channelName => ($channelName || $channelId),
                    videoCodec => $codec,
                ) ],
                stdin_fh => $mux_read,
                stdout_fh => $enc_write,
                stderr_path => $ffmpegErr,
            );
            if ($encPid) {
                $codec_used = $codec;
                last;
            }
        }
        close($mux_read);
        close($enc_write);

        unless ($muxPid && $encPid) {
            warn "Failed to start hybrid harmonizer pipeline\n";
            close($enc_read);
            stopChildProcesses(grep { $_ } (@children, $muxPid, $encPid));
            unlink $videoFifo if -p $videoFifo || -e $videoFifo;
            unlink $audioFifo if -p $audioFifo || -e $audioFifo;
            $failures++;
            next;
        }

        appendRecentLog('Harmonize gestartet: ' . $channelId . ' [' . $codec_used . ']');

        my $client_alive          = 1;
        my $mode_switch_requested = 0;
        my $stalled               = 0;
        my $startup_failed        = 0;
        my $last_output_at        = time();
        my $last_mode_check       = 0;
        my $last_disc_check       = time();
        my $first_output_seen     = 0;
        my $last_seen_discontinuity_seq;
        my $buffer                = '';
        my $sel = IO::Select->new($enc_read);

        while (1) {
            if (time() - $last_mode_check >= 1) {
                $last_mode_check = time();
                if (desiredModeByOverride($channelId, $request) eq 'copy') {
                    $mode_switch_requested = 1;
                    last;
                }
            }

            if (time() - $last_disc_check >= 2) {
                $last_disc_check = time();
                if (detectNewPlaylistDiscontinuity(createUserAgent(), $videoUrl, $audioUrl, \$last_seen_discontinuity_seq)) {
                    appendRecentLog('DISCONTINUITY erkannt, Harmonize-Neustart: ' . $channelId);
                    $stalled = 1;
                    last;
                }
            }

            my @ready = $sel->can_read(0.5);
            if (@ready) {
                my $read = sysread($enc_read, $buffer, 1316);
                last unless defined $read && $read > 0;
                $last_output_at = time();
                $first_output_seen = 1;
                my $ok = eval { $client->write($buffer); 1 };
                unless ($ok) { $client_alive = 0; last; }
            } else {
                my $enc_alive = pidIsAlive($encPid);
                my $mux_alive = pidIsAlive($muxPid);

                if (!$first_output_seen && (!$enc_alive || !$mux_alive) && (time() - $last_output_at) >= 3) {
                    appendRecentLog('Harmonize-Start fehlgeschlagen, Neustart: ' . $channelId);
                    $startup_failed = 1;
                    last;
                }

                if ((time() - $last_output_at) >= $stall_timeout) {
                    if ($debug) { printf("hybrid harmonizer stalled >%ds for %s, restarting\n", $stall_timeout, $channelId); }
                    appendRecentLog('Harmonize-Stall, Neustart: ' . $channelId);
                    $stalled = 1;
                    last;
                }
            }
        }

        close($enc_read);
        stopChildProcesses(@children, $muxPid, $encPid);
        unlink $videoFifo if -p $videoFifo || -e $videoFifo;
        unlink $audioFifo if -p $audioFifo || -e $audioFifo;

        return 'switch' if $mode_switch_requested;
        if ($stalled || $startup_failed) {
            my (undef, undef, undef, undef, $freshVideo, $freshAudio) = getPlaybackUrlsForChannel($channelId, $region, 1);
            $videoUrl = $freshVideo if $freshVideo;
            $audioUrl = $freshAudio if $freshAudio;
            next;
        }

        last unless $client_alive;
        $failures++;
    }

    return 1;
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
    my $params = getRequestParams($request);
    my $region = getRequestRegion($request, $params);

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
    eval { sendMpegTsHeaders($client); };
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

# -----------------------------------------------------------------------------
# Admin UI and JSON endpoints
# -----------------------------------------------------------------------------

sub sendAdminPage {
    my ($client, $request) = @_;
    my $params = getRequestParams($request);
    my $region = getRequestRegion($request, $params);
    my $snapshot    = buildAdminSnapshot($region);
    my $snapshotJson = encode_json($snapshot);
    my $regionsJson  = encode_json([ sort keys %regions ]);

    # Build <option> tags server-side so initial render needs no JS
    my $regionOptions = '';
    for my $r (sort keys %regions) {
        my $sel = ($r eq $region) ? ' selected' : '';
        $regionOptions .= "<option value=\"$r\"$sel>$r</option>\n";
    }

    # Single-quoted heredoc: NO Perl interpolation inside.
    # All substitutions happen via s/// below.
    my $html = <<'HTML';
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>PlutoTV Admin</title>
    <style>
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:system-ui,Arial,sans-serif;background:#f0f2f5;color:#1a1d23;font-size:14px}
        header{background:#1a1d23;color:#fff;padding:14px 24px;display:flex;align-items:center;gap:16px}
        header h1{font-size:16px;font-weight:600}
        .region-sel{padding:4px 8px;border:1px solid #555;border-radius:5px;background:#2d3340;color:#fff;font-size:12px;cursor:pointer}
        .sse-wrap{margin-left:auto;display:flex;align-items:center;gap:6px;font-size:11px;opacity:.8}
        .sse-dot{width:7px;height:7px;border-radius:50%;background:#22c55e;transition:background .3s}
        .sse-dot.off{background:#ef4444}
        main{padding:24px;max-width:1100px;margin:0 auto;display:flex;flex-direction:column;gap:18px}
        .card{background:#fff;border-radius:8px;border:1px solid #e0e4ea;overflow:hidden}
        .card-head{padding:10px 16px;border-bottom:1px solid #e0e4ea;display:flex;align-items:center;gap:8px}
        .card-head h2{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.07em;color:#667085}
        .dot{width:7px;height:7px;border-radius:50%;background:#22c55e;flex-shrink:0}
        .dot.off{background:#d1d5db}
        .card-body{padding:16px}
        table{width:100%;border-collapse:collapse}
        th{font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:#9ca3af;padding:7px 10px;text-align:left;border-bottom:2px solid #f0f2f5;white-space:nowrap}
        td{padding:9px 10px;border-bottom:1px solid #f5f7fa;vertical-align:middle}
        tr:last-child td{border-bottom:none}
        tr:hover td{background:#fafbfc}
        code{font-family:ui-monospace,monospace;font-size:12px;background:#f0f2f5;padding:1px 5px;border-radius:3px}
        .badge{display:inline-block;padding:2px 7px;border-radius:9px;font-size:11px;font-weight:600}
        .badge-copy{background:#e3f0ff;color:#1565c0}
        .badge-harmonize{background:#fff8e1;color:#8a6000}
        .badge-direct{background:#eef2ff;color:#4338ca}
        .badge-on{background:#e6f4ea;color:#1e6e35}
        .badge-off{background:#fef9ee;color:#9c6300}
        .btns{display:flex;gap:5px;flex-wrap:wrap}
        .btn{display:inline-flex;align-items:center;padding:4px 10px;border:1px solid #d1d5db;border-radius:5px;background:#fff;color:#374151;font-size:12px;cursor:pointer;font-family:inherit;white-space:nowrap}
        .btn:hover{background:#f3f4f6}
        .btn:disabled{opacity:.4;cursor:not-allowed}
        .btn-danger{background:#fef2f2;color:#c0392b;border-color:#fca5a5}
        .btn-danger:hover{background:#fee2e2}
        .btn-save{background:#1a1d23;color:#fff;border-color:#1a1d23}
        .btn-save:hover{background:#2d3340}
        .empty{color:#9ca3af;font-style:italic;text-align:center;padding:18px}
        .cfg-row{display:flex;align-items:center;gap:10px;padding:7px 0;border-bottom:1px solid #f5f7fa}
        .cfg-row:last-child{border-bottom:none}
        .cfg-label{width:160px;font-size:13px;color:#374151;flex-shrink:0}
        .cfg-hint{flex:1;font-size:12px;color:#9ca3af}
        .cfg-num{width:72px;padding:4px 7px;border:1px solid #d1d5db;border-radius:5px;font-size:13px;font-family:inherit;text-align:right}
        .cfg-num:focus{outline:none;border-color:#6366f1}
        .cfg-unit{font-size:12px;color:#9ca3af;width:20px}
        ul.harm-list{padding-left:18px;line-height:2}
        pre{font-family:ui-monospace,monospace;font-size:12px;white-space:pre-wrap;line-height:1.6;color:#374151;max-height:200px;overflow-y:auto}
        .toast{position:fixed;bottom:22px;right:22px;padding:9px 15px;border-radius:7px;font-size:13px;font-weight:500;background:#1a1d23;color:#fff;opacity:0;transform:translateY(6px);transition:opacity .2s,transform .2s;pointer-events:none;z-index:999}
        .toast.show{opacity:1;transform:none}
        .toast.err{background:#c0392b}
    </style>
</head>
<body>
<header>
    <h1>&#127916; PlutoTV Admin</h1>
    <select class="region-sel" id="regionSel">__REGION_OPTIONS__</select>
    <div class="sse-wrap">
        <span class="sse-dot off" id="sseDot"></span>
        <span id="sseLabel">Verbinde...</span>
    </div>
</header>
<main>

    <div class="card">
        <div class="card-head">
            <span class="dot off" id="streamsDot"></span>
            <h2>Aktive Streams</h2>
            <span id="streamsCnt" style="margin-left:auto;font-size:11px;color:#9ca3af"></span>
        </div>
        <table>
            <thead><tr>
                <th>Sender</th><th>ID</th><th>Start</th>
                <th>Modus</th><th>Harmonize</th><th>Aktionen</th>
            </tr></thead>
            <tbody id="streamsTbody">
            <tr><td colspan="6" class="empty">Keine aktiven Streams.</td></tr>
            </tbody>
        </table>
    </div>

    <div class="card">
        <div class="card-head">
            <span class="dot" id="channelsDot"></span>
            <h2>Sender schalten</h2>
            <span id="channelsCnt" style="margin-left:auto;font-size:11px;color:#9ca3af"></span>
        </div>
        <div class="card-body" style="padding-bottom:0">
            <input type="search" id="channelFilter" placeholder="Sender suchen..." style="width:100%;max-width:420px;padding:8px 10px;border:1px solid #d1d5db;border-radius:6px;font-size:13px;font-family:inherit">
        </div>
        <table>
            <thead><tr>
                <th>Sender</th><th>ID</th><th>Aktiv</th><th>Modus</th><th>Harmonize</th><th>Aktionen</th>
            </tr></thead>
            <tbody id="channelsTbody">
            <tr><td colspan="6" class="empty">Keine Sender geladen.</td></tr>
            </tbody>
        </table>
    </div>

    <div class="card">
        <div class="card-head"><h2>Konfiguration</h2>
            <span style="font-size:11px;color:#9ca3af;margin-left:4px">(wirkt ab naechstem ffmpeg-Start)</span>
        </div>
        <div class="card-body">
            <div class="cfg-row">
                <span class="cfg-label">Stall-Timeout</span>
                <span class="cfg-hint">Sekunden ohne ffmpeg-Output bis Neustart</span>
                <input class="cfg-num" type="number" id="cfgStall" min="5" max="120" value="15">
                <span class="cfg-unit">s</span>
            </div>
            <div class="cfg-row">
                <span class="cfg-label">Max. Fehlversuche</span>
                <span class="cfg-hint">Wie oft ffmpeg neu startet bevor Stream aufgibt</span>
                <input class="cfg-num" type="number" id="cfgFail" min="1" max="20" value="5">
                <span class="cfg-unit"></span>
            </div>
            <div class="cfg-row">
                <span class="cfg-label">Log-Tiefe</span>
                <span class="cfg-hint">Anzahl gespeicherter Log-Eintraege</span>
                <input class="cfg-num" type="number" id="cfgLogDepth" min="5" max="100" value="10">
                <span class="cfg-unit"></span>
            </div>
            <div style="margin-top:14px">
                <button class="btn btn-save" onclick="saveConfig()">Speichern</button>
            </div>
        </div>
    </div>

    <div class="card">
        <div class="card-head"><h2>Dauerhaft Harmonize</h2></div>
        <div class="card-body">
            <ul class="harm-list" id="harmList"></ul>
            <p id="harmEmpty" class="empty" style="display:none">Keine dauerhaft aktivierten Harmonize-Sender.</p>
        </div>
    </div>

    <div class="card">
        <div class="card-head"><h2>Log</h2></div>
        <div class="card-body"><pre id="logPre">Keine Eintraege.</pre></div>
    </div>

</main>
<div class="toast" id="toast"></div>
<script>
    (function(){
        var snap0 = __SNAPSHOT__;
        var region0 = '__REGION__';
        var allRegions = __REGIONS__;
        var currentSnapshot = snap0;

        // Region selector: populated server-side via __REGION_OPTIONS__,
        // just wire the onchange here.
        document.getElementById('regionSel').onchange = function(){
            location.href = '/admin?region=' + encodeURIComponent(this.value);
        };

        function esc(s){
            return String(s == null ? '' : s)
                .replace(/&/g, '&amp;').replace(/</g, '&lt;')
                .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        }

        function toast(msg, isErr) {
            var t = document.getElementById('toast');
            t.textContent = msg;
            t.className = 'toast show' + (isErr ? ' err' : '');
            clearTimeout(t._t);
            t._t = setTimeout(function(){ t.className = 'toast'; }, 2600);
        }

        function api(path, params, cb) {
            var body = [];
            for (var k in params) {
                body.push(encodeURIComponent(k) + '=' + encodeURIComponent(params[k]));
            }
            var xhr = new XMLHttpRequest();
            xhr.open('POST', path);
            xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
            xhr.onload = function(){
                try {
                    var d = JSON.parse(xhr.responseText);
                    if (d.ok) toast(d.msg || 'OK');
                    else toast(d.error || 'Fehler', true);
                    if (cb) cb(d);
                } catch(e) { toast('Fehler', true); }
            };
            xhr.onerror = function(){ toast('Netzwerkfehler', true); };
            xhr.send(body.join('&'));
        }

        window.saveConfig = function(){
            api('/admin/set_config', {
                stall_timeout: document.getElementById('cfgStall').value,
                max_failures:  document.getElementById('cfgFail').value,
                log_depth:     document.getElementById('cfgLogDepth').value
            });
        };

        window.toggleHarmonize = function(channelId, enabled) {
            api('/admin/toggle_harmonize', {channelId: channelId, enabled: enabled, region: region0}, function(d){
                if (d && d.ok) {
                    if (d.snapshot) {
                        render(d.snapshot);
                    } else {
                        applyHarmonizeLocally(channelId, enabled ? 1 : 0);
                    }
                }
            });
        };
        window.forceDisc = function(channelId) {
            api('/admin/force_discontinuity', {channelId: channelId, region: region0});
        };
        window.restartStream = function(key) {
            api('/admin/restart_stream', {key: key});
        };


        function applyHarmonizeLocally(channelId, enabled) {
            currentSnapshot = currentSnapshot || {};
            var found = false;
            currentSnapshot.channels = (currentSnapshot.channels || []).map(function(ch){
                if (ch.channelId === channelId) {
                    ch.harmonize = !!enabled;
                    found = true;
                }
                return ch;
            });
            currentSnapshot.streams = (currentSnapshot.streams || []).map(function(st){
                if (st.channelId === channelId) {
                    st.harmonize = !!enabled;
                    st.desiredMode = enabled ? 'harmonize' : 'copy';
                }
                return st;
            });
            var harm = currentSnapshot.harmonizeList || [];
            if (enabled) {
                if (!harm.some(function(x){ return x.channelId === channelId; })) {
                    var ch = (currentSnapshot.channels || []).find(function(x){ return x.channelId === channelId; });
                    harm.push({channelId: channelId, channelName: ch ? ch.channelName : channelId});
                }
            } else {
                harm = harm.filter(function(x){ return x.channelId !== channelId; });
            }
            harm.sort(function(a,b){
                return String(a.channelName||'').localeCompare(String(b.channelName||''), 'de', {sensitivity:'base'});
            });
            currentSnapshot.harmonizeList = harm;
            render(currentSnapshot);
        }

        function renderStreams(streams) {
            var tbody = document.getElementById('streamsTbody');
            var dot   = document.getElementById('streamsDot');
            var cnt   = document.getElementById('streamsCnt');
            dot.className  = 'dot' + (streams.length ? '' : ' off');
            cnt.textContent = streams.length ? streams.length + ' aktiv' : '';
            if (!streams.length) {
                tbody.innerHTML = '<tr><td colspan="6" class="empty">Keine aktiven Streams.</td></tr>';
                return;
            }
            var rows = streams.map(function(e){
                var hOn  = !!e.harmonize;
                var harmBtn = '<button class="btn" data-action="toggle-harmonize" data-channel-id="' + esc(e.channelId) + '" data-enabled="' + (hOn ? '0' : '1') + '">' +
                    (hOn ? 'Harmonize aus' : 'Harmonize ein') + '</button>';
                var discBtn = '<button class="btn" data-action="force-disc" data-channel-id="' + esc(e.channelId) + '">DISC</button>';
                var rstBtn  = '<button class="btn btn-danger" data-action="restart-stream" data-key="' + esc(e.key) + '">&#8635; Neustart</button>';
                return '<tr>' +
                    '<td><strong>' + esc(e.channelName) + '</strong></td>' +
                    '<td><code>' + esc(e.channelId) + '</code></td>' +
                    '<td>' + esc(e.started) + '</td>' +
                    '<td><span class="badge badge-' + esc(e.mode) + '">' + esc(e.mode) + '</span></td>' +
                    '<td>' + (hOn
                        ? '<span class="badge badge-on">an</span>'
                        : '<span class="badge badge-off">aus</span>') + '</td>' +
                    '<td><div class="btns">' + harmBtn + discBtn + rstBtn + '</div></td>' +
                    '</tr>';
            });
            tbody.innerHTML = rows.join('');
        }

        function renderHarm(list) {
            var ul = document.getElementById('harmList');
            var em = document.getElementById('harmEmpty');
            if (!list.length) { ul.innerHTML = ''; em.style.display = 'block'; return; }
            em.style.display = 'none';
            ul.innerHTML = list.map(function(e){
                return '<li>' + esc(e.channelName) + ' <code>' + esc(e.channelId) + '</code></li>';
            }).join('');
        }

        function renderLogs(logs) {
            document.getElementById('logPre').textContent =
                logs.map(function(l){ return '[' + l.ts + '] ' + l.line; }).join('\n') ||
                'Keine Eintraege.';
        }

        function renderConfig(cfg) {
            if (!cfg) return;
            if (cfg.stall_timeout != null) document.getElementById('cfgStall').value    = cfg.stall_timeout;
            if (cfg.max_failures  != null) document.getElementById('cfgFail').value     = cfg.max_failures;
            if (cfg.log_depth     != null) document.getElementById('cfgLogDepth').value = cfg.log_depth;
        }

        function renderChannels(channels) {
            var filter = (document.getElementById('channelFilter') && document.getElementById('channelFilter').value || '').toLowerCase().trim();
            var tbody = document.getElementById('channelsTbody');
            var dot   = document.getElementById('channelsDot');
            var cnt   = document.getElementById('channelsCnt');
            dot.className = 'dot';
            var filteredChannels = channels.filter(function(e){
                if (!filter) return true;
                return String(e.channelName || '').toLowerCase().indexOf(filter) >= 0 || String(e.channelId || '').toLowerCase().indexOf(filter) >= 0;
            });
            cnt.textContent = filteredChannels.length + ' / ' + channels.length + ' Sender';
            if (!filteredChannels.length) {
                tbody.innerHTML = '<tr><td colspan="6" class="empty">Keine passenden Sender.</td></tr>';
                return;
            }
            if (!channels.length) {
                tbody.innerHTML = '<tr><td colspan="6" class="empty">Keine Sender geladen.</td></tr>';
                return;
            }
            var rows = filteredChannels.map(function(e){
                var hOn = !!e.harmonize;
                var activeBadge = e.active
                    ? '<span class="badge badge-on">ja</span>'
                    : '<span class="badge badge-off">nein</span>';
                var modeBadge = e.activeMode
                    ? '<span class="badge badge-' + esc(e.activeMode) + '">' + esc(e.activeMode) + '</span>'
                    : '<span class="badge badge-off">-</span>';
                var harmBtn = '<button class="btn" data-action="toggle-harmonize" data-channel-id="' + esc(e.channelId) + '" data-enabled="' + (hOn ? '0' : '1') + '">' +
                    (hOn ? 'Harmonize aus' : 'Harmonize ein') + '</button>';
                var discBtn = '<button class="btn" data-action="force-disc" data-channel-id="' + esc(e.channelId) + '">DISC</button>';
                var rstBtn = e.activeKey
                    ? '<button class="btn btn-danger" data-action="restart-stream" data-key="' + esc(e.activeKey) + '">&#8635; Neustart</button>'
                    : '';
                return '<tr>' +
                    '<td><strong>' + esc(e.channelName) + '</strong></td>' +
                    '<td><code>' + esc(e.channelId) + '</code></td>' +
                    '<td>' + activeBadge + '</td>' +
                    '<td>' + modeBadge + '</td>' +
                    '<td>' + (hOn
                        ? '<span class="badge badge-on">an</span>'
                        : '<span class="badge badge-off">aus</span>') + '</td>' +
                    '<td><div class="btns">' + harmBtn + discBtn + rstBtn + '</div></td>' +
                    '</tr>';
            });
            tbody.innerHTML = rows.join('');
        }

        function render(s) {
            currentSnapshot = s || {};
            renderStreams(s.streams    || []);
            renderChannels(s.channels  || []);
            renderHarm  (s.harmonizeList || []);
            renderLogs  (s.logs        || []);
            renderConfig(s.config);
        }

        // SSE with auto-reconnect
        var es, retryTimer;
        function connectSSE() {
            var dot   = document.getElementById('sseDot');
            var label = document.getElementById('sseLabel');
            if (es) { try { es.close(); } catch(e){} }
            dot.className = 'sse-dot off'; label.textContent = 'Verbinde...';
            es = new EventSource('/admin/events?region=' + encodeURIComponent(region0));
            es.addEventListener('snapshot', function(ev){
                try { render(JSON.parse(ev.data)); } catch(e){}
            });
            es.onopen  = function(){ dot.className = 'sse-dot'; label.textContent = 'Live'; clearTimeout(retryTimer); };
            es.onerror = function(){ dot.className = 'sse-dot off'; label.textContent = 'Getrennt'; es.close(); retryTimer = setTimeout(connectSSE, 3000); };
        }
        document.addEventListener('click', function(ev){
            var btn = ev.target.closest('button[data-action]');
            if (!btn) return;
            var action = btn.getAttribute('data-action');
            if (action === 'toggle-harmonize') {
                ev.preventDefault();
                window.toggleHarmonize(btn.getAttribute('data-channel-id'), btn.getAttribute('data-enabled'));
            } else if (action === 'force-disc') {
                ev.preventDefault();
                window.forceDisc(btn.getAttribute('data-channel-id'));
            } else if (action === 'restart-stream') {
                ev.preventDefault();
                window.restartStream(btn.getAttribute('data-key'));
            }
        });
        var filterInput = document.getElementById('channelFilter');
        if (filterInput) {
            filterInput.addEventListener('input', function(){ render(currentSnapshot || snap0); });
        }
        connectSSE();
        render(snap0);
    })();
</script>
</body>
</html>
HTML

    $html =~ s/__SNAPSHOT__/$snapshotJson/;
    $html =~ s/__REGION__/$region/g;
    $html =~ s/__REGION_OPTIONS__/$regionOptions/;
    $html =~ s/__REGIONS__/$regionsJson/;

    my $response = HTTP::Response->new();
    $response->header('content-type' => 'text/html; charset=utf-8');
    $response->code(200);
    $response->message('OK');
    $response->content(encode_utf8($html));
    $client->send_response($response);
}


sub sendJsonResponse {
    my ($client, $code, $payload) = @_;
    $payload ||= {};
    my $response = HTTP::Response->new();
    $response->header('content-type', 'application/json; charset=utf-8');
    $response->code($code || 200);
    $response->message('OK');
    $response->content(encode_utf8(encode_json($payload)));
    $client->send_response($response);
}

sub sendJsonOk {
    my ($client, %payload) = @_;
    $payload{ok} = JSON::PP::true;
    sendJsonResponse($client, 200, \%payload);
}

sub sendJsonError {
    my ($client, $message, %payload) = @_;
    $payload{ok} = JSON::PP::false;
    $payload{error} = $message || 'Fehler';
    sendJsonResponse($client, 200, \%payload);
}

sub handleAdminSetConfig {
    my ($client, $request) = @_;
    my $params = getRequestParams($request);
    my $stall_timeout = int(defined $params->{stall_timeout} ? $params->{stall_timeout} : getConfigValue('stall_timeout', 15));
    my $max_failures  = int(defined $params->{max_failures} ? $params->{max_failures} : getConfigValue('max_failures', 5));
    my $log_depth     = int(defined $params->{log_depth} ? $params->{log_depth} : getConfigValue('log_depth', 10));

    $stall_timeout = 5   if $stall_timeout < 5;
    $stall_timeout = 120 if $stall_timeout > 120;
    $max_failures  = 1   if $max_failures < 1;
    $max_failures  = 20  if $max_failures > 20;
    $log_depth     = 5   if $log_depth < 5;
    $log_depth     = 100 if $log_depth > 100;

    saveRuntimeConfig({
        stall_timeout => $stall_timeout,
        max_failures  => $max_failures,
        log_depth     => $log_depth,
    });
    appendRecentLog('Konfiguration gespeichert');
    sendJsonOk($client, msg => 'Konfiguration gespeichert');
}

sub handleAdminToggleHarmonize {
    my ($client, $request) = @_;
    my $params = getRequestParams($request);
    my $channelId = $params->{channelId} || '';
    my $enabled   = defined $params->{enabled} ? $params->{enabled} : 0;
    my $region = getRequestRegion($request, $params);
    unless ($channelId) { sendJsonError($client, 'Fehlende channelId'); return; }
    my $on = isTruthy($enabled);
    my $saved = setHarmonizeOverride($channelId, $on);
    unless ($saved) {
        my $detail = getLastStateIoError();
        sendJsonError($client, 'Harmonize-Status konnte nicht gespeichert werden' . (length $detail ? ': ' . $detail : ''));
        return;
    }

    my $streams = loadActiveStreams();
    my @restarted;
    for my $key (keys %$streams) {
        my $entry = $streams->{$key};
        next unless ref($entry) eq 'HASH';
        next unless ($entry->{channelId} || '') eq $channelId;
        next if $entry->{is_direct};
        if ($entry->{pid} && pidIsAlive($entry->{pid})) {
            updateActiveStream($key, desiredMode => ($on ? 'harmonize' : 'copy'));
            kill('TERM', $entry->{pid});
            push @restarted, $entry->{pid};
        }
    }

    appendRecentLog(($on ? 'Harmonize an: ' : 'Harmonize aus: ') . $channelId . (@restarted ? ' (aktive Streams neu gestartet)' : ''));
    my $snapshot = buildAdminSnapshot($region);
    sendJsonOk(
        $client,
        msg => ($on ? 'Harmonize aktiviert' : 'Harmonize deaktiviert'),
        restarted => scalar(@restarted),
        snapshot => $snapshot,
    );
}

sub handleAdminForceDiscontinuity {
    my ($client, $request) = @_;
    my $params = getRequestParams($request);
    my $channelId = $params->{channelId} || '';
    unless ($channelId) { sendJsonError($client, 'Fehlende channelId'); return; }
    queueForcedDiscontinuity($channelId);
    appendRecentLog('DISCONTINUITY vorgemerkt: ' . $channelId);
    sendJsonOk($client, msg => 'DISCONTINUITY vorgemerkt');
}


sub handleAdminRestartStream {
    my ($client, $request) = @_;
    my $params = getRequestParams($request);
    my $key = $params->{key} || '';
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

# -----------------------------------------------------------------------------
# Request routing and server lifecycle
# -----------------------------------------------------------------------------

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
    } elsif ($path eq "/master3u8") {
        sendMasterAlias($client, $request);
    } elsif ($path eq "/epg") {
        sendXmltvEpgFile($client, $request);
    } elsif ($path =~ m{^/dynamic_stream/}) {
        sendDynamicStream($client, $request);
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