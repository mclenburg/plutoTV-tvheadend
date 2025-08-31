# plutoTV-tvheadend
Perl-Scripts to generate m3u and xmltv-epg from PlutoTV-API.   
Now with enhanced tvheadend support and direct HLS streaming capabilities.

There are two ways to use these scripts:
* **Static Generation:** Use `plutotv-generate.pl` to create static files
* **Dynamic Server:** Use `plutotv-localserver.pl` as local HTTP-Server with real-time streaming

I recommend using `plutotv-localserver.pl` to ensure that the channel list (m3u8) is always up-to-date and to benefit from advanced streaming features.

## Installation

### Required Perl Modules

**For both scripts:**
```bash
sudo cpan install DateTime JSON::Parse HTTP::Request URI::Escape LWP::UserAgent UUID::Tiny File::Which
```

**Additional modules for server mode (`plutotv-localserver.pl`):**
```bash
sudo cpan install HTTP::Request::Params HTTP::Daemon HTTP::Status Net::Address::IP::Local Getopt::Long Try::Tiny Encode Crypt::CBC IPC::Run
```

**Additional modules for static generation (`plutotv-generate.pl`):**
```bash
sudo cpan install DateTime::Format::Strptime JSON Cwd
```

### System Dependencies
- **Perl 5.10+**
- **OpenSSL binary** (**REQUIRED** for server mode - Crypt::CBC fallback does NOT work correctly for stream decryption)
- **ffmpeg** (for pipe-based streaming)
- **streamlink** (optional alternative to ffmpeg)

## Usage

### Static File Generation
`perl plutotv-generate.pl [--createm3u] [--usebash] [--useffmpeg | --usestreamlink] [--usejalle19proxy]`

