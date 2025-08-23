#!/usr/bin/perl

package PlutoTVServer;

use strict;
use warnings;
use v5.20;
use feature 'signatures';
no warnings 'experimental::signatures';

use FindBin;
use lib "$FindBin::Bin/lib";

use IO::Socket::INET;
use IO::Select;
use HTTP::Request::Params;
use HTTP::Response;
use HTTP::Status;
use LWP::UserAgent;
use JSON::XS;
use Data::Dumper;
use URI;
use URI::Escape;
use File::Which;
use Net::Address::IP::Local;
use UUID::Tiny ':std';
use Getopt::Long qw(:config no_ignore_case);
use POSIX qw(strftime);
use DateTime;
use Fcntl qw(:DEFAULT :flock);
use MIME::Base64;
use Carp qw(croak);
use Try::Tiny;
use Time::HiRes qw(time);
use File::Temp;
use File::Path qw(make_path);
use Encode qw(encode_utf8);

# Konfiguration
our $VERSION = '2.0.0';

# Konstanten
use constant {
    DEFAULT_HOST => "127.16.5.90",
    DEFAULT_PORT => 9000,
    CACHE_TTL_CHANNELS => 15 * 60,    # 15 Minuten
    CACHE_TTL_SESSION => 3600,        # 1 Stunde
    MAX_CONCURRENT_CONNECTIONS => 50,
    REQUEST_TIMEOUT => 30,
    USER_AGENT => 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/109.0',
};

# Globale Variablen
my $config = {
    hostip => DEFAULT_HOST,
    port => DEFAULT_PORT,
    deviceid => uuid_to_string(create_uuid(UUID_V1)),
    usestreamlink => 0,
    active_region => 'DE',
    localonly => 0,
    debug => 0,
    max_workers => 10,
};

# Cache-Verzeichnis
my $cache_dir = File::Temp->newdir(CLEANUP => 1);
make_path($cache_dir) unless -d $cache_dir;

my $session_file = "$cache_dir/plutotv_session.json";
my $bootTime_file = "$cache_dir/plutotv_boot_time.txt";
my $channels_file = "$cache_dir/plutotv_channels.json";
my $channels_time_file = "$cache_dir/plutotv_channels_time.txt";

# Externe Programme
my ($ffmpeg, $streamlink);

# JSON-Serializer mit besseren Optionen
my $json = JSON::XS->new->utf8->allow_blessed->convert_blessed->canonical;

# Region-Konfiguration
my %regions = (
    'DE' => {
        lat => '52.5200',
        lon => '13.4050',
        api_url => 'http://api.pluto.tv/v2/channels',
        name => 'Deutschland'
    },
    'US' => {
        lat => '34.0522',
        lon => '-118.2437',
        api_url => 'http://api.pluto.tv/v2/channels',
        name => 'United States'
    },
    'UK' => {
        lat => '51.5074',
        lon => '-0.1278',
        api_url => 'http://api.pluto.tv/v2/channels',
        name => 'United Kingdom'
    },
    'FR' => {
        lat => '48.8566',
        lon => '2.3522',
        api_url => 'http://api.pluto.tv/v2/channels',
        name => 'France'
    },
    'IT' => {
        lat => '41.9028',
        lon => '12.4964',
        api_url => 'http://api.pluto.tv/v2/channels',
        name => 'Italy'
    },
);

# Funktionen

