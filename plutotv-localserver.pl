#!/usr/bin/perl

package server;

$| = 1;

use strict;
use warnings;

$SIG{PIPE} = sub {
    print "Got sigpipe \n";

};

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
use URI::Escape;
use UUID::Tiny ':std';
use File::Which;
use Net::Address::IP::Local;

my $hostip = "127.0.0.1";
my $port   = "9000";
my $apiurl = "http://api.pluto.tv/v2/channels";
#channel-id: 5ddbf866b1862a0009a0648e

my $deviceid = uuid_to_string(create_uuid(UUID_V1));
my $ffmpeg = which 'ffmpeg';
my $streamlink = which 'streamlink';
my $session;
my $bootTime;

#check param
my $localhost = grep { $_ eq '--localonly'} @ARGV;
my $usestreamlink = grep { $_ eq '--usestreamlink'} @ARGV;
my $directstreaming = grep { $_ eq '--directstreaming'} @ARGV;

sub get_channel_json {
    my $from = DateTime->now();
    my $to = DateTime->now();
    $to=$to->add(days => 2);
    my $url = $apiurl."?start=".$from."Z&stop=".$to."Z";
    my $request = HTTP::Request->new(GET => $url);
    my $useragent = LWP::UserAgent->new;
    $useragent->agent('Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:86.0) Gecko/20100101 Firefox/86.0');
    my $response = $useragent->request($request);
    if ($response->is_success) {
        return @{parse_json($response->decoded_content)};
    }
    else{
        return ();
    }
}

sub send_help {
    my ($client, $request) = @_;
    my $response = HTTP::Response->new();
    $response->code(200);
    $response->message("OK");
    $response->content("Following endpoints are available:\n\t/playlist\tfor full m3u-file\n\t/channel?id=\tfor master.m3u8 of specific channel\n\t/epg\t\tfor xmltv-epg-file\n");

    $client->send_response($response);
}

sub send_xmltvepgfile {
    my ($client, $request) = @_;

    my @senderListe = get_channel_json;
    if(scalar @senderListe <= 0) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
        return;
    }

    my $langcode ="de";
    my $epg = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
    $epg .= "<tv>\n";

    for my $sender( @senderListe ) {
        if ($sender->{number} > 0) {
            my $sendername = $sender->{name};
            $epg .= "<channel id=\"".uri_escape($sendername)."\">\n";
            $epg .= "<display-name lang=\"$langcode\"><![CDATA[".$sender->{name}."]]></display-name>\n";
            my $logo = $sender->{logo};
            if(defined($logo)) {
                $logo->{path} = substr($logo->{path}, 0, index($logo->{path}, "?"));
                $epg .= "<icon src=\"".$logo->{path}."\" />\n";
            }
            $epg .= "</channel>\n";
        }
    }
    for my $sender( @senderListe ) {
        if($sender->{number} > 0) {
            my $sendername = $sender->{name};

            for my $sendung ( @{$sender->{timelines}} ) {
                my $start = $sendung->{start};
                $start =~ s/[-:Z\.T]//ig;
                my $stop = $sendung->{stop};
                $stop =~ s/[-:Z\.T]//ig;
                $stop = substr($stop, 0, 14);
                $epg .= "<programme start=\"".$start." +0000\" stop=\"".$stop." +0000\" channel=\"".uri_escape($sendername)."\">\n";
                my $episode = $sendung->{episode};
                $epg .= "<title lang=\"$langcode\"><![CDATA[".$sendung->{title}." - ".$episode->{rating}."]]></title>\n";

                $epg .= "<desc lang=\"$langcode\"><![CDATA[".$episode->{description}."]]></desc>\n";
                $epg .= "</programme>\n";
            }
        }
    }
    $epg .= "\n</tv>\n\n\n";

    my $response = HTTP::Response->new();
    $response->header("content-disposition", "filename=\"plutotv-epg.xml\"");
    $response->code(200);
    $response->message("OK");
    $response->content($epg);

    $client->send_response($response);
}

sub get_from_url {
    my $request = HTTP::Request->new(GET => @_);
    my $useragent = LWP::UserAgent->new;
    $useragent->agent('Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:86.0) Gecko/20100101 Firefox/86.0');
    my $response = $useragent->request($request);
    if ($response->is_success) {
        return $response->content;
    }
    else{
        return ();
    }
}

