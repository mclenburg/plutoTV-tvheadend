#!/usr/bin/perl

package PlutoTVServer;

use strict;
use warnings;
use threads;
use utf8;
use Encode qw(encode_utf8);

use HTTP::Daemon;
use HTTP::Status;
use HTTP::Request::Params;
use HTTP::Request::Common;
use HTTP::Cookies;
use DateTime;
use DateTime::Format::Strptime qw(strptime);
use JSON;
use JSON::Parse ':all';
use HTTP::Request ();
use LWP::UserAgent;
use URI::Escape qw(uri_escape_utf8);
use UUID::Tiny ':std';
use File::Which;
use Net::Address::IP::Local;
use Data::Dumper;
use Try::Tiny;
use Getopt::Long qw(:config no_ignore_case);
use Time::HiRes qw(sleep);

# Configuration
my $hostip = "127.0.0.1";
my $port = "9000";
my $apiurl = "http://api.pluto.tv/v2/channels";
my $deviceid = uuid_to_string(create_uuid(UUID_V1));
my $ffmpeg = which 'ffmpeg';
my $streamlink = which 'streamlink';

# M3U8 Validation Configuration
my $MAX_RETRIES = 3;
my $RETRY_DELAY = 2.0;  # Sekunden zwischen Retries
my $MIN_SEGMENTS = 2;   # Minimum Anzahl Segmente für valide M3U8

# Global session variables
our $session;
our $bootTime;

# Region-Konfiguration
my %regions = (
    'DE' => { lat => '52.5200', lon => '13.4050', name => 'Deutschland' },
    'US' => { lat => '40.7128', lon => '-74.0060', name => 'United States' },
    'UK' => { lat => '51.5074', lon => '-0.1278', name => 'United Kingdom' },
    'FR' => { lat => '48.8566', lon => '2.3522', name => 'France' },
    'IT' => { lat => '41.9028', lon => '12.4964', name => 'Italy' },
);

# Command line arguments
my $localhost = grep { $_ eq '--localonly'} @ARGV;
my $usestreamlink = grep { $_ eq '--usestreamlink'} @ARGV;

sub get_args_value {
    my ($param) = @_;
    for my $argnum (0 .. $#ARGV) {
        return $ARGV[$argnum+1] if $ARGV[$argnum] eq $param;
    }
    return undef;
}

sub fork_process {
    my $pid = fork;
    if ($pid) {
        waitpid $pid, 0;
    } else {
        my $pid2 = fork;  # no zombies, make orphans instead
        if ($pid2) {
            exit(0);
        } else {
            return 1;
        }
    }
    return 0;
}

sub create_user_agent {
    my $ua = LWP::UserAgent->new(keep_alive => 1);
    $ua->agent('Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/109.0');
    return $ua;
}

sub get_from_url {
    my ($url) = @_;
    my $request = HTTP::Request->new(GET => $url);
    my $ua = create_user_agent();
    my $response = $ua->request($request);

    return $response->is_success ? $response->decoded_content : undef;
}