sub parse_args {
    my %args = (
        localonly => 0,
        usestreamlink => 0,
        port => DEFAULT_PORT,
        region => 'DE',
        debug => 0,
        help => 0,
    );

    GetOptions(
        "localonly|l"     => \$args{localonly},
        "usestreamlink|s" => \$args{usestreamlink},
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
    -s, --usestreamlink     Use streamlink instead of ffmpeg
    -p, --port PORT         Server port (default: @{[DEFAULT_PORT]})
    -r, --region REGION     Region (default: DE)
    -d, --debug             Enable debug output
    -h, --help              Show this help

Available regions:
EOF
    for my $region (sort keys %regions) {
        printf "    %-4s %s\n", $region, $regions{$region}->{name};
    }
}

sub log_message($level, $message) {
    return unless $config->{debug} || $level eq 'ERROR' || $level eq 'INFO';

    my $timestamp = strftime('%Y-%m-%d %H:%M:%S', localtime);
    printf("[%s] %s: %s\n", $timestamp, $level, $message);
}

sub read_cache_file($filename) {
    return unless -e $filename && -r $filename;

    try {
        open(my $fh, '<:encoding(UTF-8)', $filename) or return;
        flock($fh, LOCK_SH) or return;

        my $content = do { local $/; <$fh> };

        flock($fh, LOCK_UN);
        close($fh);

        return $content;
    } catch {
        log_message('ERROR', "Failed to read cache file $filename: $_");
        return;
    };
}

sub write_cache_file($filename, $content) {
    try {
        open(my $fh, '>:encoding(UTF-8)', $filename) or return 0;
        flock($fh, LOCK_EX) or return 0;

        print $fh $content;

        flock($fh, LOCK_UN);
        close($fh);

        return 1;
    } catch {
        log_message('ERROR', "Failed to write cache file $filename: $_");
        return 0;
    };
}

sub create_user_agent {
    return LWP::UserAgent->new(
        agent => USER_AGENT,
        timeout => REQUEST_TIMEOUT,
        keep_alive => 1,
        max_redirect => 3,
        ssl_opts => { verify_hostname => 0 },
        protocols_allowed => ['http', 'https'],
    );
}

sub get_channel_json($ua) {
    my $now = time();

    # Versuche Cache zu verwenden
    my $cached_channels_json = read_cache_file($channels_file);
    my $cached_channels_time = read_cache_file($channels_time_file);

    if ($cached_channels_json && $cached_channels_time &&
        ($now - $cached_channels_time) < CACHE_TTL_CHANNELS) {

        log_message('DEBUG', "Using cached channel list for region '$config->{active_region}'");

        my $json_data = try { $json->decode($cached_channels_json) };
        return @{$json_data || []} if $json_data;
    }

    # Lade frische Daten
    log_message('INFO', "Fetching fresh channel list from PlutoTV API for region '$config->{active_region}'");

    my $from_ts = time();
    my $to_ts = $from_ts + (2 * 24 * 60 * 60);  # 2 Tage
    my $from_iso = strftime('%Y-%m-%dT%H:%M:%S', gmtime($from_ts));
    my $to_iso = strftime('%Y-%m-%dT%H:%M:%S', gmtime($to_ts));

    my $api_url = $regions{$config->{active_region}}->{api_url};
    my $url = "$api_url?start=${from_iso}Z&stop=${to_iso}Z";

    my $content = get_from_url($ua, $url);
    return () unless $content;

    my $json_data = try { $json->decode($content) };
    return () unless $json_data && ref $json_data eq 'ARRAY';

    # Cache speichern
    write_cache_file($channels_file, $content);
    write_cache_file($channels_time_file, $now);

    return @{$json_data};
}

sub get_bootJson($ua, $region) {
    my $now = time();

    my $session_json_content = read_cache_file($session_file);
    my $bootTime = read_cache_file($bootTime_file);

    if ($session_json_content && $bootTime) {
        my $session_ref = try { $json->decode($session_json_content) };

        if ($session_ref && $session_ref->{session}) {
            my $restart_threshold = $session_ref->{session}->{restartThresholdMS} || 0;
            my $max_time = $bootTime + ($restart_threshold / 1000);

            if ($now <= $max_time) {
                log_message('DEBUG', "Using cached session");
                return $session_ref;
            }
        }
    }

    return getBootFromPluto($ua, $region);
}

sub send_response($client_socket, $response) {
    try {
        my $status_line = "HTTP/1.1 " . $response->status_line . "\r\n";
        my $headers = $response->headers->as_string . "\r\n";
        my $content = $response->content || '';

        $client_socket->send($status_line);
        $client_socket->send($headers);
        $client_socket->send($content) if $content;

        $client_socket->shutdown(2);  # Bidirektional shutdown
    } catch {
        log_message('ERROR', "Failed to send response: $_");
    };
}

sub create_error_response($code, $message) {
    my $response = HTTP::Response->new($code, HTTP::Status::status_message($code));
    $response->header('Content-Type', 'text/plain; charset=utf-8');
    $response->content($message);
    return $response;
}

sub send_help($client_socket) {
    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'text/plain; charset=utf-8');

    my $content = <<"EOF";
Pluto TV Proxy Server v$VERSION - tvheadend Integration

Available endpoints:
    /                       This help message
    /playlist              M3U8 playlist (legacy pipe format)
    /tvheadend             M3U8 playlist optimized for tvheadend
    /stream/{id}.m3u8      Direct HLS stream for channel ID
    /epg                   XMLTV EPG file (tvheadend compatible)
    /epg?channel_id=ID     XMLTV EPG for specific channel
    /channels              Channel list in JSON format
    /search?q=QUERY        Search channels by name
    /categories            List of channel categories
    /master3u8?id=ID       Master M3U8 for specific channel
    /playlist3u8?id=ID     Playlist M3U8 for specific stream
    /status                Server status information

tvheadend Integration Guide:
    1. Add Network: IPTV Automatic Network
    2. Set M3U URL: http://$config->{hostip}:$config->{port}/tvheadend
    3. Set EPG URL: http://$config->{hostip}:$config->{port}/epg
    4. Enable 'Scan after creation' and 'Channel name in stream'
    5. Set EPG update interval to 30-60 minutes

Server Configuration:
    Region: $config->{active_region} ($regions{$config->{active_region}}->{name})
    Streaming Method: Direct HLS (tvheadend compatible)
    Listen Address: $config->{hostip}:$config->{port}

Tips for tvheadend:
    - Use /tvheadend endpoint instead of /playlist for better compatibility
    - EPG updates automatically every 30 minutes
    - Channel logos are included automatically
    - LCN (Logical Channel Numbers) are preserved from PlutoTV
EOF

    $response->content(encode_utf8($content));
    send_response($client_socket, $response);
}

sub send_status($client_socket) {
    my $uptime = time() - $^T;
    my $status = {
        version => $VERSION,
        uptime => sprintf("%.2f seconds", $uptime),
        region => $config->{active_region},
        streaming_tool => $config->{usestreamlink} ? 'streamlink' : 'ffmpeg',
        cache_dir => "$cache_dir",
        pid => $$,
    };

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/json; charset=utf-8');
    $response->content($json->encode($status));
    send_response($client_socket, $response);
}

