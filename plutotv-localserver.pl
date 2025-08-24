#!/usr/bin/perl

package PlutoTVServer;

use strict;
use warnings;
use v5.20;

use HTTP::Daemon;
use HTTP::Status;
use HTTP::Request::Params;
use HTTP::Response;
use LWP::UserAgent;
use JSON::XS;
use URI::Escape;
use UUID::Tiny ':std';
use File::Which;
use Net::Address::IP::Local;
use DateTime;
use Getopt::Long qw(:config no_ignore_case);
use POSIX qw(strftime);
use Try::Tiny;

# Konfiguration
our $VERSION = '2.1.0';

use constant {
    DEFAULT_HOST => "127.0.0.1",
    DEFAULT_PORT => 9000,
    REQUEST_TIMEOUT => 30,
    USER_AGENT => 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/109.0',
};

my $config = {
    hostip => DEFAULT_HOST,
    port => DEFAULT_PORT,
    deviceid => uuid_to_string(create_uuid(UUID_V1)),
    active_region => 'DE',
    localonly => 0,
    debug => 0,
};

# Cache-Variablen
my ($session, $bootTime, $cached_channels, $channels_time);

# JSON-Serializer
my $json = JSON::XS->new->utf8->canonical;

# Region-Konfiguration
my %regions = (
    'DE' => { lat => '52.5200', lon => '13.4050', api_url => 'http://api.pluto.tv/v2/channels', name => 'Deutschland' },
    'US' => { lat => '34.0522', lon => '-118.2437', api_url => 'http://api.pluto.tv/v2/channels', name => 'United States' },
    'UK' => { lat => '51.5074', lon => '-0.1278', api_url => 'http://api.pluto.tv/v2/channels', name => 'United Kingdom' },
);

sub parse_args {
    my %args = (
        localonly => 0,
        port => DEFAULT_PORT,
        region => 'DE',
        debug => 0,
        help => 0,
    );

    GetOptions(
        "localonly|l"     => \$args{localonly},
        "port|p=i"        => \$args{port},
        "region|r=s"      => \$args{region},
        "debug|d"         => \$args{debug},
        "help|h"          => \$args{help},
    ) or die("Error in command line arguments\n");

    if ($args{help}) {
        print_help();
        exit 0;
    }

    return %args;
}

sub print_help {
    print <<"EOF";
Pluto TV Proxy Server v$VERSION

Usage: $0 [OPTIONS]

Options:
    -l, --localonly         Bind to localhost only
    -p, --port PORT         Server port (default: @{[DEFAULT_PORT]})
    -r, --region REGION     Region (default: DE)
    -d, --debug             Enable debug output
    -h, --help              Show this help

Available regions: DE, US, UK
EOF
}

sub log_message {
    my ($level, $message) = @_;
    return unless $config->{debug} || $level eq 'ERROR' || $level eq 'INFO';
    my $timestamp = strftime('%Y-%m-%d %H:%M:%S', localtime);
    printf("[%s] %s: %s\n", $timestamp, $level, $message);
}

sub create_user_agent {
    return LWP::UserAgent->new(
        agent => USER_AGENT,
        timeout => REQUEST_TIMEOUT,
        keep_alive => 1,
    );
}

sub get_from_url {
    my ($ua, $url) = @_;
    try {
        log_message('DEBUG', "Fetching URL: $url");
        my $response = $ua->get($url);
        return $response->is_success ? $response->decoded_content : undef;
    } catch {
        log_message('ERROR', "Failed to fetch URL $url: $_");
        return undef;
    };
}

sub get_channel_json {
    my ($ua) = @_;
    my $now = time();

    # Cache-Check (15 Minuten)
    if ($cached_channels && $channels_time && ($now - $channels_time) < 900) {
        log_message('DEBUG', "Using cached channel list");
        return @{$cached_channels};
    }

    log_message('INFO', "Fetching channel list from PlutoTV API");
    my $from = DateTime->now();
    my $to = DateTime->now()->add(days => 2);
    my $api_url = $regions{$config->{active_region}}->{api_url};
    my $url = "$api_url?start=${from}Z&stop=${to}Z";

    my $content = get_from_url($ua, $url);
    return () unless $content;

    my $json_data = try { $json->decode($content) };
    return () unless $json_data && ref $json_data eq 'ARRAY';

    # Cache speichern
    $cached_channels = $json_data;
    $channels_time = $now;

    return @{$json_data};
}

