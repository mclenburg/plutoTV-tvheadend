#!/usr/bin/perl

package PlutoTVServer;

use strict;
use warnings;
use utf8;
use Encode qw(encode_utf8);
use HTTP::Daemon;
use HTTP::Status;
use HTTP::Request::Params;
use DateTime;
use JSON::Parse ':all';
use HTTP::Request ();
use HTTP::Headers;
use LWP::UserAgent;
use URI::Escape qw(uri_escape_utf8);
use UUID::Tiny ':std';
use File::Which;
use Net::Address::IP::Local;
use Try::Tiny;
use Getopt::Long qw(:config no_ignore_case);
use Crypt::CBC;
use IPC::Run qw(run);
use open qw(:std :utf8);

my $hostIp = "127.0.0.1";
my $port = "9000";
my $channelsApiUrl = "https://service-channels.clusters.pluto.tv/v2/guide/channels";
my $deviceId = uuid_to_string(create_uuid(UUID_V1));
my $ffmpeg = which 'ffmpeg';
my $streamlink = which 'streamlink';
my $version = "2.1.0";
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

GetOptions("debug" => \$debug);

our %channel_timestamps = ();

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
    if ($opts{token}) {
        $headers->header('Authorization' => 'Bearer ' . $opts{token});
    }
    $ua->default_headers($headers);
    return $ua;
}