sub send_xmltvepgfile($client_socket, $request, $ua) {
    my @channels = get_channel_json($ua);
    unless (@channels) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR,
                "Unable to fetch channel list from Pluto TV API"));
        return;
    }

    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $channel_id_filter = $params->{'channel_id'};

    my $epg = qq{<?xml version="1.0" encoding="UTF-8"?>\n};
    $epg .= qq{<!DOCTYPE tv SYSTEM "xmltv.dtd">\n};
    $epg .= qq{<tv source-info-name="PlutoTV Proxy" source-info-url="https://pluto.tv" generator-info-name="PlutoTV-Proxy-Server" generator-info-url="">\n};

    # Channel definitions mit tvheadend-kompatiblen IDs
    for my $channel (@channels) {
        next unless $channel->{number} && $channel->{number} > 0;
        next if $channel_id_filter && $channel->{_id} ne $channel_id_filter;

        my $channel_name = $channel->{name} || 'Unknown';
        my $channel_id = $channel->{_id};  # Verwende Original-ID für EPG-Mapping

        $epg .= qq{<channel id="$channel_id">\n};
        $epg .= qq{<display-name lang="de"><![CDATA[$channel_name]]></display-name>\n};
        $epg .= qq{<display-name lang="en"><![CDATA[$channel_name]]></display-name>\n};

        if ($channel->{logo} && $channel->{logo}->{path}) {
            my $logo = $channel->{logo}->{path};
            $logo =~ s/\?.*$//;  # Remove query parameters
            $epg .= qq{<icon src="$logo" />\n};
        }

        # tvheadend-spezifische Channel-Informationen
        if ($channel->{category}) {
            $epg .= qq{<lcn>$channel->{number}</lcn>\n};
        }

        $epg .= qq{</channel>\n};
    }

    # Programme data mit erweiterten tvheadend-Attributen
    for my $channel (@channels) {
        next unless $channel->{number} && $channel->{number} > 0;
        next if $channel_id_filter && $channel->{_id} ne $channel_id_filter;

        my $channel_id = $channel->{_id};

        for my $programme (@{$channel->{timelines} || []}) {
            my ($start, $stop) = ($programme->{start}, $programme->{stop});
            next unless $start && $stop;

            # Zeitformat für XMLTV (YYYYMMDDHHmmss +TTTT)
            $start =~ s/[-:Z\.T]//g;
            $stop =~ s/[-:Z\.T]//g;
            $stop = substr($stop, 0, 14);

            $epg .= qq{<programme start="$start +0000" stop="$stop +0000" channel="$channel_id">\n};

            my $episode = $programme->{episode} || {};
            my $title = $programme->{title} || 'Unknown Programme';

            # Haupttitel
            $epg .= qq{<title lang="de"><![CDATA[$title]]></title>\n};
            $epg .= qq{<title lang="en"><![CDATA[$title]]></title>\n};

            # Untertitel falls verfügbar
            if ($episode->{name} && $episode->{name} ne $title) {
                $epg .= qq{<sub-title lang="de"><![CDATA[$episode->{name}]]></sub-title>\n};
            }

            # Beschreibung
            if ($episode->{description}) {
                $epg .= qq{<desc lang="de"><![CDATA[$episode->{description}]]></desc>\n};
            }

            # Kategorien für tvheadend-Genremapping
            if ($channel->{category}) {
                $epg .= qq{<category lang="de"><![CDATA[$channel->{category}]]></category>\n};
            }

            # Zusätzliche Metadaten
            if ($episode->{rating}) {
                $epg .= qq{<rating system="PlutoTV"><value>$episode->{rating}</value></rating>\n};
            }

            # Episoden-Informationen falls verfügbar
            if ($episode->{season} && $episode->{number}) {
                my $season = $episode->{season};
                my $ep_num = $episode->{number};
                $epg .= qq{<episode-num system="onscreen">S${season}E${ep_num}</episode-num>\n};
                $epg .= qq{<episode-num system="xmltv_ns">} . ($season-1) . "." . ($ep_num-1) . ".0/1</episode-num>\n";
            }

            # Länge/Dauer falls verfügbar
            if ($programme->{duration}) {
                my $duration_sec = $programme->{duration} / 1000;  # ms zu Sekunden
                $epg .= qq{<length units="seconds">$duration_sec</length>\n};
            }

            $epg .= qq{</programme>\n};
        }
    }

    $epg .= qq{</tv>\n};

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/xml; charset=utf-8');
    $response->header('Content-Disposition', 'attachment; filename="plutotv-tvheadend-epg.xml"');
    $response->header('Cache-Control', 'public, max-age=1800');  # 30 Minuten Cache für EPG
    $response->content(encode_utf8($epg));
    send_response($client_socket, $response);
}

sub buildM3U($ua, @channels) {
    my $m3u = "#EXTM3U\n";

    for my $channel (@channels) {
        next unless $channel->{number} && $channel->{number} > 0 && $channel->{number} != 2000;

        my $name = $channel->{name} || 'Unknown Channel';
        my $category = $channel->{category} || 'PlutoTV';
        my $logo = '';

        if ($channel->{logo} && $channel->{logo}->{path}) {
            $logo = $channel->{logo}->{path};
            $logo =~ s/\?.*$//;  # Remove query parameters
        }

        # tvheadend-optimierte M3U mit allen benötigten Attributen
        $m3u .= sprintf(
            "#EXTINF:-1 tvg-id=\"%s\" tvg-chno=\"%d\" tvg-name=\"%s\" tvg-logo=\"%s\" group-title=\"%s\" radio=\"false\",%s\n",
            $channel->{_id},           # Verwende Channel-ID als tvg-id für EPG-Mapping
            $channel->{number},
            $name,
            $logo,
            $category,
            $name
        );

        # Direkte HLS-URL für tvheadend (ohne pipe)
        my $stream_url = "http://$config->{hostip}:$config->{port}/stream/$channel->{_id}.m3u8";
        $m3u .= "$stream_url\n";
    }

    return $m3u;
}

