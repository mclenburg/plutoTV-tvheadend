#!/usr/bin/perl

package server;

use strict;
use warnings;
use threads;
use threads::shared;
use FindBin;
use lib "$FindBin::Bin/lib";

use HTTP::Daemon;
use HTTP::Status;
use HTTP::Request::Params;
use LWP::UserAgent;
use JSON;
use Data::Dumper;
use URI::Escape;
use File::Which;
use Net::Address::IP::Local;
use UUID::Tiny ':std';
use Getopt::Long;
use POSIX qw(strftime);
use DateTime;

# Globale Variablen shared zwischen Threads
my $hostip : shared = "127.0.0.1";
my $port   : shared = "9000";
my $apiurl : shared = "http://api.pluto.tv/v2/channels";

my $deviceid : shared = uuid_to_string(create_uuid(UUID_V1));
my $ffmpeg : shared;
my $streamlink : shared;

our $session : shared;
our $bootTime : shared = 0;
our $usestreamlink : shared = 0;

# Caching-Variablen
our $cached_channels : shared;
our $cached_channels_time : shared = 0;
our $cached_epg : shared;
our $cached_epg_time : shared = 0;

# Aenderung: $ua wird nicht mehr als shared deklariert. Jede Funktion erstellt ihre eigene Instanz.
# my $ua : shared = LWP::UserAgent->new(...);

# Kartierung von Regionen zu Breitengrad/Längengrad
my %regions = (
    'DE' => { lat => '52.5200', lon => '13.4050' },  # Berlin, Deutschland
    'US' => { lat => '34.0522', lon => '-118.2437' }, # Los Angeles, USA
    'UK' => { lat => '51.5074', lon => '-0.1278' },  # London, UK
);

# Funktion zum Parsen der Kommandozeilenargumente
sub parse_args {
    my $localonly = 0;
    my $usestreamlink = 0;
    my $port = 9000;
    my $region = 'DE'; # Standardregion

    GetOptions(
        "localonly"     => \$localonly,
        "usestreamlink" => \$usestreamlink,
        "port=i"        => \$port,
        "region=s"      => \$region
    ) or die("Error in command line arguments\n");

    return (
        localonly => $localonly,
        usestreamlink => $usestreamlink,
        port => $port,
        region => $region
    );
}

# Aenderung: LWP::UserAgent-Instanz wird hier lokal erstellt
sub get_from_url {
    my ($url) = @_;
    my $ua = LWP::UserAgent->new(
        keep_alive => 1,
        agent      => 'Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:86.0) Gecko/20100101 Firefox/86.0'
    );
    my $request = HTTP::Request->new(GET => $url);
    my $response = $ua->request($request);
    return $response->is_success ? $response->content : undef;
}

sub get_channel_json {
    # Caching-Logik
    my $now = time();
    lock($cached_channels);
    lock($cached_channels_time);

    if (defined $cached_channels && $now - $cached_channels_time < 15 * 60) {
        printf("Using cached channel list.\n");
        return @$cached_channels;
    }

    printf("Fetching fresh channel list from PlutoTV API.\n");

    my $from_ts = time();
    my $to_ts = $from_ts + (2 * 24 * 60 * 60); # 2 Tage in der Zukunft
    my $from_iso = strftime('%Y-%m-%dT%H:%M:%S', gmtime($from_ts));
    my $to_iso = strftime('%Y-%m-%dT%H:%M:%S', gmtime($to_ts));

    my $url = "$apiurl?start=${from_iso}Z&stop=${to_iso}Z";
    my $ua = LWP::UserAgent->new(
        keep_alive => 1,
        agent      => 'Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:86.0) Gecko/20100101 Firefox/86.0'
    );
    my $request = HTTP::Request->new(GET => $url);
    my $response = $ua->request($request);

    unless ($response->is_success) {
        warn "Failed to fetch channel list: " . $response->status_line;
        return ();
    }

    my $json_data = eval { decode_json($response->decoded_content) };
    if ($@) {
        warn "Failed to parse JSON for channel list: $@";
        return ();
    }

    # Verwenden Sie share(), um die Datenstruktur vor der Zuweisung zu teilen
    $cached_channels = share($json_data);
    $cached_channels_time = $now;
    return @$json_data;
}

sub getBootFromPluto {
    my ($lat, $lon) = @_; # Breitengrad und Längengrad als Argumente
    printf("Refreshing current Session for coordinates: %s, %s\n", $lat, $lon);
    my $url = "https://boot.pluto.tv/v4/start?deviceId=$deviceid&deviceMake=Firefox&deviceType=web&deviceVersion=86.0&deviceModel=web&DNT=0&appName=web&appVersion=5.15.0-cb3de003a5ed7a595e0e5a8e1a8f8f30ad8ed23a&clientID=$deviceid&clientModelNumber=na&deviceLat=$lat&deviceLon=$lon";
    my $ua = LWP::UserAgent->new(
        keep_alive => 1,
        agent      => 'Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:86.0) Gecko/20100101 Firefox/86.0'
    );
    my $request = HTTP::Request->new(GET => $url);
    my $response = $ua->request($request);
    unless ($response->is_success) {
        warn "Failed to get boot data: " . $response->status_line;
        return;
    }
    my $json_data = eval { decode_json($response->decoded_content) };
    if ($@) {
        warn "Failed to parse JSON for boot data: $@";
        return;
    }
    lock($session);
    lock($bootTime);
    # Verwenden Sie share(), um die Datenstruktur vor der Zuweisung zu teilen
    $session = share($json_data);
    $bootTime = time();
    return $session;
}