sub getFromUrl {
    my ($url, %opts) = @_;
    my $request = HTTP::Request->new(GET => $url);
    my $ua = createUserAgent(%opts);
    my $response = $ua->request($request);
    return $response->is_success ? $response->decoded_content : undef;
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

sub getBootFromPluto {
    my ($region) = @_;
    $region ||= 'DE';
    my $url = 'https://boot.pluto.tv/v4/start?' . getBootQueryString($region);
    my $content = getFromUrl($url);
    return unless $content;
    return try { parse_json($content) };
}

sub getChannelJson {
    my ($region) = @_;
    my $boot = getBootFromPluto($region);
    my @channels;

    # Pluto returns EPG in boot/start, but current responses may contain only the
    # starting channel instead of the full channel catalog. So only trust EPG when
    # it contains a plausibly complete list.
    if ($boot && ref($boot->{EPG}) eq 'ARRAY' && @{ $boot->{EPG} } >= 10) {
        @channels = map { normalizeChannel($_) } @{ $boot->{EPG} };
        @channels = grep { $_ } @channels;
        return @channels if @channels;
    }

    return () unless $boot && $boot->{servers} && $boot->{sessionToken};
    my $url = $channelsApiUrl . '?channelIds=&offset=0&limit=1000&sort=number%3Aasc';
    my $content = getFromUrl($url, token => $boot->{sessionToken});
    return () unless $content;
    my $parsed = try { parse_json($content) };
    my $items = ref($parsed) eq 'HASH' ? ($parsed->{data} || $parsed->{channels} || []) : [];
    @channels = map { normalizeChannel($_) } @{ $items || [] };
    @channels = grep { $_ } @channels;
    return @channels;
}

sub buildDirectMasterUrl {
    my ($bootJson, $channelOrId) = @_;
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
    my $url = $stitchedPath =~ m{^https?://}
        ? $stitchedPath
        : $bootJson->{servers}->{stitcher} . $stitchedPath;
    if ($bootJson->{stitcherParams}) {
        $url .= ($url =~ /\?/) ? '&' : '?';
        $url .= $bootJson->{stitcherParams};
    }
    return $url;
}

sub buildM3uLegacy {
    my ($session, @channels) = @_;
    my $m3u = "#EXTM3U\n";
    my $activeRegion = $session && $session->{session} && $session->{session}->{activeRegion}
        ? lc($session->{session}->{activeRegion}) : 'de';
    for my $channel (@channels) {
        next unless ($channel->{number} || 0) > 0 && ($channel->{number} || 0) != 2000;
        my $logo = $channel->{logo_url} || '';
        my $name = $channel->{name};
        my $number = $channel->{number};
        my $id = $channel->{id};
        $m3u .= "#EXTINF:-1 tvg-chno=\"$number\" tvg-id=\"" . uri_escape_utf8($name) .
            "\" tvg-name=\"$name\" tvg-logo=\"$logo\" group-title=\"PlutoTV\",$name\n";
        if ($useStreamlink) {
            my $url = "https://pluto.tv/$activeRegion/live-tv/" . $channel->{slug};
            $m3u .= "pipe://$streamlink --stdout --quiet --default-stream best " .
                "--hls-live-restart --url \"$url\"\n";
        } else {
            $m3u .= "pipe://$ffmpeg -loglevel fatal -threads 0 -nostdin -re " .
                "-i \"http://$hostIp:$port/master3u8?id=$id\" " .
                "-c copy -vcodec copy -acodec copy -mpegts_copyts 1 -f mpegts " .
                "-tune zerolatency -mpegts_service_type advanced_codec_digital_hdtv " .
                "-metadata service_name=\"$name\" pipe:1\n";
        }
    }
    return $m3u;
}

sub buildM3uDirect {
    my (@channels) = @_;
    my $m3u = "#EXTM3U\n";
    for my $channel (@channels) {
        next unless ($channel->{number} || 0) > 0 && ($channel->{number} || 0) != 2000;
        my $logo = $channel->{logo_url} || '';
        my $name = $channel->{name};
        my $number = $channel->{number};
        my $id = $channel->{id};
        $m3u .= "#EXTINF:-1 tvg-chno=\"$number\" tvg-id=\"" . uri_escape_utf8($name) .
            "\" tvg-name=\"$name\" tvg-logo=\"$logo\" group-title=\"PlutoTV\",$name\n";
        $m3u .= "http://$hostIp:$port/stream/$id.m3u8\n";
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
        "\t/epg\t\tfor xmltv-epg-file\n\n" .
        "Available regions: " . join(", ", sort keys %regions) . "\n" .
        "Example: /tvheadend?region=US\n");
    $client->send_response($response);
}

sub sendXmltvEpgFile {
    my ($client, $request) = @_;
    my @channels = getChannelJson();
    unless (@channels) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel list from pluto.tv-api.");
        return;
    }
    my $langcode = "en";
    my $epg = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<tv>\n";
    for my $channel (@channels) {
        next unless ($channel->{number} || 0) > 0;
        my $channelName = $channel->{name};
        my $channelId = uri_escape_utf8($channelName);
        $epg .= "<channel id=\"$channelId\">\n";
        $epg .= "<display-name lang=\"$langcode\"><![CDATA[$channelName]]></display-name>\n";
        if (my $logoPath = $channel->{logo_url}) {
            $logoPath = substr($logoPath, 0, index($logoPath, "?")) if index($logoPath, "?") >= 0;
            $epg .= "<icon src=\"$logoPath\" />\n";
        }
        $epg .= "</channel>\n";
    }
    for my $channel (@channels) {
        next unless ($channel->{number} || 0) > 0;
        my $channelId = uri_escape_utf8($channel->{name});
        for my $programme (@{$channel->{timelines} || []}) {
            my ($start, $stop) = ($programme->{start}, $programme->{stop});
            next unless $start && $stop;
            $start =~ s/[-:Z\.T]//g;
            $stop =~ s/[-:Z\.T]//g;
            $stop = substr($stop, 0, 14);
            $epg .= "<programme start=\"$start +0000\" stop=\"$stop +0000\" channel=\"$channelId\">\n";
            my $episode = $programme->{episode} || {};
            my $title = $programme->{title};
            my $rating = $episode->{rating} || '';
            $epg .= "<title lang=\"$langcode\"><![CDATA[$title - $rating]]></title>\n";
            $epg .= "<desc lang=\"$langcode\"><![CDATA[" . ($episode->{description} || '') . "]]></desc>\n";
            $epg .= "</programme>\n";
        }
    }
    $epg .= "\n</tv>\n\n\n";
    my $response = HTTP::Response->new();
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
    $response->header("content-type", "audio/x-mpegurl");
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
    my $bootJson = getBootFromPluto();
    unless ($bootJson && $bootJson->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }
    my ($channel) = grep { ($_->{id} || '') eq $channelId } getChannelJson();
    my $url = buildDirectMasterUrl($bootJson, $channel || $channelId);
    my $master = getFromUrl($url);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream");
        return;
    }
    my $dynamicM3u = createDynamicPlaylist($master, $channelId, $bootJson->{servers}->{stitcher});
    my $response = HTTP::Response->new();
    $response->code(200);
    $response->message("OK");
    $response->header("content-type", "application/vnd.apple.mpegurl; charset=utf-8");
    $response->header("cache-control", "no-cache, no-store, must-revalidate");
    $response->header("pragma", "no-cache");
    $response->header("expires", "0");
    $response->content(encode_utf8($dynamicM3u));
    $client->send_response($response);
}

