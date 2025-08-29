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

my $hostip = "127.0.0.1";
my $port = "9000";
my $apiurl = "http://api.pluto.tv/v2/channels";
my $deviceid = uuid_to_string(create_uuid(UUID_V1));
my $ffmpeg = which 'ffmpeg';
my $streamlink = which 'streamlink';

our $session;
our $bootTime;

our %active_streams = ();
our %stream_counters = ();
our %processed_segments = ();
our %last_sequence_numbers = ();
our $runningNumber = 1;

my %regions = (
    'DE' => { lat => '52.5200', lon => '13.4050', name => 'Germany' },
    'US' => { lat => '40.7128', lon => '-74.0060', name => 'United States' },
    'UK' => { lat => '51.5074', lon => '-0.1278', name => 'United Kingdom' },
    'FR' => { lat => '48.8566', lon => '2.3522', name => 'France' },
    'IT' => { lat => '41.9028', lon => '12.4964', name => 'Italy' },
);

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
        my $pid2 = fork;
        if ($pid2) {
            exit(0);
        } else {
            return 1;
        }
    }
    return 0;
}

sub sort_by_running_number {
    my @array = @_;
    my @sorted_array = sort { $a->{running} <=> $b->{running} } @array;
    return @sorted_array;
}

sub create_user_agent {
    my $ua = LWP::UserAgent->new(keep_alive => 1);
    $ua->agent('Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/109.0');
    my $headers = HTTP::Headers->new;
    $headers->header('Cache-Control' => 'no-cache');
    $headers->header('Pragma'        => 'no-cache');
    $ua->default_headers($headers);
    return $ua;
}

sub get_from_url {
    my ($url) = @_;
    my $request = HTTP::Request->new(GET => $url);
    my $ua = create_user_agent();
    my $response = $ua->request($request);
    return $response->is_success ? $response->decoded_content : undef;
}

sub get_channel_json {
    my ($region) = @_;
    $region ||= 'DE';

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

    my $langcode = "en";
    my $epg = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<tv>\n";

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

    my $region = 'DE';
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

    my $master = get_from_url($url);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream");
        return;
    }

    my $dynamic_m3u = create_dynamic_playlist($master, $channel_id, $base_url);

    my $response = HTTP::Response->new();
    $response->code(200);
    $response->message("OK");
    $response->header("content-type", "application/vnd.apple.mpegurl; charset=utf-8");
    $response->header("cache-control", "no-cache, no-store, must-revalidate");
    $response->header("pragma", "no-cache");
    $response->header("expires", "0");
    $response->content(encode_utf8($dynamic_m3u));
    $client->send_response($response);
}

sub create_dynamic_playlist {
    my ($master_playlist, $channel_id, $base_url) = @_;

    my @lines = split /\r?\n/, $master_playlist;
    my $best_stream_url;
    my $best_bandwidth = 0;

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if ($line =~ /^#EXT-X-STREAM-INF:.*BANDWIDTH=(\d+)/i) {
            my $bandwidth = $1;
            if ($bandwidth > $best_bandwidth && $i + 1 <= $#lines) {
                my $url_line = $lines[$i + 1];
                if ($url_line && $url_line !~ /^#/) {
                    $best_bandwidth = $bandwidth;
                    $best_stream_url = $url_line;
                }
            }
        }
    }

    unless ($best_stream_url) {
        return $master_playlist;
    }

    unless ($best_stream_url =~ /^https?:\/\//) {
        $best_stream_url = "$base_url/stitch/hls/channel/$channel_id/$best_stream_url";
    }

    $stream_counters{$channel_id} = ($stream_counters{$channel_id} || 0) + 1;

    my $stream_id = $stream_counters{$channel_id};
    my $dynamic_playlist = "#EXTM3U\n";
    $dynamic_playlist .= "#EXT-X-VERSION:3\n";
    $dynamic_playlist .= "#EXT-X-TARGETDURATION:10\n";
    $dynamic_playlist .= "#EXT-X-MEDIA-SEQUENCE:0\n";
    $dynamic_playlist .= "#EXT-X-PLAYLIST-TYPE:EVENT\n";
    $dynamic_playlist .= "#EXTINF:86400.0,\n";
    $dynamic_playlist .= "http://$hostip:$port/dynamic_stream/$channel_id/$stream_id.ts\n";
    $dynamic_playlist .= "#EXT-X-ENDLIST\n";

    return $dynamic_playlist;
}

