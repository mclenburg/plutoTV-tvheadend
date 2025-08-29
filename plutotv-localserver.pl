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
my $apiUrl = "http://api.pluto.tv/v2/channels";
my $deviceId = uuid_to_string(create_uuid(UUID_V1));
my $ffmpeg = which 'ffmpeg';
my $streamlink = which 'streamlink';

my %regions = (
    'DE' => { lat => '52.5200', lon => '13.4050', name => 'Germany' },
    'US' => { lat => '40.7128', lon => '-74.0060', name => 'United States' },
    'UK' => { lat => '51.5074', lon => '-0.1278', name => 'United Kingdom' },
    'FR' => { lat => '48.8566', lon => '2.3522', name => 'France' },
    'IT' => { lat => '41.9028', lon => '12.4964', name => 'Italy' },
);

my $localhost = grep { $_ eq '--localonly'} @ARGV;
my $useStreamlink = grep { $_ eq '--usestreamlink'} @ARGV;

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
    my $ua = LWP::UserAgent->new(keep_alive => 1);
    $ua->agent('Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/109.0');
    my $headers = HTTP::Headers->new;
    $headers->header('Cache-Control' => 'no-cache');
    $headers->header('Pragma'        => 'no-cache');
    $ua->default_headers($headers);
    return $ua;
}

sub getFromUrl {
    my ($url) = @_;
    my $request = HTTP::Request->new(GET => $url);
    my $ua = createUserAgent();
    my $response = $ua->request($request);
    return $response->is_success ? $response->decoded_content : undef;
}

sub getChannelJson {
    my ($region) = @_;
    $region ||= 'DE';
    my $from = DateTime->now();
    my $to = DateTime->now()->add(days => 2);
    my $url = "$apiUrl?start=${from}Z&stop=${to}Z";
    my $content = getFromUrl($url);
    return () unless $content;
    my $channels = try { parse_json($content) };
    return $channels ? @{$channels} : ();
}

sub getBootFromPluto {
    my ($region) = @_;
    $region ||= 'DE';
    my $regionData = $regions{$region};
    unless ($regionData) {
        warn "Unknown region: $region, using DE as fallback\n";
        $regionData = $regions{'DE'};
    }
    my $url = "https://boot.pluto.tv/v4/start?" . join('&',
        "deviceId=$deviceId",
        "deviceMake=Firefox",
        "deviceType=web",
        "deviceVersion=109.0",
        "deviceModel=web",
        "DNT=1",
        "appName=web",
        "appVersion=5.17.0",
        "clientID=$deviceId",
        "clientModelNumber=na",
        "serverSideAds=false",
        "includeExtendedEvents=false",
        "deviceLat=$regionData->{lat}",
        "deviceLon=$regionData->{lon}"
    );
    my $content = getFromUrl($url);
    return unless $content;
    my $session = try { parse_json($content) };
    return $session;
}