sub createDynamicPlaylist {
    my ($masterPlaylist, $channelId, $baseUrl) = @_;
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
        $bestStreamUrl = "$baseUrl/stitch/hls/channel/$channelId/$bestStreamUrl";
    }
    my $dynamicPlaylist = "#EXTM3U\n";
    $dynamicPlaylist .= "#EXT-X-VERSION:3\n";
    $dynamicPlaylist .= "#EXT-X-TARGETDURATION:10\n";
    $dynamicPlaylist .= "#EXT-X-MEDIA-SEQUENCE:0\n";
    $dynamicPlaylist .= "#EXT-X-PLAYLIST-TYPE:EVENT\n";
    $dynamicPlaylist .= "#EXTINF:86400.0,\n";
    $dynamicPlaylist .= "http://$hostIp:$port/dynamic_stream/$channelId.ts\n";
    $dynamicPlaylist .= "#EXT-X-ENDLIST\n";
    return $dynamicPlaylist;
}

sub sendDynamicStream {
    my ($client, $request) = @_;
    my $path = $request->uri->path;
    my ($channelId) = $path =~ m{/dynamic_stream/([^/]+)\.ts$};
    unless ($channelId) {
        $client->send_error(RC_BAD_REQUEST, "Invalid dynamic stream path");
        return;
    }
    my $bootJson = getBootFromPluto();
    unless ($bootJson && $bootJson->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }
    my ($channel) = grep { ($_->{id} || '') eq $channelId } getChannelJson();
    my $masterUrl = buildDirectMasterUrl($bootJson, $channel || $channelId);
    my $master = getFromUrl($masterUrl);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch master playlist");
        return;
    }
    my $playlistUrl = extractBestPlaylistUrl($master, $bootJson->{servers}->{stitcher}, $channelId);
    unless ($playlistUrl) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to find playlist URL");
        return;
    }
    streamWithDiscontinuityRestart($client, $playlistUrl, $channelId);
}

sub extractBestPlaylistUrl {
    my ($masterPlaylist, $baseUrl, $channelId) = @_;
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
    return unless $bestStreamUrl;
    unless ($bestStreamUrl =~ /^https?:\/\//) {
        $bestStreamUrl = "$baseUrl/stitch/hls/channel/$channelId/$bestStreamUrl";
    }
    return $bestStreamUrl;
}

