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

$| = 1;

my $langcode ="de";
my $jalleHost = "localhost:8282";

my $from = DateTime->now();
my $to = DateTime->now();
$to=$to->add(days => 10);

my $programpath= cwd;
my $ffmpeg = which 'ffmpeg';
my $streamlink = which 'streamlink';

#switches for params
my $createm3u = grep { $_ eq '--createm3u'} @ARGV;
my $useffmpeg = grep { $_ eq '--useffmpeg'} @ARGV;
my $usebash = grep { $_ eq '--usebash'} @ARGV;
my $jalle19 = grep { $_ eq '--usejalle19proxy'} @ARGV;  # https://github.com/Jalle19/node-ffmpeg-mpegts-proxy
my $usestreamlink = grep { $_ eq '--usestreamlink'} @ARGV;

sub create_bashfile {
    my $bash = which 'bash';

    open(my $fhb, '>', $_[3].".sh") or die "Could not open file $_[3]";
    print $fhb "#!$bash\n";
    print $fhb "#\n\n";
    print $fhb "url=\"".$_[1]."\"\n";
    print $fhb "uuid=\$(uuidgen)\n";
    print $fhb "deviceid=\"$_[2]\"\n";
    #print $fhb "#uuid=$_[2]\n";
    print $fhb "repurl=\${url/\\{uuid\\}/\$uuid}\n";
    print $fhb "repurl=\${repurl/\\{deviceid\\}/\$deviceid}\n";
    print $fhb "while :\n";
    print $fhb "do\n";

    if(!defined($streamlink) or $useffmpeg) {
        print $fhb $ffmpeg." -loglevel fatal -copytb 1 -threads 2 -re -fflags +genpts+ignidx -vsync cfr -dts_delta_threshold 30 -err_detect ignore_err -user-agent \"Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:82.0) Gecko/20100101 Firefox/76.0\" -i \$repurl  -vcodec copy -acodec copy -f mpegts -tune zerolatency -preset ultrafast -metadata service_name='".$_[0]->{name}."' pipe:1\n";
    }
    else {
        print $fhb "$streamlink --stdout --quiet --hls-live-restart --hds-segment-threads 2 \"\$repurl\" 720,best  | $ffmpeg -loglevel quiet -i pipe:0 -err_detect ignore_err -dts_delta_threshold 30 -vsync cfr -vcodec copy -acodec copy -mpegts_service_type advanced_codec_digital_hdtv -f mpegts pipe:1 \n";
    }
    print $fhb "done\n";
    close $fhb;
    chmod 0777, $_[3].".sh";
}

printf("From %sZ To %sZ\n", $from, $to);

my $url = "http://api.pluto.tv/v2/channels?start=".$from."Z&stop=".$to."Z";
#printf($url . "\n");
my $request = HTTP::Request->new(GET => $url);
my $useragent = LWP::UserAgent->new;
my $response = $useragent->request($request);

#validate params
if($usestreamlink and !defined($streamlink)) {
    printf("WARNING: Usage of streamlink requested, but no streamlink found on system. Will use ffmpeg instead.\n");
    $useffmpeg = 1;
    $usestreamlink = 0;
}
if($useffmpeg and !defined($ffmpeg)) {
    printf("WARNING: Usage of ffmpeg requested, but no ffmpeg found on system. Will use raw-URL instead.\n");
    $useffmpeg = 0;
}
if($useffmpeg and $usestreamlink) {
    if($usebash) {
        printf("WARNING: Invalid combined usage of params useffmpeg and usestreamlink. Will use ffmpeg as default.\n");
        $usestreamlink = 0;
    }
    else {
        printf("WARNING: Invalid combined usage of params useffmpeg and usestreamlink. Will use default raw-URL.\n");
        $useffmpeg = 0;
        $usestreamlink = 0;
    }
}

