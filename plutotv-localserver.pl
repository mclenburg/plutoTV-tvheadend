#!/usr/bin/perl

package PlutoTVServer;

use strict;
use warnings;
use utf8;
use Encode qw(encode_utf8);
use HTTP::Daemon;
use HTTP::Status qw(:constants);
use HTTP::Request::Params;
use HTTP::Request ();
use HTTP::Headers;
use DateTime;
use JSON::Parse ':all';
use LWP::UserAgent;
use URI;
use URI::Escape qw(uri_escape_utf8);
use UUID::Tiny ':std';
use File::Which qw(which);
use Net::Address::IP::Local;
use Try::Tiny;
use Getopt::Long qw(GetOptionsFromArray);
use POSIX qw(strftime);
use File::Path qw(make_path);
use File::Spec;
use HTTP::Response;
use MIME::Base64 qw(decode_base64);
use open qw(:std :utf8);

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

my $version = '3.1.2';
my $deviceId = uuid_to_string(create_uuid(UUID_V4));
my $defaultPort = 9000;
my $defaultRegion = 'DE';
my $requestTimeout = 15;
my $channelCacheSeconds = 900;
my $appVersionCacheSeconds = 3600;
my $cacheDir = '/tmp/plutotv-localserver';

my $channelsApiUrl = 'https://service-channels.clusters.pluto.tv/v2/guide/channels';
my $categoriesApiUrl = 'https://service-channels.clusters.pluto.tv/v2/guide/categories';
my $timelinesApiUrl = 'https://service-channels.clusters.pluto.tv/v2/guide/timelines';
my $legacyGuideApiUrl = 'https://api.pluto.tv/v2/channels';
my $bootApiUrl = 'https://boot.pluto.tv/v4/start';
my $plutoWebsiteUrl = 'https://pluto.tv/';

my %regions = (
    'DE' => { lat => '52.5200', lon => '13.4050', name => 'Deutschland' },
    'US' => { lat => '40.7128', lon => '-74.0060', name => 'USA' },
    'UK' => { lat => '51.5074', lon => '-0.1278', name => 'Vereinigtes Königreich' },
    'FR' => { lat => '48.8566', lon => '2.3522', name => 'Frankreich' },
    'IT' => { lat => '41.9028', lon => '12.4964', name => 'Italien' },
);

my $debug = 0;
my $localOnly = 0;
my $useStreamlink = 0;
my $port = $defaultPort;
my $bindAddress;
my $showHelp = 0;

my @args = @ARGV;
GetOptionsFromArray(
    \@args,
    'debug!'         => \$debug,
    'localonly|localhost!' => \$localOnly,
    'usestreamlink!' => \$useStreamlink,
    'port=i'         => \$port,
    'bind=s'         => \$bindAddress,
    'help|h'         => \$showHelp,
) or die "Ungültige Kommandozeilenoption. Verwende --help.\n";

die "Unbekannte Argumente: " . join(' ', @args) . "\n" if @args;
die "Ungültiger Port: $port\n" if $port < 1 || $port > 65535;

my $ffmpeg = which('ffmpeg');
my $streamlink = which('streamlink');

if ($useStreamlink && !$streamlink) {
    die "--usestreamlink wurde gesetzt, aber 'streamlink' wurde nicht gefunden.\n";
}

if (!$useStreamlink && !$ffmpeg) {
    die "'ffmpeg' wurde nicht gefunden. Bitte ffmpeg installieren.\n";
}

if ($localOnly) {
    $bindAddress = '127.0.0.1';
} elsif (!defined $bindAddress || $bindAddress eq '') {
    $bindAddress = '0.0.0.0';
}

my $advertisedHost = '127.0.0.1';
if (!$localOnly) {
    my $detected = try { Net::Address::IP::Local->public_ipv4 };
    $advertisedHost = $detected if defined $detected && $detected ne '';
}

make_path($cacheDir) unless -d $cacheDir;

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

sub logDebug {
    return unless $debug;
    my ($message) = @_;
    my $timestamp = strftime('%Y-%m-%d %H:%M:%S', localtime());
    print STDERR "[$timestamp] DEBUG: $message\n";
}

sub logWarn {
    my ($message) = @_;
    my $timestamp = strftime('%Y-%m-%d %H:%M:%S', localtime());
    print STDERR "[$timestamp] WARNUNG: $message\n";
}

sub xmlEscape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&apos;/g;
    return $value;
}

sub m3uEscape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/[\r\n]+/ /g;
    $value =~ s/"/'/g;
    return $value;
}

sub validateRegion {
    my ($region) = @_;
    $region = uc($region || $defaultRegion);
    return exists $regions{$region} ? $region : $defaultRegion;
}

sub requestParams {
    my ($request) = @_;
    return {} unless $request;
    my $params = try { HTTP::Request::Params->new({ req => $request })->params };
    return $params || {};
}

