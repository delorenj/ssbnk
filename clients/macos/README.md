# SSBNK Client for macOS

SSBNK Client is an arm64-native menu-bar app that moves new screenshots and screen recordings to the existing SSBNK watch roots over SSH and rsync. It does not use the HTTP upload key, delete Mac originals, or mirror the capture folder.

## Default routes

Both media types start in `/Users/delorenj/Pictures/Screenshots`:

- PNG, JPG, JPEG, GIF, and WebP → `delorenj@big-chungus.burro-salmon.ts.net:/home/delorenj/Pictures/Screenshots`
- MOV, MP4, AVI, MKV, WebM, FLV, and WMV → `delorenj@big-chungus.burro-salmon.ts.net:/home/delorenj/Videos/Screencasts`

The destination, public `https://ss.delo.sh/health` URL, roots, and source folder are editable in Settings. The SSH destination accepts hostnames only; no upload credential is stored by this app.

## First launch

1. Copy `SSBNK Client.app` from the DMG to Applications and open it.
2. Use Settings to confirm the capture folder and SSH destination.
3. Allow macOS folder access when prompted.
4. Select **Test Connection**. Healthy means the source and outbox are usable, the public health endpoint responds, batch-mode SSH works, both remote roots are writable, and no sync error or queued work remains.
5. Enable **Launch at Login** if desired.

The first scan records existing supported files as a baseline and uploads nothing. **Sync Existing…** is the explicit, confirmed way to enqueue baseline files. New stable captures are copied into `~/Library/Application Support/SSBNK Client/Outbox`; only that copy is removed after rsync succeeds. Queue and delivery state survive relaunches.

Configure key-based SSH before testing. This must succeed without a password or host-key prompt:

```bash
/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 delorenj@big-chungus.burro-salmon.ts.net /usr/bin/true
```

## Retiring the old uploader

When the new client reports Healthy, Settings enables **Retire Legacy Uploader…**. After confirmation it unloads and removes `~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist` and deletes `~/.config/ssbnk/remote.env`, which contains the obsolete plaintext HTTP upload credential. The migration refuses to run before the replacement is Healthy.

## Test and package

Run deterministic tests on an Apple Silicon Mac:

```bash
cd clients/macos
swift test
```

The test target pins the official Swift Testing release matched to Swift 6.3.3 and supplies the standard Command Line Tools linker path, so this command works without a full Xcode install. The shipped app has no package runtime dependencies.

Set the exact Developer ID identity shown by `security find-identity -v -p codesigning`, then build:

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Example (TEAMID)'
clients/macos/scripts/build-dmg.sh
```

The script runs tests, builds only `arm64`, assembles and signs the menu-bar app with the hardened runtime, verifies the signature, creates the DMG, mounts it, and verifies the mounted app. The output is `clients/macos/dist/SSBNK-Client.dmg`; `dist/` is intentionally untracked. Public notarization is not part of this first package.

After installing, complete the physical smoke test: launch without a Dock icon, confirm menu actions and both mappings, relaunch once, then create one PNG and one MOV. Confirm each appears once in the public gallery through the correct watch root while both originals remain on the Mac.
