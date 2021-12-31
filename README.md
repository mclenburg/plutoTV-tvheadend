# plutoTV-tvheadend
Perl-Script to generate m3u and xmltv-epg from PlutoTV-API.  
So far, there are still short interruptions when advertising starts or ends.  
This is due to an [issue in ffmpeg](https://trac.ffmpeg.org/ticket/5419).    
   
There are two ways to use these scripts:
* you can generate a static m3u8 by using the `plutotv-generate.pl`-script with params 
* you can start `plutotv-localserver.pl` as local HTTP-Server and call it via URLs


## install used modules
`sudo cpan install DateTime DateTime::Format::Strptime JSON JSON:Parse HTTP::Request URI::Escape LWP::UserAgent UUID::Tiny File::Which`

when using `plutotv-localserver.pl` also:
`sudo cpan install HTTP::Request::Params HTTP::Daemon HTTP::Status HTTP::Request::Common HTTP::Cookies Net::Address::IP::Local`


## usage
`perl plutotv-generate.pl [--createm3u] [--usebash] [--useffmpeg | --usestreamlink]`

### or
`perl plutotv-localserver.pl [--localonly] [--port <portnumber>]` (or start as systemd-daemon)

### meaning of params

#### plutotv-generate.pl

| parameter | effect |  
|---|---|  
| `--createm3u` | create playlist-file plutotv.m3u8 and xmltv-file plutotv-epg.xml |
| `--usebash` | create bash-file for each pluto-tv-channel for starting service |
| `--useffmpeg` | will use ffmpeg-pipe instead of using original URL to channel |
| `--usestreamlink` | same as `--useffmpeg`, but using `streamlink` instead of ffmpeg |

#### plutotv-localserver.pl  

|parameter | effect |
|---|---|
| `--localonly` | will configure server to listen on localhost 127.0.0.1 |
| `--port <number>` | set listening-port for server (default: 9000) | 

### available endpoints for localserver
|endpoint | task |
|---|---|
|`/playlist`|path to get m3u8-file|
|`/master3u8?id=`|path to get playlist.m3u8 for given channelid|
|`/channel?id=`|path to get ts via ffmpeg or streamlink for given channelid|
|`/epg`|path to get xmltv-epg-file|

## how to load xmltv-guide into tvheadend
* Go to menu option "Configuration" > "Channel/EPG" > "EPG Grabber Modules" and enable "External: XMLTV"
* Go to menu option "Configuration" > "Channel/EPG" > "Channel" > "Map services" > "Map all services" and map the services
* Run the following command twice:

`cat plutotv-epg.xml | socat - UNIX-CONNECT:/var/lib/hts/.hts/tvheadend/epggrab/xmltv.sock`


## more
PlutoTV only delivers timelines 6h in future. So epg has to be fetched at least every 6 hours:
crontab:
`15 */6 * * * perl plutotv-generate.pl`

or

`15 */6 * * * wget http://localhost:9000/epg -O plutotv-epg.xml`

