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

my $runtimeStateDir = '/tmp/plutotv-localserver';
my $harmonizeStateFile = $runtimeStateDir . '/harmonize_channels.json';
my $activeStreamsStateFile = $runtimeStateDir . '/active_streams.json';
my $forceDiscontinuityStateFile = $runtimeStateDir . '/force_discontinuity.json';
my $recentLogStateFile = $runtimeStateDir . '/recent_logs.json';
my $runtimeConfigStateFile = $runtimeStateDir . '/runtime_config.json';
my $tempFile;

GetOptions("debug" => \$debug, "tempFile=s" => \$tempFile);
if (defined $tempFile && length $tempFile) {
    require File::Basename;
    $runtimeStateDir = File::Basename::dirname($tempFile);
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
    return if -d $runtimeStateDir;
    mkdir $runtimeStateDir;
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
    ensureRuntimeStateDir();
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
    ensureRuntimeStateDir();
    my $tmp = $path . '.tmp.' . $$;
    open(my $fh, '>', $tmp) or return 0;
    flock($fh, LOCK_EX);
    print $fh encode_json($data);
    close($fh);
    rename($tmp, $path) or return 0;
    return 1;
}

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
    if ($enabled) {
        $overrides->{$channelId} = JSON::PP::true;
    } else {
        delete $overrides->{$channelId};
    }
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

sub cleanupStaleActiveStreams {
    my $streams = loadActiveStreams();
    my $changed = 0;
    for my $key (keys %$streams) {
        my $entry = $streams->{$key};
        my $pid = ref($entry) eq 'HASH' ? $entry->{pid} : undef;
        if (!$pid || !kill(0, $pid)) {
            delete $streams->{$key};
            $changed = 1;
        }
    }
    saveActiveStreams($streams) if $changed;
    return $streams;
}


# ── Runtime config ───────────────────────────────────────────────────────────
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
    return (defined $cfg->{$key} && length $cfg->{$key}) ? $cfg->{$key} : $default;
}

# Read-only view for the SSE loop.  NEVER writes back – avoids overwriting
# entries that stream processes registered between our read and the write.
sub readActiveStreamsForDisplay {
    my $streams = loadActiveStreams();
    my %live;
    for my $key (keys %$streams) {
        my $entry = $streams->{$key};
        my $pid = ref($entry) eq 'HASH' ? $entry->{pid} : undef;
        $live{$key} = $entry if $pid && kill(0, $pid);
    }
    return \%live;
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
    my $overrides = loadHarmonizeOverrides();
    return 'harmonize' if $overrides->{$channelId};
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
    $maxLogs = 5 unless $maxLogs >= 5;
    shift @$logs while @$logs > $maxLogs;
    saveRecentLogs($logs);
}