sub streamWithDiscontinuityRestart {
    my ($client, $playlistUrl, $channelId) = @_;
    $client->timeout(5);
    eval {
        $client->write("HTTP/1.1 200 OK\r\n");
        $client->write("Content-Type: video/mp2t\r\n");
        $client->write("Cache-Control: no-cache, no-store, must-revalidate\r\n");
        $client->write("Connection: close\r\n");
        $client->write("\r\n");
    };
    if ($@) {
        printf("Failed to send headers - client disconnected: %s\n", $@);
        return;
    }
    my $ua = createUserAgent();
    my %processedSegments = ();
    my $runningNumber = 1;
    if ($debug) {
        printf("Starting stream for channel $channelId\n");
    }
    while (1) {
        my $playlistContent = getFromUrl($playlistUrl);
        unless ($playlistContent) {
            if ($debug) {
                printf("Failed to fetch playlist for %s, restarting stream\n", $channelId);
            }
            last;
        }
        my $playlistInfo = parsePlaylistInfo($playlistContent);
        my @allSegments = extractSegmentsFromPlaylist($playlistContent, $playlistUrl, $playlistInfo, \$runningNumber);
        my @newSegments = filterNewSegments(\@allSegments, \%processedSegments);
        if (@newSegments == 0) {
            sleep(1);
            next;
        }
        if ($debug) {
            printf("Processing %d new segments for channel %s\n", scalar(@newSegments), $channelId);
        }
        for my $segment (@newSegments) {
            my $success = streamSegment($client, $ua, $segment, $channelId);
            unless ($success) {
                if ($debug) {
                    printf("Failed to stream segment, ending stream for %s\n", $channelId);
                }
                last;
            }
            $processedSegments{$segment->{url}} = time();
        }
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
    return $value if $value =~ m{^https?://}i;

    my ($schemeHost) = $baseUrl =~ m{^(https?://[^/]+)}i;
    my ($playlistBase) = $baseUrl =~ m{^(.+)/[^/]+(?:\?.*)?$};

    if ($value =~ m{^/}) {
        return ($schemeHost || '') . $value;
    }
    return ($playlistBase || $baseUrl) . "/" . $value;
}

sub extractSegmentsFromPlaylist {
    my ($playlistContent, $baseUrl, $playlistInfo, $runningNumberRef) = @_;
    my @lines = split /
?
/, $playlistContent;
    my @segments = ();
    my %currentSegment;
    my $sequenceNumber = $playlistInfo->{mediaSequence} || 0;
    my $inDiscontinuityBlock = 0;
    my %currentKey = (method => 'NONE');

    $$runningNumberRef = 1;

    for my $line (@lines) {
        if ($line =~ /^#EXT-X-DISCONTINUITY$/) {
            $inDiscontinuityBlock = 1;
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
                    keyUri => resolvePlaylistUrl($baseUrl, $attrs{URI}),
                    iv     => $attrs{IV},
                );
                $currentKey{iv} =~ s/^0x//i if defined $currentKey{iv};
            }
        }
        elsif ($line =~ /^#EXTINF:([0-9.]+),/) {
            $currentSegment{duration} = $1;
        }
        elsif ($line !~ /^#/ && $line =~ /\.(?:ts|m4s)(?:\?.*)?$/) {
            $currentSegment{url} = resolvePlaylistUrl($baseUrl, $line);
            $currentSegment{sequence} = $sequenceNumber;
            $currentSegment{running} = $$runningNumberRef;
            $currentSegment{isDiscontinuity} = $inDiscontinuityBlock;

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

sub streamSegment {
    my ($client, $ua, $segment, $channelId) = @_;
    my $is_discontinuity = $segment->{isDiscontinuity} || 0;
    my $req = HTTP::Request->new(GET => $segment->{url});
    my $res = $ua->request($req);
    unless ($res->is_success) {
        if ($debug) {
            printf("Failed to fetch segment %s: %s\n", $segment->{url}, $res->status_line);
        }
        return 0;
    }

    my $chunk = $res->content;
    my $decryptedData;

    if ($segment->{keyUri}) {
        my $keyRes = $ua->get($segment->{keyUri});
        unless ($keyRes->is_success) {
            if ($debug) {
                printf("Failed to fetch key %s: %s\n", $segment->{keyUri}, $keyRes->status_line);
            }
            return 0;
        }
        my $encryptionKey = $keyRes->content;
        if (length($encryptionKey) != 16) {
            if ($debug) {
                printf("Invalid key length: %d bytes (expected 16)\n", length($encryptionKey));
            }
            return 0;
        }

        my $iv = $segment->{iv};
        $iv = sprintf('%032x', $segment->{sequence} || 0) unless defined $iv && length $iv;
        my $hexKey = unpack('H*', $encryptionKey);

        if (which('openssl')) {
            my $opensslStderr = '';
            run(
                [
                    "openssl", "aes-128-cbc", "-d",
                    "-in", "-",
                    "-out", "-",
                    "-K", $hexKey,
                    "-iv", $iv
                ],
                "<", \$chunk,
                ">", \$decryptedData,
                "2>", \$opensslStderr
            );
            if (!defined $decryptedData || !length $decryptedData) {
                if ($debug && length $opensslStderr) {
                    printf("OpenSSL decrypt failed for %s: %s\n", $segment->{url}, $opensslStderr);
                }
                return 0;
            }
        } else {
            if ($debug) {
                printf("Using Crypt::CBC\n");
            }
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
    } else {
        $decryptedData = $chunk;
    }

    if (length($decryptedData) > 0) {
        my $firstByte = unpack('C', substr($decryptedData, 0, 1));
        unless ($firstByte == 0x47) {
            if ($debug) {
                printf("Warning: Segment doesn't start with MPEG-TS sync byte (0x%02X)\n", $firstByte);
            }
        }
    }
    eval {
        my $correctedData = correctMpegTsTimestamps($decryptedData, $channelId, $is_discontinuity);
        print $client $correctedData;
        $client->flush();
    };
    if ($@) {
        printf("Failed to send data to client: %s\n", $@);
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
        $ts_info->{pcr_calculated} = 0;
        $ts_info->{pts_calculated} = 0;
        $ts_info->{dts_calculated} = 0;
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
    my $adaptation_field = ($header_byte_4 & 0xF0);
    my $corrected_header_byte_4 = $adaptation_field | $cc;
    substr($packet_data, 3, 1) = pack('C', $corrected_header_byte_4);
    $ts_info->{cc_counters}->{$pid} = $cc;
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
            $ts_info->{pcr_offset} = $ts_info->{last_pcr} - $pcr_base;
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