sub requestRegion {
    my ($request) = @_;
    my $params = requestParams($request);
    return validateRegion($params->{region});
}

sub requestProto {
    my ($request) = @_;
    my $params = requestParams($request);
    my $proto = lc($params->{proto} || 'http');
    return ($proto eq 'https') ? 'https' : 'http';
}

sub requestHost {
    my ($request) = @_;
    my $host = $request ? $request->header('Host') : undef;
    if (defined $host && $host =~ /\A(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(?::\d{1,5})?\z/) {
        return $host;
    }
    return "$advertisedHost:$port";
}

sub createUserAgent {
    my $ua = LWP::UserAgent->new(
        keep_alive => 1,
        timeout => $requestTimeout,
        max_redirect => 5,
    );
    $ua->agent('Mozilla/5.0 (X11; Linux aarch64; rv:128.0) Gecko/20100101 Firefox/128.0');
    my $headers = HTTP::Headers->new;
    $headers->header('Accept' => '*/*');
    $headers->header('Cache-Control' => 'no-cache');
    $headers->header('Pragma' => 'no-cache');
    $ua->default_headers($headers);
    return $ua;
}

sub httpGetResponse {
    my ($url, $extraHeaders) = @_;
    my $ua = createUserAgent();
    my $request = HTTP::Request->new(GET => $url);
    if ($extraHeaders) {
        for my $name (keys %{$extraHeaders}) {
            $request->header($name => $extraHeaders->{$name});
        }
    }
    logDebug("HTTP GET $url");
    my $response = $ua->request($request);
    unless ($response->is_success) {
        logWarn("HTTP-Aufruf fehlgeschlagen: $url -> " . $response->status_line);
    }
    return $response;
}

sub httpGetContent {
    my ($url, $extraHeaders) = @_;
    my $response = httpGetResponse($url, $extraHeaders);
    return undef unless $response->is_success;
    return $response->decoded_content(charset => 'none');
}

sub parseJsonSafe {
    my ($content, $context) = @_;
    return undef unless defined $content && $content ne '';
    my $json;
    try {
        $json = parse_json($content);
    } catch {
        logWarn("Ungültiges JSON bei $context: $_");
    };
    return $json;
}

sub readCacheFile {
    my ($name, $maxAge) = @_;
    my $path = File::Spec->catfile($cacheDir, $name);
    return undef unless -f $path;
    my @stat = stat($path);
    return undef unless @stat && (time() - $stat[9]) <= $maxAge;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

sub writeCacheFile {
    my ($name, $content) = @_;
    my $path = File::Spec->catfile($cacheDir, $name);
    my $tmp = "$path.$$";
    open(my $fh, '>:raw', $tmp) or do {
        logWarn("Cache-Datei $tmp konnte nicht geschrieben werden: $!");
        return;
    };
    print {$fh} $content;
    close($fh);
    rename($tmp, $path) or do {
        logWarn("Cache-Datei $path konnte nicht atomar ersetzt werden: $!");
        unlink($tmp);
    };
}

sub getPlutoAppVersion {
    my $cached = readCacheFile('app-version.txt', $appVersionCacheSeconds);
    if (defined $cached) {
        $cached =~ s/\s+\z//;
        return $cached if $cached ne '';
    }

    my $content = httpGetContent($plutoWebsiteUrl);
    my $version;

    if (defined $content) {
        if ($content =~ /<meta\s+[^>]*(?:name=["'](?:appVersion|app_version)["'][^>]*content=["']([^"']+)["']|content=["']([^"']+)["'][^>]*name=["'](?:appVersion|app_version)["'])/i) {
            $version = defined $1 ? $1 : $2;
        }
        if (!$version && $content =~ /"globalAppVersion"\s*:\s*"([^"]+)"/) {
            $version = $1;
        }
    }

    # Pluto war historisch bei appVersion tolerant. Der Fallback wird nur genutzt,
    # falls die Website ihre HTML-Struktur ändert oder kurzzeitig nicht erreichbar ist.
    $version ||= '9.1.0';

    writeCacheFile('app-version.txt', $version . "\n");
    logDebug("Verwendete Pluto-appVersion: $version");
    return $version;
}

sub buildBootUrl {
    my ($region, $channelSlug) = @_;
    $region = validateRegion($region);
    my $regionData = $regions{$region};
    my $appVersion = getPlutoAppVersion();

    my %params = (
        appName => 'web',
        appVersion => $appVersion,
        deviceVersion => '128.0',
        deviceModel => 'web',
        deviceMake => 'firefox',
        deviceType => 'web',
        clientID => $deviceId,
        clientModelNumber => '1.0.0',
        serverSideAds => 'false',
        includeExtendedEvents => 'true',
        DNT => '1',
        deviceId => $deviceId,
        deviceLat => $regionData->{lat},
        deviceLon => $regionData->{lon},
    );
    $params{channelSlug} = $channelSlug if defined $channelSlug && $channelSlug ne '';

    return $bootApiUrl . '?' . join('&', map {
        uri_escape_utf8($_) . '=' . uri_escape_utf8(defined $params{$_} ? $params{$_} : '')
    } sort keys %params);
}

sub tokenExpiry {
    my ($token) = @_;
    return 0 unless defined $token;
    my @parts = split /\./, $token;
    return 0 unless @parts >= 2;
    my $payload = $parts[1];
    $payload =~ tr/-_/+\//;
    $payload .= '=' x ((4 - length($payload) % 4) % 4);
    my $decoded = try { decode_base64($payload) };
    return 0 unless defined $decoded && $decoded ne '';
    my $json = parseJsonSafe($decoded, 'JWT');
    return ($json && ref($json) eq 'HASH' && $json->{exp}) ? $json->{exp} : 0;
}

sub getBootFromPluto {
    my ($region, $channelSlug) = @_;
    $region = validateRegion($region);

    my $cacheName = 'boot-' . lc($region) . '.json';
    if (!defined $channelSlug || $channelSlug eq '') {
        my $cached = readCacheFile($cacheName, 3600);
        if (defined $cached) {
            my $boot = parseJsonSafe($cached, 'Boot-Cache');
            if ($boot && ref($boot) eq 'HASH' && $boot->{sessionToken}) {
                my $exp = tokenExpiry($boot->{sessionToken});
                if (!$exp || $exp > time() + 60) {
                    return $boot if $boot->{servers} && $boot->{servers}->{stitcher} && $boot->{stitcherParams};
                }
            }
        }
    }

    my $url = buildBootUrl($region, $channelSlug);
    my $content = httpGetContent($url);
    my $boot = parseJsonSafe($content, 'Pluto-Boot-API');

    unless ($boot && ref($boot) eq 'HASH' && $boot->{servers} && $boot->{servers}->{stitcher} && defined $boot->{stitcherParams} && $boot->{sessionToken}) {
        logWarn('Boot-Antwort enthält nicht die erwarteten Session-/Stitcher-Daten.');
        return undef;
    }

    writeCacheFile($cacheName, $content) if !defined $channelSlug || $channelSlug eq '';
    return $boot;
}

sub authHeaders {
    my ($boot) = @_;
    return {
        'Accept' => 'application/json, text/plain, */*',
        'Authorization' => 'Bearer ' . $boot->{sessionToken},
        'Origin' => 'https://pluto.tv',
        'Referer' => 'https://pluto.tv/',
    };
}

sub modernChannelCatalog {
    my ($boot) = @_;
    my $headers = authHeaders($boot);
    my $params = 'channelIds=&offset=0&limit=1000&sort=number%3Aasc';

    my $channelContent = httpGetContent($channelsApiUrl . '?' . $params, $headers);
    my $channelResponse = parseJsonSafe($channelContent, 'moderne Sender-API');
    my $channelList = ($channelResponse && ref($channelResponse) eq 'HASH' && ref($channelResponse->{data}) eq 'ARRAY')
        ? $channelResponse->{data} : [];
    return [] unless @{$channelList};

    my %categories;
    my $categoryContent = httpGetContent($categoriesApiUrl . '?' . $params, $headers);
    my $categoryResponse = parseJsonSafe($categoryContent, 'moderne Kategorien-API');
    if ($categoryResponse && ref($categoryResponse) eq 'HASH' && ref($categoryResponse->{data}) eq 'ARRAY') {
        for my $category (@{$categoryResponse->{data}}) {
            next unless ref($category) eq 'HASH';
            my $name = $category->{name} || '';
            for my $id (@{$category->{channelIDs} || []}) {
                $categories{$id} = $name;
            }
        }
    }

    my @channels;
    for my $channel (@{$channelList}) {
        next unless ref($channel) eq 'HASH';
        my $id = $channel->{id} || '';
        next if $id eq '';
        my $logo = '';
        for my $image (@{$channel->{images} || []}) {
            next unless ref($image) eq 'HASH';
            if (($image->{type} || '') eq 'colorLogoPNG' && $image->{url}) {
                $logo = $image->{url};
                last;
            }
        }
        push @channels, {
            _id => $id,
            name => $channel->{name} || '',
            slug => $channel->{slug} || '',
            number => $channel->{number} || 0,
            category => $categories{$id} || '',
            logo => { path => $logo },
            timelines => [],
        };
    }
    return \@channels;
}

sub attachModernGuide {
    my ($boot, $channels) = @_;
    return unless $channels && @{$channels};
    my $headers = authHeaders($boot);
    my %lookup = map { $_->{_id} => $_ } @{$channels};
    my @ids = map { $_->{_id} } @{$channels};

    for my $dayOffset (0, 1) {
        my $window = DateTime->now(time_zone => 'UTC')->add(days => $dayOffset);
        $window->set(minute => 0, second => 0, nanosecond => 0) if $window->can('set');
        my $startString = $window->strftime('%Y-%m-%dT%H:00:00Z');

        for (my $i = 0; $i < @ids; $i += 100) {
            my $last = $i + 99;
            $last = $#ids if $last > $#ids;
            my @group = @ids[$i .. $last];
            my $url = $timelinesApiUrl
                . '?start=' . uri_escape_utf8($startString)
                . '&channelIds=' . uri_escape_utf8(join(',', @group))
                . '&duration=1440';

            my $content = httpGetContent($url, $headers);
            my $response = parseJsonSafe($content, 'moderne EPG-API');
            next unless $response && ref($response) eq 'HASH' && ref($response->{data}) eq 'ARRAY';

            for my $entry (@{$response->{data}}) {
                next unless ref($entry) eq 'HASH';
                my $id = $entry->{channelId} || '';
                next unless $lookup{$id};
                push @{$lookup{$id}->{timelines}}, @{$entry->{timelines} || []};
            }
        }
    }
}

sub getChannelJsonLegacy {
    my ($region, $boot) = @_;
    my $from = DateTime->now(time_zone => 'UTC');
    my $to = DateTime->now(time_zone => 'UTC')->add(days => 2);
    my $fromString = $from->strftime('%Y-%m-%dT%H:%M:%S.000Z');
    my $toString = $to->strftime('%Y-%m-%dT%H:%M:%S.000Z');

    my $url = $legacyGuideApiUrl
        . '?start=' . uri_escape_utf8($fromString)
        . '&stop=' . uri_escape_utf8($toString)
        . '&sid=' . uri_escape_utf8($deviceId)
        . '&deviceId=' . uri_escape_utf8($deviceId);

    my $content = httpGetContent($url);
    my $channels = parseJsonSafe($content, 'Legacy-Sender-/EPG-API');
    return ($channels && ref($channels) eq 'ARRAY') ? ($channels, $content) : (undef, undef);
}

sub getChannelJson {
    my ($region) = @_;
    $region = validateRegion($region);
    my $cacheName = 'channels-' . lc($region) . '.json';
    my $cachedContent = readCacheFile($cacheName, $channelCacheSeconds);
    if (defined $cachedContent) {
        my $cachedChannels = parseJsonSafe($cachedContent, 'Sender-Cache');
        return @{$cachedChannels} if $cachedChannels && ref($cachedChannels) eq 'ARRAY';
    }

    my $boot = getBootFromPluto($region, undef);
    if ($boot) {
        my $channels = modernChannelCatalog($boot);
        if ($channels && @{$channels}) {
            attachModernGuide($boot, $channels);
            require JSON::PP;
            my $content = JSON::PP->new->utf8->canonical->encode($channels);
            writeCacheFile($cacheName, $content);
            return @{$channels};
        }
        logWarn('Moderne Pluto-Sender-API lieferte keine Sender; Legacy-Fallback wird verwendet.');
    }

    my ($legacyChannels, $legacyContent) = getChannelJsonLegacy($region, $boot);
    if ($legacyChannels) {
        writeCacheFile($cacheName, $legacyContent);
        return @{$legacyChannels};
    }

    return ();
}

sub buildModernStitcherUrl {
    my ($boot, $channelId) = @_;
    my $base = $boot->{servers}->{stitcher};
    $base =~ s{/+$}{};

    my $uri = URI->new($base . '/v2/stitch/hls/channel/' . $channelId . '/master.m3u8');
    my $queryParser = URI->new('http://localhost/?' . ($boot->{stitcherParams} || ''));
    my %params = $queryParser->query_form;
    $params{jwt} = $boot->{sessionToken};
    $params{includeExtendedEvents} = 'true';
    $params{masterJWTPassthrough} = 'true';
    $uri->query_form(%params);
    return $uri->as_string;
}

sub getModernStreamUrl {
    my ($region, $channelId) = @_;
    my $boot = getBootFromPluto($region, undef);
    return undef unless $boot;
    return buildModernStitcherUrl($boot, $channelId);
}

sub resolveBestVariantUrl {
    my ($masterUrl) = @_;
    my $master = httpGetContent($masterUrl);
    return $masterUrl unless defined $master && $master =~ /^#EXTM3U/m;

    my @lines = split /\r?\n/, $master;
    my $bestUrl;
    my $bestBandwidth = -1;

    for (my $i = 0; $i <= $#lines; $i++) {
        my $line = $lines[$i];
        next unless $line =~ /^#EXT-X-STREAM-INF:(.*)$/i;
        my $attrs = $1;
        my ($bandwidth) = $attrs =~ /(?:^|,)BANDWIDTH=(\d+)/i;
        $bandwidth ||= 0;

        my $j = $i + 1;
        $j++ while $j <= $#lines && ($lines[$j] eq '' || $lines[$j] =~ /^#/);
        next if $j > $#lines;

        if ($bandwidth > $bestBandwidth) {
            $bestBandwidth = $bandwidth;
            $bestUrl = URI->new_abs($lines[$j], $masterUrl)->as_string;
        }
    }

    return $bestUrl || $masterUrl;
}

sub sendPlainResponse {
    my ($client, $code, $contentType, $content) = @_;
    my $response = HTTP::Response->new($code);
    $response->header('Content-Type' => $contentType);
    $response->header('Cache-Control' => 'no-cache, no-store, must-revalidate');
    $response->header('Pragma' => 'no-cache');
    $response->header('Expires' => '0');
    $response->content($content);
    $client->send_response($response);
}

# ---------------------------------------------------------------------------
# M3U / EPG
# ---------------------------------------------------------------------------

sub buildM3uLegacy {
    my ($proto, $host, $region, @channels) = @_;
    my $m3u = "#EXTM3U\n";

    for my $channel (@channels) {
        next unless ref($channel) eq 'HASH';
        next unless ($channel->{number} || 0) > 0 && ($channel->{number} || 0) != 2000;
        next unless $channel->{_id};

        my $logo = ref($channel->{logo}) eq 'HASH' ? ($channel->{logo}->{path} || '') : '';
        my $name = m3uEscape($channel->{name} || $channel->{_id});
        my $number = $channel->{number};
        my $id = m3uEscape($channel->{_id});
        my $regionParam = uri_escape_utf8($region);

        $m3u .= "#EXTINF:-1 tvg-chno=\"$number\" tvg-id=\"$id\" tvg-name=\"$name\" tvg-logo=\""
            . m3uEscape($logo) . "\" group-title=\"PlutoTV\",$name\n";

        if ($useStreamlink) {
            my $slug = $channel->{slug} || $channel->{_id};
            # Öffentliche URL-Struktur des Originals beibehalten.
            $m3u .= 'pipe://' . $streamlink
                . ' --stdout --quiet --default-stream best '
                . '--hls-live-restart --url '
                . '"https://pluto.tv/' . $region . '/live-tv/' . m3uEscape($slug) . '"' . "\n";
        } else {
            # Kompatibilität: /playlist benutzt weiterhin den bereits vorhandenen
            # /stream/{id}.m3u8-Endpunkt. Die Modernisierung bleibt dahinter verborgen.
            my $localUrl = "$proto://$host/stream/$channel->{_id}.m3u8?proto=$proto&region=$regionParam";
            $m3u .= 'pipe://' . $ffmpeg
                . ' -loglevel fatal -threads 0 -nostdin -re '
                . '-i "' . $localUrl . '" '
                . '-c copy -vcodec copy -acodec copy -mpegts_copyts 1 -f mpegts '
                . '-tune zerolatency -mpegts_service_type advanced_codec_digital_hdtv '
                . '-metadata service_name="' . $name . '" pipe:1' . "\n";
        }
    }
    return $m3u;
}

sub buildM3uDirect {
    my ($proto, $host, $region, @channels) = @_;
    my $m3u = "#EXTM3U\n";

    for my $channel (@channels) {
        next unless ref($channel) eq 'HASH';
        next unless ($channel->{number} || 0) > 0 && ($channel->{number} || 0) != 2000;
        next unless $channel->{_id};

        my $logo = ref($channel->{logo}) eq 'HASH' ? ($channel->{logo}->{path} || '') : '';
        my $name = m3uEscape($channel->{name} || $channel->{_id});
        my $number = $channel->{number};
        my $id = m3uEscape($channel->{_id});
        my $regionParam = uri_escape_utf8($region);

        $m3u .= "#EXTINF:-1 tvg-chno=\"$number\" tvg-id=\"$id\" tvg-name=\"$name\" tvg-logo=\""
            . m3uEscape($logo) . "\" group-title=\"PlutoTV\",$name\n";
        # Öffentliche TVHeadend-URL wie im Original beibehalten.
        $m3u .= "$proto://$host/stream/$channel->{_id}.m3u8?proto=$proto&region=$regionParam\n";
    }
    return $m3u;
}

sub sendHelp {
    my ($client) = @_;
    my $text = "PlutoTVServer $version\n\n"
        . "Endpunkte:\n"
        . "  /playlist?region=DE   M3U mit Pipe-Einträgen\n"
        . "  /tvheadend?region=DE  M3U mit direkten lokalen MPEG-TS-Streams\n"
        . "  /stream/{id}.m3u8     Kompatibilitäts-HLS-Endpunkt\n"
        . "  /dynamic_stream/{id}.ts?region=DE  direkter MPEG-TS-Stream\n"
        . "  /epg?region=DE        XMLTV-EPG\n"
        . "  /health               Statusprüfung\n\n"
        . "Regionen: " . join(', ', sort keys %regions) . "\n\n"
        . "Hinweis: Pluto bestimmt den tatsächlichen Katalog primär über die öffentliche IP-Adresse.\n"
        . "Die Regionsangabe wird an die Pluto-Session weitergegeben, kann aber kein VPN/Geo-Routing ersetzen.\n";
    sendPlainResponse($client, HTTP_OK, 'text/plain; charset=utf-8', encode_utf8($text));
}

sub sendHealth {
    my ($client) = @_;
    my $status = "OK\nVersion=$version\nffmpeg=" . ($ffmpeg || 'nicht gefunden')
        . "\nstreamlink=" . ($streamlink || 'nicht gefunden') . "\n";
    sendPlainResponse($client, HTTP_OK, 'text/plain; charset=utf-8', encode_utf8($status));
}

sub sendXmltvEpgFile {
    my ($client, $request) = @_;
    my $region = requestRegion($request);
    my @channels = getChannelJson($region);
    unless (@channels) {
        $client->send_error(HTTP_INTERNAL_SERVER_ERROR, 'Senderliste konnte nicht von Pluto TV geladen werden.');
        return;
    }

    my $langcode = lc($region eq 'UK' ? 'en' : $region);
    my $epg = qq{<?xml version="1.0" encoding="UTF-8" ?>\n<tv generator-info-name="PlutoTVServer $version">\n};

    for my $channel (@channels) {
        next unless ref($channel) eq 'HASH';
        next unless ($channel->{number} || 0) > 0;
        next unless $channel->{_id};

        my $channelName = xmlEscape($channel->{name} || $channel->{_id});
        my $channelId = xmlEscape($channel->{_id});
        $epg .= qq{<channel id="$channelId">\n};
        $epg .= qq{<display-name lang="$langcode">$channelName</display-name>\n};

        if (ref($channel->{logo}) eq 'HASH' && $channel->{logo}->{path}) {
            my $logoPath = $channel->{logo}->{path};
            $logoPath =~ s/\?.*$//;
            $epg .= qq{<icon src="} . xmlEscape($logoPath) . qq{" />\n};
        }
        $epg .= "</channel>\n";
    }

    for my $channel (@channels) {
        next unless ref($channel) eq 'HASH';
        next unless ($channel->{number} || 0) > 0;
        next unless $channel->{_id};

        my $channelId = xmlEscape($channel->{_id});
        for my $programme (@{$channel->{timelines} || []}) {
            next unless ref($programme) eq 'HASH';
            my ($start, $stop) = ($programme->{start}, $programme->{stop});
            next unless $start && $stop;
            $start =~ s/[-:Z\.T]//g;
            $stop =~ s/[-:Z\.T]//g;
            $start = substr($start, 0, 14);
            $stop = substr($stop, 0, 14);

            my $episode = ref($programme->{episode}) eq 'HASH' ? $programme->{episode} : {};
            my $title = $programme->{title} || $episode->{name} || 'Unbekannte Sendung';
            my $desc = $episode->{description} || $programme->{description} || '';
            my $rating = $episode->{rating} || '';

            $epg .= qq{<programme start="$start +0000" stop="$stop +0000" channel="$channelId">\n};
            $epg .= qq{<title lang="$langcode">} . xmlEscape($title) . qq{</title>\n};
            $epg .= qq{<desc lang="$langcode">} . xmlEscape($desc) . qq{</desc>\n} if $desc ne '';
            $epg .= qq{<rating><value>} . xmlEscape($rating) . qq{</value></rating>\n} if $rating ne '';
            $epg .= "</programme>\n";
        }
    }

    $epg .= "</tv>\n";

    my $response = HTTP::Response->new(HTTP_OK);
    $response->header('Content-Type' => 'application/xml; charset=utf-8');
    $response->header('Content-Disposition' => 'attachment; filename="plutotv-epg.xml"');
    $response->header('Cache-Control' => 'no-cache');
    $response->content(encode_utf8($epg));
    $client->send_response($response);
}

sub sendM3uFile {
    my ($client, $useDirectStreams, $request) = @_;
    my $region = requestRegion($request);
    my $proto = requestProto($request);
    my $host = requestHost($request);

    my @channels = getChannelJson($region);
    unless (@channels) {
        $client->send_error(HTTP_INTERNAL_SERVER_ERROR, 'Senderliste konnte nicht von Pluto TV geladen werden.');
        return;
    }

    my $m3uContent = $useDirectStreams
        ? buildM3uDirect($proto, $host, $region, @channels)
        : buildM3uLegacy($proto, $host, $region, @channels);

    my $response = HTTP::Response->new(HTTP_OK);
    $response->header('Content-Type' => 'audio/x-mpegurl; charset=utf-8');
    $response->header('Content-Disposition' => 'attachment; filename="plutotv.m3u8"');
    $response->header('Cache-Control' => 'no-cache');
    $response->content(encode_utf8($m3uContent));
    $client->send_response($response);
}

# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------

sub sendDirectStream {
    my ($client, $request) = @_;
    my $path = $request->uri->path;
    my ($channelId) = $path =~ m{^/stream/([A-Za-z0-9_-]+)\.m3u8$};
    unless ($channelId) {
        $client->send_error(HTTP_BAD_REQUEST, 'Ungültiger Stream-Pfad.');
        return;
    }

    my $region = requestRegion($request);
    my $proto = requestProto($request);
    my $host = requestHost($request);
    my $regionParam = uri_escape_utf8($region);

    # Kompatibilitäts-Endpunkt: ein dauerhaft laufender MPEG-TS-Endpunkt wird als
    # einzelnes HLS-Event-Segment angeboten. TVHeadend bekommt über /tvheadend
    # inzwischen direkt den MPEG-TS-Endpunkt und benötigt diesen Umweg nicht mehr.
    # Form und Semantik der bisherigen lokalen HLS-Hülle beibehalten.
    # Intern liefert /dynamic_stream nun den modernisierten, durch ffmpeg
    # zeitstempelbereinigten MPEG-TS-Strom.
    my $playlist = "#EXTM3U\n"
        . "#EXT-X-VERSION:3\n"
        . "#EXT-X-TARGETDURATION:10\n"
        . "#EXT-X-MEDIA-SEQUENCE:0\n"
        . "#EXT-X-PLAYLIST-TYPE:EVENT\n"
        . "#EXTINF:86400.0,\n"
        . "$proto://$host/dynamic_stream/$channelId.ts?region=$regionParam\n"
        . "#EXT-X-ENDLIST\n";

    sendPlainResponse($client, HTTP_OK, 'application/vnd.apple.mpegurl; charset=utf-8', encode_utf8($playlist));
}

sub streamThroughFfmpeg {
    my ($client, $inputUrl, $channelId) = @_;

    my @command = (
        $ffmpeg,
        '-hide_banner',
        '-loglevel', ($debug ? 'warning' : 'error'),
        '-nostdin',
        '-rw_timeout', '15000000',
        '-reconnect', '1',
        '-reconnect_streamed', '1',
        '-reconnect_at_eof', '1',
        '-reconnect_delay_max', '5',
        # HLS/MPEG-TS sind AVFMT_TS_DISCONT-Formate. Ohne -copyts darf ffmpeg
        # DTS-/PTS-Sprünge selbst korrigieren. Pluto setzt solche Sprünge insbesondere
        # an Werbe- und Programmgrenzen. 1 s ist absichtlich deutlich strenger als
        # ffmpegs Standard von 10 s, damit auch kleinere Rücksprünge normalisiert werden.
        '-fflags', '+genpts+discardcorrupt',
        '-dts_delta_threshold', '1.0',
        '-i', $inputUrl,
        '-map', '0:v?',
        '-map', '0:a?',
        '-map_metadata', '-1',
        '-c', 'copy',
        '-copytb', '1',
        '-avoid_negative_ts', 'make_non_negative',
        '-mpegts_flags', '+resend_headers+initial_discontinuity',
        '-muxdelay', '0',
        '-muxpreload', '0',
        '-f', 'mpegts',
        'pipe:1',
    );

    logDebug("Starte ffmpeg für Kanal $channelId");

    my $pid = open(my $pipe, '-|', @command);
    unless (defined $pid) {
        logWarn("ffmpeg konnte für Kanal $channelId nicht gestartet werden: $!");
        return 0;
    }
    binmode($pipe);

    my $ok = 1;
    my $buffer;
    while (1) {
        my $read = sysread($pipe, $buffer, 64 * 1024);
        if (!defined $read) {
            next if $!{EINTR};
            logWarn("Fehler beim Lesen von ffmpeg für Kanal $channelId: $!");
            $ok = 0;
            last;
        }
        last if $read == 0;

        my $offset = 0;
        while ($offset < $read) {
            my $written = syswrite($client, $buffer, $read - $offset, $offset);
            if (!defined $written) {
                logDebug("Client hat Stream $channelId beendet: $!");
                $ok = 0;
                last;
            }
            $offset += $written;
        }
        last unless $ok;
    }

    if (!$ok && $pid > 0) {
        kill 'TERM', $pid;
    }
    close($pipe);
    return $ok;
}

sub sendDynamicStream {
    my ($client, $request) = @_;
    my $path = $request->uri->path;
    my ($channelId) = $path =~ m{^/dynamic_stream/([A-Za-z0-9_-]+)\.ts$};
    unless ($channelId) {
        $client->send_error(HTTP_BAD_REQUEST, 'Ungültiger Stream-Pfad.');
        return;
    }

    my $region = requestRegion($request);
    my $masterUrl = getModernStreamUrl($region, $channelId);
    unless ($masterUrl) {
        $client->send_error(HTTP_BAD_GATEWAY, 'Pluto-Session oder Stream-URL konnte nicht erzeugt werden.');
        return;
    }

    # Den höchsten verfügbaren HLS-Variant-Stream einmalig auflösen. Dadurch muss
    # ffmpeg nicht alle Varianten des Master-Manifests gleichzeitig behandeln.
    my $inputUrl = resolveBestVariantUrl($masterUrl);
    logDebug("Stream-URL für $channelId: $inputUrl");

    $client->timeout(30);
    my $headerOk = try {
        $client->write("HTTP/1.1 200 OK\r\n");
        $client->write("Content-Type: video/mp2t\r\n");
        $client->write("Cache-Control: no-cache, no-store, must-revalidate\r\n");
        $client->write("Pragma: no-cache\r\n");
        $client->write("Expires: 0\r\n");
        $client->write("Connection: close\r\n");
        $client->write("\r\n");
        1;
    } catch {
        logDebug("Client war vor Streamstart bereits getrennt: $_");
        0;
    };
    return unless $headerOk;

    streamThroughFfmpeg($client, $inputUrl, $channelId);
}

# ---------------------------------------------------------------------------
# HTTP-Server
# ---------------------------------------------------------------------------

sub processRequest {
    my ($client) = @_;
    my $request = $client->get_request();
    return unless $request;

    $client->autoflush(1);
    my $path = $request->uri->path;
    logDebug("Request: $path");

    if ($request->method ne 'GET' && $request->method ne 'HEAD') {
        $client->send_error(HTTP_METHOD_NOT_ALLOWED, 'Nur GET/HEAD wird unterstützt.');
        return;
    }

    if ($path eq '/playlist') {
        sendM3uFile($client, 0, $request);
    } elsif ($path eq '/tvheadend') {
        sendM3uFile($client, 1, $request);
    } elsif ($path =~ m{^/stream/}) {
        sendDirectStream($client, $request);
    } elsif ($path eq '/epg') {
        sendXmltvEpgFile($client, $request);
    } elsif ($path =~ m{^/dynamic_stream/}) {
        sendDynamicStream($client, $request);
    } elsif ($path eq '/health') {
        sendHealth($client);
    } elsif ($path eq '/') {
        sendHelp($client);
    } else {
        $client->send_error(HTTP_NOT_FOUND, "Unbekannter Pfad: $path");
    }
}

sub printCommandLineHelp {
    print <<"HELP";
PlutoTVServer $version

Aufruf:
  plutotv-localserver.pl [Optionen]

Optionen:
  --port PORT          TCP-Port, Standard: $defaultPort
  --localonly, --localhost
                       nur an 127.0.0.1 binden
  --bind ADRESSE       explizite Bind-Adresse, z.B. 192.168.1.30
  --usestreamlink      nur für /playlist Streamlink statt lokalem ffmpeg verwenden
  --debug              ausführliche Diagnosemeldungen
  --help               diese Hilfe

Beispiele:
  plutotv-localserver.pl --localonly --port 9000
  plutotv-localserver.pl --bind 0.0.0.0 --port 9000
HELP
}

if ($showHelp) {
    printCommandLineHelp();
    exit 0;
}

my $daemon = HTTP::Daemon->new(
    LocalAddr => $bindAddress,
    LocalPort => $port,
    ReuseAddr => 1,
) or die "Server konnte auf $bindAddress:$port nicht gestartet werden: $!\n";

$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

print "PlutoTVServer $version gestartet auf $bindAddress:$port.\n";
print "TVHeadend-Playlist: http://$advertisedHost:$port/tvheadend?region=$defaultRegion\n";
print "EPG:               http://$advertisedHost:$port/epg?region=$defaultRegion\n";

while (my $client = $daemon->accept) {
    my $pid = fork();
    if (!defined $pid) {
        logWarn("fork() fehlgeschlagen: $!");
        $client->close();
        next;
    }

    if ($pid == 0) {
        # HTTP::Daemon::ClientConn hält intern eine Referenz auf das
        # Daemon-Objekt. Der Listener darf im Kindprozess deshalb nicht vor
        # Abschluss der Request-Verarbeitung geschlossen werden, da sonst
        # sockhost/sockport für Antwortheader undefiniert sind. Beim exit()
        # schließt das Betriebssystem den geerbten Listener automatisch.
        try {
            processRequest($client);
        } catch {
            logWarn("Fehler bei Request-Verarbeitung: $_");
            try { $client->send_error(HTTP_INTERNAL_SERVER_ERROR, 'Interner Serverfehler.'); };
        };
        $client->close();
        exit 0;
    }

    $client->close();
}

exit 0;
