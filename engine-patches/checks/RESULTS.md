# MatriX.145.2-mumpa2 validation

- Pinned fresh-source Go suite: **PASS**, 12 tests plus four IP subcases.
- Negative controls: **PASS**; restoring the old MSE return, malformed IP,
  automatic override, or missing cancellation guard makes its regression fail.
- Deadline scheduling stability: **PASS**, 30 repetitions.
- Initiator lifecycle: actual client-side Close is observed before fallback
  and at completion, including cancellation and forced-encryption rejection.
- Binary reproducibility: **PASS**; a second fresh-source build reproduces all
  four primary-lock SHA256 values. Compiler/ABI build metadata was inspected
  without executing the engines.
- Native integration, confirmed by the coordinating agent: **PASS** on Windows
  and Android. Each rejects one MSE attempt, accepts one outgoing plaintext
  attempt, and advances audio before full download (1451 ms / 1601 ms).
  Range, cache, restart, offline integrity, reader cleanup, and Android
  audio-service checks pass.
- Strict real favorites on Windows: **FAIL**; both original swarms still have
  zero peers/audio. The local protocol fixes do not establish public playback
  or explain the remaining network timeouts.

Corresponding source:
`artifacts/TorrServer-MatriX.145.2-mumpa2-source.zip`

SHA256: `e7de66d436aa6e63ac5e80dfdf032379a9c2bd545556705bfcd602918bf61ee2`

The archived README matches the final checkout README. The local fork license
and `server/managed.mod` are present. The primary release lock is promoted;
the duplicate candidate was moved to ignored local diagnostics. Generic
`prepare-engines.ps1` verifies all four binaries. The temporary hardcoded
candidate protection was removed; generic `-LockFile`, `-TestsOnly`, and
pending-build safeguards remain.

Evidence: `mumpa2-final-build.log`, `mumpa2-negative-controls.log`,
`negative-*.log`, `deadline-stability.log`, and the reproducible
`run-negative-controls.ps1`. No user profile, credentials, VPN/firewall setting,
or public/private tracker probe was changed or used by these checks.