#### Parameters for plutotv-generate.pl
| Parameter | Effect |
|---|---|
| `--createm3u` | Create playlist file `plutotv.m3u8` and xmltv file `plutotv-epg.xml` |
| `--usebash` | Create bash script for each PlutoTV channel for starting service |
| `--useffmpeg` | Use ffmpeg-pipe instead of direct URLs to channels |
| `--usestreamlink` | Same as `--useffmpeg`, but using `streamlink` instead of ffmpeg |
| `--usejalle19proxy` | Generate sources.json for [Jalle19 node-ffmpeg-mpegts-proxy](https://github.com/Jalle19/node-ffmpeg-mpegts-proxy) |

### Dynamic Server Mode
`perl plutotv-localserver.pl [--localonly] [--port <portnumber>] [--usestreamlink]`

#### Parameters for plutotv-localserver.pl
| Parameter | Effect |
|---|---|
| `--localonly` | Server listens only on localhost (127.0.0.1) instead of public IP |
| `--port <number>` | Set listening port for server (default: 9000) |
| `--usestreamlink` | Use streamlink instead of ffmpeg in legacy playlist pipes |

## Server Endpoints (plutotv-localserver.pl)

### Available Endpoints
| Endpoint | Description |
|---|---|
| `/playlist` or `/playlist?region=REGION` | Legacy m3u8 with ffmpeg/streamlink pipes |
| `/tvheadend` or `/tvheadend?region=REGION` | **RECOMMENDED:** Direct HLS streams optimized for tvheadend |
| `/stream/{channelId}.m3u8` | **NEW:** Direct HLS stream for individual channel with real-time decryption |
| `/dynamic_stream/{channelId}.ts` | **NEW:** Continuous MPEG-TS stream with timestamp correction |
| `/epg` | XMLTV EPG file |
| `/` | Help page showing available endpoints and regions |

### Supported Regions (Server Mode Only)
The server supports region selection for accessing different PlutoTV content:

| Region Code | Location | Coordinates |
|---|---|---|
| `DE` (default) | Germany (Berlin) | 52.5200, 13.4050 |
| `US` | United States (New York) | 40.7128, -74.0060 |
| `UK` | United Kingdom (London) | 51.5074, -0.1278 |
| `FR` | France (Paris) | 48.8566, 2.3522 |
| `IT` | Italy (Rome) | 41.9028, 12.4964 |

**Server Examples:**
- `http://localhost:9000/tvheadend?region=US` - US channels with direct streams
- `http://localhost:9000/playlist?region=UK` - UK channels with pipes
- `http://localhost:9000/stream/5ad8d135e738977e2c312330.m3u8` - direct HLS stream

## Generated Files (plutotv-generate.pl)

### Standard Output Files
- `plutotv-epg.xml` - XMLTV EPG file (always generated)
- `plutotv.m3u8` - M3U playlist (generated with `--createm3u` or `--usejalle19proxy`)
- `sources.json` - Jalle19 proxy configuration (generated with `--usejalle19proxy`)
- `{ChannelName}.sh` - Individual bash scripts per channel (generated with `--usebash`)

### Static Generation Examples
```bash
# Generate EPG and M3U with direct URLs
perl plutotv-generate.pl --createm3u

# Generate EPG and M3U with ffmpeg pipes
perl plutotv-generate.pl --createm3u --useffmpeg

# Generate bash scripts for each channel
perl plutotv-generate.pl --usebash --useffmpeg

# Generate for Jalle19 proxy
perl plutotv-generate.pl --usejalle19proxy
```

## TVHeadend Integration

### Recommended Setup (Server Mode)
1. **Add Network:** IPTV Automatic Network
2. **Set M3U URL:** `http://YOUR_SERVER_IP:9000/tvheadend` (optionally with `?region=REGION`)
3. **Set EPG URL:** `http://YOUR_SERVER_IP:9000/epg`
4. **Enable:** "Scan after creation" and "Channel name in stream"
5. **Set EPG update interval:** 30-60 minutes

### Static File Setup
1. **Add Network:** IPTV Automatic Network
2. **Set M3U file:** `/path/to/plutotv.m3u8`
3. **Set EPG file:** `/path/to/plutotv-epg.xml`
4. **Enable:** "Scan after creation" and "Channel name in stream"

### Advantages Comparison

#### Server Mode (`plutotv-localserver.pl`)
✅ **Always up-to-date** - Channel list updates automatically  
✅ **Real-time AES-128 decryption** - Handles encrypted segments  
✅ **MPEG-TS timestamp correction** - Fixes discontinuity issues  
✅ **Multiple regions** - Switch regions via URL parameter  
✅ **Direct HLS streaming** - No external process dependencies  
✅ **Concurrent streams** - Multiple channels simultaneously

#### Static Files (`plutotv-generate.pl`)
✅ **Simple setup** - Generate once, use multiple times  
✅ **No server required** - Works with file-based IPTV solutions  
✅ **Offline capability** - Works without running server  
✅ **Jalle19 proxy support** - Advanced proxy integration  
✅ **Flexible output modes** - Direct URLs, pipes, or bash scripts  
⚠️ **Manual updates required** - Must regenerate files regularly  
⚠️ **No region switching** - Fixed to default region

## Advanced Features

### Server Mode Stream Technology
- **AES-128 Decryption:** Automatic segment decryption using OpenSSL (**REQUIRED** - Crypt::CBC fallback does NOT work correctly)
- **Timestamp Correction:** Fixes PCR, PTS, and DTS timestamps across segment boundaries
- **Discontinuity Handling:** Manages EXT-X-DISCONTINUITY markers for seamless streaming
- **33-bit Wrap-around Protection:** Handles MPEG-TS timestamp overflow
- **Session Management:** Per-channel state tracking for concurrent streams
- **Segment Filtering:** Prevents duplicate processing and memory leaks

### Static File Features
- **Multiple Stream Modes:** Direct URLs, ffmpeg pipes, streamlink pipes, or bash scripts
- **Jalle19 Integration:** Generates proxy configuration for [node-ffmpeg-mpegts-proxy](https://github.com/Jalle19/node-ffmpeg-mpegts-proxy)
- **UUID Management:** Proper session and device ID handling
- **EPG Optimization:** 10-day program guide generation

## Automated Updates

### Static Files
PlutoTV provides timelines only 6 hours in advance, requiring regular updates:

```bash
# Generate new files every 6 hours
15 */6 * * * cd /path/to/script && perl plutotv-generate.pl --createm3u --useffmpeg
```

### Server Mode
EPG updates are handled automatically, but you can still cache EPG files:

```bash
# Optional: Cache EPG file every 6 hours
15 */6 * * * wget -q http://localhost:9000/epg -O /path/to/plutotv-epg.xml
```

## Loading XMLTV Guide into TVHeadend

### For Server Mode
TVHeadend can directly use the EPG URL: `http://YOUR_SERVER_IP:9000/epg`

### For Static Files
1. Go to **Configuration** > **Channel/EPG** > **EPG Grabber Modules** and enable "External: XMLTV"
2. Go to **Configuration** > **Channel/EPG** > **Channel** > **Map services** > **Map all services**
3. Load the EPG file:

```bash
cat plutotv-epg.xml | socat - UNIX-CONNECT:/var/lib/hts/.hts/tvheadend/epggrab/xmltv.sock
```

Run this command twice for proper loading.

## Troubleshooting

### Common Issues

#### No Channels Found
- **Static Mode:** Check internet connectivity during generation
- **Server Mode:** Verify API connectivity: `curl -s http://api.pluto.tv/v2/channels`
- Channels with number ≤ 0 are filtered out automatically
- Missing logos will cause channels to be skipped

#### Streams Stop/Buffer (Server Mode)
- **CRITICAL:** Ensure OpenSSL is installed: `which openssl`
- **Crypt::CBC fallback does NOT work correctly** for stream decryption
- Use `/tvheadend` endpoint instead of `/playlist` for better performance
- Monitor server logs for decryption errors

#### Static Files Outdated
- PlutoTV content changes frequently - regenerate files regularly
- Use server mode for always up-to-date content
- Check generation timestamp in created files

#### Tool Dependencies Missing (Static Mode)
- Script validates ffmpeg/streamlink availability and warns if missing
- Falls back to direct URLs if requested tools are not found
- Invalid parameter combinations are automatically resolved with warnings

#### Server Mode Decryption Failures
- **OpenSSL is REQUIRED** - install with: `apt-get install openssl`
- Crypt::CBC is used as fallback but **does not work correctly** for PlutoTV streams
- Monitor logs for "Failed to fetch key" or "Invalid key length" errors
- Verify 16-byte AES key length in server output

### Process Management (Server Mode)

- **Forking Server:** Each request handled in separate process
- **Signal Handling:** Proper cleanup on SIGPIPE and SIGCHLD
- **Resource Cleanup:** Automatic removal of old segment references (15 minute TTL)

## Systemd Service (Server Mode)

```ini
[Unit]
Description=PlutoTV Local Server
After=network.target

[Service]
Type=simple
User=plutotv
Group=plutotv
WorkingDirectory=/opt/plutotv
ExecStart=/usr/bin/perl /opt/plutotv/plutotv-localserver.pl --port 9000
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

## Performance & Security Notes

### Memory Usage
- **Server Mode:** Scales with concurrent stream count, automatic cleanup
- **Static Mode:** Minimal memory usage during generation

### Security Considerations
- **Server Mode:** Binds to public IP by default (use `--localonly` for localhost only)
- No authentication implemented - secure with firewall if needed
- External dependencies should be from trusted sources

### File Locations
- **Static files:** Generated in script directory
- **Server logs:** Output to stdout/stderr (use systemd journal)
- **Temporary data:** In-memory only (server mode)

## Third-Party Integration

### Jalle19 node-ffmpeg-mpegts-proxy
The static generator supports [Jalle19's proxy](https://github.com/Jalle19/node-ffmpeg-mpegts-proxy):

```bash
perl plutotv-generate.pl --usejalle19proxy
```

This generates:
- `sources.json` - Proxy source configuration
- `plutotv.m3u8` - M3U pointing to proxy URLs (localhost:8282)

Configure the proxy to use the generated sources.json file.