#!/usr/bin/perl

package server;

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";

use IO::Socket::INET;
use HTTP::Request::Params;
use HTTP::Response;
use HTTP::Status;
use LWP::UserAgent;
use JSON;
use Data::Dumper;
use URI;
use URI::Escape;
use File::Which;
use Net::Address::IP::Local;
use UUID::Tiny ':std';
use Getopt::Long;
use POSIX qw(strftime);
use DateTime;
use Fcntl qw(:DEFAULT :flock);
use MIME::Base64;

# Globale Variablen - jetzt nicht mehr 'shared'
my $hostip = "127.16.5.90";
my $port   = "9000";

my $deviceid = uuid_to_string(create_uuid(UUID_V1));
my $ffmpeg;
my $streamlink;

# Die Cache-Variablen werden in Dateien gespeichert, um sie zwischen Prozessen zu teilen
my $session_file = "/tmp/plutotv_session.json";
my $bootTime_file = "/tmp/plutotv_boot_time.txt";
my $channels_file = "/tmp/plutotv_channels.json";
my $channels_time_file = "/tmp/plutotv_channels_time.txt";

my $usestreamlink = 0;
my $active_region;

my $json_serializer = JSON->new->allow_blessed->convert_blessed->utf8(1);

my %regions = (
    'DE' => { lat => '52.5200', lon => '13.4050', api_url => 'http://api.pluto.tv/v2/channels' },
    'US' => { lat => '34.0522', lon => '-118.2437', api_url => 'http://api.pluto.tv/v2/channels' },
    'UK' => { lat => '51.5074', lon => '-0.1278', api_url => 'http://api.pluto.tv/v2/channels' },
);

sub parse_args {
    my $localonly = 0;
    my $usestreamlink_opt = 0;
    my $port = 9000;
    my $region = 'DE';

    GetOptions(
        "localonly"     => \$localonly,
        "usestreamlink" => \$usestreamlink_opt,
        "port=i"        => \$port,
        "region=s"      => \$region
    ) or die("Error in command line arguments\n");

    return (
        localonly => $localonly,
        usestreamlink => $usestreamlink_opt,
        port => $port,
        region => $region
    );
}

sub read_cache_file {
    my ($filename) = @_;
    unless (-e $filename) {
        return undef;
    }
    open(my $fh, '<', $filename) or return undef;
    flock($fh, LOCK_SH);
    my $content = do { local $/; <$fh> };
    flock($fh, LOCK_UN);
    close($fh);
    return $content;
}

sub write_cache_file {
    my ($filename, $content) = @_;
    open(my $fh, '>', $filename) or return;
    flock($fh, LOCK_EX);
    print $fh $content;
    flock($fh, LOCK_UN);
    close($fh);
}

sub get_from_url {
    my ($ua_thread, $url) = @_;
    my $request = HTTP::Request->new(GET => $url);
    my $response = $ua_thread->request($request);
    return $response->is_success ? $response->content : undef;
}

sub get_channel_json {
    my ($ua_thread) = @_;
    my $now = time();
    my $json_data;

    my $cached_channels_json = read_cache_file($channels_file);
    my $cached_channels_time = read_cache_file($channels_time_file);

    if (defined($cached_channels_json) && $cached_channels_json ne "" && defined($cached_channels_time) && $now - $cached_channels_time < 15 * 60) {
        printf("Using cached channel list for region '%s'.\n", $active_region);
        $json_data = eval { $json_serializer->decode($cached_channels_json) };
        if ($@) {
            warn "Failed to parse cached JSON: $@";
            return ();
        }
        return @{$json_data};
    }

    printf("Fetching fresh channel list from PlutoTV API for region '%s'.\n", $active_region);
    my $from_ts = time();
    my $to_ts = $from_ts + (2 * 24 * 60 * 60);
    my $from_iso = strftime('%Y-%m-%dT%H:%M:%S', gmtime($from_ts));
    my $to_iso = strftime('%Y-%m-%dT%H:%M:%S', gmtime($to_ts));

    my $api_url_for_region = $regions{$active_region}->{api_url};
    my $url = "$api_url_for_region?start=${from_iso}Z&stop=${to_iso}Z";
    my $request = HTTP::Request->new(GET => $url);
    my $response = $ua_thread->request($request);

    unless ($response->is_success) {
        warn "Failed to fetch channel list for region '$active_region': " . $response->status_line;
        return ();
    }

    $json_data = eval { $json_serializer->decode($response->decoded_content) };
    if ($@) {
        warn "Failed to parse JSON for channel list for region '$active_region': $@";
        return ();
    }

    write_cache_file($channels_file, $response->decoded_content);
    write_cache_file($channels_time_file, $now);

    return @{$json_data};
}

