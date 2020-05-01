# plutoTV-tvheadend
Perl-Script to generate m3u and xmltv-epg from PlutoTV-API


## install used modules
`sudo cpan install DateTime DateTime::Format::Strptime JSON JSON:Parse HTTP::Request URI::Escape LWP::UserAgent`

## usage
`perl plutotv-generate.pl [--createm3u] `

## more
PlutoTV only delivers timelines 6h in future. So epg has to be fetched at least every 6 hours:
crontab:
`15 */5 * * * perl plutotv-generate.pl`