sub send_dynamic_stream {
    my ($client, $request) = @_;
    my $path = $request->uri->path;
    my ($channel_id, $stream_id) = $path =~ m{/dynamic_stream/([^/]+)/(\d+)\.ts$};

    unless ($channel_id && defined $stream_id) {
        $client->send_error(RC_BAD_REQUEST, "Invalid dynamic stream path");
        return;
    }

    if (!exists $active_streams{$channel_id} || $active_streams{$channel_id} != $stream_id) {
        printf("Starting new stream session for channel $channel_id (stream $stream_id)\n");
        $active_streams{$channel_id} = $stream_id;
    }

    my $boot_json = get_boot_json($channel_id);
    unless ($boot_json && $boot_json->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }

    my $base_url = $boot_json->{servers}->{stitcher};
    my $master_url = "$base_url/stitch/hls/channel/$channel_id/master.m3u8?" . $boot_json->{stitcherParams};

    my $master = get_from_url($master_url);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch master playlist");
        return;
    }

    my $playlist_url = extract_best_playlist_url($master, $base_url, $channel_id);
    unless ($playlist_url) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to find playlist URL");
        return;
    }

    stream_with_discontinuity_restart($client, $playlist_url, $channel_id, $stream_id);
}

sub extract_best_playlist_url {
    my ($master_playlist, $base_url, $channel_id) = @_;
    my @lines = split /\r?\n/, $master_playlist;
    my $best_stream_url;
    my $best_bandwidth = 0;

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if ($line =~ /^#EXT-X-STREAM-INF:.*BANDWIDTH=(\d+)/i) {
            my $bandwidth = $1;
            if ($bandwidth > $best_bandwidth && $i + 1 <= $#lines) {
                my $url_line = $lines[$i + 1];
                if ($url_line && $url_line !~ /^#/) {
                    $best_bandwidth = $bandwidth;
                    $best_stream_url = $url_line;
                }
            }
        }
    }

    return unless $best_stream_url;

    unless ($best_stream_url =~ /^https?:\/\//) {
        $best_stream_url = "$base_url/stitch/hls/channel/$channel_id/$best_stream_url";
    }

    return $best_stream_url;
}

sub stream_with_discontinuity_restart {
    my ($client, $playlist_url, $channel_id, $stream_id) = @_;

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

    my $ua = create_user_agent();

    $processed_segments{$channel_id} = {} unless exists $processed_segments{$channel_id};
    $last_sequence_numbers{$channel_id} = -1;

    printf("Starting stream for channel $channel_id with stream_id $stream_id\n");

    while (1) {
        my $playlist_content = get_from_url($playlist_url);
        unless ($playlist_content) {
            printf("Failed to fetch playlist for %s, restarting stream\n", $channel_id);
            last;
        }

        my $playlist_info = parse_playlist_info($playlist_content);

        my @all_segments = extract_segments_from_playlist($playlist_content, $playlist_url, $playlist_info);
        my @new_segments = filter_new_segments(\@all_segments, $channel_id);

        if (@new_segments == 0) {
            sleep(1);
            next;
        }

        printf("Processing %d new segments for channel %s\n", scalar(@new_segments), $channel_id);

        for my $segment (@new_segments) {
            last unless exists $active_streams{$channel_id} && $active_streams{$channel_id} == $stream_id;
            my $success = stream_segment($client, $ua, $segment, $channel_id);
            unless ($success) {
                printf("Failed to stream segment, ending stream for %s\n", $channel_id);
                last;
            }
            $processed_segments{$channel_id}->{$segment->{url}} = time();
        }

        cleanup_old_segments($channel_id);
        sleep(2);
    }
}

sub parse_playlist_info {
    my ($playlist_content) = @_;
    my @lines = split /\r?\n/, $playlist_content;
    my %info = (
        media_sequence => 0,
        has_discontinuity => 0,
        target_duration => 10,
    );

    for my $line (@lines) {
        if ($line =~ /^#EXT-X-MEDIA-SEQUENCE:(\d+)/) {
            $info{media_sequence} = $1;
        }
        elsif ($line =~ /^#EXT-X-TARGETDURATION:(\d+)/) {
            $info{target_duration} = $1;
        }
        elsif ($line =~ /^#EXT-X-DISCONTINUITY$/) {
            $info{has_discontinuity} = 1;
        }
    }

    return \%info;
}

sub extract_segments_from_playlist {
    my ($playlist_content, $base_url, $playlist_info) = @_;
    my @lines = split /\r?\n/, $playlist_content;
    my @segments = ();
    my %current_segment;
    my $sequence_number = $playlist_info->{media_sequence} || 0;
    my ($playlist_base) = $base_url =~ m{^(.+)/[^/]+$};

    my $in_discontinuity_block = 0;

    for my $line (@lines) {
        if ($line =~ /^#EXT-X-KEY:METHOD=AES-128,URI="(.+?)",IV=(.+?)$/) {
            $current_segment{key_uri} = $1;
            $current_segment{iv} = $2;
            $current_segment{iv} =~ s/^0x//;
            $in_discontinuity_block = 0;
        }
        elsif ($line =~ /^#EXT-X-DISCONTINUITY$/) {
            $in_discontinuity_block = 1;
        }
        elsif ($line =~ /^#EXTINF:([0-9.]+),/) {
            $current_segment{duration} = $1;
        }
        elsif ($line =~ /^(https?:\/\/.+?\.ts)$/) {
            $current_segment{url} = $1;
            $current_segment{sequence} = $sequence_number;
            $current_segment{running} = $runningNumber;
            $current_segment{is_discontinuity} = $in_discontinuity_block;

            unless ($current_segment{url} =~ /^https?:\/\//) {
                $current_segment{url} = "$playlist_base/$current_segment{url}";
            }

            if (exists $current_segment{key_uri} && exists $current_segment{iv}) {
                push @segments, { %current_segment };
            }
            %current_segment = ();
            $sequence_number++;
            $runningNumber++;
            if($runningNumber > 1000000) {
                $runningNumber = 1;
            }
        }
    }
    @segments = sort_by_running_number(@segments);
    return @segments;
}

