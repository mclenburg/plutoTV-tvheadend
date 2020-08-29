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
use File::Which;

package main;

my $langcode ="de";
my $jalleHost = "localhost:8282";

my $from = DateTime->now();
my $to = DateTime->now();
$to=$to->add(days => 10);

my $programpath= cwd;
my $ffmpeg = which 'ffmpeg';
my $streamlink = which 'streamlink';

sub create_bashfile {
    my $bash = which 'bash';
    open(my $fhb, '>', $_[0]->{_id}.".sh") or die "Could not open file";
    print $fhb "#!$bash\n";
    print $fhb "#\n\n";
    print $fhb "url=\"".$_[1]."\"\n";
    print $fhb "uuid=\$(uuidgen)\n";
    print $fhb "#uuid=$_[2]\n";
    print $fhb "repurl=\${url/\\{uuid\\}/\$uuid}\n";
    print $fhb "while :\n";
    print $fhb "do\n";

    if(! defined $streamlink) {
        print $fhb $ffmpeg." -loglevel fatal -copytb 1 -threads 2 -re -fflags +genpts+ignidx -user-agent \"Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:76.0) Gecko/20100101 Firefox/76.0\" -i \$repurl  -vcodec copy -acodec copy -f mpegts -tune zerolatency -preset ultrafast -metadata service_name='".$_[0]->{name}."' pipe:1\n";
    }
    else {
        print $fhb "$streamlink --stdout --quiet --twitch-disable-hosting --ringbuffer-size 8M --hds-segment-threads 2 \"\$repurl\" 720,best \n";
    }
    print $fhb "done\n";
    close $fhb;
    chmod 0777, $_[0]->{_id}.".sh";
}

printf("From %sZ To %sZ\n", $from, $to);

my $url = "http://api.pluto.tv/v2/channels?start=".$from."Z&stop=".$to."Z";
#printf($url . "\n");
my $request = HTTP::Request->new(GET => $url);
my $useragent = LWP::UserAgent->new;
my $response = $useragent->request($request);
my $withm3u = grep { $_ eq '--createm3u'} @ARGV;
my $useffmpeg = grep { $_ eq '--useffmpeg'} @ARGV;
my $usebash = grep { $_ eq '--usebash'} @ARGV;
my $jalle19 = grep { $_ eq '--usejalle19proxy'} @ARGV;  # https://github.com/Jalle19/node-ffmpeg-mpegts-proxy

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
    my $uuid = uuid_to_string(create_uuid(UUID_V1));
    my @senderListe = @{parse_json($response->decoded_content)};
    for my $sender( @senderListe ) {
      if($sender->{number} > 0) { 
        my $sendername = $sender->{name};
        my $url = $sender->{stitched}->{urls}[0]->{url};
        $url =~ s/&deviceMake=/&deviceMake=Chrome/ig;
        $url =~ s/&deviceType=/&deviceType=web/ig;
        $url =~ s/&deviceModel=/&deviceModel=Chrome/ig;
        $url =~ s/&sid=/&sid=\{uuid\}/ig;
        $uuid = uuid_to_string(create_uuid(UUID_V1));

        print $fh "<channel id=\"".uri_escape($sendername)."\">\n";
        print $fh "<display-name lang=\"$langcode\"><![CDATA[".$sender->{name}."]]></display-name>\n" ;
        my $logo = $sender->{logo};
        $logo->{path} = substr($logo->{path}, 0, index($logo->{path}, "?"));
        print $fh "<icon src=\"".$logo->{path}."\" />\n";
        print $fh "</channel>\n";
      
	      if( $withm3u or $jalle19 ) {
                $url =~ s/{uuid}/$uuid/ig;
		        print $fhm "#EXTINF:-1 tvg-chno=\"".$sender->{number}."\" tvg-id=\"".uri_escape($sendername)."\" tvg-name=\"".$sender->{name}."\" tvg-logo=\"".$logo->{path}."\" group-title=\"PlutoTV\",".$sender->{name}."\n";
                
                if($useffmpeg) {
                  print $fhm "pipe://".$ffmpeg." -loglevel fatal -threads 2 -re -fflags +genpts+ignidx+igndts -user-agent \"Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:76.0) Gecko/20100101 Firefox/76.0\" -i \"".$url."\" -vcodec copy -acodec copy -f mpegts -tune zerolatency -metadata service_name=\"".$sender->{name}."\" pipe:1\n";
                }
                elsif( $jalle19 ) {
                  print $fhj "\t".$pre."{\n\t\t\"name\": \"".$sender->{name}."\",\n";
                  print $fhj "\t\t\"provider\": \"PlutoTV\",\n";
                  print $fhj "\t\t\"url\": \"/".$sender->{_id}."\",\n";
                  print $fhj "\t\t\"source\": \"$url\"\n";
                  print $fhj "\t}\n";
                  print $fhm "http://$jalleHost/".$sender->{_id}."\n";
                  $pre = ",";
                }
                elsif ( $usebash ) {
                  create_bashfile ($sender, $url, $uuid);
                  print $fhm "pipe://".$programpath."/".$sender->{_id}.".sh \n";
                }
                else {	
		          print $fhm $url."\n";
                }
	      }
          if( $usebash and !$withm3u) {
              create_bashfile( $sender, $url, $uuid);
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