if ($response->is_success) {
    my $epgfile = 'plutotv-epg.xml';
    my $m3ufile = 'plutotv.m3u';
    my $sourcesfile = 'sources.json';
    open(my $fh, '>', $epgfile) or die "Could not open file '$epgfile' $!";
    my $fhm;
    if( $createm3u or $jalle19) {
      open($fhm, '>', $m3ufile) or die "Could not open file '$m3ufile' $!";
    }
    my $fhj;
    if( $jalle19 ) {
      open($fhj, '>', $sourcesfile) or die "Could not open file '$sourcesfile' $!";
      print $fhj "[\n";
    }
    
    print $fh "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
    print $fh "<tv>\n";  

    if( $createm3u or $jalle19 ) {
      print $fhm "#EXTM3U\n";  
    }

    my $pre = "";
    my $uuid = uuid_to_string(create_uuid(UUID_V1));
    my @senderListe = @{parse_json($response->decoded_content)};
    for my $sender( @senderListe ) {
      if($sender->{number} > 0) { 
        my $sendername = $sender->{name};
        my $url = undef;
        $url = $sender->{stitched}->{urls}[0]->{url};
        if(!defined $url) {
          printf("WARNING: no url found for $sendername\n");
          next;
        }

        $url =~ s/&deviceMake=/&deviceMake=Firefox/ig;
        $url =~ s/&deviceType=/&deviceType=web/ig;
        $url =~ s/&deviceId=unknown/&deviceId=\{deviceid\}/ig;
        $url =~ s/&deviceModel=/&deviceModel=Firefox/ig;
        $url =~ s/&deviceVersion=unknown/&deviceVersion=82\.0/ig;
        $url =~ s/&appName=&/&appName=web&/ig;
        $url =~ s/&appVersion=&/&appVersion=5.9.1-e0b37ef76504d23c6bdc8157813d13333dfa33a3&/ig;
        $url =~ s/&sid=/&sid=\{uuid\}/ig;
        $url = $url."&serverSideAds=true&paln=";
        $uuid = uuid_to_string(create_uuid(UUID_V1));
        my $deviceid = uuid_to_string(create_uuid(UUID_V1));

        print $fh "<channel id=\"".uri_escape($sendername)."\">\n";
        print $fh "<display-name lang=\"$langcode\"><![CDATA[".$sender->{name}."]]></display-name>\n" ;
        my $logo = $sender->{logo};
        $logo->{path} = substr($logo->{path}, 0, index($logo->{path}, "?"));
        print $fh "<icon src=\"".$logo->{path}."\" />\n";
        print $fh "</channel>\n";
      
	      if( $createm3u or $jalle19 ) {
                $url =~ s/{uuid}/$uuid/ig;
                $url =~ s/{deviceid}/$deviceid/ig;
		        print $fhm "#EXTINF:-1 tvg-chno=\"".$sender->{number}."\" tvg-id=\"".uri_escape($sendername)."\" tvg-name=\"".$sender->{name}."\" tvg-logo=\"".$logo->{path}."\" group-title=\"PlutoTV\",".$sender->{name}."\n";
                
                if(($useffmpeg or $usestreamlink) and !$usebash) {
                    if(!defined($streamlink) or $useffmpeg) {
                        print $fhm "pipe://".$ffmpeg." -loglevel fatal -threads 2 -re -fflags +genpts+ignidx+igndts -user-agent \"Mozilla/5.0 (X11; Ubuntu; Linux i686; rv:76.0) Gecko/20100101 Firefox/76.0\" -i \"".$url."\" -vcodec copy -acodec copy -f mpegts -tune zerolatency -metadata service_name=\"".$sender->{name}."\" pipe:1\n";
                    }
                    else {
                        print $fhm "pipe://".$streamlink." --stdout --quiet --twitch-disable-hosting --ringbuffer-size 8M --hds-segment-threads 2 \"".$url."\" 720,best \n";
                    }
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
                  my $filename = $sender->{name};
                  $filename=~s/ /_/ig;
                  $filename=~s/\'//ig;
                  $filename=~s/\//_/ig;
                    $filename=~s/\(//ig;
                    $filename=~s/\)//ig;
                  create_bashfile ($sender, $url, $deviceid, $filename);
                  print $fhm "pipe://".$programpath."/".$filename.".sh \n";
                }
                else {	
		          print $fhm $url."\n";
                }
	      }
          if( $usebash and !$createm3u) {
              my $filename = $sender->{name};
              $filename=~s/ /_/ig;
              $filename=~s/\'//ig;
              $filename=~s/\//_/ig;
              $filename=~s/\(//ig;
              $filename=~s/\)//ig;
              create_bashfile( $sender, $url, $deviceid, $filename);
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
  if( $createm3u or $jalle19) {
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


