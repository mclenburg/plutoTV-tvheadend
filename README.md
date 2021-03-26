# plutoTV-tvheadend
Perl-Script to generate m3u and xmltv-epg from PlutoTV-API.  
So far, there are still short interruptions when advertising starts or ends.  
      
There are two ways to use these scripts:
* you can generate a static m3u by using the `plutotv-generate.pl`-script with params 
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
|parameter | effect |
|-|-|
| `--createm3u` | use with `perl-generate.pl` only, create playlist-file plutotv.m3u and xmltv-file plutotv-epg.xml |
| `--usebash` | use with `perl-generate.pl` only, create bash-file for each pluto-tv-channel for starting service |
| `--useffmpeg` | use with `perl-generate.pl` only, will use ffmpeg-pipe instead of using original URL to channel (default in localserver) |
| `--usestreamlink` | same as `--useffmpeg`, but using `streamlink` instead of ffmpeg |
| `--localonly` | use with `plutotv-localserver` only, will configure server to listen on localhost 127.0.0.1 |
| `--directstreaming` | use with `plutotv-localserver` only, delivers m3u with URL to stream from localserver |

### available endpoints for localserver
|endpoint | task |
|-|-|
|`/playlist`|path to get m3u-file|
|`/channel?id=`|path to get playlist.m3u8 for given channelid|
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

