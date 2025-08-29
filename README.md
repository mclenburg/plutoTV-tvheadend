# plutoTV-tvheadend
Perl-Script to generate m3u and xmltv-epg from PlutoTV-API.   
Now with enhanced tvheadend support and direct HLS streaming capabilities.

There are two ways to use these scripts:
* you can generate a static m3u8 by using the `plutotv-generate.pl`-script with params
* you can start `plutotv-localserver.pl` as local HTTP-Server and call it via URLs

I recommend using `plutotv-localserver.pl` to ensure that the channel list (m3u8) is always up-to-date.

## install used modules
```bash
sudo cpan install DateTime DateTime::Format::Strptime JSON JSON:Parse HTTP::Request URI::Escape LWP::UserAgent UUID::Tiny File::Which
```

when using `plutotv-localserver.pl` also:
```bash
sudo cpan install HTTP::Request::Params HTTP::Daemon HTTP::Status Net::Address::IP::Local Getopt::Long Try::Tiny Encode Crypt::CBC IPC::Run;
```

## usage
`perl plutotv-generate.pl [--createm3u] [--usebash] [--useffmpeg | --usestreamlink]`

### or
`perl plutotv-localserver.pl [--localonly] [--port <portnumber>] [--usestreamlink]` (or start as systemd-daemon)

### meaning of params

#### plutotv-generate.pl

| parameter | effect |  
|---|---|  
| `--createm3u` | create playlist-file plutotv.m3u8 and xmltv-file plutotv-epg.xml |
| `--usebash` | create bash-file for each pluto-tv-channel for starting service |
| `--useffmpeg` | will use ffmpeg-pipe instead of using original URL to channel |
| `--usestreamlink` | same as `--useffmpeg`, but using `streamlink` instead of ffmpeg |

#### plutotv-localserver.pl

|parameter | effect                                                   |
|---|----------------------------------------------------------|
| `--localonly` | will configure server to listen on localhost 127.0.0.1   |
| `--port <number>` | set listening-port for server (default: 9000)            | 
| `--usestreamlink` | provide playlist with call for streamlink instead ffmpeg |

### available endpoints for localserver
|endpoint | task |
|---|---|
|`/playlist` or `/playlist?region=REGION`|path to get m3u8-file with ffmpeg/streamlink pipes (legacy)|
|`/tvheadend` or `/tvheadend?region=REGION`|**RECOMMENDED:** optimized m3u8 for tvheadend with direct HLS streams|
|`/stream/{id}.m3u8`|**NEW:** direct HLS stream for individual channel with real-time decryption|
|`/epg`|path to get xmltv-epg-file|
|`/` or `/help`|shows available endpoints and regions|

### supported regions
Both `/playlist` and `/tvheadend` endpoints support region selection via URL parameter:

|Region Code | Location | Coordinates |
|---|---|---|
|`DE` (default) | Berlin, Deutschland | 52.5200, 13.4050 |
|`US` | New York, United States | 40.7128, -74.0060 |
|`UK` | London, United Kingdom | 51.5074, -0.1278 |
|`FR` | Paris, France | 48.8566, 2.3522 |
|`IT` | Rome, Italy | 41.9028, 12.4964 |

**Examples:**
- `http://localhost:9000/tvheadend?region=US` - US channels with direct streams
- `http://localhost:9000/playlist?region=UK` - UK channels with pipes
- `http://localhost:9000/stream/5ad8d135e738977e2c312330.m3u8` - direct stream for specific channel
- `http://localhost:9000/tvheadend` - German channels (default)

## tvheadend integration

### recommended setup for tvheadend
1. **Add Network:** IPTV Automatic Network
2. **Set M3U URL:** `http://YOUR_SERVER_IP:9000/tvheadend` (or with `?region=REGION`)
3. **Set EPG URL:** `http://YOUR_SERVER_IP:9000/epg`
4. **Enable:** "Scan after creation" and "Channel name in stream"
5. **Set EPG update interval:** 30-60 minutes

### advantages of /tvheadend endpoint
- **Direct HLS streams** - no ffmpeg pipes needed, better performance
- **Real-time decryption** - handles encrypted segments automatically
- **Optimized for tvheadend** - better compatibility and stability
- **Ad-blocking parameters** - reduced stream interruptions from ads
- **Regional content** - access different PlutoTV regions
- **Discontinuity handling** - automatically skips problematic segments

### legacy support
The original `/playlist` endpoint remains available for backward compatibility and still uses ffmpeg/streamlink pipes as before.

## stream technology

### direct HLS streaming (/stream/ endpoints)
- **AES-128 decryption** - automatic decryption of encrypted segments using OpenSSL or Crypt::CBC
- **Discontinuity handling** - skips segments that cause stream interruptions
- **Dynamic playlists** - creates optimized playlists for continuous streaming
- **Session management** - tracks multiple concurrent streams efficiently
- **Segment filtering** - prevents duplicate segment processing

### anti-advertisement features
The server includes several parameters to minimize ad-related stream issues:
- `serverSideAds=false` - disables server-side ad insertion
- `DNT=1` - enables "Do Not Track"
- `includeExtendedEvents=false` - disables extended ad events
- Automatic discontinuity segment skipping

## how to load xmltv-guide into tvheadend
* Go to menu option "Configuration" > "Channel/EPG" > "EPG Grabber Modules" and enable "External: XMLTV"
* Go to menu option "Configuration" > "Channel/EPG" > "Channel" > "Map services" > "Map all services" and map the services
* Run the following command twice:

```bash
cat plutotv-epg.xml | socat - UNIX-CONNECT:/var/lib/hts/.hts/tvheadend/epggrab/xmltv.sock
```

## automated updates
PlutoTV only delivers timelines 6h in future. So epg has to be fetched at least every 6 hours:

**crontab for static files:**
```cron
15 */6 * * * perl plutotv-generate.pl
```

**crontab for server mode:**
```cron
15 */6 * * * wget http://localhost:9000/epg -O plutotv-epg.xml
```

## requirements
- **Perl 5.10+** with required modules
- **OpenSSL** (recommended for fast AES decryption) or Crypt::CBC as fallback
- **Internet connection** to PlutoTV API
- **Port 9000** available (or custom port via --port)

## troubleshooting

### streams stop or buffer frequently
- The server automatically handles discontinuities and skips problematic segments
- Direct streams (/tvheadend) perform better than pipe-based streams (/playlist)
- Try different regions which may have different streaming policies
- Check server logs for decryption or segment processing errors

### no channels visible
- Check if the region parameter matches available content
- Verify internet connectivity to PlutoTV API (`curl -s http://api.pluto.tv/v2/channels`)
- Some regions may have limited channel availability
- Check server logs for API response errors

### decryption errors
- Ensure OpenSSL is installed: `which openssl`
- If OpenSSL is not available, Crypt::CBC will be used as fallback
- Check that all required Perl modules are installed

## systemd service example
```ini
[Unit]
Description=PlutoTV Local Server
After=network.target

[Service]
Type=simple
User=plutotv
WorkingDirectory=/opt/plutotv
ExecStart=/usr/bin/perl /opt/plutotv/plutotv-localserver.pl --port 9000
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

## performance notes
- The server uses forking for concurrent request handling
- Stream sessions are tracked individually to prevent conflicts
- Old segment references are automatically cleaned up
- Memory usage scales with number of concurrent streams