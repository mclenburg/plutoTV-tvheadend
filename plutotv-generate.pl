#!/usr/bin/perl

use strict;
use warnings;

use DateTime;
use DateTime::Format::Strptime qw(strptime);
use JSON;
use JSON::Parse ':all';
use HTTP::Request ();
use LWP::UserAgent;
use URI::Escape;
use UUID::Tiny ':std';
use Cwd qw(cwd);

package main;

my $from = DateTime->now();
my $to = DateTime->now();
$to=$to->add(days => 10);

printf("From %sZ To %sZ\n", $from, $to);

my $url = "http://api.pluto.tv/v2/channels?start=".$from."Z&stop=".$to."Z";
#printf($url . "\n");
my $request = HTTP::Request->new(GET => $url);
my $useragent = LWP::UserAgent->new;
my $response = $useragent->request($request);
my $withm3u = grep { $_ eq '--createm3u'} @ARGV;
# my $withgivenurl = grep { $_ eq '--usegivenurl'} @ARGV;
my $useffmpeg = grep { $_ eq '--useffmpeg'} @ARGV;
my $usebash = grep { $_ eq '--usebash'} @ARGV;
my $jalle19 = grep { $_ eq '--usejalle19proxy'} @ARGV;  # https://github.com/Jalle19/node-ffmpeg-mpegts-proxy
my $regionCode = "DE";  # may overwritten by stitched URL
my $langcode ="de";
my $jalleHost = "localhost:8282";

if ($response->is_success) {
    my $epgfile = 'plutotv-epg.xml';
    my $m3ufile = 'plutotv.m3u';
    my $sourcesfile = 'sources.json';
    open(my $fh, '>', $epgfile) or die "Could not open file '$epgfile' $!";
    my $fhm;
    if( $withm3u or $jalle19) {
      open($fhm, '>', $m3ufile) or die "Could not open file '$m3ufile' $!";
    }
    my $fhj;
    if( $jalle19 ) {
      open($fhj, '>', $sourcesfile) or die "Could not open file '$sourcesfile' $!";
      print $fhj "[\n";
    }
    
    print $fh "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
    print $fh "<tv>\n";  

    if( $withm3u or $jalle19 ) {
      print $fhm "#EXTM3U\n";  
    }

    my $pre = "";
#    my $uuid = uuid_to_string(create_uuid(UUID_V1));
    my @senderListe = @{parse_json($response->decoded_content)};
    for my $sender( @senderListe ) {
      if($sender->{number} > 0) { 
        my $sendername = $sender->{name};
        my $url = $sender->{stitched}->{urls}[0]->{url};
        $url =~ s/&deviceMake=/&deviceMake=Chrome/ig;
        $url =~ s/&deviceType=/&deviceType=web/ig;
        $url =~ s/&deviceModel=/&deviceModel=Chrome/ig;
        $url =~ s/&sid=/&sid=\{uuid\}/ig;
#        $uuid = uuid_to_string(create_uuid(UUID_V1));
        my $regionStart = index($url, "marketingRegion=")+16;
        my $regionEnds = index($url, "&", index($url, "marketingRegion=")+16);
        if($regionStart>0) {
          $regionCode = substr($url, $regionStart, $regionEnds-$regionStart); 
        }
        print $fh "<channel id=\"".uri_escape($sendername)."\">\n";
        print $fh "<display-name lang=\"$langcode\"><![CDATA[".$sender->{name}."]]></display-name>\n" ;
        my $logo = $sender->{logo};
        $logo->{path} = substr($logo->{path}, 0, index($logo->{path}, "?"));
        print $fh "<icon src=\"".$logo->{path}."\" />\n";
        print $fh "</channel>\n";
      
	      if( $withm3u or $jalle19 ) {
		        print $fhm "#EXTINF:-1 tvg-chno=\"".$sender->{number}."\" tvg-id=\"".uri_escape($sendername)."\" tvg-name=\"".$sender->{name}."\" tvg-logo=\"".$logo->{path}."\" group-title=\"PlutoTV\",".$sender->{name}."\n";
                
                if($useffmpeg) {
                  print $fhm "pipe:///usr/bin/ffmpeg -i \"".$url."\" -vcodec copy -acodec copy -f mpegts -tune zerolatency -metadata service_name=\"".$sender->{name}."\" pipe:1\n";
                }
                elsif( $jalle19 ) {
                  print $fhj "\t".$pre."{\n\t\t\"name\": \"".$sender->{name}."\",\n";
                  print $fhj "\t\t\"provider\": \"PlutoTV\",\n";
                  print $fhj "\t\t\"url\": \"/".$sender->{_id}."\",\n";
                  print $fhj "\t\t\"source\": \"http://service-stitcher.clusters.pluto.tv/stitch/hls/channel/".$sender->{_id}."/master.m3u8?deviceType=web&deviceMake=web&deviceModel=web&sid=".$sender->{number}."&deviceId=".$sender->{_id}."&deviceVersion=DNT&appVersion=DNT&deviceDNT=0&userId=&advertisingId=&deviceLat=&deviceLon=&app_name=&appName=web&buildVersion=&appStoreUrl=&architecture=&includeExtendedEvents=false&marketingRegion=$regionCode&serverSideAds=true\"\n";
                  print $fhj "\t}\n";
                  print $fhm "http://$jalleHost/".$sender->{_id}."\n";
                  $pre = ",";
                }
                elsif ( $usebash ) {
                  my $path= cwd;
                  print $fhm "pipe://".$path."/".$sender->{_id}.".sh\n";
                  open(my $fhb, '>', $sender->{_id}.".sh") or die "Could not open file";
                  print $fhb "#!/bin/bash\n";
                  print $fhb "#\n\n";
                  print $fhb "url=\"".$url."\"\n";
                  print $fhb "uuid=\$(uuidgen)\n";
                  print $fhb "repurl=\${url/\\{uuid\\}/\$uuid}\n";
                  print $fhb "/usr/bin/ffmpeg -loglevel fatal -user-agent \"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/71.0.3554.0 Safari/537.36\" -i \$repurl  -vcodec copy -acodec copy -f mpegts -tune zerolatency -preset normal -metadata service_name='' pipe:1\n";
                  close $fhb;
                  chmod 0777, $sender->{_id}.".sh";
                }
                else {	
		          print $fhm $url."\n";
                }
	      }
      }
    }

    for my $sender( @senderListe ) {
      if($sender->{number} > 0) {
              my $sendername = $sender->{name};
	      for my $sendung ( @{$sender->{timelines}}) {
		my $start = $sendung->{start};
		$start =~ s/[-:Z\.T]//ig;
		#$start = substr($start, 0, 14);

		my $stop = $sendung->{stop};
		$stop =~ s/[-:Z\.T]//ig;
		$stop = substr($stop, 0, 14);
		print $fh "<programme start=\"".$start." +0000\" stop=\"".$stop." +0000\" channel=\"".uri_escape($sendername)."\">\n";
		my $episode = $sendung->{episode};
		print $fh "<title lang=\"$langcode\"><![CDATA[".$sendung->{title}." - ".$episode->{rating}."]]></title>\n";
		
		print $fh "<desc lang=\"$langcode\"><![CDATA[".$episode->{description}."]]></desc>\n";
		print $fh "</programme>\n";
	      }
	    }
    }
  print $fh "\n</tv>\n\n\n";
  close $fh;
  if( $withm3u or $jalle19) {
    close $fhm;
  }
  if( $jalle19 ) {
    print $fhj "]";
    close $fhj;
  }
  print "Ready\n";
}
else {
    print STDERR $response->status_line, "\n";
}