sub getBootFromPluto {
    my ($ua, $region) = @_;
    my $region_data = $regions{$region} or return;
    my ($lat, $lon) = ($region_data->{lat}, $region_data->{lon});

    log_message('INFO', "Refreshing session for region '$region'");

    my $url = "https://boot.pluto.tv/v4/start?" . join('&',
        "deviceId=$config->{deviceid}",
        "deviceMake=Firefox",
        "deviceType=web",
        "deviceVersion=109.0",
        "deviceModel=web",
        "DNT=0",
        "appName=web",
        "appVersion=5.17.0",
        "clientID=$config->{deviceid}",
        "deviceLat=$lat",
        "deviceLon=$lon"
    );

    my $content = get_from_url($ua, $url);
    return unless $content;

    my $json_data = try { $json->decode($content) };
    if ($json_data) {
        $session = $json_data;
        $bootTime = DateTime->now();
    }

    return $json_data;
}

sub get_bootJson {
    my ($ua, $region) = @_;
    my $now = DateTime->now();
    my $maxTime;

    if (defined $session && defined $bootTime) {
        $maxTime = $bootTime->clone->add(seconds => ($session->{session}->{restartThresholdMS} || 3600000) / 1000);
    } else {
        $maxTime = $now->subtract(hours => 2);
    }

    if (!defined $session || $now > $maxTime) {
        $session = getBootFromPluto($ua, $region);
    }

    return $session;
}

sub send_help {
    my ($client) = @_;
    my $response = HTTP::Response->new(200, 'OK');
    $response->content_type('text/plain');

    my $content = <<"EOF";
Pluto TV Proxy Server v$VERSION - tvheadend Integration

Available endpoints:
    /                       This help message
    /playlist              M3U8 playlist for tvheadend
    /stream/{id}.m3u8      Direct HLS stream for channel ID
    /epg                   XMLTV EPG file
    /master3u8?id=ID       Master M3U8 for specific channel
    /playlist3u8?id=ID     Playlist M3U8 for specific stream
    /channels              Channel list in JSON format

Server Configuration:
    Region: $config->{active_region} ($regions{$config->{active_region}}->{name})
    Listen Address: $config->{hostip}:$config->{port}
EOF

    $response->content($content);
    $client->send_response($response);
}

sub send_xmltvepgfile {
    my ($client) = @_;
    my $ua = create_user_agent();
    my @channels = get_channel_json($ua);

    unless (@channels) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel list from Pluto TV API");
        return;
    }

    my $epg = qq{<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n};

    # Channel definitions
    for my $channel (@channels) {
        next unless $channel->{number} && $channel->{number} > 0;
        my $channel_name = $channel->{name} || 'Unknown';
        my $channel_id = uri_escape($channel_name);

        $epg .= qq{<channel id="$channel_id">\n};
        $epg .= qq{<display-name lang="de"><![CDATA[$channel_name]]></display-name>\n};

        if ($channel->{logo} && $channel->{logo}->{path}) {
            my $logo = $channel->{logo}->{path};
            $logo =~ s/\?.*$//;
            $epg .= qq{<icon src="$logo" />\n};
        }
        $epg .= qq{</channel>\n};
    }

    # Programme data
    for my $channel (@channels) {
        next unless $channel->{number} && $channel->{number} > 0;
        my $channel_id = uri_escape($channel->{name});

        for my $programme (@{$channel->{timelines} || []}) {
            my ($start, $stop) = ($programme->{start}, $programme->{stop});
            next unless $start && $stop;

            $start =~ s/[-:Z\.T]//g;
            $stop =~ s/[-:Z\.T]//g;
            $stop = substr($stop, 0, 14);

            $epg .= qq{<programme start="$start +0000" stop="$stop +0000" channel="$channel_id">\n};

            my $episode = $programme->{episode} || {};
            my $title = $programme->{title} || 'Unknown Programme';

            $epg .= qq{<title lang="de"><![CDATA[$title]]></title>\n};

            if ($episode->{description}) {
                $epg .= qq{<desc lang="de"><![CDATA[$episode->{description}]]></desc>\n};
            }

            $epg .= qq{</programme>\n};
        }
    }

    $epg .= qq{</tv>\n};

    my $response = HTTP::Response->new(200, 'OK');
    $response->header("content-disposition", "filename=\"plutotv-epg.xml\"");
    $response->content_type('application/xml');
    $response->content($epg);
    $client->send_response($response);
}

sub buildM3U {
    my (@channels) = @_;
    my $m3u = "#EXTM3U\n";

    for my $channel (@channels) {
        next unless $channel->{number} && $channel->{number} > 0 && $channel->{number} != 2000;

        my $name = $channel->{name} || 'Unknown Channel';
        my $logo = '';

        if ($channel->{logo} && $channel->{logo}->{path}) {
            $logo = $channel->{logo}->{path};
            $logo =~ s/\?.*$//;
        }

        $m3u .= sprintf(
            "#EXTINF:-1 tvg-chno=\"%d\" tvg-id=\"%s\" tvg-name=\"%s\" tvg-logo=\"%s\" group-title=\"PlutoTV\",%s\n",
            $channel->{number},
            uri_escape($name),
            $name,
            $logo,
            $name
        );

        # Direkte HLS-URL
        $m3u .= "http://$config->{hostip}:$config->{port}/stream/$channel->{_id}.m3u8\n";
    }

    return $m3u;
}