sub getBootFromPluto {
    my ($ua, $region) = @_;
    my $lat = $regions{$region}->{lat};
    my $lon = $regions{$region}->{lon};
    printf("Refreshing current Session for region '%s' with coordinates: %s, %s\n", $region, $lat, $lon);
    my $url = "https://boot.pluto.tv/v4/start?deviceId=$deviceid&deviceMake=Firefox&deviceType=web&deviceVersion=86.0&deviceModel=web&DNT=0&appName=web&appVersion=5.15.0-cb3de003a5ed7a595e0e5a8e1a8f8f30ad8ed23a&clientID=$deviceid&clientModelNumber=na&deviceLat=$lat&deviceLon=$lon";
    my $request = HTTP::Request->new(GET => $url);
    my $response = $ua->request($request);
    unless ($response->is_success) {
        warn "Failed to get boot data for region '$region': " . $response->status_line;
        return;
    }
    my $json_data_ref = eval { $json_serializer->decode($response->decoded_content) };
    if ($@) {
        warn "Failed to parse JSON for boot data for region '$region': $@";
        return;
    }

    write_cache_file($session_file, $response->decoded_content);
    write_cache_file($bootTime_file, time());

    return $json_data_ref;
}

sub get_bootJson {
    my ($ua, $region) = @_;
    my $now = time();

    my $session_json_content = read_cache_file($session_file);
    my $bootTime = read_cache_file($bootTime_file);

    my $session_ref = defined($session_json_content) ? eval { $json_serializer->decode($session_json_content) } : undef;
    if ($@) {
        warn "Failed to parse session JSON from file: $@";
        $session_ref = undef;
    }

    my $restartThresholdSec = defined($session_ref) ? $session_ref->{session}->{restartThresholdMS} / 1000 : 0;
    my $maxTime = $bootTime + $restartThresholdSec;

    unless (defined $session_ref && $now <= $maxTime) {
        return getBootFromPluto($ua, $region);
    }
    return $session_ref;
}

sub send_response {
    my ($client_socket, $response) = @_;
    my $header = $response->headers->as_string;
    $client_socket->send("HTTP/1.1 " . $response->status_line . "\r\n");
    $client_socket->send($header . "\r\n");
    $client_socket->send($response->content);
}

sub send_help {
    my ($client_socket) = @_;
    my $response = HTTP::Response->new(RC_OK, 'OK');
    my $content = "Following endpoints are available:\n";
    $content .= "\t/\t\t\tThis help message\n";
    $content .= "\t/playlist\t\tfor full m3u8-file\n";
    $content .= "\t/epg\t\t\tfor xmltv-epg-file\n";
    $content .= "\t/epg?channel_id=id\tfor xmltv-epg-file of a specific channel\n";
    $content .= "\t/channels\t\tfor full channel list in JSON format\n";
    $content .= "\t/search?q=query\t\tto search channels by name\n";
    $content .= "\t/categories\t\tto get a list of channel categories\n";
    $content .= "\t/master3u8?id=\t\tfor master.m3u8 of specific channel\n";
    $content .= "\t/playlist3u8?id=\tfor playlist.m3u8 of specific stream\n";
    $response->content($content);
    send_response($client_socket, $response);
}

