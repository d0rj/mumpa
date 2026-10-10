# Network diagnosis, 2026-10-10

The existing public favorites are alive. An independent qBittorrent 5.1.2
(libtorrent 1.2.20.0) in a temporary profile repeatedly obtains 30 / 12 peers
from the original `bt.t-ru.org` / `bt4.t-ru.org` trackers and downloads both
selected audio files over IPv4 TCP. Proxy, UPnP, LSD and automatically added
trackers are disabled. Its profile and downloaded diagnostic data are removed
after each run. This establishes swarm availability, **not Mumpa playback**.

The transport comparison explains the otherwise conflicting results:

- System-selected Mumpa/Python HTTP sockets use the running VPN interface.
  The original announces end without a response after about 15 seconds,
  including when replaying qBittorrent's actual request framing. Explicit
  binding to the same VPN source address gives the same result.
- A 50 ms socket monitor observes qBittorrent's short successful HTTP announces
  using the Wi-Fi source address. Read-only `GetBestRoute2` classifies the
  system-selected route as VPN and the route with that captured source as
  Wi-Fi. This measures route selection, not the actual external IP address.
- The separately authorized OpenTrackr UDP test returns 5 / 4 peers, zero
  seeders and zero reachable TCP endpoints. It has not enabled Mumpa playback.
- The strict native `mumpa2` test with original trackers plus OpenTrackr still
  fails: no decoded duration, advancing position, connected peers or audio.

No VPN, system routes or firewall rules were changed. Direct tracker/peer
traffic can expose the provider IP; it requires the user's separate choice.
Mumpa's new Windows interface setting defaults to the system route. The saved
interface name is resolved again at startup, and absence of that interface
fails instead of selecting another network. Changing it applies on restart.

Live diagnostic output is excluded from Git. Sanitized evidence is retained in
`engine-patches/checks/network-comparison.json`; it contains no torrent hashes,
peer addresses, source addresses, credentials or raw tracker queries. The
remaining acceptance criterion is native network playback of an existing
favorite, with positive duration and at least 2.5 seconds of advancing audio.