# Neue Funktion: Direkter HLS-Stream für tvheadend
sub send_direct_stream($client_socket, $request, $ua) {
    my $path = $request->uri->path;
    my ($channel_id) = $path =~ m{/stream/([^/]+)\.m3u8$};

    unless ($channel_id) {
        send_response($client_socket,
            create_error_response(RC_BAD_REQUEST, "Invalid stream path"));
        return;
    }

    my $boot_json = get_bootJson($ua, $config->{active_region});
    unless ($boot_json && $boot_json->{servers}) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, "Failed to get session data"));
        return;
    }

    my $base_url = "$boot_json->{servers}->{stitcher}/stitch/hls/channel/$channel_id/";
    my $url = "${base_url}master.m3u8?$boot_json->{stitcherParams}";

    my $master = get_from_url($ua, $url);
    unless ($master) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream"));
        return;
    }

    # Für tvheadend: URLs in Master-Playlist anpassen
    $master = fixPlaylistUrlsInMaster($master, $channel_id, $boot_json->{session}->{sessionID});

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/vnd.apple.mpegurl; charset=utf-8');
    $response->header('Cache-Control', 'no-cache, no-store, must-revalidate');
    $response->header('Pragma', 'no-cache');
    $response->header('Expires', '0');
    $response->content(encode_utf8($master));
    send_response($client_socket, $response);
}

# tvheadend-spezifische M3U-Variante
sub send_tvheadend_m3u($client_socket, $ua) {
    my @channels = get_channel_json($ua);
    unless (@channels) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR,
                "Unable to fetch channel list from Pluto TV API"));
        return;
    }

    my $m3u_content = buildM3U($ua, @channels);

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'audio/x-mpegurl; charset=utf-8');
    $response->header('Content-Disposition', 'attachment; filename="plutotv-tvheadend.m3u8"');
    $response->header('Cache-Control', 'public, max-age=900');  # 15 Minuten Cache
    $response->content(encode_utf8($m3u_content));
    send_response($client_socket, $response);
}

sub send_m3ufile($client_socket, $ua) {
    my @channels = get_channel_json($ua);
    unless (@channels) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR,
                "Unable to fetch channel list from Pluto TV API"));
        return;
    }

    my $m3u_content = buildM3U($ua, @channels);

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'audio/x-mpegurl; charset=utf-8');
    $response->header('Content-Disposition', 'attachment; filename="plutotv.m3u8"');
    $response->content(encode_utf8($m3u_content));
    send_response($client_socket, $response);
}