# M3U8 Validation Functions
sub validate_m3u8 {
    my ($m3u8_content) = @_;

    # Grundlegende M3U8-Struktur prüfen
    return 0 unless defined $m3u8_content && length($m3u8_content) > 0;

    # M3U8-Header prüfen
    return 0 unless $m3u8_content =~ /^#EXTM3U/m;

    # Prüfen ob mindestens ein gültiges Segment vorhanden ist
    my @segments = $m3u8_content =~ /^(?!#)(.+)$/gm;
    return 0 unless @segments >= $MIN_SEGMENTS;

    # Prüfen auf typische Werbe-/Übergangs-Indikatoren
    # Leere Segmente oder nur Logo-Dateien ausschließen
    my $valid_segments = 0;
    foreach my $segment (@segments) {
        $segment =~ s/^\s+|\s+$//g;  # Whitespace entfernen
        next if $segment eq '';
        next if $segment =~ /logo|placeholder|empty/i;
        $valid_segments++;
    }

    return $valid_segments >= $MIN_SEGMENTS;
}

sub generate_fallback_m3u8 {
    my $fallback = <<'EOF';
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAA==
#EXTINF:10.0,
data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAA==
#EXT-X-ENDLIST
EOF

    printf STDERR "Fallback M3U8 wird verwendet\n";
    return $fallback;
}

sub get_from_url_validated {
    my ($url) = @_;
    my $local_retry_delay = $RETRY_DELAY;

    for my $attempt (1..$MAX_RETRIES) {
        printf STDERR "M3U8 Abruf Versuch $attempt/$MAX_RETRIES für: $url\n";

        # Original get_from_url Funktion verwenden
        my $m3u8_content = get_from_url($url);

        if ($m3u8_content && validate_m3u8($m3u8_content)) {
            printf STDERR "Valide M3U8 erhalten nach Versuch $attempt\n";
            return $m3u8_content;
        }

        printf STDERR "Invalide M3U8 in Versuch $attempt - ";
        if ($attempt < $MAX_RETRIES) {
            printf STDERR "Retry in ${local_retry_delay}s...\n";
            sleep($local_retry_delay);
            # Exponentieller Backoff
            $local_retry_delay *= 1.5;
        } else {
            printf STDERR "Alle Versuche fehlgeschlagen\n";
        }
    }

    # Fallback: Leere aber valide M3U8 zurückgeben
    return generate_fallback_m3u8();
}

sub get_channel_json {
    my ($region) = @_;
    $region ||= 'DE';  # Default region

    my $from = DateTime->now();
    my $to = DateTime->now()->add(days => 2);
    my $url = "$apiurl?start=${from}Z&stop=${to}Z";

    my $content = get_from_url($url);
    return () unless $content;

    my $channels = try { parse_json($content) };
    return $channels ? @{$channels} : ();
}

sub get_boot_from_pluto {
    my ($region) = @_;
    $region ||= 'DE';

    my $region_data = $regions{$region};
    unless ($region_data) {
        warn "Unknown region: $region, using DE as fallback\n";
        $region_data = $regions{'DE'};
    }

    printf("Refresh of current Session for region $region\n");
    my $url = "https://boot.pluto.tv/v4/start?" . join('&',
        "deviceId=$deviceid",
        "deviceMake=Firefox",
        "deviceType=web",
        "deviceVersion=109.0",
        "deviceModel=web",
        "DNT=1",
        "appName=web",
        "appVersion=5.17.0",
        "clientID=$deviceid",
        "clientModelNumber=na",
        "serverSideAds=false",
        "includeExtendedEvents=false",
        "deviceLat=$region_data->{lat}",
        "deviceLon=$region_data->{lon}"
    );

    my $content = get_from_url($url);
    return unless $content;

    $session = try { parse_json($content) };
    $bootTime = DateTime->now() if $session;
    return $session;
}

sub get_boot_json {
    my ($channel_id, $region) = @_;
    $region ||= 'DE';

    my $now = DateTime->now();
    my $max_time;

    if (defined $session && defined $bootTime) {
        my $threshold = $session->{session}->{restartThresholdMS} || 3600000;
        $max_time = $bootTime->clone->add(seconds => $threshold / 1000);
    } else {
        $max_time = $now->subtract(hours => 2);
    }

    if (!defined $session || $now > $max_time) {
        $session = get_boot_from_pluto($region);
    }
    return $session;
}

sub build_m3u_legacy {
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

        if ($usestreamlink) {
            my $url = "https://pluto.tv/" . $session->{session}->{activeRegion} .
                "/live-tv/" . $channel->{slug};
            $m3u .= "pipe://$streamlink --stdout --quiet --default-stream best " .
                "--hls-live-restart --url \"$url\"\n";
        } else {
            $m3u .= "pipe://$ffmpeg -loglevel fatal -threads 0 -nostdin -re " .
                "-i \"http://$hostip:$port/master3u8?id=$id\" " .
                "-c copy -vcodec copy -acodec copy -mpegts_copyts 1 -f mpegts " .
                "-tune zerolatency -mpegts_service_type advanced_codec_digital_hdtv " .
                "-metadata service_name=\"$name\" pipe:1\n";
        }
    }
    return $m3u;
}

sub build_m3u_direct {
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
        $m3u .= "http://$hostip:$port/stream/$id.m3u8\n";
    }
    return $m3u;
}

sub send_help {
    my ($client, $request) = @_;
    my $response = HTTP::Response->new();
    $response->code(200);
    $response->message("OK");
    $response->content("Following endpoints are available:\n" .
        "\t/playlist?region=REGION\tfor full m3u8-file (legacy pipes)\n" .
        "\t/tvheadend?region=REGION\tfor direct streams (tvheadend optimized)\n" .
        "\t/stream/{id}.m3u8\tfor direct HLS stream\n" .
        "\t/master3u8?id=\tfor master.m3u8 of specific channel\n" .
        "\t/epg\t\tfor xmltv-epg-file\n\n" .
        "Available regions: " . join(", ", sort keys %regions) . "\n" .
        "Example: /tvheadend?region=US\n");
    $client->send_response($response);
}

