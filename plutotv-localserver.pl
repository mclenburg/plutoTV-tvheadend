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

# On Linux/RPi, /proc/$pid is the only reliable liveness check for
# double-forked orphan processes when SIG{CHLD}='IGNORE'.
sub pidIsAlive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return (-d "/proc/$pid") ? 1 : 0 if -d '/proc';
    return kill(0, $pid) ? 1 : 0;
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

# SSE-only read: no write-back, avoids race with stream processes.
sub readActiveStreamsForDisplay {
    return loadActiveStreams();
}


sub loadRuntimeConfig {
    my $parsed = loadJsonFile($runtimeConfigStateFile, {});
    return {} unless ref($parsed) eq 'HASH';
    return $parsed;
}
sub saveRuntimeConfig {
    my ($hashref) = @_;
    return saveJsonFile($runtimeConfigStateFile, $hashref || {});
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
    my $ml = int(getConfigValue('log_depth', 10)); $ml = 5 if $ml < 5;
    shift @$logs while @$logs > $ml;
    saveRecentLogs($logs);
}

sub buildAdminSnapshot {
    my ($region, %opts) = @_;
    $region ||= 'DE';
    my $streams = $opts{readonly} ? readActiveStreamsForDisplay() : cleanupStaleActiveStreams();
    my $harmonize = loadHarmonizeOverrides();
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
            started   => formatEpochLocal($entry->{startedAt}),
            pid       => $entry->{pid} || 0,
            harmonize => ($harmonize->{$channelId} || 0) ? 1 : 0,
        };
    }

    my @harm;
    for my $channelId (sort keys %$harmonize) {
        my $channel = findChannelMetaById($channelId, $region);
        my $name = $channel ? ($channel->{name} || $channelId) : $channelId;
        push @harm, { channelId => $channelId, channelName => $name };
    }

    my @recent = map {
        +{
            ts => formatEpochLocal($_->{ts}),
            line => $_->{line},
        }
    } @$logs;

    return {
        region        => $region,
        streams       => \@entries,
        harmonizeList => \@harm,
        logs          => \@recent,
        config        => {
            stall_timeout => int(getConfigValue('stall_timeout', 30)),
            max_failures  => int(getConfigValue('max_failures',  5)),
            log_depth     => int(getConfigValue('log_depth',     10)),
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

# ── Hardware encoder detection ────────────────────────────────────────────────
# ── RPi4 hardware encoder detection ──────────────────────────────────────────
sub detectHwEncoder {
    return 'libx264' unless $ffmpeg;
    my $out = '';
    if (open(my $fh, '-|', $ffmpeg, '-hide_banner', '-encoders', '2>/dev/null')) {
        while (<$fh>) { $out .= $_; }
        close $fh;
    }
    return ($out =~ /h264_v4l2m2m/) ? 'h264_v4l2m2m' : 'libx264';
}

# Return '/dev/shm' if it exists (RPi RAM disk), else '/tmp'
sub shmBase { return (-d '/dev/shm') ? '/dev/shm' : '/tmp'; }

# ── Fetch one segment, decrypt AES-128-CBC if needed, return raw bytes ────────
# $keyCache: hashref {keyUri => hexKey} to avoid re-fetching the same key
sub fetchDecryptSegment {
    my ($ua, $segment, $keyCache) = @_;
    $keyCache //= {};

    my $res = $ua->get($segment->{url});
    unless ($res && $res->is_success) {
        printf("fetchDecrypt: segment fetch failed: %s\n", $segment->{url}) if $debug;
        return undef;
    }
    my $data = $res->content;

    if (($segment->{method} || 'NONE') eq 'AES-128' && ($segment->{keyUri} || '') ne '') {
        my $hexKey = $keyCache->{$segment->{keyUri}};
        unless ($hexKey) {
            my $kr = $ua->get($segment->{keyUri});
            unless ($kr && $kr->is_success && length($kr->content) == 16) {
                printf("fetchDecrypt: key fetch failed: %s\n", $segment->{keyUri}) if $debug;
                return undef;
            }
            $hexKey = unpack('H*', $kr->content);
            $keyCache->{$segment->{keyUri}} = $hexKey;
        }
        my $iv = $segment->{iv} || sprintf('%032x', $segment->{sequence} || 0);
        if (which('openssl')) {
            my ($out, $err) = ('', '');
            my $ok = eval {
                run(
                    ['openssl', 'enc', '-d', '-aes-128-cbc', '-K', $hexKey, '-iv', $iv],
                    '<', \$data, '>', \$out, '2>', \$err
                ); 1;
            };
            unless ($ok && length($out)) {
                printf("fetchDecrypt: openssl failed: %s\n", $err) if $debug;
                return undef;
            }
            $data = $out;
        } else {
            my $cipher = Crypt::CBC->new(
                -key     => pack('H*', $hexKey),
                -cipher  => 'Rijndael',
                -iv      => pack('H*', $iv),
                -header  => 'none',
                -padding => 'standard',
            );
            $data = $cipher->decrypt($data);
        }
    }
    return $data;
}

# ── Download + decrypt a batch of segments into $batchDir (RAM disk) ──────────
# Returns list of local file paths, or empty list on hard failure.
sub prepareSegmentBatch {
    my ($ua, $segsRef, $batchDir, $keyCache) = @_;
    my @segs = @{$segsRef || []};
    return () unless @segs;

    mkdir $batchDir unless -d $batchDir;

    my %savedMaps;   # mapUrl => local path
    my @localPaths;

    for my $i (0 .. $#segs) {
        my $seg  = $segs[$i];
        my $base = sprintf('%s/seg%04d.ts', $batchDir, $i);

        # Save init segment (fmp4 MAP) once per unique mapUrl
        if ($seg->{mapUrl} && !$savedMaps{$seg->{mapUrl}}) {
            my $mapData;
            if ($seg->{mapUrl} =~ m{^data:}i) {
                $mapData = decodeDataUri($seg->{mapUrl});
            } else {
                my $mr = $ua->get($seg->{mapUrl});
                $mapData = ($mr && $mr->is_success) ? $mr->content : undef;
            }
            if (defined $mapData) {
                my $mapPath = "$batchDir/init_$i.mp4";
                if (open(my $fh, '>', $mapPath)) {
                    binmode $fh; print $fh $mapData; close $fh;
                    $savedMaps{$seg->{mapUrl}} = $mapPath;
                }
            }
        }

        my $data = fetchDecryptSegment($ua, $seg, $keyCache);
        unless (defined $data) {
            printf("prepareSegmentBatch: failed segment %d, skipping batch\n", $i) if $debug;
            # Clean up partial batch
            unlink $_ for glob("$batchDir/*");
            rmdir $batchDir;
            return ();
        }

        if (open(my $fh, '>', $base)) {
            binmode $fh; print $fh $data; close $fh;
            push @localPaths, { path => $base,
                duration => $seg->{duration} || 10,
                mapPath  => $savedMaps{$seg->{mapUrl}} || '' };
        } else {
            printf("prepareSegmentBatch: write failed: %s\n", $!) if $debug;
            unlink $_ for glob("$batchDir/*");
            rmdir $batchDir;
            return ();
        }
    }
    return @localPaths;
}

# ── Write a finite HLS playlist for local (decrypted) segment files ───────────
sub writeBatchM3u8 {
    my ($m3uPath, $localPathsRef) = @_;
    my @paths = @{$localPathsRef || []};
    return 0 unless @paths;

    my $maxDur = 0;
    for my $p (@paths) { $maxDur = $p->{duration} if $p->{duration} > $maxDur; }
    $maxDur = int($maxDur + 1); $maxDur ||= 12;

    my $m3u  = "#EXTM3U\n#EXT-X-VERSION:3\n";
    $m3u    .= "#EXT-X-TARGETDURATION:$maxDur\n";
    $m3u    .= "#EXT-X-MEDIA-SEQUENCE:0\n";

    my $lastMap = '';
    for my $p (@paths) {
        if (($p->{mapPath} || '') ne $lastMap && $p->{mapPath}) {
            $m3u .= "#EXT-X-MAP:URI=\"$p->{mapPath}\"\n";
            $lastMap = $p->{mapPath};
        }
        $m3u .= sprintf("#EXTINF:%.4f,\n%s\n", $p->{duration}, $p->{path});
    }
    $m3u .= "#EXT-X-ENDLIST\n";

    open(my $fh, '>', $m3uPath) or return 0;
    print $fh $m3u;
    close $fh;
    return 1;
}

# ── Build the ffmpeg encoding command ─────────────────────────────────────────
sub buildFfmpegCmd {
    my ($m3uPath, $encoder) = @_;
    my @cmd = (
        $ffmpeg, '-v', 'fatal', '-nostdin',
        '-allowed_extensions', 'ALL',
        '-protocol_whitelist', 'file,pipe,crypto',
        '-fflags', '+genpts+discardcorrupt',
        '-i', $m3uPath,
        '-map', '0:v:0', '-map', '0:a:0?',  # '?' = no-abort if audio absent
    );
    if ($encoder eq 'h264_v4l2m2m') {
        push @cmd,
            '-c:v',              'h264_v4l2m2m',
            '-vf',               'format=nv12,scale=1280:720',  # NV12 is mandatory for RPi4 hw encoder
            '-num_capture_buffers', '16',
            '-num_output_buffers',  '16',
            '-b:v',              '4M',
            '-maxrate',          '4M',
            '-bufsize',          '8M';
    } else {
        push @cmd,
            '-c:v',     'libx264',
            '-preset',  'fast',
            '-crf',     '23',
            '-vf',      'scale=1280:720';
    }
    push @cmd,
        '-c:a',              'aac',
        '-ar',               '48000',
        '-b:a',              '128k',
        '-avoid_negative_ts', 'make_zero',
        '-f',                'mpegts',
        'pipe:1';
    return @cmd;
}

# ── Harmonized transcode pipeline ─────────────────────────────────────────────
# Masterplan:
#  1. Poll PlutoTV m3u8
#  2. Download + decrypt each segment to /dev/shm/ (or /tmp)
#  3. Write local m3u8 for each batch (up to next DISCONTINUITY)
#  4. Run ffmpeg (HW encoder if available) on local m3u8
#  5. Wait for previous ffmpeg to fully drain before starting next (sequential stitching)
#  6. Apply correctMpegTsTimestamps to ffmpeg output
#  7. Stream corrected bytes to tvheadend
sub streamHarmonized {
    my ($client, $channelId, $region, $videoUrl, $channelName, $headersSentRef, $activeStreamKey) = @_;
    return 0 unless $ffmpeg && $videoUrl;

    if (!$headersSentRef || !$$headersSentRef) {
        eval {
            $client->write("HTTP/1.1 200 OK\n");
            $client->write("Content-Type: video/mp2t\n");
            $client->write("Cache-Control: no-cache, no-store, must-revalidate\n");
            $client->write("Connection: close\n\n");
        };
        if ($@) {
            printf("streamHarmonized: header write failed: %s\n", $@) if $debug;
            return 0;
        }
        $$headersSentRef = 1 if $headersSentRef;
    }

    my $encoder        = detectHwEncoder();
    my $maxFailures    = int(getConfigValue('max_failures',  5));
    my $stallTimeout   = int(getConfigValue('stall_timeout', 30));
    my $startupTimeout = ($stallTimeout >= 30) ? $stallTimeout : 30;  # RPi4 hw driver needs time
    my $ua             = createUserAgent();
    my %keyCache;
    my %processed;
    my $lastRefreshAt  = 0;
    my $batchNum       = 0;
    my $failures       = 0;
    my $clientAlive    = 1;
    my @pendingSegs;   # segments carried over from after a DISCONTINUITY

    printf("streamHarmonized: channel=%s encoder=%s startup_timeout=%ds\n",
        $channelId, $encoder, $startupTimeout) if $debug;

    while ($clientAlive && $failures < $maxFailures) {

        # Periodically refresh the playlist URL (session token expiry)
        if ((time() - $lastRefreshAt) >= $sessionRefreshInterval) {
            my (undef, undef, undef, undef, $fresh) = getPlaybackUrlsForChannel($channelId, $region, 1);
            if ($fresh) { $videoUrl = $fresh; $lastRefreshAt = time(); }
        }

        # Fetch current playlist
        my $resp = getResponseFromUrl($videoUrl, ua => $ua);
        unless ($resp && $resp->is_success) {
            printf("streamHarmonized: playlist failed for %s: %s\n",
                $channelId, $resp ? $resp->status_line : 'no response') if $debug;
            $failures++; sleep(1); next;
        }

        my $content = $resp->decoded_content;
        my $info    = parsePlaylistInfo($content);
        my $rn      = 1;
        my @all     = extractSegmentsFromPlaylist($content, $videoUrl, $info, \$rn);
        my @newSegs = filterNewSegments(\@all, \%processed);

        # Merge carryover segments from previous DISCONTINUITY boundary
        unshift @newSegs, @pendingSegs;
        @pendingSegs = ();

        unless (@newSegs) { sleep(2); next; }

        # Split at first DISCONTINUITY: batch = segments BEFORE it
        my (@batch, @remainder);
        my $foundDisc = 0;
        for my $i (0 .. $#newSegs) {
            my $seg = $newSegs[$i];
            if ($seg->{isDiscontinuity} && @batch) {
                @remainder = @newSegs[$i .. $#newSegs];
                $foundDisc = 1;
                last;
            }
            push @batch, $seg;
        }
        @batch = @newSegs unless @batch;   # edge: DISCONTINUITY on very first segment

        # ── Step 2+3: Download, decrypt, write to RAM disk ────────────────────
        my $batchDir = shmBase() . "/plutotv-$$-$batchNum";
        my @local    = prepareSegmentBatch($ua, \@batch, $batchDir, \%keyCache);
        unless (@local) {
            printf("streamHarmonized: segment download failed, batch %d\n", $batchNum) if $debug;
            $failures++; sleep(1); next;
        }

        my $m3uPath = "$batchDir/playlist.m3u8";
        unless (writeBatchM3u8($m3uPath, \@local)) {
            unlink $_ for glob("$batchDir/*"); rmdir $batchDir;
            $failures++; sleep(1); next;
        }

        printf("streamHarmonized: batch %d: %d segs, disc=%s, encoder=%s\n",
            $batchNum, scalar(@batch), $foundDisc ? 'yes' : 'no', $encoder) if $debug;

        # ── Step 4: Start ffmpeg on local playlist ────────────────────────────
        my @cmd = buildFfmpegCmd($m3uPath, $encoder);

        my $ffh;
        my $ffpid = open($ffh, '-|');
        unless (defined $ffpid) {
            warn "streamHarmonized: fork failed: $!\n";
            unlink $_ for glob("$batchDir/*"); rmdir $batchDir;
            $failures++; sleep(1); next;
        }
        if ($ffpid == 0) { exec @cmd; exit(1); }
        binmode($ffh);

        # ── Steps 5+6+7: Read ffmpeg output → correct timestamps → send ───────
        # Sequential stitching is guaranteed because we read to EOF (close($ffh)
        # calls waitpid) before starting the next batch.
        my $sel         = IO::Select->new($ffh);
        my $lastOutput  = time();
        my $firstChunk  = ($batchNum > 0) ? 1 : 0;   # triggers TS discontinuity correction
        my $gotOutput   = 0;
        my $curTimeout  = $startupTimeout;             # longer wait for first byte (hw driver init)
        my $buf         = '';

        FFREAD: while (1) {
            my @ready = $sel->can_read(0.5);
            if (@ready) {
                my $n = sysread($ffh, $buf, 65536);
                last FFREAD unless defined $n && $n > 0;
                unless ($gotOutput) {
                    $gotOutput   = 1;
                    $curTimeout  = $stallTimeout;   # switch to shorter stall timeout after first byte
                }
                $lastOutput = time();
                # Step 6: timestamp correction
                my $out = correctMpegTsTimestamps($buf, "$channelId-harm", $firstChunk);
                $firstChunk = 0;
                # Step 7: send to tvheadend
                my $ok = eval { $client->write($out); 1 };
                unless ($ok) { $clientAlive = 0; last FFREAD; }
            } elsif (time() - $lastOutput >= $curTimeout) {
                printf("streamHarmonized: %s >%ds for %s batch %d\n",
                    $gotOutput ? 'stall' : 'startup timeout',
                    $curTimeout, $channelId, $batchNum) if $debug;
                last FFREAD;
            }
        }

        # Sequential stitching: wait for ffmpeg to fully exit before next batch
        close($ffh);   # implicit waitpid - previous process fully drained

        # Clean up RAM disk for this batch
        unlink $_ for glob("$batchDir/*");
        rmdir $batchDir;

        # Mark segments as processed
        $processed{$_->{url}} = time() for @batch;
        cleanupOldSegments(\%processed);
        $failures = 0;
        $batchNum++;

        if ($foundDisc && @remainder) {
            @pendingSegs = @remainder;
            # No sleep: move immediately to next batch
        } else {
            sleep(2);
        }
    }

    return 1;
}


sub sendDynamicStream {
    my ($client, $request) = @_;
    my $path = $request->uri->path;
    my ($channelId) = $path =~ m{/dynamic_stream/([^/]+)\.ts$};
    unless ($channelId) {
        $client->send_error(RC_BAD_REQUEST, "Invalid stream path");
        return;
    }
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'}
        if $params && $params->{'region'} && exists $regions{$params->{'region'}};

    my (undef, $channel, undef, undef, $videoUrl) = getPlaybackUrlsForChannel($channelId, $region);
    unless ($videoUrl) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream URL");
        return;
    }

    my $channelName = $channel ? ($channel->{name} || $channelId) : $channelId;
    my $harmonize   = loadHarmonizeOverrides();
    my $useHarmonize = ($harmonize->{$channelId} || $hybrid_harmonize_channels{$channelId}) ? 1 : 0;
    my $mode        = $useHarmonize ? 'harmonize' : 'copy';

    my $activeStreamKey = registerActiveStream(
        channelId   => $channelId,
        channelName => $channelName,
        mode        => $mode,
    );
    appendRecentLog("Stream gestartet: $channelName [$mode]");

    # Local handlers: guarantee cleanup on disconnect (SIGPIPE) or admin restart (SIGTERM)
    my $cleanup = sub {
        unregisterActiveStream($activeStreamKey) if $activeStreamKey;
        appendRecentLog("Stream unterbrochen: $channelName");
        exit(0);
    };
    local $SIG{PIPE} = $cleanup;
    local $SIG{TERM} = $cleanup;

    if ($debug) { printf("sendDynamicStream: %s mode=%s\n", $channelId, $mode); }

    my $headersSent = 0;
    if ($useHarmonize && $ffmpeg) {
        streamHarmonized($client, $channelId, $region, $videoUrl, $channelName,
            \$headersSent, $activeStreamKey);
    } else {
        streamWithDiscontinuityRestart($client, $channelId, $region, $videoUrl);
    }

    unregisterActiveStream($activeStreamKey);
    appendRecentLog("Stream beendet: $channelName");
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
    $region = $params->{'region'}
        if $params && $params->{'region'} && exists $regions{$params->{'region'}};
    my $snapshot     = buildAdminSnapshot($region);
    my $snapshotJson = encode_json($snapshot);
    my $regionsJson  = encode_json([ sort keys %regions ]);
    my $regionOpts   = join('', map {
        my $sel = ($_ eq $region) ? ' selected' : '';
        "<option value=\"$_\"$sel>$_</option>"
    } sort keys %regions);

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
        header{background:#1a1d23;color:#fff;padding:12px 20px;display:flex;align-items:center;gap:14px}
        header h1{font-size:15px;font-weight:600}
        .rsel{padding:4px 8px;border:1px solid #555;border-radius:5px;background:#2d3340;color:#fff;font-size:12px;cursor:pointer}
        .sse-pill{margin-left:auto;display:flex;align-items:center;gap:5px;font-size:11px;opacity:.75}
        .dot{width:7px;height:7px;border-radius:50%;background:#22c55e}
        .dot.off{background:#ef4444}
        main{padding:20px;max-width:1140px;margin:0 auto;display:flex;flex-direction:column;gap:16px}
        .card{background:#fff;border-radius:8px;border:1px solid #e0e4ea;overflow:hidden}
        .ch{padding:10px 16px;border-bottom:1px solid #e0e4ea;display:flex;align-items:center;gap:8px}
        .ch h2{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.07em;color:#667085}
        .cb{padding:0}
        .search-wrap{padding:10px 14px;border-bottom:1px solid #f0f2f5}
        .search-wrap input{width:100%;padding:7px 10px;border:1px solid #d1d5db;border-radius:5px;font-size:13px;font-family:inherit}
        .search-wrap input:focus{outline:none;border-color:#6366f1}
        .ch-list{max-height:420px;overflow-y:auto}
        .ch-row{display:flex;align-items:center;padding:8px 14px;border-bottom:1px solid #f5f7fa;gap:10px}
        .ch-row:last-child{border-bottom:none}
        .ch-row:hover{background:#fafbfc}
        .ch-name{flex:1;font-size:13px}
        .ch-id{font-size:11px;color:#9ca3af;font-family:ui-monospace,monospace}
        /* Toggle switch */
        .sw{position:relative;display:inline-block;width:36px;height:20px;flex-shrink:0}
        .sw input{opacity:0;width:0;height:0}
        .sl{position:absolute;inset:0;background:#d1d5db;border-radius:20px;cursor:pointer;transition:.2s}
        .sl:before{content:'';position:absolute;width:14px;height:14px;left:3px;top:3px;background:#fff;border-radius:50%;transition:.2s}
        input:checked+.sl{background:#6366f1}
        input:checked+.sl:before{transform:translateX(16px)}
        .ch-empty{padding:20px;text-align:center;color:#9ca3af;font-style:italic}
        table{width:100%;border-collapse:collapse}
        th{font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:#9ca3af;padding:7px 10px;text-align:left;border-bottom:2px solid #f0f2f5;white-space:nowrap}
        td{padding:9px 10px;border-bottom:1px solid #f5f7fa;vertical-align:middle}
        tr:last-child td{border-bottom:none}
        tr:hover td{background:#fafbfc}
        code{font-family:ui-monospace,monospace;font-size:12px;background:#f0f2f5;padding:1px 5px;border-radius:3px}
        .badge{display:inline-block;padding:2px 7px;border-radius:9px;font-size:11px;font-weight:600}
        .badge-harmonize{background:#fff8e1;color:#8a6000}
        .badge-copy{background:#e3f0ff;color:#1565c0}
        .btns{display:flex;gap:5px;flex-wrap:wrap}
        .btn{display:inline-flex;align-items:center;padding:4px 10px;border:1px solid #d1d5db;border-radius:5px;background:#fff;color:#374151;font-size:12px;cursor:pointer;font-family:inherit;white-space:nowrap}
        .btn:hover{background:#f3f4f6}
        .btn-danger{background:#fef2f2;color:#c0392b;border-color:#fca5a5}
        .btn-danger:hover{background:#fee2e2}
        .btn-save{background:#1a1d23;color:#fff;border-color:#1a1d23}
        .btn-save:hover{background:#2d3340}
        .empty{color:#9ca3af;font-style:italic;text-align:center;padding:16px}
        .cfg-row{display:flex;align-items:center;gap:10px;padding:7px 0;border-bottom:1px solid #f5f7fa}
        .cfg-row:last-child{border-bottom:none}
        .cfg-label{width:155px;font-size:13px;flex-shrink:0}
        .cfg-hint{flex:1;font-size:12px;color:#9ca3af}
        .cfg-num{width:70px;padding:4px 7px;border:1px solid #d1d5db;border-radius:5px;font-size:13px;font-family:inherit;text-align:right}
        .cfg-num:focus{outline:none;border-color:#6366f1}
        .cfg-unit{font-size:12px;color:#9ca3af;width:18px}
        pre{font-family:ui-monospace,monospace;font-size:12px;white-space:pre-wrap;line-height:1.6;color:#374151;max-height:190px;overflow-y:auto}
        .loading{color:#9ca3af;padding:20px;text-align:center}
        .toast{position:fixed;bottom:20px;right:20px;padding:9px 15px;border-radius:7px;font-size:13px;font-weight:500;background:#1a1d23;color:#fff;opacity:0;transform:translateY(6px);transition:opacity .2s,transform .2s;pointer-events:none;z-index:999}
        .toast.show{opacity:1;transform:none}
        .toast.err{background:#c0392b}
    </style>
</head>
<body>
<header>
    <h1>&#127916; PlutoTV Admin</h1>
    <select class="rsel" id="rsel">__REGION_OPTIONS__</select>
    <div class="sse-pill">
        <span class="dot off" id="sseDot"></span>
        <span id="sseLabel">Verbinde...</span>
    </div>
</header>
<main>

    <!-- Channel list with harmonize toggles -->
    <div class="card">
        <div class="ch">
            <h2>Sender-Konfiguration</h2>
            <span id="chCount" style="font-size:11px;color:#9ca3af;margin-left:auto"></span>
        </div>
        <div class="search-wrap">
            <input type="text" id="chSearch" placeholder="Sender suchen..." oninput="filterChannels(this.value)">
        </div>
        <div class="ch-list" id="chList">
            <div class="loading">Lade Sender...</div>
        </div>
    </div>

    <!-- Active streams -->
    <div class="card">
        <div class="ch">
            <span class="dot off" id="streamsDot"></span>
            <h2>Aktive Streams</h2>
            <span id="streamsCnt" style="font-size:11px;color:#9ca3af;margin-left:auto"></span>
        </div>
        <table>
            <thead><tr>
                <th>Sender</th><th>Modus</th><th>Start</th><th>Aktionen</th>
            </tr></thead>
            <tbody id="streamsTbody">
            <tr><td colspan="4" class="empty">Keine aktiven Streams.</td></tr>
            </tbody>
        </table>
    </div>

    <!-- Config -->
    <div class="card">
        <div class="ch">
            <h2>Konfiguration</h2>
            <span style="font-size:11px;color:#9ca3af;margin-left:6px">(ab naechstem Stream-Start)</span>
        </div>
        <div style="padding:12px 16px">
            <div class="cfg-row">
                <span class="cfg-label">Stall-Timeout</span>
                <span class="cfg-hint">Sekunden ohne ffmpeg-Output bis Neustart</span>
                <input class="cfg-num" type="number" id="cfgStall" min="5" max="120" value="30">
                <span class="cfg-unit">s</span>
            </div>
            <div class="cfg-row">
                <span class="cfg-label">Max. Fehlversuche</span>
                <span class="cfg-hint">Wie oft ein Batch neu startet</span>
                <input class="cfg-num" type="number" id="cfgFail" min="1" max="20" value="5">
                <span class="cfg-unit"></span>
            </div>
            <div class="cfg-row">
                <span class="cfg-label">Log-Tiefe</span>
                <span class="cfg-hint">Gespeicherte Log-Eintraege</span>
                <input class="cfg-num" type="number" id="cfgLog" min="5" max="100" value="10">
                <span class="cfg-unit"></span>
            </div>
            <div style="margin-top:12px">
                <button class="btn btn-save" onclick="saveConfig()">Speichern</button>
            </div>
        </div>
    </div>

    <!-- Log -->
    <div class="card">
        <div class="ch"><h2>Log</h2></div>
        <div style="padding:12px 16px"><pre id="logPre">Keine Eintraege.</pre></div>
    </div>

</main>
<div class="toast" id="toast"></div>
<script>
    (function(){
        'use strict';
        var snap0      = __SNAPSHOT__;
        var region0    = '__REGION__';
        var allRegions = __REGIONS__;
        var channels   = [];  // [{id, name, harmonize}]

    // Region selector
        document.getElementById('rsel').onchange = function(){
            location.href = '/admin?region=' + encodeURIComponent(this.value);
        };

        function esc(s){
            return String(s==null?'':s)
                .replace(/&/g,'&amp;').replace(/</g,'&lt;')
                .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        }
        function toast(msg, err){
            var t=document.getElementById('toast');
            t.textContent=msg; t.className='toast show'+(err?' err':'');
            clearTimeout(t._t); t._t=setTimeout(function(){t.className='toast';},2500);
        }
        function api(path, data, cb){
            var body=Object.keys(data).map(function(k){
                return encodeURIComponent(k)+'='+encodeURIComponent(data[k]);
            }).join('&');
            var xhr=new XMLHttpRequest();
            xhr.open('POST',path);
            xhr.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
            xhr.onload=function(){
                try{
                    var d=JSON.parse(xhr.responseText);
                    if(d.ok) toast(d.msg||'OK'); else toast(d.error||'Fehler',true);
                    if(cb) cb(d);
                }catch(e){toast('Fehler',true);}
            };
            xhr.onerror=function(){toast('Netzwerkfehler',true);};
            xhr.send(body);
        }

    // ── Channel list ─────────────────────────────────────────────────────────────
        function renderChannels(filter){
            var list=document.getElementById('chList');
            var q=(filter||'').toLowerCase().trim();
            var visible=q ? channels.filter(function(c){
                return (c.name||'').toLowerCase().indexOf(q)>=0 ||
                    (c.id||'').toLowerCase().indexOf(q)>=0;
            }) : channels;

            document.getElementById('chCount').textContent =
                channels.length + ' Sender' + (q ? ', '+visible.length+' gefiltert' : '');

            if(!visible.length){
                list.innerHTML='<div class="ch-empty">Keine Treffer.</div>';
                return;
            }
            list.innerHTML = visible.map(function(c){
                var chk = c.harmonize ? ' checked' : '';
                return '<div class="ch-row" data-id="'+esc(c.id)+'">'
                    + '<span class="ch-name">'+esc(c.name)+'</span>'
                    + '<span class="ch-id">'+esc(c.id)+'</span>'
                    + '<label class="sw"><input type="checkbox"'+chk+' onchange="toggleHarmonize(\''+esc(c.id)+'\',this.checked)">'
                    + '<span class="sl"></span></label>'
                    + '</div>';
            }).join('');
        }

        window.filterChannels = function(v){ renderChannels(v); };

        window.toggleHarmonize = function(channelId, on){
            api('/admin/toggle_harmonize',
                {channelId: channelId, enabled: on?'1':'0', region: region0},
                function(d){
                    if(!d.ok) return;
                    // Update local cache
                    var ch=channels.find(function(c){return c.id===channelId;});
                    if(ch){ ch.harmonize=on?1:0; }
                });
        };

        function loadChannels(){
            var xhr=new XMLHttpRequest();
            xhr.open('GET','/admin/channels?region='+encodeURIComponent(region0));
            xhr.onload=function(){
                try{
                    channels=JSON.parse(xhr.responseText);
                    renderChannels(document.getElementById('chSearch').value);
                }catch(e){
                    document.getElementById('chList').innerHTML=
                        '<div class="ch-empty">Fehler beim Laden.</div>';
                }
            };
            xhr.onerror=function(){
                document.getElementById('chList').innerHTML=
                    '<div class="ch-empty">Netzwerkfehler.</div>';
            };
            xhr.send();
        }

    // ── Active streams ────────────────────────────────────────────────────────────
        function renderStreams(streams){
            var tbody=document.getElementById('streamsTbody');
            var sdot=document.getElementById('streamsDot');
            var cnt=document.getElementById('streamsCnt');
            sdot.className='dot'+(streams.length?'':' off');
            cnt.textContent=streams.length?(streams.length+' aktiv'):'';
            if(!streams.length){
                tbody.innerHTML='<tr><td colspan="4" class="empty">Keine aktiven Streams.</td></tr>';
                return;
            }
            tbody.innerHTML=streams.map(function(e){
                return '<tr>'
                    +'<td><strong>'+esc(e.channelName)+'</strong><br>'
                    +'<span style="font-size:11px;color:#9ca3af">'+esc(e.channelId)+'</span></td>'
                    +'<td><span class="badge badge-'+esc(e.mode)+'">'+esc(e.mode)+'</span></td>'
                    +'<td>'+esc(e.started)+'</td>'
                    +'<td><div class="btns">'
                    +'<button class="btn btn-danger" onclick="restartStream(\''+esc(e.key)+'\')">'
                    +'&#8635; Neustart</button>'
                    +'</div></td>'
                    +'</tr>';
            }).join('');
        }

        window.restartStream = function(key){
            api('/admin/restart_stream',{key:key});
        };

    // ── Config ────────────────────────────────────────────────────────────────────
        function renderConfig(cfg){
            if(!cfg) return;
            if(cfg.stall_timeout!=null) document.getElementById('cfgStall').value=cfg.stall_timeout;
            if(cfg.max_failures!=null)  document.getElementById('cfgFail').value=cfg.max_failures;
            if(cfg.log_depth!=null)     document.getElementById('cfgLog').value=cfg.log_depth;
        }
        window.saveConfig = function(){
            api('/admin/set_config',{
                stall_timeout: document.getElementById('cfgStall').value,
                max_failures:  document.getElementById('cfgFail').value,
                log_depth:     document.getElementById('cfgLog').value
            });
        };

    // ── Render SSE snapshot ───────────────────────────────────────────────────────
        function renderLogs(logs){
            document.getElementById('logPre').textContent =
                (logs||[]).map(function(l){return '['+l.ts+'] '+l.line;}).join('\n')
                || 'Keine Eintraege.';
        }
        function render(s){
            renderStreams(s.streams||[]);
            renderLogs(s.logs||[]);
            renderConfig(s.config);
            // Update harmonize state in channel list from snapshot harmonizeList
            if(s.harmonizeList){
                var hmSet={};
                (s.harmonizeList||[]).forEach(function(e){ hmSet[e.channelId]=1; });
                channels.forEach(function(c){ c.harmonize=hmSet[c.id]?1:0; });
                renderChannels(document.getElementById('chSearch').value);
            }
        }

    // ── SSE ───────────────────────────────────────────────────────────────────────
        var es, retryT;
        function connectSSE(){
            var dot=document.getElementById('sseDot');
            var lbl=document.getElementById('sseLabel');
            if(es){try{es.close();}catch(e){}}
            dot.className='dot off'; lbl.textContent='Verbinde...';
            es=new EventSource('/admin/events?region='+encodeURIComponent(region0));
            es.addEventListener('snapshot',function(ev){
                try{render(JSON.parse(ev.data));}catch(e){}
            });
            es.onopen=function(){dot.className='dot';lbl.textContent='Live';clearTimeout(retryT);};
            es.onerror=function(){
                dot.className='dot off';lbl.textContent='Getrennt';
                es.close();retryT=setTimeout(connectSSE,3000);
            };
        }

    // ── Init ──────────────────────────────────────────────────────────────────────
        render(snap0);
        loadChannels();
        connectSSE();
    })();
</script>
</body>
</html>
HTML

    $html =~ s/__SNAPSHOT__/$snapshotJson/;
    $html =~ s/__REGION__/$region/g;
    $html =~ s/__REGION_OPTIONS__/$regionOpts/;
    $html =~ s/__REGIONS__/$regionsJson/;

    my $resp = HTTP::Response->new(200);
    $resp->header('content-type' => 'text/html; charset=utf-8');
    $resp->code(200);
    $resp->message('OK');
    $resp->content(encode_utf8($html));
    $client->send_response($resp);
}

sub sendJsonOk {
    my ($client, %extra) = @_;
    my $r = HTTP::Response->new(200);
    $r->header('Content-Type' => 'application/json; charset=utf-8');
    $r->content(encode_json({ ok => 1, %extra }));
    $client->send_response($r);
}
sub sendJsonError {
    my ($client, $msg) = @_;
    my $r = HTTP::Response->new(400);
    $r->header('Content-Type' => 'application/json; charset=utf-8');
    $r->content(encode_json({ ok => 0, error => ($msg || 'error') }));
    $client->send_response($r);
}

sub sendAdminChannels {
    my ($client, $request) = @_;
    my $region = 'DE';
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    $region = $params->{'region'}
        if $params && $params->{'region'} && exists $regions{$params->{'region'}};
    my @channels  = getChannelJson($region);
    my $harmonize = loadHarmonizeOverrides();
    my @result = map {
        { id        => ($_->{id} || ''),
            name      => ($_->{name} || ''),
            harmonize => ($harmonize->{$_->{id} || ''} ? 1 : 0) }
    } sort { lc($a->{name}||'') cmp lc($b->{name}||'') }
        grep { ($_->{number}||0) > 0 } @channels;
    my $r = HTTP::Response->new(200);
    $r->header('Content-Type' => 'application/json; charset=utf-8');
    $r->content(encode_json(\@result));
    $client->send_response($r);
}

sub handleAdminSetConfig {
    my ($client, $request) = @_;
    my $params  = try { HTTP::Request::Params->new({ req => $request })->params };
    my $cfg     = loadRuntimeConfig();
    my $changed = 0;
    my %limits  = (stall_timeout => [5, 120], max_failures => [1, 20], log_depth => [5, 100]);
    for my $key (keys %limits) {
        next unless $params && defined $params->{$key} && $params->{$key} =~ /^\d+$/;
        my $val = int($params->{$key});
        my ($lo, $hi) = @{$limits{$key}};
        $val = $lo if $val < $lo; $val = $hi if $val > $hi;
        $cfg->{$key} = $val; $changed = 1;
    }
    if ($changed) {
        saveRuntimeConfig($cfg);
        appendRecentLog(sprintf('Config: stall=%ds fail=%d logs=%d',
            $cfg->{stall_timeout}||30, $cfg->{max_failures}||5, $cfg->{log_depth}||10));
        sendJsonOk($client);
    } else {
        sendJsonError($client, 'Keine gueltigen Parameter');
    }
}

sub handleAdminRestartStream {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $key    = ($params && $params->{key}) ? $params->{key} : '';
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

sub sendRedirect {
    my ($client, $location) = @_;
    my $response = HTTP::Response->new(303);
    $response->header('Location' => $location);
    $response->content('');
    $client->send_response($response);
}

sub handleAdminToggleHarmonize {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $channelId = $params && $params->{channelId} ? $params->{channelId} : '';
    my $enabled = $params && defined $params->{enabled} ? $params->{enabled} : 0;
    my $region = $params && $params->{region} ? $params->{region} : 'DE';

    unless ($channelId) {
        sendRedirect($client, '/admin?msg=' . uri_escape_utf8('Fehlende channelId') . '&region=' . uri_escape_utf8($region));
        return;
    }

    my $on = ($enabled =~ /^(1|true|yes|on)$/i) ? 1 : 0;
    setHarmonizeOverride($channelId, $on);
    appendRecentLog(($on ? 'Harmonize aktiviert: ' : 'Harmonize deaktiviert: ') . $channelId);
    my $channel = findChannelMetaById($channelId, $region);
    my $name = $channel ? ($channel->{name} || $channelId) : $channelId;
    my $msg = $on
        ? "Harmonize für $name aktiviert."
        : "Harmonize für $name deaktiviert.";
    sendRedirect($client, '/admin?msg=' . uri_escape_utf8($msg) . '&region=' . uri_escape_utf8($region));
}

sub handleAdminForceDiscontinuity {
    my ($client, $request) = @_;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    my $channelId = $params && $params->{channelId} ? $params->{channelId} : '';
    my $region = $params && $params->{region} ? $params->{region} : 'DE';

    unless ($channelId) {
        sendRedirect($client, '/admin?msg=' . uri_escape_utf8('Fehlende channelId') . '&region=' . uri_escape_utf8($region));
        return;
    }

    queueForcedDiscontinuity($channelId);
    appendRecentLog('DISCONTINUITY vorgemerkt: ' . $channelId);
    my $channel = findChannelMetaById($channelId, $region);
    my $name = $channel ? ($channel->{name} || $channelId) : $channelId;
    my $msg = "DISCONTINUITY wird beim nächsten m3u8 für $name eingefügt.";
    sendRedirect($client, '/admin?msg=' . uri_escape_utf8($msg) . '&region=' . uri_escape_utf8($region));
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
    } elsif ($path eq "/admin") {
        sendAdminPage($client, $request);
    } elsif ($path eq "/admin/events") {
        sendAdminEvents($client, $request);
    } elsif ($path eq "/admin/toggle_harmonize") {
        handleAdminToggleHarmonize($client, $request);
    } elsif ($path eq "/admin/force_discontinuity") {
        handleAdminForceDiscontinuity($client, $request);
    } elsif ($path eq "/admin/channels") {
        sendAdminChannels($client, $request);
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