sub fixPlaylistUrlsInMaster($master, $channelid, $sessionid) {
    my $host_port = "$config->{hostip}:$config->{port}";

    # Behandle sowohl relative als auch absolute URLs
    $master =~ s{#EXT-X-STREAM-INF:([^\n]+)\n([^/\n]+\.m3u8)}
        {#EXT-X-STREAM-INF:$1\nhttp://$host_port/playlist3u8?id=$2&channelid=$channelid&session=$sessionid}g;

    # Für absolute URLs (falls vorhanden)
    $master =~ s{#EXT-X-STREAM-INF:([^\n]+)\n(https?://[^\n]+\.m3u8[^\n]*)}
        {#EXT-X-STREAM-INF:$1\n$2}g;

    # Stelle sicher, dass terminate auf false gesetzt ist
    $master =~ s{terminate=true}{terminate=false}g;

    return $master;
}

# Verbesserte Session-Initialisierung
sub getBootFromPluto($ua, $region) {
    my $region_data = $regions{$region} or return;
    my ($lat, $lon) = ($region_data->{lat}, $region_data->{lon});

    log_message('INFO', "Refreshing session for region '$region' with coordinates: $lat, $lon");

    # Verwende v4 API für boot (das ist noch aktuell)
    my $url = "https://boot.pluto.tv/v4/start?" . join('&',
        "deviceId=$config->{deviceid}",
        "deviceMake=Firefox",
        "deviceType=web",
        "deviceVersion=109.0",
        "deviceModel=web",
        "DNT=0",
        "appName=web",
        "appVersion=5.17.0-38a5bd7",
        "clientID=$config->{deviceid}",
        "clientModelNumber=na",
        "deviceLat=$lat",
        "deviceLon=$lon",
        "deviceDNT=0",
        "userId=",
        "advertisingId=",
        "freeWheelHash="
    );

    # Erweiterte Header für Boot-Request
    my $headers = {
        'User-Agent' => USER_AGENT,
        'Accept' => 'application/json',
        'Accept-Language' => 'de-DE,de;q=0.9,en;q=0.8',
        'Origin' => 'https://pluto.tv',
        'Referer' => 'https://pluto.tv/',
        'DNT' => '0',
    };

    my $content = get_from_url($ua, $url, $headers);
    return unless $content;

    my $json_data = try { $json->decode($content) };
    return unless $json_data;

    # Validiere Session-Daten
    unless ($json_data->{session} && $json_data->{session}->{sessionID}) {
        log_message('ERROR', "Boot response missing session data");
        return;
    }

    # Cache speichern
    write_cache_file($session_file, $content);
    write_cache_file($bootTime_file, time());

    log_message('DEBUG', "Session initialized: $json_data->{session}->{sessionID}");

    return $json_data;
}

# Verbesserte get_from_url Funktion mit Retry-Logik
sub get_from_url($ua, $url, $headers = {}) {
    my $max_retries = 3;
    my $retry_delay = 2;

    for my $attempt (1..$max_retries) {
        try {
            log_message('DEBUG', "Fetching URL (attempt $attempt): $url");

            my $request = HTTP::Request->new(GET => $url);
            for my $header_name (keys %$headers) {
                $request->header($header_name => $headers->{$header_name});
            }

            my $response = $ua->request($request);

            if ($response->is_success) {
                my $content = $response->decoded_content;

                # Zusätzliche Validierung für M3U8-Inhalte
                if ($url =~ /\.m3u8/ && $content !~ /#EXTM3U|#EXT-X-/) {
                    log_message('WARN', "Response doesn't look like valid M3U8 content");
                    return unless $attempt == $max_retries;  # Letzter Versuch
                }

                return $content;
            } else {
                log_message('WARN', "HTTP request failed (attempt $attempt): " . $response->status_line);

                # Bei 4xx Fehlern (Client-Fehler) nicht wiederholen
                if ($response->code >= 400 && $response->code < 500) {
                    log_message('ERROR', "Client error, not retrying: " . $response->status_line);
                    return;
                }

                # Bei letztem Versuch Fehler ausgeben
                if ($attempt == $max_retries) {
                    log_message('ERROR', "HTTP request failed after $max_retries attempts: " . $response->status_line);
                    return;
                }

                # Warte vor erneutem Versuch
                sleep($retry_delay);
                $retry_delay *= 2;  # Exponential backoff
            }
        } catch {
            log_message('ERROR', "Exception during HTTP request (attempt $attempt): $_");
            if ($attempt == $max_retries) {
                return;
            }
            sleep($retry_delay);
        };
    }

    return;
}

sub send_playlistm3u8file($client_socket, $request, $ua) {
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my ($playlistid, $channelid, $sessionid) =
        ($params->{'id'}, $params->{'channelid'}, $params->{'session'});

    unless ($playlistid && $channelid && $sessionid) {
        send_response($client_socket,
            create_error_response(RC_BAD_REQUEST, "Missing required parameters"));
        return;
    }

    my $boot_json = get_bootJson($ua, $config->{active_region});
    unless ($boot_json && $boot_json->{servers}) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, "Failed to get session data"));
        return;
    }

    # Verwende den aktuellen Session-Token aus boot_json, nicht den aus der URL
    my $current_session = $boot_json->{session}->{sessionID};

    my $region_data = $regions{$config->{active_region}};

    # Verbesserte Parameter für bessere Kompatibilität
    my $get_params = join('&',
        "terminate=false",
        "embedPartner=",
        "serverSideAds=true",  # Geändert auf true für bessere Kompatibilität
        "paln=",
        "includeExtendedEvents=false",
        "architecture=",
        "deviceId=$config->{deviceid}",  # Verwende die konfigurierte Device-ID
        "deviceVersion=109.0",
        "appVersion=5.17.0-38a5bd7",
        "deviceType=web",
        "deviceMake=Firefox",
        "sid=$current_session",  # Verwende aktuelle Session
        "advertisingId=",
        "deviceLat=$region_data->{lat}",
        "deviceLon=$region_data->{lon}",
        "deviceDNT=0",
        "deviceModel=web",
        "userId=",
        "appName=web",
        "clientID=$config->{deviceid}",
        "clientModelNumber=na"
    );

    # Verwende stitcher v1 statt v2 für bessere Kompatibilität
    my $base_url = $boot_json->{servers}->{stitcher};
    # Stelle sicher, dass wir v1 verwenden
    $base_url =~ s/\/v2\//\/v1\//g;

    my $url = "$base_url/stitch/hls/channel/$channelid/$playlistid/playlist.m3u8?$get_params";

    log_message('DEBUG', "Fetching playlist from: $url");

    # Erweiterte Header für bessere Authentifizierung
    my $headers = {
        'User-Agent' => USER_AGENT,
        'Accept' => 'application/vnd.apple.mpegurl',
        'Accept-Language' => 'de-DE,de;q=0.9,en;q=0.8',
        'Origin' => 'https://pluto.tv',
        'Referer' => 'https://pluto.tv/',
        'DNT' => '0',
        'Connection' => 'keep-alive',
        'Sec-Fetch-Dest' => 'empty',
        'Sec-Fetch-Mode' => 'cors',
        'Sec-Fetch-Site' => 'cross-site',
    };

    my $playlist = get_from_url($ua, $url, $headers);
    unless ($playlist) {
        # Fallback: Versuche alternative URL-Struktur
        log_message('DEBUG', "First attempt failed, trying fallback URL structure");

        # Alternative URL ohne zusätzliche Parameter
        my $fallback_url = "$base_url/stitch/hls/channel/$channelid/master.m3u8?$boot_json->{stitcherParams}";
        $playlist = get_from_url($ua, $fallback_url, $headers);

        unless ($playlist) {
            send_response($client_socket,
                create_error_response(RC_INTERNAL_SERVER_ERROR, "Failed to fetch playlist from PlutoTV"));
            return;
        }
    }

    # Validiere dass die Playlist tatsächlich Segmente enthält
    unless ($playlist =~ /#EXTINF:|#EXT-X-STREAM-INF:/) {
        log_message('ERROR', "Received playlist has no segments or streams");
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, "Playlist has no segments"));
        return;
    }

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/vnd.apple.mpegurl; charset=utf-8');
    $response->header('Cache-Control', 'no-cache, no-store, must-revalidate');
    $response->header('Pragma', 'no-cache');
    $response->header('Expires', '0');
    $response->content(encode_utf8($playlist));
    send_response($client_socket, $response);
}