sub buildM3uLegacy {
    my ($session, @channels) = @_;
    my $m3u = "#EXTM3U\n";
    for my $channel (@channels) {
        next unless $channel->{number} > 0 && $channel->{number} != 2000;
        next unless defined $channel->{logo}->{path};
        my $logo = $channel->{logo}->{path};
        my $name = $channel->{name};
        my $number = $channel->{number};
        my $id = $channel->{_id};
        $m3u .= "#EXTINF:-1 tvg-chno=\"$number\" tvg-id=\"" . uri_escape_utf8($name) .
            "\" tvg-name=\"$name\" tvg-logo=\"$logo\" group-title=\"PlutoTV\",$name\n";
        if ($useStreamlink) {
            my $url = "https://pluto.tv/" . $session->{session}->{activeRegion} .
                "/live-tv/" . $channel->{slug};
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
        next unless $channel->{number} > 0 && $channel->{number} != 2000;
        next unless defined $channel->{logo}->{path};
        my $logo = $channel->{logo}->{path};
        my $name = $channel->{name};
        my $number = $channel->{number};
        my $id = $channel->{_id};
        $m3u .= "#EXTINF:-1 tvg-chno=\"$number\" tvg-id=\"" . uri_escape_utf8($name) .
            "\" tvg-name=\"$name\" tvg-logo=\"$logo\" group-title=\"PlutoTV\",$name\n";
        $m3u .= "http://$hostIp:$port/stream/$id.m3u8\n";
    }
    return $m3u;
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
        next unless $channel->{number} > 0;
        my $channelName = $channel->{name};
        my $channelId = uri_escape_utf8($channelName);
        $epg .= "<channel id=\"$channelId\">\n";
        $epg .= "<display-name lang=\"$langcode\"><![CDATA[$channelName]]></display-name>\n";
        if (my $logo = $channel->{logo}) {
            my $logoPath = $logo->{path};
            $logoPath = substr($logoPath, 0, index($logoPath, "?")) if index($logoPath, "?") >= 0;
            $epg .= "<icon src=\"$logoPath\" />\n";
        }
        $epg .= "</channel>\n";
    }
    for my $channel (@channels) {
        next unless $channel->{number} > 0;
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
    my $baseUrl = $bootJson->{servers}->{stitcher};
    my $url = "$baseUrl/stitch/hls/channel/$channelId/master.m3u8?" . $bootJson->{stitcherParams};
    my $master = getFromUrl($url);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream");
        return;
    }
    my $dynamicM3u = createDynamicPlaylist($master, $channelId, $baseUrl);
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
    unless ($bestStreamUrl) {
        return $masterPlaylist;
    }
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
    my $baseUrl = $bootJson->{servers}->{stitcher};
    my $masterUrl = "$baseUrl/stitch/hls/channel/$channelId/master.m3u8?" . $bootJson->{stitcherParams};
    my $master = getFromUrl($masterUrl);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch master playlist");
        return;
    }
    my $playlistUrl = extractBestPlaylistUrl($master, $baseUrl, $channelId);
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
    printf("Starting stream for channel $channelId\n");
    while (1) {
        my $playlistContent = getFromUrl($playlistUrl);
        unless ($playlistContent) {
            printf("Failed to fetch playlist for %s, restarting stream\n", $channelId);
            last;
        }
        my $playlistInfo = parsePlaylistInfo($playlistContent);
        my @allSegments = extractSegmentsFromPlaylist($playlistContent, $playlistUrl, $playlistInfo, \$runningNumber);
        my @newSegments = filterNewSegments(\@allSegments, \%processedSegments);
        if (@newSegments == 0) {
            sleep(1);
            next;
        }
        printf("Processing %d new segments for channel %s\n", scalar(@newSegments), $channelId);
        for my $segment (@newSegments) {
            my $success = streamSegment($client, $ua, $segment, $channelId);
            unless ($success) {
                printf("Failed to stream segment, ending stream for %s\n", $channelId);
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

sub extractSegmentsFromPlaylist {
    my ($playlistContent, $baseUrl, $playlistInfo, $runningNumberRef) = @_;
    my @lines = split /\r?\n/, $playlistContent;
    my @segments = ();
    my %currentSegment;
    my $sequenceNumber = $playlistInfo->{mediaSequence} || 0;
    my ($playlistBase) = $baseUrl =~ m{^(.+)/[^/]+$};
    my $inDiscontinuityBlock = 0;
    for my $line (@lines) {
        if ($line =~ /^#EXT-X-KEY:METHOD=AES-128,URI="(.+?)",IV=(.+?)$/) {
            $currentSegment{keyUri} = $1;
            $currentSegment{iv} = $2;
            $currentSegment{iv} =~ s/^0x//;
            $inDiscontinuityBlock = 0;
        }
        elsif ($line =~ /^#EXT-X-DISCONTINUITY$/) {
            $inDiscontinuityBlock = 1;
        }
        elsif ($line =~ /^#EXTINF:([0-9.]+),/) {
            $currentSegment{duration} = $1;
        }
        elsif ($line =~ /^(https?:\/\/.+?\.ts)$/) {
            $currentSegment{url} = $1;
            $currentSegment{sequence} = $sequenceNumber;
            $currentSegment{running} = $$runningNumberRef;
            $currentSegment{isDiscontinuity} = $inDiscontinuityBlock;
            unless ($currentSegment{url} =~ /^https?:\/\//) {
                $currentSegment{url} = "$playlistBase/$currentSegment{url}";
            }
            if (exists $currentSegment{keyUri} && exists $currentSegment{iv}) {
                push @segments, { %currentSegment };
            }
            %currentSegment = ();
            $sequenceNumber++;
            $$runningNumberRef++;
            if($$runningNumberRef > 1000000) {
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
    my $req = HTTP::Request->new(GET => $segment->{url});
    my $res = $ua->request($req);
    unless ($res->is_success) {
        printf("Failed to fetch segment %s: %s\n", $segment->{url}, $res->status_line);
        return 0;
    }
    my $keyRes = $ua->get($segment->{keyUri});
    unless ($keyRes->is_success) {
        printf("Failed to fetch key %s: %s\n", $segment->{keyUri}, $keyRes->status_line);
        return 0;
    }
    my $encryptionKey = $keyRes->content;
    if (length($encryptionKey) != 16) {
        printf("Invalid key length: %d bytes (expected 16)\n", length($encryptionKey));
        return 0;
    }
    my $hexKey = unpack('H*', $encryptionKey);
    my $chunk = $res->content;
    my $decryptedData;
    if (which('openssl')) {
        my $opensslStderr = '';
        run(
            [
                "openssl", "aes-128-cbc", "-d",
                "-in", "-",
                "-out", "-",
                "-K", $hexKey,
                "-iv", $segment->{iv}
            ],
            "<", \$chunk,
            ">", \$decryptedData,
            "2>", \$opensslStderr
        );
    } else {
        printf("!!! Using Crypt::CBC\n");
        my $ivBin = pack 'H*', $segment->{iv};
        my $cipher = Crypt::CBC->new(
            -key     => $encryptionKey,
            -cipher  => 'Rijndael',
            -iv      => $ivBin,
            -header  => 'none',
            -padding => 'standard',
        );
        $decryptedData = $cipher->decrypt($chunk);
    }
    if (length($decryptedData) > 0) {
        my $firstByte = unpack('C', substr($decryptedData, 0, 1));
        unless ($firstByte == 0x47) {
            printf("Warning: Segment doesn't start with MPEG-TS sync byte (0x%02X)\n", $firstByte);
        }
    }
    eval {
        my $outputData;
        run(
            [
                "ffmpeg", "-loglevel",  "error", "-i", "-",
                "-c", "copy",
                "-f", "mpegts",
                "-"
            ],
            "<", \$decryptedData,
            ">", \$outputData
        );
        print $client $outputData;
        $client->flush();
    };
    if ($@) {
        printf("Failed to send data to client: %s\n", $@);
        return 0;
    }
    return 1;
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
    printf("Removed %d old segments.\n", $removedCount) if $removedCount > 0;
}

sub processRequest {
    my ($client) = @_;
    my $request = $client->get_request() or die("could not get Client-Request.\n");
    $client->autoflush(1);
    my $path = $request->uri->path;
    printf("Request received for path $path\n");
    if ($path eq "/playlist") {
        sendM3uFile($client, 0, $request);
    } elsif ($path eq "/tvheadend") {
        sendM3uFile($client, 1, $request);
    } elsif ($path =~ m{^/stream/}) {
        sendDirectStream($client, $request);
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
    printf("SIGPIPE received - client disconnected\n");
    exit(0);
};
$SIG{CHLD} = 'IGNORE';

printf("Server started listening on $hostIp using port $port\n");

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