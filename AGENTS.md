# Workspace storage

- Keep one complete local release under `artifacts/release-<version>`. Package with `pwsh -File tools/package-release.ps1`; it validates the new files before pruning older local versions and build caches. Preserve source archives and matching symbols/manifests. Do not delete hosted GitHub releases.
- Use `pwsh -File tools/clean-workspace.ps1 -WhatIf` to inspect a cleanup plan and omit `-WhatIf` to apply it when no build, emulator, or app is using this checkout. `-BuildCaches`, `-Temporary`, and `-Releases` select individual scopes. The temporary scope deletes `.local`, including test profiles; never store durable work or credentials there.
- Avoid full scratch copies of this project. If a temporary clone, emulator, extracted archive, or test fixture is needed, remove it in `finally` after the check. Keep small reports/screenshots in `test-output`, not copied runtimes or build trees.
- The managed engine builder removes its own `run-*` directory even after errors. Use `-KeepWorkDirectory` only for active debugging, then explicitly clean it up.
- A direct `flutter build` may retain its current build cache. Run `tools/clean-workspace.ps1 -BuildCaches` after an ad hoc validation session; the packaging script does this automatically. Do not commit generated archives, build output, or caches.
