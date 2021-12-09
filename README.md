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
`sudo cpan install HTTP::Request::Params HTTP::Deamon HTTP::Status HTTP::Requst::Common HTTP::Cookies Net::Address::IP::Local`


## usage
`perl plutotv-generate.pl [--createm3u] [--usebash] [--useffmpeg | --usestreamlink]`

### or
`perl plutotv-localserver.pl [--usestreamlink] [--localonly] [--directstreaming]` (or start as systemd-daemon)

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

or using pluto-localserver.pl

`curl http://127.0.0.1:9120/epg | socat - UNIX-CONNECT:/var/lib/hts/.hts/tvheadend/epggrab/xmltv.sock`

## how to Add localserver to Tvheadend
Go to Configuration -> DVB-Inputs -> Networks
Add a new IPTV-Automatic Network, settings see below

![alt_text](https://https://github.com/phil2sat/plutoTV-tvheadend/edit/master/tvheadend.png?raw=true)


## more
PlutoTV only delivers timelines 6h in future. So epg has to be fetched at least every 6 hours:
crontab:

`15 */6 * * * perl plutotv-generate.pl`

or to push the changes directly to Tvheadend

`15 */6 * * * curl http://127.0.0.1:9120/epg | socat - UNIX-CONNECT:/var/lib/hts/.hts/tvheadend/epggrab/xmltv.sock`