sub send_xmltvepgfile {
    my ($client_socket, $request, $ua_thread) = @_;
    my @senderListe = get_channel_json($ua_thread);
    unless (@senderListe) {
        my $response = HTTP::Response->new(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
        send_response($client_socket, $response);
        return;
    }
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $channel_id_filter = $params->{'channel_id'};
    my $epg = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<tv>\n";
    for my $sender (@senderListe) {
        next unless $sender->{number} > 0;
        if (defined $channel_id_filter && $sender->{_id} ne $channel_id_filter) {
            next;
        }
        my $sendername = uri_escape($sender->{name});
        $epg .= "<channel id=\"$sendername\">\n";
        $epg .= "<display-name lang=\"de\"><![CDATA[" . $sender->{name} . "]]></display-name>\n";
        if (defined $sender->{logo} && defined $sender->{logo}->{path}) {
            my $logo = $sender->{logo}->{path};
            $logo =~ s/\?.*$//;
            $epg .= "<icon src=\"$logo\" />\n";
        }
        $epg .= "</channel>\n";
    }
    for my $sender (@senderListe) {
        next unless $sender->{number} > 0;
        if (defined $channel_id_filter && $sender->{_id} ne $channel_id_filter) {
            next;
        }
        my $sendername = uri_escape($sender->{name});
        for my $sendung (@{$sender->{timelines} || []}) {
            my ($start, $stop) = ($sendung->{start}, $sendung->{stop});
            $start =~ s/[-:Z\.T]//g;
            $stop =~ s/[-:Z\.T]//g;
            $stop = substr($stop, 0, 14);
            $epg .= "<programme start=\"$start +0000\" stop=\"$stop +0000\" channel=\"$sendername\">\n";
            my $episode = $sendung->{episode};
            my $title = "$sendung->{title}" . (defined $episode->{rating} ? " - $episode->{rating}" : "");
            $epg .= "<title lang=\"de\"><![CDATA[$title]]></title>\n";
            if (defined $episode->{description}) {
                $epg .= "<desc lang=\"de\"><![CDATA[" . $episode->{description} . "]]></desc>\n";
            }
            $epg .= "</programme>\n";
        }
    }
    $epg .= "</tv>\n";
    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header("Content-Type", "application/xml");
    $response->header("Content-Disposition", "attachment; filename=\"plutotv-epg.xml\"");
    $response->content($epg);
    send_response($client_socket, $response);
}

sub buildM3U {
    my ($ua_thread, @senderliste) = @_;
    my $m3u = "#EXTM3U\n";
    for my $sender (@senderliste) {
        next unless $sender->{number} > 0 && $sender->{number} != 2000;
        my $logo = $sender->{logo}->{path};
        if (defined $logo) {
            $logo =~ s/\?.*$//;
            my $encoded_logo = encode_base64($logo, "");
            $m3u .= "#EXTINF:-1 tvg-chno=\"" . $sender->{number} . "\" tvg-id=\"" . uri_escape($sender->{name}) . "\" tvg-name=\"" . $sender->{name} . "\" tvg-logo=\"" . $logo . "\" group-title=\"" . ($sender->{category} || "PlutoTV") . "\"," . $sender->{name} . "\n";
            if ($usestreamlink) {
                my $url = "https://pluto.tv/".$active_region."/live-tv/".$sender->{_id};
                $m3u .= "pipe://$streamlink --stdout --quiet --default-stream best --hls-live-restart --url \"$url\"\n";
            } else {
                my $m3u8_url = "http://$hostip:$port/master3u8?id=" . $sender->{_id};
                $m3u .= "pipe://$ffmpeg -loglevel fatal -threads 0 -nostdin -re -i \"$m3u8_url\" -c copy -vcodec copy -acodec copy -mpegts_copyts 1 -f mpegts -tune zerolatency -mpegts_service_type advanced_codec_digital_hdtv -metadata service_name=\"" . $sender->{name} . "\" pipe:1\n";
            }
        }
    }
    return $m3u;
}

sub send_m3ufile {
    my ($client_socket, $ua_thread) = @_;
    my @senderListe = get_channel_json($ua_thread);
    unless (@senderListe) {
        my $response = HTTP::Response->new(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
        send_response($client_socket, $response);
        return;
    }
    my $m3uContent = buildM3U($ua_thread, @senderListe);
    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header("Content-Type", "audio/x-mpegurl");
    $response->header("Content-Disposition", "attachment; filename=\"plutotv.m3u8\"");
    $response->content($m3uContent);
    send_response($client_socket, $response);
}

sub fixPlaylistUrlsInMaster {
    my ($master, $channelid, $sessionid) = @_;
    my $fixed_master = $master;
    my $host_port = "$hostip:$port";
    $fixed_master =~ s{#EXT-X-STREAM-INF:PROGRAM-ID=([^,]+).*?\n(.*\.m3u8)}{#EXT-X-STREAM-INF:PROGRAM-ID=$1\nhttp://$host_port/playlist3u8?id=$2&channelid=$channelid&session=$sessionid}g;
    $fixed_master =~ s{terminate=true}{terminate=false}g;
    return $fixed_master;
}

sub send_playlistm3u8file {
    my ($client_socket, $request, $ua_thread) = @_;
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my ($playlistid, $channelid, $sessionid) = ($params->{'id'}, $params->{'channelid'}, $params->{'session'});
    unless ($playlistid && $channelid && $sessionid) {
        my $response = HTTP::Response->new(RC_BAD_REQUEST, "Missing required parameters.");
        send_response($client_socket, $response);
        return;
    }
    my $bootJson = get_bootJson($ua_thread, $active_region);
    my $getparams = "terminate=false&embedPartner=&serverSideAds=false&paln=&includeExtendedEvents=false&architecture=&deviceId=unknown&deviceVersion=unknown&appVersion=unknown&deviceType=web&deviceMake=Firefox&sid=".$sessionid."&advertisingId=&deviceLat=54.1241&deviceLon=12.1247&deviceDNT=0&deviceModel=web&userId=&appName=";
    my $url = $bootJson->{servers}->{stitcher}."/stitch/hls/channel/".$channelid."/".$playlistid."/playlist.m3u8?".$getparams;
    my $playlist = get_from_url($ua_thread, $url);
    unless (defined $playlist) {
        my $response = HTTP::Response->new(RC_INTERNAL_SERVER_ERROR, "Failed to fetch playlist.");
        send_response($client_socket, $response);
        return;
    }
    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header("Content-Type", "application/vnd.apple.mpegurl");
    $response->header("Content-Disposition", "attachment; filename=\"playlist.m3u8\"");
    $response->content($playlist);
    send_response($client_socket, $response);
}

sub send_masterm3u8file {
    my ($client_socket, $request, $ua_thread) = @_;
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $channelid = $params->{'id'};
    unless ($channelid) {
        my $response = HTTP::Response->new(RC_BAD_REQUEST, "Missing channel ID.");
        send_response($client_socket, $response);
        return;
    }
    my $bootJson = get_bootJson($ua_thread, $active_region);
    my $baseurl = $bootJson->{servers}->{stitcher}."/stitch/hls/channel/".$channelid."/";
    my $url = $baseurl."master.m3u8?".$bootJson->{stitcherParams};
    my $master = get_from_url($ua_thread, $url);
    unless (defined $master) {
        my $response = HTTP::Response->new(RC_INTERNAL_SERVER_ERROR, "Failed to fetch master playlist.");
        send_response($client_socket, $response);
        return;
    }
    $master = fixPlaylistUrlsInMaster($master, $channelid, $bootJson->{session}->{sessionID});
    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header("Content-Type", "application/vnd.apple.mpegurl");
    $response->header("Content-Disposition", "attachment; filename=\"master.m3u8\"");
    $response->content($master);
    send_response($client_socket, $response);
}

sub send_channels_json {
    my ($client_socket, $ua_thread) = @_;
    my @senderListe = get_channel_json($ua_thread);

    unless (@senderListe) {
        my $response = HTTP::Response->new(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel list from pluto.tv-api.");
        send_response($client_socket, $response);
        return;
    }

    my @filtered_channels;
    for my $sender (@senderListe) {
        # Die `next unless` verhindert, dass der Code bei fehlenden keys abstürzt.
        next unless ref $sender eq 'HASH';
        next unless $sender->{number} > 0;

        my $logo_url = "";
        if (defined $sender->{logo} && defined $sender->{logo}->{path}) {
            $logo_url = $sender->{logo}->{path};
            $logo_url =~ s/\?.*$//;
        }

        my $stream_url = "";
        if (defined $sender->{stitched} && ref $sender->{stitched} eq 'ARRAY' && @{$sender->{stitched}}) {
            $stream_url = $sender->{stitched}->{urls}[0];
        }

        my $filtered_channel = {
            id       => $sender->{_id} // "no_id",
            name     => $sender->{name} // "Unknown Name",
            category => $sender->{category} // "Uncategorized",
            logo_url => $logo_url,
            stream_url => $stream_url,
        };
        push @filtered_channels, $filtered_channel;
    }

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header("Content-Type", "application/json");
    $response->content($json_serializer->encode(\@filtered_channels));
    send_response($client_socket, $response);
}

sub search_channels {
    my ($client_socket, $request, $ua_thread) = @_;
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $query = lc($params->{'q'} || '');

    unless ($query) {
        my $response = HTTP::Response->new(RC_BAD_REQUEST, "Search query 'q' is missing.");
        send_response($client_socket, $response);
        return;
    }

    my @senderListe = get_channel_json($ua_thread);
    my @results;

    for my $sender (@senderListe) {
        if ($sender->{name} && index(lc($sender->{name}), $query) != -1) {
            push @results, $sender;
        }
    }

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header("Content-Type", "application/json");
    $response->content($json_serializer->encode(\@results));
    send_response($client_socket, $response);
}

sub get_categories {
    my ($client_socket, $ua_thread) = @_;
    my @senderListe = get_channel_json($ua_thread);
    my %categories;
    for my $sender (@senderListe) {
        if ($sender->{category}) {
            $categories{$sender->{category}} = 1;
        }
    }
    my @cat_list = sort keys %categories;

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header("Content-Type", "application/json");
    $response->content($json_serializer->encode(\@cat_list));
    send_response($client_socket, $response);
}

sub process_request {
    my ($client_socket) = @_;
    my $ua = LWP::UserAgent->new(
        keep_alive => 1,
        agent      => 'Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:86.0) Gecko/20100101 Firefox/86.0'
    );

    my $request_line = <$client_socket>;
    unless (defined $request_line) {
        warn "Received empty or invalid request.\n";
        $client_socket->close;
        return;
    }

    my ($method, $uri_path) = split(/\s+/, $request_line);

    unless ($method eq 'GET') {
        my $response = HTTP::Response->new(RC_METHOD_NOT_ALLOWED, 'Method Not Allowed');
        send_response($client_socket, $response);
        $client_socket->close;
        return;
    }

    my $uri = eval { URI->new($uri_path) };
    if ($@ || !defined $uri) {
        my $response = HTTP::Response->new(RC_BAD_REQUEST, 'Bad Request');
        send_response($client_socket, $response);
        $client_socket->close;
        return;
    }

    my $path = $uri->path;
    my $request = HTTP::Request->new('GET', $uri);

    printf("Request received for path %s\n", $path);

    if ($path eq "/playlist") {
        send_m3ufile($client_socket, $ua);
    } elsif ($path eq "/master3u8") {
        send_masterm3u8file($client_socket, $request, $ua);
    } elsif ($path eq "/playlist3u8") {
        send_playlistm3u8file($client_socket, $request, $ua);
    } elsif ($path eq "/epg") {
        send_xmltvepgfile($client_socket, $request, $ua);
    } elsif ($path eq "/channels") {
        send_channels_json($client_socket, $ua);
    } elsif ($path eq "/search") {
        search_channels($client_socket, $request, $ua);
    } elsif ($path eq "/categories") {
        get_categories($client_socket, $ua);
    } elsif ($path eq "/") {
        send_help($client_socket);
    } elsif ($path eq "/favicon.ico") {
        my $response = HTTP::Response->new(RC_NO_CONTENT, 'No Content');
        send_response($client_socket, $response);
    } else {
        my $response = HTTP::Response->new(RC_NOT_FOUND, 'Not Found');
        $response->content("No such path available: " . $path);
        send_response($client_socket, $response);
    }

    $client_socket->close;
}

sub sig_handler {
    my $signame = shift;
    printf("Received signal %s. Shutting down...\n", $signame);
    exit;
}

sub main {
    $SIG{INT} = 'sig_handler';
    $SIG{TERM} = 'sig_handler';
    $SIG{CHLD} = 'IGNORE';

    my %args = parse_args();
    $usestreamlink = $args{usestreamlink};
    if ($usestreamlink) {
        $streamlink = which 'streamlink' or die "streamlink not found in PATH.\n";
    } else {
        $ffmpeg = which 'ffmpeg' or die "ffmpeg not found in PATH.\n";
    }

    $port = $args{port} if defined $args{port};
    $active_region = $args{region};

    unless ($args{localonly}) {
        $hostip = Net::Address::IP::Local->public_ipv4;
    }

    unless (exists $regions{$active_region}) {
        die "Unknown region: $active_region. Available regions are: " . join(", ", sort keys %regions) . "\n";
    }

    my $sock = new IO::Socket::INET (
        LocalHost => $hostip,
        LocalPort => $port,
        Proto => 'tcp',
        Listen => 10,
        Reuse => 1,
    ) or die "Cannot create socket: $!\n";

    printf("Server started listening on $hostip using port $port\n");
    printf("Using %s for streaming\n", $usestreamlink ? "streamlink" : "ffmpeg");
    printf("Pluto TV content is being fetched for region '%s'\n", $active_region);

    my $init_ua = LWP::UserAgent->new(
        keep_alive => 1,
        agent      => 'Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:86.0) Gecko/20100101 Firefox/86.0'
    );
    getBootFromPluto($init_ua, $active_region);

    while (my $client_socket = $sock->accept()) {
        my $pid = fork();
        if ($pid == 0) {
            close($sock);
            process_request($client_socket);
            exit(0);
        } else {
            close($client_socket);
        }
    }
}

main();