sub send_m3ufile {
    my ($client) = @_;
    my $ua = create_user_agent();
    my @channels = get_channel_json($ua);

    unless (@channels) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel list from Pluto TV API");
        return;
    }

    my $m3u_content = buildM3U(@channels);

    my $response = HTTP::Response->new(200, 'OK');
    $response->header("content-type", "audio/x-mpegurl");
    $response->header("content-disposition", "filename=\"plutotv.m3u8\"");
    $response->content($m3u_content);
    $client->send_response($response);
}

sub send_direct_stream {
    my ($client, $request) = @_;
    my $ua = create_user_agent();
    my $path = $request->uri->path;
    my ($channel_id) = $path =~ m{/stream/([^/]+)\.m3u8$};

    unless ($channel_id) {
        $client->send_error(RC_BAD_REQUEST, "Invalid stream path");
        return;
    }

    my $boot_json = get_bootJson($ua, $config->{active_region});
    unless ($boot_json && $boot_json->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }

    my $base_url = $boot_json->{servers}->{stitcher};
    my $url = "$base_url/stitch/hls/channel/$channel_id/master.m3u8?$boot_json->{stitcherParams}";

    my $master = get_from_url($ua, $url);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream");
        return;
    }

    # Konvertiere relative URLs zu absoluten URLs
    my $stitcher_base = "$base_url/stitch/hls/channel/$channel_id/";
    $master =~ s{^([^#\n][^\n]*\.m3u8[^\n]*)$}{$stitcher_base$1}gm;
    $master =~ s{URI="([^"]*\.m3u8[^"]*)"}{URI="$stitcher_base$1"}g;

    my $response = HTTP::Response->new(200, 'OK');
    $response->content_type('application/vnd.apple.mpegurl');
    $response->content($master);
    $client->send_response($response);
}

sub fixPlaylistUrlsInMaster {
    my ($master, $channelid, $sessionid) = @_;
    my @lines = split /\n/, $master;
    my $m3u8 = "";
    my $readnextline = 0;

    for my $line (@lines) {
        if ($readnextline) {
            # Extrahiere Playlist-ID aus der URL
            my ($playlist_id) = $line =~ m{([^/]+)/playlist\.m3u8};
            $playlist_id ||= $line;
            $playlist_id =~ s{/.*$}{};

            my $url = "http://$config->{hostip}:$config->{port}/playlist3u8?id=$playlist_id&channelid=$channelid&session=$sessionid\n";
            $m3u8 .= $url;
            $readnextline = 0;
        } elsif ($line =~ /#EXT-X-STREAM-INF:/) {
            $m3u8 .= "$line\n";
            $readnextline = 1;
        } else {
            $m3u8 .= "$line\n";
        }
    }

    $m3u8 =~ s/terminate=true/terminate=false/g;
    return $m3u8;
}

sub send_masterm3u8file {
    my ($client, $request) = @_;
    my $ua = create_user_agent();
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $channelid = $params->{'id'};

    unless ($channelid) {
        $client->send_error(RC_BAD_REQUEST, "Missing channel ID");
        return;
    }

    my $bootJson = get_bootJson($ua, $config->{active_region});
    unless ($bootJson && $bootJson->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }

    my $base_url = $bootJson->{servers}->{stitcher};
    my $url = "$base_url/stitch/hls/channel/$channelid/master.m3u8?$bootJson->{stitcherParams}";

    my $master = get_from_url($ua, $url);
    unless ($master) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch master playlist");
        return;
    }

    $master = fixPlaylistUrlsInMaster($master, $channelid, $bootJson->{session}->{sessionID});

    my $response = HTTP::Response->new(200, 'OK');
    $response->header("content-disposition", "filename=\"master.m3u8\"");
    $response->content_type('application/vnd.apple.mpegurl');
    $response->content($master);
    $client->send_response($response);
}

sub send_playlistm3u8file {
    my ($client, $request) = @_;
    my $ua = create_user_agent();
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my ($playlistid, $channelid, $sessionid) = ($params->{'id'}, $params->{'channelid'}, $params->{'session'});

    unless ($playlistid && $channelid && $sessionid) {
        $client->send_error(RC_BAD_REQUEST, "Missing required parameters");
        return;
    }

    my $bootJson = get_bootJson($ua, $config->{active_region});
    unless ($bootJson && $bootJson->{servers}) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to get session data");
        return;
    }

    my $region_data = $regions{$config->{active_region}};
    my $getparams = join('&',
        "terminate=false",
        "sid=$sessionid",
        "deviceLat=$region_data->{lat}",
        "deviceLon=$region_data->{lon}",
        "deviceId=$config->{deviceid}",
        "deviceType=web",
        "deviceMake=Firefox",
        "deviceDNT=0",
        "deviceModel=web",
        "appName=web"
    );

    my $url = "$bootJson->{servers}->{stitcher}/stitch/hls/channel/$channelid/$playlistid/playlist.m3u8?$getparams";
    my $playlist = get_from_url($ua, $url);

    unless ($playlist) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Failed to fetch playlist");
        return;
    }

    my $response = HTTP::Response->new(200, 'OK');
    $response->header("content-disposition", "filename=\"playlist.m3u8\"");
    $response->content_type('application/vnd.apple.mpegurl');
    $response->content($playlist);
    $client->send_response($response);
}

