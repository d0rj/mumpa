# Network diagnosis, 2026-10-10

After explicit user authorization for direct torrent traffic through Wi-Fi,
native Mumpa `MatriX.145.2-mumpa3` **plays the existing favorite
`Роженица в метро`**. First advancing audio is observed in **2959 ms**;
position reaches **2650 ms**, duration is **240457 ms**, and four peers are
connected. The player uses a fresh HTTP torrent source, with copied favorite
cache paths cleared, no local audio path and automatic caching disabled in
the isolated test. This is the user's stored favorite/metainfo, not a fixture
or qBittorrent download. The strict native test exits zero.

The saved Windows profile now selects `Беспроводная сеть`; all other library
data, four likes, track IDs, Jackett/RuTracker.org settings and enabled automatic
caching are preserved. The packaged app has been restarted. VPN, system routes
and firewall rules remain unchanged. Only the app's torrent source selection
was changed. Evidence: `engine-patches/checks/favorites-wifi-native.json` and
`test-output/real-favorites-wifi-native.log`.

The following comparison records why the original system-route attempt failed.

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
traffic can expose the provider IP; the user explicitly authorized that choice.
Mumpa's new Windows interface setting defaults to the system route. The saved
interface name is resolved again at startup, and absence of that interface
fails instead of selecting another network. Changing it applies on restart.

Live diagnostic output is excluded from Git. Sanitized evidence is retained in
`engine-patches/checks/network-comparison.json`; it contains no torrent hashes,
peer addresses, source addresses, credentials or raw tracker queries. The
acceptance criterion of native network playback with positive duration and
at least 2.5 seconds of advancing audio is now met for one existing favorite.
This does not promise availability of every swarm or establish public Android
playback, physical-phone behavior or public DHT health.

## Repeated Windows Firewall notifications

A read-only check of the running portable 1.2.1 app found an unnecessary
inbound-listener operation in Mumpa's bootstrap. Before launching TorrServer,
`_PeerPort.reserve` opened a TCP listener and bound UDP on `0.0.0.0` in
`mumpa.exe` itself, solely to test whether a candidate port was available.
Firewall's active application filters contain separate TCP/UDP `Query User`
block rules for the portable Mumpa executable paths from versions 1.1.0 through
1.2.1. This matches the changing application path of each released build.
Microsoft documents that notifications are triggered by application listen
operations and that application rules use the complete executable path; rules
for one portable release do not cover a different release directory.
[Windows Firewall application rules](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules#applications-rules).

The bootstrap probe now reserves TCP and UDP on `127.0.0.1` only. It still
spreads candidate ports to avoid Windows UDP exclusion ranges, closes both
sockets before native startup, and detects an early engine exit. A preflight
reservation cannot eliminate the existing gap between releasing a port and
the native engine binding it; a simultaneous bind on another interface can
still make the engine report a startup error. The actual peer listener remains
owned by the native engine at its stable runtime executable path, and its
selected network interface and peer transports are unchanged.

The live process check found no remaining listeners in the Mumpa process.
Jackett and FlareSolverr HTTP listeners were loopback-only, while TorrServer
owned the peer TCP/UDP sockets. All three helper executable paths were in the
persistent runtime directory. Sanitized evidence is saved locally in
`test-output/firewall-listener-diagnosis.json`; no firewall rules, VPN settings
or routes were changed. The evidence establishes repeated notifications across
different portable release paths; it does not establish repeated prompts for
the identical executable path after an existing rule has already been created.

The engine regression checks every bootstrap bind address over two starts,
verifies that both reservation sockets have been released before native
ownership, and retains the occupied-UDP and startup-failure checks. Test sockets
also use loopback, avoiding a new inbound-listener notification during these
unit checks. A first permission request for a genuine peer-facing helper on a
new installation remains an operating-system decision.