sub get_bootJson {
    my ($lat, $lon) = @_; # Übernimmt die Koordinaten vom Aufrufer
    my $now = time();
    lock($session);
    lock($bootTime);

    my $restartThresholdSec = defined($session) ? $session->{session}->{restartThresholdMS} / 1000 : 0;
    my $maxTime = $bootTime + $restartThresholdSec;

    unless (defined $session && $now <= $maxTime) {
        return getBootFromPluto($lat, $lon);
    }
    return $session;
}

sub send_help {
    my ($client) = @_;
    my $response = HTTP::Response->new(200, 'OK');
    my $content = "Following endpoints are available:\n";
    $content .= "\t/\t\t\tThis help message\n";
    $content .= "\t/playlist\t\tfor full m3u8-file\n";
    $content .= "\t/epg\t\t\tfor xmltv-epg-file\n";
    $content .= "\t/epg?channel_id=id\tfor xmltv-epg-file of a specific channel\n";
    $content .= "\t/channels\t\tfor full channel list in JSON format\n";
    $content .= "\t/search?q=query\t\tto search channels by name\n";
    $content .= "\t/categories\t\tto get a list of channel categories\n";
    $content .= "\t/master3u8?id=\t\tfor master.m3u8 of specific channel\n";
    $response->content($content);
    $client->send_response($response);
}

sub send_xmltvepgfile {
    my ($client, $request) = @_;
    my @senderListe = get_channel_json();
    unless (@senderListe) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
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
    my $response = HTTP::Response->new(200, 'OK');
    $response->header("Content-Type", "application/xml");
    $response->header("Content-Disposition", "attachment; filename=\"plutotv-epg.xml\"");
    $response->content($epg);
    $client->send_response($response);
}