sub send_xmltv_epg_file {
    my ($client, $request) = @_;
    my @channels = get_channel_json();

    unless (@channels) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
        return;
    }

    my $langcode = "de";
    my $epg = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<tv>\n";

    # Channel definitions
    for my $channel (@channels) {
        next unless $channel->{number} > 0;

        my $channel_name = $channel->{name};
        my $channel_id = uri_escape_utf8($channel_name);

        $epg .= "<channel id=\"$channel_id\">\n";
        $epg .= "<display-name lang=\"$langcode\"><![CDATA[$channel_name]]></display-name>\n";

        if (my $logo = $channel->{logo}) {
            my $logo_path = $logo->{path};
            $logo_path = substr($logo_path, 0, index($logo_path, "?")) if index($logo_path, "?") >= 0;
            $epg .= "<icon src=\"$logo_path\" />\n";
        }
        $epg .= "</channel>\n";
    }

    # Programme data
    for my $channel (@channels) {
        next unless $channel->{number} > 0;

        my $channel_id = uri_escape_utf8($channel->{name});

        for my $programme (@{$channel->{timelines} || []}) {
            my ($start, $stop) = ($programme->{start}, $programme->{stop});
            next unless $start && $stop;

            $start =~ s/[-:Z\.T]//g;
            $stop =~ s/[-:Z\.T]//g;
            $stop = substr($stop, 0, 14);

            $epg .= "<programme start=\"$start +0000\" stop=\"$stop +0000\" channel=\"$channel_id\">\n";

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

sub send_m3u_file {
    my ($client, $use_direct_streams, $request) = @_;

    # Extract region parameter if provided
    my $region = 'DE';  # Default
    if ($request) {
        my $params = try { HTTP::Request::Params->new({ req => $request })->params };
        $region = $params->{'region'} if $params && $params->{'region'} && exists $regions{$params->{'region'}};
    }

    my @channels = get_channel_json($region);

    unless (@channels) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
        return;
    }

    my $m3u_content = $use_direct_streams ? build_m3u_direct(@channels) : build_m3u_legacy(@channels);

    my $response = HTTP::Response->new();
    $response->header("content-type", "audio/x-mpegurl");
    $response->header("content-disposition", "filename=\"plutotv.m3u8\"");
    $response->code(200);
    $response->message("OK");
    $response->content(encode_utf8($m3u_content));
    $client->send_response($response);
}

sub get_playlists_from_master {
    my ($master, $base_url) = @_;
    my @lines = split /\n/, $master;
    my $m3u8 = "";
    my $read_next_line = 0;

    for my $line (@lines) {
        if ($read_next_line) {
            $m3u8 .= $base_url . $line;
            $read_next_line = 0;
        } elsif ($line =~ /#EXT-X-STREAM-INF:PROGRAM-ID=/) {
            $read_next_line = 1;
        }
    }
    return $m3u8;
}

sub fix_playlist_urls_in_master {
    my ($master, $channel_id, $session_id) = @_;
    my @lines = split /\n/, $master;
    my $m3u8 = "";
    my $read_next_line = 0;

    for my $line (@lines) {
        if ($read_next_line) {
            my $playlist_part = substr($line, 0, index($line, "/"));
            my $url = "http://$hostip:$port/playlist3u8?id=$playlist_part&channelid=$channel_id&session=$session_id\n";
            $m3u8 .= $url;
            $read_next_line = 0;
        } elsif ($line =~ /#EXT-X-STREAM-INF:PROGRAM-ID=/) {
            $m3u8 .= "$line\n";
            $read_next_line = 1;
        } else {
            $m3u8 .= "$line\n";
        }
    }
    return $m3u8;
}

sub send_direct_stream {
    my ($client, $request) = @_;
    my $path = $request->uri->path;
    my ($channel_id) = $path =~ m{/stream/([^/]+)\.m3u8$};

    unless ($channel_id) {
        $client->send_error(RC_BAD_REQUEST, "Invalid stream path");
        return;
    }

    my $boot_json = get_boot_json($channel_id);
    unless ($boot_json && $boot_json->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }

    my $base_url = $boot_json->{servers}->{stitcher};
    my $url = "$base_url/stitch/hls/channel/$channel_id/master.m3u8?" . $boot_json->{stitcherParams};

    # HIER: get_from_url durch get_from_url_validated ersetzen
    my $master = get_from_url_validated($url);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream");
        return;
    }

    # Convert relative URLs to absolute URLs
    my $stream_base = "$base_url/stitch/hls/channel/$channel_id/";
    $master =~ s{^([^#\n][^\n]*\.m3u8[^\n]*)$}{$stream_base$1}gm;
    $master =~ s{URI="([^"]*\.m3u8[^"]*)"}{URI="$stream_base$1"}g;

    my $response = HTTP::Response->new();
    $response->code(200);
    $response->message("OK");
    $response->header("content-type", "application/vnd.apple.mpegurl");
    $response->content(encode_utf8($master));
    $client->send_response($response);
}

sub send_playlist_m3u8_file {
    my ($client, $request) = @_;
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my ($playlist_id, $channel_id, $session_id) =
        ($params->{'id'}, $params->{'channelid'}, $params->{'session'});

    unless ($playlist_id && $channel_id && $session_id) {
        $client->send_error(RC_BAD_REQUEST, "Missing required parameters");
        return;
    }

    my $boot_json = get_boot_json($channel_id);
    unless ($boot_json && $boot_json->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }

    my $get_params = join('&',
        "terminate=false",
        "embedPartner=",
        "serverSideAds=false",
        "paln=",
        "includeExtendedEvents=false",
        "architecture=",
        "deviceId=$deviceid",
        "deviceVersion=109.0",
        "appVersion=5.17.0",
        "deviceType=web",
        "deviceMake=Firefox",
        "sid=$session_id",
        "advertisingId=",
        "deviceLat=54.1241",
        "deviceLon=12.1247",
        "deviceDNT=1",
        "deviceModel=web",
        "userId=",
        "appName=web"
    );

    my $url = $boot_json->{servers}->{stitcher} .
        "/stitch/hls/channel/$channel_id/$playlist_id/playlist.m3u8?$get_params";

    # HIER: get_from_url durch get_from_url_validated ersetzen
    my $playlist = get_from_url_validated($url);
    unless ($playlist) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch playlist");
        return;
    }

    my $response = HTTP::Response->new();
    $response->header("content-disposition", "filename=\"playlist.m3u8\"");
    $response->code(200);
    $response->message("OK");
    $response->content(encode_utf8($playlist));
    $client->send_response($response);
}

sub send_master_m3u8_file {
    my ($client, $request) = @_;
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $channel_id = $params->{'id'};

    unless ($channel_id) {
        $client->send_error(RC_BAD_REQUEST, "Missing channel ID");
        return;
    }

    my $boot_json = get_boot_json($channel_id);
    unless ($boot_json && $boot_json->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }

    my $base_url = $boot_json->{servers}->{stitcher} . "/stitch/hls/channel/$channel_id/";
    my $url = "${base_url}master.m3u8?" . $boot_json->{stitcherParams};

    # HIER: get_from_url durch get_from_url_validated ersetzen
    my $master = get_from_url_validated($url);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch master playlist");
        return;
    }

    $master =~ s/terminate=true/terminate=false/g;
    $master = fix_playlist_urls_in_master($master, $channel_id, $boot_json->{session}->{sessionID});

    my $response = HTTP::Response->new();
    $response->header("content-disposition", "filename=\"master.m3u8\"");
    $response->code(200);
    $response->message("OK");
    $response->content(encode_utf8($master));
    $client->send_response($response);
}

sub process_request {
    my ($client) = @_;
    my $request = $client->get_request() or die("could not get Client-Request.\n");
    $client->autoflush(1);

    my $path = $request->uri->path;
    printf(" Request received for path $path\n");

    if ($path eq "/playlist") {
        send_m3u_file($client, 0, $request);  # Legacy pipes
    } elsif ($path eq "/tvheadend") {
        send_m3u_file($client, 1, $request);  # Direct streams
    } elsif ($path =~ m{^/stream/}) {
        send_direct_stream($client, $request);
    } elsif ($path eq "/master3u8") {
        send_master_m3u8_file($client, $request);
    } elsif ($path eq "/playlist3u8") {
        send_playlist_m3u8_file($client, $request);
    } elsif ($path eq "/epg") {
        send_xmltv_epg_file($client, $request);
    } elsif ($path eq "/") {
        send_help($client, $request);
    } else {
        $client->send_error(RC_NOT_FOUND, "No such path available: $path");
    }
}

# Initialize configuration
if (!$localhost) {
    $hostip = Net::Address::IP::Local->public_ipv4;
}

if (defined(get_args_value("--port"))) {
    $port = get_args_value("--port");
}

# Start daemon
my $daemon = HTTP::Daemon->new(
    LocalAddr => $hostip,
    LocalPort => $port,
    Reuse => 1,
    ReuseAddr => 1,
    ReusePort => $port,
) or die "Server could not be started.\n\n";

$session = get_boot_json();

printf("Server started listening on $hostip using port $port\n");
while (my $client = $daemon->accept) {
    if (fork_process() == 1) {
        try {
            process_request($client);
        } catch {
            warn "Error processing request: $_\n";
        };
        exit(0);
    }
}