sub buildAdminSnapshot {
    my ($region, %opts) = @_;
    $region ||= 'DE';
    # readonly=1: called from SSE loop (never writes active_streams.json)
    # readonly=0: called from page load (cleans up stale entries once)
    my $streams = $opts{readonly} ? readActiveStreamsForDisplay() : cleanupStaleActiveStreams();
    my $harmonize = loadHarmonizeOverrides();
    my $cfg = loadRuntimeConfig();
    my $logs = loadRecentLogs();

    my @entries;
    for my $key (sort keys %$streams) {
        my $entry = $streams->{$key};
        next unless ref($entry) eq 'HASH';
        my $channelId = $entry->{channelId} || '';
        push @entries, {
            key => $key,
            channelId => $channelId,
            channelName => $entry->{channelName} || $channelId,
            mode => $entry->{mode} || 'copy',
            desiredMode => $entry->{desiredMode} || ($harmonize->{$channelId} ? 'harmonize' : 'copy'),
            started => formatEpochLocal($entry->{startedAt}),
            pid => $entry->{pid} || 0,
            harmonize => ($harmonize->{$channelId} || 0) ? 1 : 0,
        };
    }

    my @harm;
    for my $channelId (sort keys %$harmonize) {
        my $channel = findChannelMetaById($channelId, $region);
        my $name = $channel ? ($channel->{name} || $channelId) : $channelId;
        push @harm, { channelId => $channelId, channelName => $name };
    }

    my $logDepth = int(getConfigValue('log_depth', 10));
    my @recent = map {
        +{
            ts => formatEpochLocal($_->{ts}),
            line => $_->{line},
        }
    } @$logs;

    return {
        region => $region,
        streams => \@entries,
        harmonizeList => \@harm,
        logs => \@recent,
        config => {
            stall_timeout => int(getConfigValue('stall_timeout', 15)),
            max_failures  => int(getConfigValue('max_failures', 5)),
            log_depth     => $logDepth,
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
                $client->flush();
                1
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

sub streamHlsViaFfmpeg {
    my ($client, $channelId, $region, $videoUrl, $audioUrl, $channelName, $headersSentRef, $activeStreamKey, $request) = @_;
    return 0 unless $ffmpeg;
    return 0 unless $videoUrl;

    $client->timeout(5);
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
            if ($debug) { printf("Failed to send headers - client disconnected: %s
", $@); }
            return 0;
        }
        $$headersSentRef = 1 if $headersSentRef;
    }

    my $maxFailures = int(getConfigValue('max_failures', 5));
    my $stall_timeout = int(getConfigValue('stall_timeout', 15));
    my $failures = 0;
    my $ua = createUserAgent();

    while ($failures < $maxFailures) {
        updateActiveStream($activeStreamKey, mode => 'harmonize', desiredMode => desiredModeByOverride($channelId, $request)) if $activeStreamKey;

        if ($failures > 0) {
            if ($debug) { printf("Restarting ffmpeg HLS harmonizer for %s (attempt %d/%d)
", $channelId, $failures + 1, $maxFailures); }
            sleep(2);
            my (undef, undef, undef, undef, $freshVideo, $freshAudio) = getPlaybackUrlsForChannel($channelId, $region, 1);
            $videoUrl = $freshVideo if $freshVideo;
            $audioUrl = $freshAudio if $freshAudio;
            detectNewPlaylistDiscontinuity($ua, $videoUrl, $audioUrl, \$last_seen_discontinuity_seq) unless defined $last_seen_discontinuity_seq;
        }

        my @cmd = (
            $ffmpeg, '-loglevel', 'fatal', '-nostdin',
            '-fflags', '+genpts+discardcorrupt',
            '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '2',
            '-i', $videoUrl,
        );

        if ($audioUrl) {
            push @cmd,
                '-fflags', '+genpts+discardcorrupt',
                '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '2',
                '-i', $audioUrl,
                '-map', '0:v:0?', '-map', '1:a:0?';
        } else {
            push @cmd, '-map', '0:v:0?', '-map', '0:a:0?';
        }

        push @cmd,
            '-c:v', 'copy',
            '-bsf:v', 'h264_mp4toannexb',
            '-c:a', 'copy',
            '-muxdelay', '0', '-muxpreload', '0',
            '-mpegts_flags', '+resend_headers',
            '-avoid_negative_ts', 'make_zero',
            '-max_interleave_delta', '1000000',
            '-flush_packets', '1',
            '-metadata', 'service_provider=PlutoTV',
            '-metadata', 'service_name=' . ($channelName || $channelId),
            '-f', 'mpegts', 'pipe:1';

        if ($debug) { printf("Starting ffmpeg HLS harmonizer for %s
", $channelId); }

        my $ffh;
        my $ffpid = open($ffh, '-|', @cmd);
        unless ($ffpid) { warn "Failed to start ffmpeg HLS harmonizer: $!
"; $failures++; next; }
        binmode($ffh);

        my $client_alive = 1;
        my $mode_switch_requested = 0;
        my $restart_due_to_discontinuity = 0;
        my $buffer = '';
        my $last_poll_at = 0;

        while (1) {
            if (desiredModeByOverride($channelId, $request) eq 'copy') {
                $mode_switch_requested = 1;
                last;
            }

            if (time() - $last_poll_at >= 1) {
                $last_poll_at = time();
                if ((time() - $last_restart_at) >= $restart_cooldown &&
                    detectNewPlaylistDiscontinuity($ua, $videoUrl, $audioUrl, \$last_seen_discontinuity_seq)) {
                    if ($debug) {
                        printf("Detected playlist discontinuity change for %s, restarting ffmpeg harmonizer
", $channelId);
                    }
                    appendRecentLog('DISCONTINUITY-Neustart: ' . $channelId);
                    $restart_due_to_discontinuity = 1;
                    $last_restart_at = time();
                    last;
                }
            }

            my $read = sysread($ffh, $buffer, 1316);
            last unless defined $read && $read > 0;
            my $ok = eval { $client->write($buffer); 1 };
            unless ($ok) { $client_alive = 0; last; }
        }

        if ($mode_switch_requested || $restart_due_to_discontinuity) {
            kill 'TERM', $ffpid if $ffpid;
        }
        close($ffh);

        return 'switch' if $mode_switch_requested;
        if ($restart_due_to_discontinuity) {
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

    if ($debug) {
        printf("Dynamic stream mode for %s: %s
", $channelId, $mode);
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
new_admin = r'''
sub sendAdminPage {
    my ($client, $request) = @_;
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};
    my $snapshot = buildAdminSnapshot($region);
    my $snapshotJson = encode_json($snapshot);
    my $regionsJson = encode_json([ sort keys %regions ]);

    my $html = <<"HTML";
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
header h1{font-size:16px;font-weight:600;letter-spacing:.02em}
header .sub{opacity:.55;font-size:12px;margin-left:auto}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.04em}
.badge-copy{background:#e3f0ff;color:#1565c0}
.badge-harmonize{background:#fdf3cd;color:#8a6000}
.badge-ok{background:#e6f4ea;color:#1e6e35}
.badge-warn{background:#fff3e0;color:#8a4500}
main{padding:24px;max-width:1200px;margin:0 auto;display:flex;flex-direction:column;gap:20px}
.card{background:#fff;border-radius:8px;border:1px solid #e0e4ea;overflow:hidden}
.card-head{padding:12px 18px;border-bottom:1px solid #e0e4ea;display:flex;align-items:center;gap:10px}
.card-head h2{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:#667085}
.card-head .dot{width:7px;height:7px;border-radius:50%;background:#22c55e}
.card-head .dot-off{background:#d1d5db}
.card-body{padding:18px}
table{width:100%;border-collapse:collapse}
th{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:#667085;padding:8px 12px;text-align:left;border-bottom:2px solid #e0e4ea;white-space:nowrap}
td{padding:10px 12px;border-bottom:1px solid #f0f2f5;vertical-align:middle}
tr:last-child td{border-bottom:none}
tr:hover td{background:#f8f9fb}
code{font-family:ui-monospace,monospace;font-size:12px;background:#f0f2f5;padding:1px 5px;border-radius:3px}
.btn{display:inline-flex;align-items:center;gap:5px;padding:5px 11px;border:1px solid #d1d5db;border-radius:5px;background:#fff;color:#374151;font-size:12px;cursor:pointer;font-family:inherit;transition:background .12s,border-color .12s;white-space:nowrap}
.btn:hover{background:#f3f4f6;border-color:#9ca3af}
.btn:active{background:#e5e7eb}
.btn:disabled{opacity:.45;cursor:not-allowed}
.btn-primary{background:#1a1d23;color:#fff;border-color:#1a1d23}
.btn-primary:hover{background:#2d3340;border-color:#2d3340}
.btn-danger{background:#fef2f2;color:#c0392b;border-color:#fca5a5}
.btn-danger:hover{background:#fee2e2;border-color:#f87171}
.btn-sm{padding:3px 8px;font-size:11px}
.actions{display:flex;gap:6px;flex-wrap:wrap}
.empty{color:#9ca3af;font-style:italic;padding:20px;text-align:center}
.cfg-row{display:flex;align-items:center;gap:12px;padding:8px 0;border-bottom:1px solid #f0f2f5}
.cfg-row:last-child{border-bottom:none}
.cfg-label{flex:1;font-size:13px;color:#374151}
.cfg-hint{flex:2;font-size:12px;color:#9ca3af}
.cfg-input{width:80px;padding:5px 8px;border:1px solid #d1d5db;border-radius:5px;font-size:13px;font-family:inherit;text-align:right}
.cfg-input:focus{outline:none;border-color:#6366f1}
.toast{position:fixed;bottom:24px;right:24px;padding:10px 16px;border-radius:7px;font-size:13px;font-weight:500;background:#1a1d23;color:#fff;opacity:0;transform:translateY(8px);transition:opacity .2s,transform .2s;pointer-events:none;z-index:999}
.toast.show{opacity:1;transform:translateY(0)}
.toast.err{background:#c0392b}
pre{font-family:ui-monospace,monospace;font-size:12px;white-space:pre-wrap;word-break:break-all;line-height:1.6;color:#374151;max-height:220px;overflow-y:auto}
.region-select{padding:4px 8px;border:1px solid #444;border-radius:5px;background:#2d3340;color:#fff;font-size:12px;font-family:inherit;cursor:pointer}
.sse-status{font-size:11px;display:flex;align-items:center;gap:5px}
.sse-dot{width:6px;height:6px;border-radius:50%;background:#22c55e;transition:background .3s}
.sse-dot.off{background:#ef4444}
</style>
</head>
<body>
<header>
  <h1>&#127916; PlutoTV Admin</h1>
  <select class="region-select" id="regionSel" onchange="changeRegion(this.value)">__REGION_OPTIONS__</select>
  <span class="sub">
    <span class="sse-status"><span class="sse-dot" id="sseDot"></span><span id="sseLabel">Verbinde...</span></span>
  </span>
</header>
<main>

  <div class="card" id="streamsCard">
    <div class="card-head">
      <span class="dot dot-off" id="streamsDot"></span>
      <h2>Aktive Streams</h2>
      <span id="streamsCount" style="margin-left:auto;font-size:11px;color:#9ca3af"></span>
    </div>
    <div id="streamsWrap">
      <table>
        <thead><tr>
          <th>Sender</th><th>ID</th><th>Start</th>
          <th>Modus</th><th>Harmonize</th><th>Aktionen</th>
        </tr></thead>
        <tbody id="streamsBody"><tr><td colspan="6" class="empty">Keine aktiven Streams.</td></tr></tbody>
      </table>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><h2>Konfiguration (wirkt ab n&auml;chstem ffmpeg-Start)</h2></div>
    <div class="card-body">
      <div class="cfg-row">
        <span class="cfg-label">Stall-Timeout</span>
        <span class="cfg-hint">Sekunden ohne ffmpeg-Output bevor Neustart</span>
        <input class="cfg-input" type="number" id="cfgStall" min="5" max="120" value="15">
        <span style="font-size:12px;color:#9ca3af">s</span>
      </div>
      <div class="cfg-row">
        <span class="cfg-label">Max. Fehlversuche</span>
        <span class="cfg-hint">Wie oft ffmpeg neu gestartet wird bevor Stream aufgibt</span>
        <input class="cfg-input" type="number" id="cfgFail" min="1" max="20" value="5">
      </div>
      <div class="cfg-row">
        <span class="cfg-label">Log-Tiefe</span>
        <span class="cfg-hint">Anzahl gespeicherter Log-Eintr&auml;ge</span>
        <input class="cfg-input" type="number" id="cfgLogDepth" min="5" max="100" value="10">
      </div>
      <div style="margin-top:14px">
        <button class="btn btn-primary" onclick="saveConfig()">Speichern</button>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><h2>Dauerhaft Harmonize</h2></div>
    <div class="card-body">
      <ul id="harmonizeList" style="padding-left:16px;line-height:1.9"></ul>
      <p id="harmonizeEmpty" class="empty" style="display:none">Keine dauerhaft aktivierten Harmonize-Sender.</p>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><h2>Letzte Log-Eintr&auml;ge</h2></div>
    <div class="card-body"><pre id="logBox">Keine Eintr&auml;ge.</pre></div>
  </div>

</main>
<div class="toast" id="toast"></div>
<script>
(function(){
const INIT = __SNAPSHOT__;
let currentRegion = "__REGION__";
const ALL_REGIONS = __REGIONS__;

function esc(s){
    return String(s==null?'':s)
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function toast(msg, isErr){
    const t = document.getElementById('toast');
    t.textContent = msg;
    t.className = 'toast show' + (isErr ? ' err' : '');
    clearTimeout(t._tid);
    t._tid = setTimeout(() => t.className = 'toast', 2800);
}

function api(path, params){
    const body = new URLSearchParams(params);
    return fetch(path, {method:'POST', body})
        .then(r => r.json())
        .then(d => {
            if(d.ok) toast(d.msg || 'OK');
            else toast(d.error || 'Fehler', true);
            return d;
        })
        .catch(e => { toast('Netzwerkfehler', true); });
}

function changeRegion(r){
    currentRegion = r;
    location.href = '/admin?region=' + encodeURIComponent(r);
}

function saveConfig(){
    api('/admin/set_config', {
        stall_timeout: document.getElementById('cfgStall').value,
        max_failures:  document.getElementById('cfgFail').value,
        log_depth:     document.getElementById('cfgLogDepth').value,
    });
}
window.saveConfig = saveConfig;
window.changeRegion = changeRegion;

function renderStreams(streams){
    const body = document.getElementById('streamsBody');
    const dot  = document.getElementById('streamsDot');
    const cnt  = document.getElementById('streamsCount');
    cnt.textContent = streams.length ? streams.length + ' aktiv' : '';
    dot.className   = 'dot' + (streams.length ? '' : ' dot-off');
    if(!streams.length){
        body.innerHTML = '<tr><td colspan="6" class="empty">Keine aktiven Streams.</td></tr>';
        return;
    }
    body.innerHTML = streams.map(e => {
        const harmOn = !!e.harmonize;
        return '<tr>'
            + '<td><strong>' + esc(e.channelName) + '</strong></td>'
            + '<td><code>' + esc(e.channelId) + '</code></td>'
            + '<td style="white-space:nowrap">' + esc(e.started) + '</td>'
            + '<td><span class="badge badge-' + esc(e.mode) + '">' + esc(e.mode) + '</span></td>'
            + '<td>' + (harmOn ? '<span class="badge badge-ok">an</span>' : '<span class="badge badge-warn">aus</span>') + '</td>'
            + '<td><div class="actions">'
            + '<button class="btn btn-sm" onclick="toggleHarmonize(' + JSON.stringify(e.channelId) + ',' + (harmOn?'0':'1') + ')">'
            +   (harmOn ? 'Harmonize aus' : 'Harmonize ein') + '</button>'
            + '<button class="btn btn-sm" onclick="forceDisc(' + JSON.stringify(e.channelId) + ')">'
            +   'DISCONTINUITY' + '</button>'
            + '<button class="btn btn-sm btn-danger" onclick="restartStream(' + JSON.stringify(e.key) + ')">'
            +   '&#8635; Neustart' + '</button>'
            + '</div></td>'
            + '</tr>';
    }).join('');
}

function renderHarmonize(list){
    const ul = document.getElementById('harmonizeList');
    const em = document.getElementById('harmonizeEmpty');
    if(!list.length){ ul.innerHTML=''; em.style.display='block'; return; }
    em.style.display='none';
    ul.innerHTML = list.map(e =>
        '<li>' + esc(e.channelName) + ' <code>' + esc(e.channelId) + '</code></li>'
    ).join('');
}

function renderLogs(logs){
    document.getElementById('logBox').textContent =
        logs.map(l => '[' + l.ts + '] ' + l.line).join('\n') || 'Keine Eintr\u00e4ge.';
}

function renderConfig(cfg){
    if(!cfg) return;
    document.getElementById('cfgStall').value    = cfg.stall_timeout ?? 15;
    document.getElementById('cfgFail').value     = cfg.max_failures  ?? 5;
    document.getElementById('cfgLogDepth').value = cfg.log_depth     ?? 10;
}

function render(snap){
    renderStreams(snap.streams || []);
    renderHarmonize(snap.harmonizeList || []);
    renderLogs(snap.logs || []);
    renderConfig(snap.config);
}

// Actions
function toggleHarmonize(channelId, enabled){
    api('/admin/toggle_harmonize', {channelId, enabled, region: currentRegion});
}
function forceDisc(channelId){
    api('/admin/force_discontinuity', {channelId, region: currentRegion});
}
function restartStream(key){
    api('/admin/restart_stream', {key});
}
window.toggleHarmonize = toggleHarmonize;
window.forceDisc = forceDisc;
window.restartStream = restartStream;

// Region selector
(function(){
    const sel = document.getElementById('regionSel');
    ALL_REGIONS.forEach(r => {
        const o = document.createElement('option');
        o.value = r; o.textContent = r;
        if(r === currentRegion) o.selected = true;
        sel.appendChild(o);
    });
})();

// SSE
let es, sseRetryTimer;
function connectSSE(){
    const dot   = document.getElementById('sseDot');
    const label = document.getElementById('sseLabel');
    if(es){ try{ es.close(); }catch(e){} }
    dot.className = 'sse-dot off';
    label.textContent = 'Verbinde...';
    es = new EventSource('/admin/events?region=' + encodeURIComponent(currentRegion));
    es.addEventListener('snapshot', ev => {
        try{ render(JSON.parse(ev.data)); }catch(e){}
    });
    es.onopen = () => {
        dot.className = 'sse-dot';
        label.textContent = 'Live';
        clearTimeout(sseRetryTimer);
    };
    es.onerror = () => {
        dot.className = 'sse-dot off';
        label.textContent = 'Getrennt';
        es.close();
        sseRetryTimer = setTimeout(connectSSE, 3000);
    };
}
connectSSE();

// Initial render from server-side snapshot
render(INIT);

})();
</script>
</body>
</html>
HTML
    # Build region <option> tags  (no JS needed, renders immediately)
    my $regionOptions = '';
    for my $r (sort keys %regions) {
        my $sel = ($r eq $region) ? ' selected' : '';
        $regionOptions .= "<option value=\"$r\"$sel>$r</option>";
    }
    $html =~ s/__SNAPSHOT__/$snapshotJson/;
    $html =~ s/__REGION__/$region/g;
    $html =~ s/__REGION_OPTIONS__/$regionOptions/;
    $html =~ s/__REGIONS__/$regionsJson/;
    my $response = HTTP::Response->new();
    $response->header("content-type", "text/html; charset=utf-8");
    $response->code(200);
    $response->message("OK");
    $response->content(encode_utf8($html));
    $client->send_response($response);
}
'''

with open('/home/claude/new_admin_page.py', 'w') as f:
f.write(new_admin)

print("admin page text written")

sub sendRedirect {
    my ($client, $location) = @_;
    my $response = HTTP::Response->new(303);
    $response->header('Location' => $location);
    $response->content('');
    $client->send_response($response);
}

sub sendJsonOk {
    my ($client, %extra) = @_;
    my $response = HTTP::Response->new(200);
    $response->header('Content-Type' => 'application/json; charset=utf-8');
    $response->header('Access-Control-Allow-Origin' => '*');
    $response->content(encode_json({ ok => 1, %extra }));
    $client->send_response($response);
}

sub sendJsonError {
    my ($client, $msg) = @_;
    my $response = HTTP::Response->new(400);
    $response->header('Content-Type' => 'application/json; charset=utf-8');
    $response->content(encode_json({ ok => 0, error => ($msg || 'error') }));
    $client->send_response($response);
}

sub handleAdminSetConfig {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $cfg = loadRuntimeConfig();
    my $changed = 0;
    for my $key (qw(stall_timeout max_failures log_depth)) {
        if ($params && defined $params->{$key} && $params->{$key} =~ /^\d+$/) {
            my $val = int($params->{$key});
            my %min = (stall_timeout => 5, max_failures => 1, log_depth => 5);
            my %max = (stall_timeout => 120, max_failures => 20, log_depth => 100);
            $val = $min{$key} if $val < $min{$key};
            $val = $max{$key} if $val > $max{$key};
            $cfg->{$key} = $val;
            $changed = 1;
        }
    }
    if ($changed) {
        saveRuntimeConfig($cfg);
        appendRecentLog(sprintf('Konfiguration gespeichert: stall=%ds fail=%d logs=%d',
            $cfg->{stall_timeout}||15, $cfg->{max_failures}||5, $cfg->{log_depth}||10));
        sendJsonOk($client);
    } else {
        sendJsonError($client, 'Keine gültigen Parameter');
    }
}

sub handleAdminRestartStream {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $key = $params && $params->{key} ? $params->{key} : '';
    unless ($key) {
        sendJsonError($client, 'Fehlender key-Parameter');
        return;
    }
    my $streams = loadActiveStreams();
    my $entry = $streams->{$key};
    unless (ref($entry) eq 'HASH' && $entry->{pid}) {
        sendJsonError($client, 'Stream nicht gefunden');
        return;
    }
    my $pid = $entry->{pid};
    unless (kill(0, $pid)) {
        sendJsonError($client, 'Prozess nicht mehr aktiv');
        return;
    }
    kill('TERM', $pid);
    appendRecentLog('Stream-Neustart angefordert: ' . ($entry->{channelId} || $key));
    sendJsonOk($client);
}

sub handleAdminToggleHarmonize {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $channelId = $params && $params->{channelId} ? $params->{channelId} : '';
    my $enabled = $params && defined $params->{enabled} ? $params->{enabled} : 0;
    my $region = $params && $params->{region} ? $params->{region} : 'DE';
    unless ($channelId) {
        sendJsonError($client, 'Fehlende channelId');
        return;
    }
    my $on = ($enabled =~ /^(1|true|yes|on)$/i) ? 1 : 0;
    setHarmonizeOverride($channelId, $on);
    appendRecentLog(($on ? 'Harmonize aktiviert: ' : 'Harmonize deaktiviert: ') . $channelId);
    sendJsonOk($client, msg => ($on ? 'Harmonize aktiviert' : 'Harmonize deaktiviert'));
}

sub handleAdminForceDiscontinuity {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $channelId = $params && $params->{channelId} ? $params->{channelId} : '';
    unless ($channelId) {
        sendJsonError($client, 'Fehlende channelId');
        return;
    }
    queueForcedDiscontinuity($channelId);
    appendRecentLog('DISCONTINUITY vorgemerkt: ' . $channelId);
    sendJsonOk($client, msg => 'DISCONTINUITY vorgemerkt');
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