sub send_channels_json {
    my ($client) = @_;
    my $ua = create_user_agent();
    my @channels = get_channel_json($ua);

    unless (@channels) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel list from Pluto TV API");
        return;
    }

    my @filtered_channels;
    for my $channel (@channels) {
        next unless ref $channel eq 'HASH';
        next unless $channel->{number} && $channel->{number} > 0;

        my $logo_url = '';
        if ($channel->{logo} && $channel->{logo}->{path}) {
            $logo_url = $channel->{logo}->{path};
            $logo_url =~ s/\?.*$//;
        }

        push @filtered_channels, {
            id       => $channel->{_id} || 'no_id',
            name     => $channel->{name} || 'Unknown Name',
            number   => $channel->{number},
            category => $channel->{category} || 'Uncategorized',
            logo_url => $logo_url,
        };
    }

    my $response = HTTP::Response->new(200, 'OK');
    $response->content_type('application/json');
    $response->content($json->encode(\@filtered_channels));
    $client->send_response($response);
}

sub process_request {
    my ($client) = @_;
    my $request = $client->get_request() or return;
    $client->autoflush(1);

    my $path = $request->uri->path;
    log_message('DEBUG', "Processing request: $path");

    if ($path eq "/") {
        send_help($client);
    } elsif ($path eq "/playlist") {
        send_m3ufile($client);
    } elsif ($path =~ m{^/stream/}) {
        send_direct_stream($client, $request);
    } elsif ($path eq "/master3u8") {
        send_masterm3u8file($client, $request);
    } elsif ($path eq "/playlist3u8") {
        send_playlistm3u8file($client, $request);
    } elsif ($path eq "/epg") {
        send_xmltvepgfile($client);
    } elsif ($path eq "/channels") {
        send_channels_json($client);
    } else {
        $client->send_error(RC_NOT_FOUND, "Path not found: $path");
    }
}

sub main {
    # Kommandozeilen-Argumente parsen
    my %args = parse_args();
    $config->{$_} = $args{$_} for keys %args;

    # Validierung
    unless (exists $regions{$config->{active_region}}) {
        die "Unknown region: $config->{active_region}\n";
    }

    # Netzwerk-Konfiguration
    unless ($config->{localonly}) {
        my $public_ip = try { Net::Address::IP::Local->public_ipv4 };
        $config->{hostip} = $public_ip || DEFAULT_HOST;
    }

    # Server-Socket erstellen
    my $daemon = HTTP::Daemon->new(
        LocalAddr => $config->{hostip},
        LocalPort => $config->{port},
        Reuse => 1,
        ReuseAddr => 1,
    ) or die "Cannot create server socket: $!\n";

    log_message('INFO', "Pluto TV Proxy Server v$VERSION started on $config->{hostip}:$config->{port}");
    log_message('INFO', "Serving Pluto TV content for region '$config->{active_region}' ($regions{$config->{active_region}}->{name})");

    # Session initialisieren
    my $ua = create_user_agent();
    get_bootJson($ua, $config->{active_region});

    # Server-Loop
    while (my $client = $daemon->accept) {
        my $pid = fork();
        if (!defined $pid) {
            log_message('ERROR', "Failed to fork: $!");
            next;
        }

        if ($pid == 0) {
            # Kind-Prozess
            try {
                process_request($client);
            } catch {
                log_message('ERROR', "Error in child process: $_");
            };
            exit 0;
        } else {
            # Eltern-Prozess - warte auf Kind
            waitpid($pid, 0);
        }
    }
}

main() unless caller;