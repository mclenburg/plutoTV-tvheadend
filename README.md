# plutoTV-tvheadend
Perl-Script to generate m3u and xmltv-epg from PlutoTV-API for seamless tvheadend integration.   
Provides direct HLS streams without external dependencies for optimal tvheadend compatibility.

There are two ways to use these scripts:
* you can generate a static m3u8 by using the `plutotv-generate.pl`-script with params
* you can start `plutotv-localserver.pl` as local HTTP-Server and call it via URLs

**For tvheadend integration, use `plutotv-localserver.pl` to ensure that the channel list (m3u8) and EPG data are always up-to-date.**

## Prerequisites

### Required Perl modules
```bash
sudo cpan install DateTime JSON::XS LWP::UserAgent UUID::Tiny File::Which Try::Tiny Time::HiRes
sudo cpan install HTTP::Request::Params HTTP::Status URI URI::Escape Net::Address::IP::Local 
sudo cpan install Getopt::Long POSIX Fcntl MIME::Base64 IO::Socket::INET IO::Select
```

### Optional external tools
- **ffmpeg** (only needed if using legacy pipe mode with `--usestreamlink=0`)
- **streamlink** (only needed if using `--usestreamlink` option)

**Note**: For tvheadend integration, external tools are **not required** as direct HLS streams are used.

## Usage

### Static generation
`perl plutotv-generate.pl [--createm3u] [--usebash] [--useffmpeg | --usestreamlink]`

### Local server (recommended for tvheadend)
`perl plutotv-localserver.pl [OPTIONS]`

### Command line options for plutotv-localserver.pl

| Parameter | Effect |  
|---|---|  
| `-l, --localonly` | Bind server to localhost (127.0.0.1) only |
| `-p, --port <number>` | Set listening port (default: 9000) | 
| `-r, --region <REGION>` | Set region: DE, US, UK, FR, IT (default: DE) |
| `-s, --usestreamlink` | Use streamlink for legacy pipe mode (not recommended for tvheadend) |
| `-d, --debug` | Enable debug logging |
| `-h, --help` | Show help message with all available regions |

### Available endpoints

| Endpoint | Purpose | tvheadend Usage |
|---|---|---|
| `/` | Help and setup instructions | - |
| `/tvheadend` | **M3U8 playlist optimized for tvheadend** | **Use this for M3U URL** |
| `/epg` | **XMLTV EPG file (tvheadend compatible)** | **Use this for EPG URL** |
| `/stream/{id}.m3u8` | Direct HLS stream for channel ID | Auto-generated in tvheadend playlist |
| `/status` | Server status and configuration | Monitoring |
| `/channels` | Channel list in JSON format | API access |
| `/search?q=query` | Search channels by name | API access |
| `/categories` | List of channel categories | API access |
| `/playlist` | Legacy M3U8 with pipe commands | Legacy support |
| `/master3u8?id=` | Master playlist for channel ID | Internal use |
| `/epg?channel_id=ID` | EPG for specific channel | Selective EPG |

## tvheadend Integration Guide

### Step-by-Step Setup

1. **Start the PlutoTV proxy server:**
   ```bash
   perl plutotv-localserver.pl --region DE --port 9000
   ```

2. **Add IPTV Network in tvheadend:**
    - Go to: **Configuration → DVB Inputs → Networks**
    - Click **Add** → **IPTV Automatic Network**
    - Configure as follows:

   | Setting | Value |
      |---|---|
   | **Network name** | PlutoTV DE |
   | **M3U URL** | `http://your-server-ip:9000/tvheadend` |
   | **EPG URL** | `http://your-server-ip:9000/epg` |
   | **Channel name in stream** | ✅ Enabled |
   | **Scan after creation** | ✅ Enabled |
   | **Channel number from stream** | ✅ Enabled |
   | **Update interval (minutes)** | 60 |

3. **Configure EPG:**
    - Go to: **Configuration → Channel/EPG → EPG Grabber**
    - Enable **External: XMLTV**
    - Set update interval: **30-60 minutes**

4. **Map services:**
    - Go to: **Configuration → Channel/EPG → Channels → Map Services**
    - Click **Map all services** to automatically map channels

### Advanced tvheadend Configuration

#### Multiple Regions
You can run multiple instances for different regions:

```bash
# Germany
perl plutotv-localserver.pl --region DE --port 9000 &

# US
perl plutotv-localserver.pl --region US --port 9001 &

# UK  
perl plutotv-localserver.pl --region UK --port 9002 &
```

Then add separate IPTV networks for each region.

#### Systemd Service
Create `/etc/systemd/system/plutotv-proxy.service`:

```ini
[Unit]
Description=PlutoTV Proxy Server
After=network.target

[Service]
Type=simple
User=tvheadend
WorkingDirectory=/opt/plutotv-proxy
ExecStart=/usr/bin/perl plutotv-localserver.pl --region DE --port 9000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl enable plutotv-proxy
sudo systemctl start plutotv-proxy
```

## Automatic EPG Updates

PlutoTV provides EPG data up to 48 hours in advance. The proxy automatically caches EPG data for 30 minutes to reduce API load.

### Manual EPG refresh (if needed)
```bash
# Download current EPG
wget http://localhost:9000/epg -O plutotv-epg.xml

# Import to tvheadend (if using external import)
cat plutotv-epg.xml | socat - UNIX-CONNECT:/var/lib/hts/.hts/tvheadend/epggrab/xmltv.sock
```

## Supported Regions

| Region | Code | Country |
|---|---|---|
| Germany | DE | Deutschland |
| United States | US | United States |
| United Kingdom | UK | United Kingdom |
| France | FR | France |
| Italy | IT | Italy |

## Troubleshooting

### Common Issues

1. **Channels not loading in tvheadend:**
    - Check if proxy server is running: `http://your-server:9000/status`
    - Verify M3U URL returns channel list: `http://your-server:9000/tvheadend`
    - Check tvheadend logs for network errors

2. **EPG not updating:**
    - Verify EPG URL returns data: `http://your-server:9000/epg`
    - Check EPG grabber configuration in tvheadend
    - Ensure channel IDs match between M3U and EPG

3. **Streams not playing:**
    - Verify direct stream access: `http://your-server:9000/stream/CHANNEL_ID.m3u8`
    - Check network connectivity to PlutoTV CDN
    - Review proxy server logs with `--debug` option

### Debug Mode
Run with debug logging for troubleshooting:
```bash
perl plutotv-localserver.pl --debug --region DE
```

## Performance Notes

- **Direct HLS**: No transcoding overhead, minimal CPU usage
- **Automatic caching**: Channel lists cached for 15 minutes, EPG for 30 minutes
- **Connection pooling**: Efficient HTTP client with keep-alive
- **Concurrent handling**: Fork-based request processing

## License & Disclaimer

This tool is for educational and personal use only. Respect PlutoTV's terms of service and applicable laws in your jurisdiction.