sub buildM3U {
    my @senderliste = @_;
    my $m3u = "#EXTM3U\n";
    for my $sender (@senderliste) {
        next unless $sender->{number} > 0 && $sender->{number} != 2000;
        my $logo = $sender->{logo}->{path};
        if (defined $logo) {
            $logo =~ s/\?.*$//;
            $m3u .= "#EXTINF:-1 tvg-chno=\"" . $sender->{number} . "\" tvg-id=\"" . uri_escape($sender->{name}) . "\" tvg-name=\"" . $sender->{name} . "\" tvg-logo=\"" . $logo . "\" group-title=\"" . ($sender->{category} || "PlutoTV") . "\"," . $sender->{name} . "\n";
            if ($usestreamlink) {
                my $url = "https://pluto.tv/".$session->{session}->{activeRegion}."/live-tv/".$sender->{_id};
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
    my ($client) = @_;
    my @senderListe = get_channel_json();
    unless (@senderListe) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
        return;
    }
    my $m3uContent = buildM3U(@senderListe);
    my $response = HTTP::Response->new(200, 'OK');
    $response->header("Content-Type", "audio/x-mpegurl");
    $response->header("Content-Disposition", "attachment; filename=\"plutotv.m3u8\"");
    $response->content($m3uContent);
    $client->send_response($response);
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
    my ($client, $request) = @_;
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my ($playlistid, $channelid, $sessionid) = ($params->{'id'}, $params->{'channelid'}, $params->{'session'});
    unless ($playlistid && $channelid && $sessionid) {
        $client->send_error(RC_BAD_REQUEST, "Missing required parameters.");
        return;
    }
    my $bootJson = get_bootJson($regions{DE}->{lat}, $regions{DE}->{lon});
    my $getparams = "terminate=false&embedPartner=&serverSideAds=false&paln=&includeExtendedEvents=false&architecture=&deviceId=unknown&deviceVersion=unknown&appVersion=unknown&deviceType=web&deviceMake=Firefox&sid=".$sessionid."&advertisingId=&deviceLat=54.1241&deviceLon=12.1247&deviceDNT=0&deviceModel=web&userId=&appName=";
    my $url = $bootJson->{servers}->{stitcher}."/stitch/hls/channel/".$channelid."/".$playlistid."/playlist.m3u8?".$getparams;
    my $playlist = get_from_url($url);
    unless (defined $playlist) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch playlist.");
        return;
    }
    my $response = HTTP::Response->new(200, 'OK');
    $response->header("Content-Type", "application/vnd.apple.mpegurl");
    $response->header("Content-Disposition", "attachment; filename=\"playlist.m3u8\"");
    $response->content($playlist);
    $client->send_response($response);
}

sub send_masterm3u8file {
    my ($client, $request) = @_;
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $channelid = $params->{'id'};
    unless ($channelid) {
        $client->send_error(RC_BAD_REQUEST, "Missing channel ID.");
        return;
    }
    my $bootJson = get_bootJson($regions{DE}->{lat}, $regions{DE}->{lon});
    my $baseurl = $bootJson->{servers}->{stitcher}."/stitch/hls/channel/".$channelid."/";
    my $url = $baseurl."master.m3u8?".$bootJson->{stitcherParams};
    my $master = get_from_url($url);
    unless (defined $master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch master playlist.");
        return;
    }
    $master = fixPlaylistUrlsInMaster($master, $channelid, $bootJson->{session}->{sessionID});
    my $response = HTTP::Response->new(200, 'OK');
    $response->header("Content-Type", "application/vnd.apple.mpegurl");
    $response->header("Content-Disposition", "attachment; filename=\"master.m3u8\"");
    $response->content($master);
    $client->send_response($response);
}

sub send_channels_json {
    my ($client) = @_;
    my @senderListe = get_channel_json();
    my $response = HTTP::Response->new(200, 'OK');
    $response->header("Content-Type", "application/json");
    $response->content(encode_json(\@senderListe));
    $client->send_response($response);
}

sub search_channels {
    my ($client, $request) = @_;
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $query = lc($params->{'q'} || '');

    unless ($query) {
        $client->send_error(RC_BAD_REQUEST, "Search query 'q' is missing.");
        return;
    }

    my @senderListe = get_channel_json();
    my @results;

    for my $sender (@senderListe) {
        if ($sender->{name} && index(lc($sender->{name}), $query) != -1) {
            push @results, $sender;
        }
    }

    my $response = HTTP::Response->new(200, 'OK');
    $response->header("Content-Type", "application/json");
    $response->content(encode_json(\@results));
    $client->send_response($response);
}

sub get_categories {
    my ($client) = @_;
    my @senderListe = get_channel_json();
    my %categories;
    for my $sender (@senderListe) {
        if ($sender->{category}) {
            $categories{$sender->{category}} = 1;
        }
    }
    my @cat_list = sort keys %categories;

    my $response = HTTP::Response->new(200, 'OK');
    $response->header("Content-Type", "application/json");
    $response->content(encode_json(\@cat_list));
    $client->send_response($response);
}

sub process_request {
    my $client = shift;
    my $request = eval { $client->get_request() };
    unless (defined $request) {
        warn "Could not get client request.\n";
        $client->close;
        return;
    }
    my $path = $request->uri->path;
    printf("Request received for path %s\n", $path);
    if ($path eq "/playlist") {
        send_m3ufile($client);
    } elsif ($path eq "/master3u8") {
        send_masterm3u8file($client, $request);
    } elsif ($path eq "/playlist3u8") {
        send_playlistm3u8file($client, $request);
    } elsif ($path eq "/epg") {
        send_xmltvepgfile($client, $request);
    } elsif ($path eq "/channels") {
        send_channels_json($client);
    } elsif ($path eq "/search") {
        search_channels($client, $request);
    } elsif ($path eq "/categories") {
        get_categories($client);
    } elsif ($path eq "/") {
        send_help($client);
    } else {
        $client->send_error(RC_NOT_FOUND, "No such path available: " . $path);
    }
    $client->close;
}

sub sig_handler {
    my $signame = shift;
    printf("Received signal %s. Shutting down...\n", $signame);
    exit;
}

# Hauptfunktion
sub main {
    # Signal-Handler registrieren
    $SIG{INT} = 'sig_handler';
    $SIG{TERM} = 'sig_handler';

    my %args = parse_args();
    if ($args{usestreamlink}) {
        $usestreamlink = 1;
        $streamlink = which 'streamlink' or die "streamlink not found in PATH.\n";
    } else {
        $ffmpeg = which 'ffmpeg' or die "ffmpeg not found in PATH.\n";
    }

    $port = $args{port} if defined $args{port};

    unless ($args{localonly}) {
        $hostip = Net::Address::IP::Local->public_ipv4;
    }

    my $lat;
    my $lon;

    if (exists $regions{$args{region}}) {
        $lat = $regions{$args{region}}->{lat};
        $lon = $regions{$args{region}}->{lon};
    } else {
        die "Unknown region: $args{region}. Available regions are: " . join(", ", sort keys %regions) . "\n";
    }

    my $daemon = HTTP::Daemon->new(
        LocalAddr => $hostip,
        LocalPort => $port,
        Reuse     => 1,
        ReuseAddr => 1,
    ) or die "Server could not be started: $!\n";

    printf("Server started listening on $hostip using port $port\n");
    printf("Using %s for streaming\n", $usestreamlink ? "streamlink" : "ffmpeg");
    printf("Pluto TV content is being fetched for region '%s'\n", $args{region});

    # getBootJson einmalig vor dem Thread-Loop aufrufen, um die Session zu initialisieren
    get_bootJson($lat, $lon);

    while (my $client = $daemon->accept) {
        threads->new(\&process_request, $client)->detach();
    }
}

main();