#!/usr/bin/perl

package server;

$| = 1;

use strict;
use warnings;

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

my $hostip = "127.0.0.1";
my $port   = "9000";
my $apiurl = "http://api.pluto.tv/v2/channels?start={from}Z&stop={to}Z";

sub get_channel_json {
    my $request = HTTP::Request->new(GET => $apiurl);
    my $useragent = LWP::UserAgent->new;
    my $response = $useragent->request($request);
    printf($response->code);
    if ($response->is_success) {
        return @{parse_json($response->decoded_content)};
    }
    else{
        return ();
    }
}

sub buildM3U {
    my @senderliste = @_;
    my $m3u = "#EXTM3U\n";
    for my $sender( @senderliste ) {
        if($sender->{number} > 0) {
            $m3u = $m3u."#EXTINF:-1 tvg-chno=\"".$sender->{number}."\" tvg-id=\"".uri_escape($sender->{name})."\" tvg-name=\"".$sender->{name}."\" tvg-logo=\"".$sender->{logo}->{path}."\" group-title=\"PlutoTV\",".$sender->{name}."\n";
            $m3u = $m3u."http://$hostip:$port/channel?id=".$sender->{_id}."\n";
        }
    }
    return $m3u;
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

    if($request->uri->path eq "/playlist") {
        my @senderListe = get_channel_json;
        if(scalar @senderListe <= 0) {
            $client->send_error(RC_INTERNAL_SERVER_ERROR, "Unable to fetch channel-list from pluto.tv-api.");
            return;
        }
        my $m3uContent = buildM3U(@senderListe);
        my $response = HTTP::Response->new();
        $response->header("content-disposition", "filename=\"plutotv.m3u\"");
        $response->code(200);
        $response->message("OK");
        $response->content($m3uContent);

        $client->send_response($response);
    }
    elsif($request->uri->path eq "/channel") {
        my $parse_params = HTTP::Request::Params->new({
            req => $request,
        });
        my $params = $parse_params->params;
        my $channelid = $params->{'id'};

        my $response = HTTP::Response->parse("This is channel-response with id $channelid." );

        $client->send_response($response);
    }
    else {
        $client->send_error(RC_NOT_FOUND, "No such path available: ".$request->uri->path);
    }
}

# START DAEMON
my $deamon = HTTP::Daemon->new(
    LocalAddr => $hostip,
    LocalPort => $port,
    Reuse => 1,
    ReuseAddr => 1,
    ReusePort => $port,
) or die "Server could not be started.\n\n";

while (1) {
    process_request($deamon);
}