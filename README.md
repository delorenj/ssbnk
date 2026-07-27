# ssbnk (ScreenShot Bank)

**Screenshot sharing that hits different**

A dead simple, lightning-fast screenshot hosting service designed for developers, content creators, and anyone who needs instant screenshot sharing. Take a screenshot on any machine, get a hosted URL on your clipboard instantly.

## Features

- **Instant hosting**: Screenshots are immediately available via HTTPS
- **Auto-clipboard**: URLs automatically copied to clipboard on the host machine
- **Remote upload**: Screenshots from any Tailnet machine are auto-uploaded and clipboard-ready
- **Paste image**: Ctrl+Shift+V pastes the actual image (not just the URL) into the active window
- **Smart cleanup**: Configurable retention with intelligent daily cleanup
- **Display server agnostic**: Supports both X11 and Wayland seamlessly
- **Secure by default**: Hosted behind Traefik reverse proxy with automatic TLS
- **Lightning fast**: Go-powered file watcher with minimal overhead

## Quick Start

```bash
# Clone and configure
git clone https://github.com/delorenj/ssbnk.git
cd ssbnk
cp .env.example .env  # Edit with your domain and directories

# Start the stack
docker compose up -d
```

## Architecture

```
Remote Machines                    ssbnk Host (big-chungus)
+-----------------+               +---------------------------+
| screenshot taken|               |  ssbnk-watcher (Go)       |
| fswatch/inotify |--POST /upload-->  - processes image       |
| detects file    |               |  - saves to web/html/     |
+-----------------+               |  - creates metadata JSON  |
                                  |  - copies URL to clipboard|
Local Screenshots                 +---------------------------+
+-----------------+               |  ssbnk-web (nginx)        |
| screenshot dir  |               |  - serves hosted assets   |
| fsnotify watch  |--move-------->|  - proxies API endpoints  |
+-----------------+               +---------------------------+
                                  |  ssbnk-cleanup (cron)     |
                                  |  - daily retention sweep  |
                                  +---------------------------+
```

## Workflow

### Local screenshots
1. Screenshot saved to your configured watch directory
2. Watcher detects new file instantly
3. File moved to hosted directory with timestamp-based naming
4. URL copied to clipboard automatically

### Remote screenshots
1. Screenshot taken on a remote machine (macOS or Linux)
2. `ssbnk-remote-upload` service detects the new file
3. File POSTed to `https://your-domain/upload` with API key auth
4. Watcher saves file, creates metadata, copies URL to host clipboard
5. SSH into host, Ctrl+V pastes the URL

### Paste image (Ctrl+Shift+V)
- Bound as a GNOME custom shortcut
- Temporarily swaps clipboard to image data, simulates Ctrl+V, restores original clipboard
- Uses `ydotool` for input simulation on GNOME/Wayland

## Remote Machine Setup

The remote uploader runs as a user service on any machine that can reach your ssbnk host. The installer handles everything: dependencies, config, service registration, macOS privacy permissions, and an end-to-end test.

```bash
# On the remote machine (Linux or macOS), from a cloned repo:
scripts/install-remote-client.sh
```

You'll be asked for `SSBNK_HOST`, `SSBNK_UPLOAD_KEY`, and the screenshot directory (defaults: `~/Screenshots` on Linux, `~/Desktop` on macOS) — saved to `~/.config/ssbnk/remote.env`.

**Linux**: installs a systemd user service (`~/.config/systemd/user/ssbnk-remote-upload.service`). Requires `inotify-tools`.

**macOS**: installs a launchd agent (`~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist`). Requires `fswatch` (the installer offers to `brew install` it). If your screenshots save to Desktop/Documents/Downloads, macOS requires a one-time privacy grant — the installer detects this, shows you exactly where to click in System Settings, and waits until the permission is in place before finishing.

Both paths end with an end-to-end test: a probe screenshot is dropped into your watch folder and the installer confirms it lands on the host.

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/latest` | GET | Metadata-driven latest screenshot lookup |
| `/hybrid` | GET | Metadata + filesystem fallback lookup |
| `/stateless` | GET | Filesystem-only lookup |
| `/upload` | POST | Remote upload (requires `X-Upload-Key` header) |
| `/health` | GET | Metadata/file consistency status |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/paste-image.sh` | Paste last screenshot as image via Ctrl+Shift+V |
| `scripts/remote-screenshot-upload.sh` | Uploader that runs on remote machines (inotifywait/fswatch → POST /upload) |
| `scripts/install-remote-client.sh` | Interactive remote-client installer (service registration, macOS privacy wizard, e2e test) |
| `scripts/cleanup.sh` | Retention-based file cleanup (runs via cron container) |

## License

MIT License - see [LICENSE](https://github.com/delorenj/ssbnk/blob/main/LICENSE) for details.