sub filter_new_segments {
    my ($segments, $channel_id) = @_;
    my @new_segments;

    for my $segment (@$segments) {
        next if exists $processed_segments{$channel_id}->{$segment->{url}};

        push @new_segments, $segment;
    }

    return sort_by_running_number(@new_segments);
}

sub stream_segment {
    my ($client, $ua, $segment, $channel_id) = @_;

    my $req = HTTP::Request->new(GET => $segment->{url});
    my $res = $ua->request($req);

    unless ($res->is_success) {
        printf("Failed to fetch segment %s: %s\n", $segment->{url}, $res->status_line);
        return 0;
    }

    my $key_res = $ua->get($segment->{key_uri});
    unless ($key_res->is_success) {
        printf("Failed to fetch key %s: %s\n", $segment->{key_uri}, $key_res->status_line);
        return 0;
    }

    my $encryption_key = $key_res->content;
    if (length($encryption_key) != 16) {
        printf("Invalid key length: %d bytes (expected 16)\n", length($encryption_key));
        return 0;
    }

    my $hex_key = unpack('H*', $encryption_key);
    my $chunk = $res->content;
    my $decrypted_data;

    if (which('openssl')) {
        my $openssl_stderr = '';
        run(
            [
                "openssl", "aes-128-cbc", "-d",
                "-in", "-",
                "-out", "-",
                "-K", $hex_key,
                "-iv", $segment->{iv}
            ],
            "<", \$chunk,
            ">", \$decrypted_data,
            "2>", \$openssl_stderr
        );
    } else {
        printf("!!! Using Crypt::CBC\n");
        my $iv_bin = pack 'H*', $segment->{iv};
        my $cipher = Crypt::CBC->new(
            -key     => $encryption_key,
            -cipher  => 'Rijndael',
            -iv      => $iv_bin,
            -header  => 'none',
            -padding => 'standard',
        );
        $decrypted_data = $cipher->decrypt($chunk);
    }

    if (length($decrypted_data) > 0) {
        my $first_byte = unpack('C', substr($decrypted_data, 0, 1));
        unless ($first_byte == 0x47) {
            printf("Warning: Segment doesn't start with MPEG-TS sync byte (0x%02X)\n", $first_byte);
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
            "<", \$decrypted_data,
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

sub cleanup_old_segments {
    my ($channel_id) = @_;

    return unless exists $processed_segments{$channel_id};

    my $now = time();
    my $cutoff_time = $now - (15 * 60);

    my $removed_count = 0;
    for my $url (keys %{$processed_segments{$channel_id}}) {
        my $segment_time = $processed_segments{$channel_id}->{$url};
        if ($segment_time < $cutoff_time) {
            delete $processed_segments{$channel_id}->{$url};
            $removed_count++;
        }
    }

    printf("Removed %d old segments for channel %s\n", $removed_count, $channel_id) if $removed_count > 0;
}

sub process_request {
    my ($client) = @_;
    my $request = $client->get_request() or die("could not get Client-Request.\n");
    $client->autoflush(1);

    my $path = $request->uri->path;
    printf("Request received for path $path\n");

    if ($path eq "/playlist") {
        send_m3u_file($client, 0, $request);
    }
    elsif ($path eq "/tvheadend") {
        send_m3u_file($client, 1, $request);
    }
    elsif ($path =~ m{^/stream/}) {
        send_direct_stream($client, $request);
    }
    elsif ($path eq "/epg") {
        send_xmltv_epg_file($client, $request);
    }
    elsif ($path =~ m{^/dynamic_stream/}) {
        send_dynamic_stream($client, $request);
    }
    elsif ($path eq "/") {
        send_help($client, $request);
    }
    else {
        $client->send_error(RC_NOT_FOUND, "No such path available: $path");
    }
}

if (!$localhost) {
    $hostip = Net::Address::IP::Local->public_ipv4;
}

if (defined(get_args_value("--port"))) {
    $port = get_args_value("--port");
}

my $daemon = HTTP::Daemon->new(
    LocalAddr => $hostip,
    LocalPort => $port,
    Reuse => 1,
    ReuseAddr => 1,
    ReusePort => $port,
) or die "Server could not be started.\n\n";

$session = get_boot_json();

$SIG{PIPE} = sub {
    printf("SIGPIPE received - client disconnected\n");
    exit(0);
};
$SIG{CHLD} = 'IGNORE';

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