# Erweiterte Funktion für direkten Stream (Alternative Implementierung)
sub send_direct_stream_v2($client_socket, $request, $ua) {
    my $path = $request->uri->path;
    my ($channel_id) = $path =~ m{/stream/([^/]+)\.m3u8$};

    unless ($channel_id) {
        send_response($client_socket,
            create_error_response(RC_BAD_REQUEST, "Invalid stream path"));
        return;
    }

    my $boot_json = get_bootJson($ua, $config->{active_region});
    unless ($boot_json && $boot_json->{servers}) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, "Failed to get session data"));
        return;
    }

    # Verwende direkt den stitcher mit v1 API
    my $base_url = $boot_json->{servers}->{stitcher};
    $base_url =~ s/\/v2\//\/v1\//g;

    # Verwende den einfacheren master.m3u8 Endpunkt
    my $url = "$base_url/stitch/hls/channel/$channel_id/master.m3u8?$boot_json->{stitcherParams}";

    log_message('DEBUG', "Fetching direct stream from: $url");

    my $headers = {
        'User-Agent' => USER_AGENT,
        'Accept' => 'application/vnd.apple.mpegurl',
        'Origin' => 'https://pluto.tv',
        'Referer' => 'https://pluto.tv/',
    };

    my $master = get_from_url($ua, $url, $headers);
    unless ($master) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, "Failed to fetch stream"));
        return;
    }

    # Für tvheadend: Gib die Master-Playlist direkt zurück ohne URL-Umschreibung
    # da tvheadend die relativen URLs selbst auflösen kann

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/vnd.apple.mpegurl; charset=utf-8');
    $response->header('Cache-Control', 'no-cache, no-store, must-revalidate');
    $response->header('Pragma', 'no-cache');
    $response->header('Expires', '0');
    $response->content(encode_utf8($master));
    send_response($client_socket, $response);
}

sub send_masterm3u8file($client_socket, $request, $ua) {
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $channelid = $params->{'id'};

    unless ($channelid) {
        send_response($client_socket,
            create_error_response(RC_BAD_REQUEST, "Missing channel ID"));
        return;
    }

    my $boot_json = get_bootJson($ua, $config->{active_region});
    unless ($boot_json && $boot_json->{servers}) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, "Failed to get session data"));
        return;
    }

    my $base_url = "$boot_json->{servers}->{stitcher}/stitch/hls/channel/$channelid/";
    my $url = "${base_url}master.m3u8?$boot_json->{stitcherParams}";

    my $master = get_from_url($ua, $url);
    unless ($master) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, "Failed to fetch master playlist"));
        return;
    }

    $master = fixPlaylistUrlsInMaster($master, $channelid, $boot_json->{session}->{sessionID});

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/vnd.apple.mpegurl; charset=utf-8');
    $response->header('Content-Disposition', 'attachment; filename="master.m3u8"');
    $response->content(encode_utf8($master));
    send_response($client_socket, $response);
}

sub send_channels_json($client_socket, $ua) {
    my @channels = get_channel_json($ua);
    unless (@channels) {
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR,
                "Unable to fetch channel list from Pluto TV API"));
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

        my $stream_url = '';
        if ($channel->{stitched} && ref $channel->{stitched} eq 'HASH' &&
            $channel->{stitched}->{urls} && @{$channel->{stitched}->{urls}}) {
            $stream_url = $channel->{stitched}->{urls}[0];
        }

        push @filtered_channels, {
            id       => $channel->{_id} || 'no_id',
            name     => $channel->{name} || 'Unknown Name',
            number   => $channel->{number},
            category => $channel->{category} || 'Uncategorized',
            logo_url => $logo_url,
            stream_url => $stream_url,
        };
    }

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/json; charset=utf-8');
    $response->content($json->encode(\@filtered_channels));
    send_response($client_socket, $response);
}

sub search_channels($client_socket, $request, $ua) {
    my $params = HTTP::Request::Params->new({ req => $request })->params;
    my $query = lc($params->{'q'} || '');

    unless ($query) {
        send_response($client_socket,
            create_error_response(RC_BAD_REQUEST, "Search query 'q' is missing"));
        return;
    }

    my @channels = get_channel_json($ua);
    my @results;

    for my $channel (@channels) {
        if ($channel->{name} && index(lc($channel->{name}), $query) != -1) {
            push @results, {
                id       => $channel->{_id} || 'no_id',
                name     => $channel->{name} || 'Unknown',
                number   => $channel->{number} || 0,
                category => $channel->{category} || 'Uncategorized',
            };
        }
    }

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/json; charset=utf-8');
    $response->content($json->encode(\@results));
    send_response($client_socket, $response);
}

