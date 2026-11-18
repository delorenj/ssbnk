# Remote clipboard and paste-image verification

This is an operator checklist, not a claim that a device has been tested. Coordinate
before changing the running host, desktop, or either remote machine. Production
Compose, service lifecycle, mounts, and secrets are owned by `~/docker`, not this
source repository; inspect that deployment before applying changes.

## Wiring

- **Remote clients:** On `tiny-chungus` (Linux), install `inotify-tools` and
  `curl`; on `carries-macbook-air` (macOS), install `fswatch` and `curl`. Run
  `scripts/install-remote-client.sh` on each remote machine. The installer
  creates or retains private `~/.config/ssbnk/remote.env` with
  `SSBNK_HOST=https://ss.delo.sh`, `SSBNK_UPLOAD_KEY` matching the server, and
  `SSBNK_SCREENSHOT_DIR` (colon-separated, existing screenshot directories).
  Do not commit the key. Linux enables `~/.config/systemd/user/ssbnk-remote-upload.service`
  at user login; macOS loads `~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist`
  in the GUI user domain. Protected macOS Desktop folders need the installer's
  privacy grant. Verify the installed service or agent label rather than assuming
  an older plist name is still in use.
- **Host:** `ssbnk serve` publishes `last-screenshot` (filename only) and
  `latest-url` under its `SSBNK_STATE_DIR` (container default `/data/state`).
  The production host paths are typically
  `/home/delorenj/data/ssbnk/state` and `/home/delorenj/data/ssbnk/hosted`;
  verify the actual bind mounts first. The public `serve` service has no display
  socket. Run `ssbnk clipboard-bridge` separately as the desktop user with
  read-only state and only the exact Wayland socket, no network. It watches
  `latest-url` and copies the URL with `wl-copy`. Do not reintroduce direct
  clipboard access in the public service. The development example is the
  `desktop` profile in `compose.dev.yml`; it is not the production deployment.
- **GNOME host shortcut:** Install `wl-clipboard`, `ydotool` with a working
  `ydotoold`, `libnotify`, and Bash. Link `scripts/paste-image.sh` to
  `~/.local/bin/ssbnk-paste-image`, then use GNOME Settings → Keyboard → View
  and Customize Shortcuts → Custom Shortcuts to bind the absolute path to
  Ctrl+Shift+V. Set `SSBNK_STATE_DIR` and `SSBNK_HOSTED_DIR` in the shortcut's
  launcher environment if host paths differ. The script fills in missing
  `WAYLAND_DISPLAY` (`wayland-0`) and `XDG_RUNTIME_DIR` (`/run/user/$(id -u)`);
  check the actual socket name if this session uses another display. It accepts
  only a filename marker under the host hosted root; a container `/data/hosted`
  path is not valid on the host. Its text restoration requires a readable text
  clipboard; it fails without changing the clipboard if reading fails.

## Source checks (no desktop proof)

From the source tree, run `bash scripts/test-paste-image.sh`,
`bash -n scripts/paste-image.sh`, and `cd watcher && go test ./...` (via
`mise exec -- go test ./...` if Go is not on PATH). These test command shims,
state publication, upload handler, and bridge behavior. They do **not** test
GNOME focus, real Wayland clipboard ownership, the network path, TCC,
user-session startup, or reboot.

## Real-device checks (record evidence separately)

1. On each remote device, confirm the active uploader and its watched directory:
   `systemctl --user is-enabled ssbnk-remote-upload.service` and
   `systemctl --user status ssbnk-remote-upload.service` on Linux;
   `launchctl print gui/$(id -u)/sh.delo.ss.remote-upload` and the agent logs
   under `~/Library/Logs/ssbnk/` on macOS. Ensure the host bridge is running
   and `wl-paste --no-newline` returns text in the host desktop session.
2. On each remote, capture a fresh distinguishable screenshot in the watched
   directory and record the capture timestamp (with timezone), device name,
   screenshot filename, and its hash. On the **host desktop**, record the first
   observation timestamp at which `wl-paste --no-newline` equals that capture's
   hosted URL. Measure elapsed time; the target is **under 2 seconds** from
   capture for each device. Read host `state/last-screenshot` and `state/latest-url`:
   the former must be a bare filename, the latter the same URL. Fetch the URL
   and compare downloaded bytes to the host `hosted/<marker>` image (and to
   the source screenshot if the server's normalization preserves bytes).
3. Before the shortcut, Ctrl+V into a plain-text field must paste the hosted
   URL. Focus an image-capable app and invoke GNOME Ctrl+Shift+V: inspect that
   an actual image, not a URL or filename, was inserted and corresponds to the
   latest remote image. Ctrl+V into a plain-text field **after restoration**
   must still paste the prior URL. Record app, session type, timestamps, and
   observed content. Repeat with the shortcut launched without inherited
   `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`. Temporarily remove the marker and
   separately point it at a missing image (with operator approval): each must
   notify, return nonzero, and leave the clipboard untouched. Restore state.
4. Capture a local screenshot on the host and repeat marker/URL, fetch and
   shortcut checks; it must now select that local image. With an approved
   maintenance window, reboot and log back into **each** remote device,
   confirm its user service or launch agent started, then repeat step 2 with
   a new screenshot. Merely seeing an enabled unit or a source test does not
   certify reboot behavior.

Keep secret values and private screenshot contents out of shared logs. Report
untested device, desktop, and reboot steps explicitly rather than extrapolating
from source tests.