sub buildM3U {
    my @senderliste = @_;
    my $m3u = "#EXTM3U\n";
    my $i = 0;
    for my $sender( @senderliste ) {
        if($sender->{number} > 0) {
            my $logo = $sender->{logo}->{path};
            if(defined $logo) {
                $m3u = $m3u . "#EXTINF:-1 tvg-chno=\"" . $sender->{number} . "\" tvg-id=\"" . uri_escape($sender->{name}) . "\" tvg-name=\"" . $sender->{name} . "\" tvg-logo=\"" . $logo . "\" group-title=\"PlutoTV\"," . $sender->{name} . "\n";
                if($directstreaming || $usestreamlink) {
                    $m3u .= "http://".$hostip.":$port/channel?id=$sender->{_id}\n";
                }
                else {
                    $m3u .= "pipe://" . $ffmpeg . " -loglevel fatal -threads 2 -re -i \"http://" . $hostip . ":" . $port . "/master3u8?id=" . $sender->{_id} . "\" -fflags +genpts+ignidx+igndts -vcodec copy -acodec copy -mpegts_copyts 1 -f mpegts -tune zerolatency -mpegts_flags +initial_discontinuity -mpegts_service_type advanced_codec_digital_hdtv -metadata service_name=\"" . $sender->{name} . "\" pipe:1\n";
                }
            }
        }
    }
    return $m3u;
}
sub getBootFromPluto {
    printf("Refresh of current Session\n");
    my $url = "https://boot.pluto.tv/v4/start?deviceId=".$deviceid."&deviceMake=Firefox&deviceType=web&deviceVersion=86.0&deviceModel=web&DNT=0&appName=web&appVersion=5.15.0-cb3de003a5ed7a595e0e5a8e1a8f8f30ad8ed23a&clientID=".$deviceid."&clientModelNumber=na";
    my $request = HTTP::Request->new(GET => $url);
    my $useragent = LWP::UserAgent->new;
    $useragent->agent('Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:86.0) Gecko/20100101 Firefox/86.0');
    my $response = $useragent->request($request);
    if ($response->is_success) {
        $session = parse_json($response->decoded_content);
        $bootTime = DateTime->now();
        return $session;
    }
    else {
        return ();
    }
}

sub get_bootJson {
    my $now = DateTime->now();
    my $maxTime;

    if(defined $session) {
        $maxTime = $bootTime->add(seconds=>$session->{session}->{restartThresholdMS}/1000);
    }
    else {
        $maxTime = $now->subtract(hours=>2);
    }

    if(!defined $session) {
      return getBootFromPluto;
    }
    elsif($now > $maxTime) {
      return getBootFromPluto;
    }
    return $session;
}

sub send_m3ufile {
    my $client = $_[0];
    my @senderListe = get_channel_json;
    if(scalar @senderListe <= 0) {
        $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
        return;
    }
    my $m3uContent = buildM3U(@senderListe);
    my $response = HTTP::Response->new();
    $response->header("content-type", "audio/x-mpegurl");
    $response->header("content-disposition", "filename=\"plutotv.m3u\"");
    $response->code(200);
    $response->message("OK");
    $response->content($m3uContent);

    $client->send_response($response);
}

sub getPlaylistsFromMaster {
    my ($master, $baseurl) = @_;
    my $lines = () = $master =~ m/\n/g;

    my $linebreakpos = 0;
    my $readnextline = 0;
    my $m3u8 = "";
    for (my $linenum=0; $linenum<$lines; $linenum++) {
        my $line = substr($master, $linebreakpos+1, index($master, "\n", $linebreakpos+1)-$linebreakpos);
        if($readnextline == 1) {
            $m3u8 .= $baseurl.$line;
        }
        if(index($line, "#EXT-X-STREAM-INF:PROGRAM-ID=") >=0) {
            $readnextline = 1;
        }
        else {
            $readnextline = 0;
        }
        $linebreakpos = index($master, "\n", $linebreakpos+1);
    }
    return $m3u8;
}

sub fixPlaylistUrlsInMaster {
    my ($master, $baseurl) = @_;
    my $lines = () = $master =~ m/\n/g;

    my $linebreakpos = -1;
    my $readnextline = 0;
    my $m3u8 = "";
    for (my $linenum=0; $linenum<$lines; $linenum++) {
        my $line = substr($master, $linebreakpos+1, index($master, "\n", $linebreakpos+1)-$linebreakpos);
        if($readnextline == 1) {
            $m3u8 .= $baseurl.$line;
            $readnextline = 0;
            $linebreakpos = index($master, "\n", $linebreakpos+1);
            next;
        }
        if(index($line, "#EXT-X-STREAM-INF:PROGRAM-ID=") >=0) {
            $m3u8 .= $line;
            $readnextline = 1;
        }
        else {
          $m3u8 .= $line;
        }
        $linebreakpos = index($master, "\n", $linebreakpos+1);
    }
    return $m3u8;
}