sub get_categories($client_socket, $ua) {
    my @channels = get_channel_json($ua);
    my %categories;

    for my $channel (@channels) {
        if ($channel->{category}) {
            $categories{$channel->{category}} = 1;
        }
    }

    my @category_list = sort keys %categories;

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/json; charset=utf-8');
    $response->content($json->encode(\@category_list));
    send_response($client_socket, $response);
}

sub process_request($client_socket) {
    my $ua = create_user_agent();

    # Request lesen mit Timeout
    my $select = IO::Select->new($client_socket);
    unless ($select->can_read(10)) {  # 10 Sekunden Timeout
        log_message('WARN', "Request timeout");
        $client_socket->close;
        return;
    }

    my $request_line = <$client_socket>;
    unless (defined $request_line) {
        log_message('WARN', "Received empty or invalid request");
        $client_socket->close;
        return;
    }

    chomp $request_line;
    my ($method, $uri_path, $protocol) = split(/\s+/, $request_line, 3);

    # Nur GET-Requests unterstützen
    unless ($method && $method eq 'GET') {
        send_response($client_socket,
            create_error_response(RC_METHOD_NOT_ALLOWED, 'Method Not Allowed'));
        return;
    }

    # URI parsen
    my $uri = try { URI->new($uri_path) };
    unless ($uri) {
        send_response($client_socket,
            create_error_response(RC_BAD_REQUEST, 'Invalid URI'));
        return;
    }

    my $path = $uri->path;
    my $request = HTTP::Request->new('GET', $uri);

    log_message('DEBUG', "Processing request: $method $path");

    # Request-Headers überspringen (für einfache Implementierung)
    while (my $header_line = <$client_socket>) {
        last if $header_line =~ /^\r?\n$/;
    }

    # Route dispatch
    try {
        given ($path) {
            when ('/') {
                send_help($client_socket);
            }
            when ('/playlist') {
                send_m3ufile($client_socket, $ua);
            }
            when ('/tvheadend') {
                send_tvheadend_m3u($client_socket, $ua);
            }
            when (m{^/stream/}) {
                send_direct_stream($client_socket, $request, $ua);
            }
            when ('/master3u8') {
                send_masterm3u8file($client_socket, $request, $ua);
            }
            when ('/playlist3u8') {
                send_playlistm3u8file($client_socket, $request, $ua);
            }
            when ('/epg') {
                send_xmltvepgfile($client_socket, $request, $ua);
            }
            when ('/channels') {
                send_channels_json($client_socket, $ua);
            }
            when ('/search') {
                search_channels($client_socket, $request, $ua);
            }
            when ('/categories') {
                get_categories($client_socket, $ua);
            }
            when ('/status') {
                send_status($client_socket);
            }
            when ('/favicon.ico') {
                my $response = HTTP::Response->new(RC_NO_CONTENT, 'No Content');
                send_response($client_socket, $response);
            }
            when ('/debug') {
                send_debug_info($client_socket, $ua);
            }
            default {
                send_response($client_socket,
                    create_error_response(RC_NOT_FOUND, "Path not found: $path"));
            }
        }
    } catch {
        log_message('ERROR', "Error processing request $path: $_");
        send_response($client_socket,
            create_error_response(RC_INTERNAL_SERVER_ERROR, 'Internal Server Error'));
    };
}

sub setup_signal_handlers {
    $SIG{INT} = sub {
        my $signame = shift;
        log_message('INFO', "Received signal $signame. Shutting down gracefully...");
        exit 0;
    };

    $SIG{TERM} = $SIG{INT};
    $SIG{CHLD} = 'IGNORE';  # Verhindert Zombie-Prozesse

    # Broken pipe ignorieren (Client disconnect)
    $SIG{PIPE} = 'IGNORE';
}

sub validate_external_tools {
    if ($config->{usestreamlink}) {
        $streamlink = which('streamlink')
            or croak "streamlink not found in PATH. Install it or use --usestreamlink=0";
        log_message('INFO', "Using streamlink: $streamlink");
    } else {
        $ffmpeg = which('ffmpeg')
            or croak "ffmpeg not found in PATH. Install it or use --usestreamlink";
        log_message('INFO', "Using ffmpeg: $ffmpeg");
    }
}

sub validate_region($region) {
    unless (exists $regions{$region}) {
        my $available = join(", ", sort keys %regions);
        croak "Unknown region: $region. Available regions: $available";
    }
}

sub setup_network {
    unless ($config->{localonly}) {
        my $public_ip = try { Net::Address::IP::Local->public_ipv4 };
        $config->{hostip} = $public_ip || DEFAULT_HOST;
    }

    log_message('INFO', "Server will bind to: $config->{hostip}:$config->{port}");
}

sub create_server_socket {
    my $socket = try {
        IO::Socket::INET->new(
            LocalHost => $config->{hostip},
            LocalPort => $config->{port},
            Proto     => 'tcp',
            Listen    => SOMAXCONN,
            Reuse     => 1,
            Timeout   => REQUEST_TIMEOUT,
        )
    };

    unless ($socket) {
        croak "Cannot create server socket on $config->{hostip}:$config->{port}: $!";
    }

    return $socket;
}

