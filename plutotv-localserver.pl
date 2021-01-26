#!/usr/bin/perl

package server;

use strict;
use warnings;

use HTTP::Daemon;
use HTTP::Status;
use HTTP::Request::Params;
use HTTP::Request::Common;
use HTTP::Cookies;

my $hostip = "127.0.0.1";
my $port   = "9000";

sub process_request {
    my $deamon = shift;
    my $client = $deamon->accept or die("could not get any Client");
    my $request = $client->get_request() or die("could not get Client-Request.");
    $client->autoflush(1);

    my $parse_params = HTTP::Request::Params->new({
        req => $request,
    });
    my $params = $parse_params->params;
    my $channelid = $params->{'channelid'};

    my $url = "";
    for my $param (keys %{$params}) {
        if ($param ne "channelid") {
            $url .= "&" . $param . "=" . $params->{$param};
        }
    }
    $url = substr($url, 1);
    print($url);
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