sub send_masterm3u8file {
    my ($client, $request) = @_;
    my $parse_params = HTTP::Request::Params->new({
        req => $request,
    });
    my $params = $parse_params->params;
    my $channelid = $params->{'id'};

    my $bootJson = get_bootJson($channelid);

    my $baseurl = $bootJson->{servers}->{stitcher}."/stitch/hls/channel/".$channelid."/";
    my $url = $baseurl."master.m3u8";
    $url.="?".$bootJson->{stitcherParams};
    printf("Request for Channel ".$channelid." received");
    my $master = get_from_url($url);

    $master =~ s/terminate=true/terminate=false/ig;
    $master = fixPlaylistUrlsInMaster($master, $baseurl);
    #$playlists =~ s/terminate=true/terminate=false/ig;

    my $response = HTTP::Response->new();
    $response->header("content-disposition", "filename=\"master.m3u8\"");
    $response->code(200);
    $response->message("OK");
    $response->content($master);

    $client->send_response($response);
    printf(" and served.\n");
}

sub stream {
    my ($client, $request) = @_;
    my $parse_params = HTTP::Request::Params->new({
        req => $request,
    });
    my $params = $parse_params->params;
    my $channelid = $params->{'id'};

    my $bootJson = get_bootJson($channelid);

    my $baseurl = $bootJson->{servers}->{stitcher}."/stitch/hls/channel/".$channelid."/";
    my $url = $baseurl."master.m3u8?".$bootJson->{stitcherParams};

    printf("Request for Channel ".$channelid." received");

    # workaround until real streaming is working
    #$url = "http://".$hostip.":".$port."/master3u8?id=".$channelid;

    my $stream_fh;
    if($usestreamlink && defined($streamlink)) {
        open($stream_fh, "-|", $streamlink." --stdout --quiet --twitch-disable-hosting --ringbuffer-size 8M --hds-segment-threads 2 --ffmpeg-fout mpegts --hls-segment-attempts 2 --hls-segment-timeout 5 \"".$url."\" 720,best");
    }
    else {
        open($stream_fh, "-|", $ffmpeg . " -loglevel fatal -threads 2 -re -i '$url' -fflags +genpts+ignidx+igndts -vcodec copy -acodec copy -mpegts_copyts 1 -f mpegts -tune zerolatency -mpegts_flags +initial_discontinuity -c copy -mpegts_service_type advanced_codec_digital_hdtv pipe:1");
    }
    $client->send_header("Content-Type", "video/MP2T");
    $client->send_file($stream_fh);

    printf(" and served.\n");
}

sub process_request {
    my $from = DateTime->now();
    my $to = $from->add(hours => 6);

    $apiurl =~ s/{from}/$from/ig;
    $apiurl =~ s/{to}/$to/ig;

    my $deamon = shift;
    my $client = $deamon->accept or die("could not get any Client");
    my $request = $client->get_request() or die("could not get Client-Request.");
    $client->autoflush(1);

    #http://localhost:9000/playlist <-- liefert m3u aus
    #http://localhost:9000/channel?id=xxxx <-- liefert Stream des angefragten Senders
    #http://localhost:9000/epg <-- liefert XMLTV-EPG
    #http://localhost:9000/ <-- liefert Liste der möglichen Endpunkte

    if($request->uri->path eq "/playlist") {
        send_m3ufile($client);
    }
    elsif($request->uri->path eq "/master3u8") {
        send_masterm3u8file($client, $request);
    }
    elsif($request->uri->path eq "/channel") {
        stream($client, $request);
    }
    elsif($request->uri->path eq "/epg") {
        send_xmltvepgfile($client, $request)
    }
    elsif($request->uri->path eq "/") {
        send_help($client, $request);
    }
    else {
        $client->send_error(RC_NOT_FOUND, "No such path available: ".$request->uri->path);
    }
}

#####  ---- starting the server

if(!$localhost) {
    $hostip = Net::Address::IP::Local->public_ipv4;
}

# START DAEMON
my $deamon = HTTP::Daemon->new(
    LocalAddr => $hostip,
    LocalPort => $port,
    Reuse => 1,
    ReuseAddr => 1,
    ReusePort => $port,
) or die "Server could not be started.\n\n";

printf("Server started listening on $hostip using port ".$port."\n");
while (1) {
    process_request($deamon);
}
printf("Server stopped\n");