sub send_debug_info($client_socket, $ua) {
    my $debug_info = {
        version => $VERSION,
        region => $config->{active_region},
        device_id => $config->{deviceid},
    };

    # Teste Boot-JSON
    my $boot_json = get_bootJson($ua, $config->{active_region});
    if ($boot_json) {
        $debug_info->{session_valid} = 1;
        $debug_info->{session_id} = $boot_json->{session}->{sessionID} || 'missing';
        $debug_info->{stitcher_url} = $boot_json->{servers}->{stitcher} || 'missing';
        $debug_info->{stitcher_params} = $boot_json->{stitcherParams} || 'missing';
    } else {
        $debug_info->{session_valid} = 0;
        $debug_info->{error} = "Failed to get boot session";
    }

    # Teste Channel-Liste
    my @channels = get_channel_json($ua);
    $debug_info->{channels_count} = scalar @channels;

    if (@channels > 0) {
        my $first_channel = $channels[0];
        $debug_info->{sample_channel} = {
            id => $first_channel->{_id},
            name => $first_channel->{name},
            number => $first_channel->{number},
        };

        # Teste eine Master-URL
        if ($boot_json && $boot_json->{servers}) {
            my $base_url = $boot_json->{servers}->{stitcher};
            $base_url =~ s/\/v2\//\/v1\//g;

            my $test_url = "$base_url/stitch/hls/channel/$first_channel->{_id}/master.m3u8?$boot_json->{stitcherParams}";
            $debug_info->{sample_master_url} = $test_url;

            # Teste den Aufruf
            my $master_content = get_from_url($ua, $test_url, {
                'User-Agent' => USER_AGENT,
                'Accept' => 'application/vnd.apple.mpegurl',
                'Origin' => 'https://pluto.tv',
                'Referer' => 'https://pluto.tv/',
            });

            if ($master_content) {
                $debug_info->{master_test_success} = 1;
                $debug_info->{master_content_length} = length($master_content);
                $debug_info->{master_has_streams} = $master_content =~ /#EXT-X-STREAM-INF/ ? 1 : 0;
            } else {
                $debug_info->{master_test_success} = 0;
            }
        }
    }

    my $response = HTTP::Response->new(RC_OK, 'OK');
    $response->header('Content-Type', 'application/json; charset=utf-8');
    $response->content($json->encode($debug_info));
    send_response($client_socket, $response);
}

sub initialize_session {
    my $ua = create_user_agent();

    log_message('INFO', "Initializing session for region '$config->{active_region}'");

    my $session = getBootFromPluto($ua, $config->{active_region});
    unless ($session) {
        log_message('WARN', "Failed to initialize session, but continuing anyway");
    }

    return $session;
}

sub main {
    # Kommandozeilen-Argumente parsen
    my %args = parse_args();

    # Konfiguration aktualisieren
    $config->{$_} = $args{$_} for keys %args;

    # Validierung
    validate_region($config->{active_region});
    validate_external_tools();

    # Signal-Handler einrichten
    setup_signal_handlers();

    # Netzwerk-Konfiguration
    setup_network();

    # Server-Socket erstellen
    my $server_socket = create_server_socket();

    log_message('INFO', sprintf(
        "Pluto TV Proxy Server v%s started on %s:%d",
        $VERSION, $config->{hostip}, $config->{port}
    ));
    log_message('INFO', sprintf(
        "Using %s for streaming",
        $config->{usestreamlink} ? 'streamlink' : 'ffmpeg'
    ));
    log_message('INFO', sprintf(
        "Serving Pluto TV content for region '%s' (%s)",
        $config->{active_region}, $regions{$config->{active_region}}->{name}
    ));

    # Session initialisieren
    initialize_session();

    # Haupt-Server-Loop mit verbessertem Prozess-Management
    my $select = IO::Select->new($server_socket);
    my $active_connections = 0;

    while (1) {
        # Auf eingehende Verbindungen warten
        my @ready = $select->can_read(1);  # 1 Sekunde Timeout

        for my $socket (@ready) {
            if ($socket == $server_socket) {
                # Neue Verbindung akzeptieren
                my $client_socket = $server_socket->accept();
                next unless $client_socket;

                # Verbindungslimit prüfen
                if ($active_connections >= MAX_CONCURRENT_CONNECTIONS) {
                    log_message('WARN', 'Maximum concurrent connections reached');
                    my $response = create_error_response(RC_SERVICE_UNAVAILABLE,
                        'Server busy, try again later');
                    send_response($client_socket, $response);
                    next;
                }

                # Client-IP für Logging
                my $client_addr = $client_socket->peerhost() || 'unknown';
                log_message('DEBUG', "New connection from $client_addr");

                # Fork für Request-Handling
                my $pid = fork();
                if (!defined $pid) {
                    log_message('ERROR', "Failed to fork: $!");
                    $client_socket->close;
                    next;
                }

                if ($pid == 0) {
                    # Kind-Prozess
                    $server_socket->close;  # Server-Socket im Kind nicht benötigt

                    try {
                        process_request($client_socket);
                    } catch {
                        log_message('ERROR', "Error in child process: $_");
                    };

                    $client_socket->close;
                    exit 0;
                } else {
                    # Eltern-Prozess
                    $client_socket->close;  # Client-Socket im Eltern nicht benötigt
                    $active_connections++;

                    # Gelegentlich beendete Kinder aufräumen
                    while ((my $finished_pid = waitpid(-1, POSIX::WNOHANG())) > 0) {
                        $active_connections--;
                        log_message('DEBUG', "Child process $finished_pid finished");
                    }
                }
            }
        }
    }
}

# Programm starten
main() unless caller;