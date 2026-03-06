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

The remote uploader runs as a service on any machine in your Tailnet.

**Linux** (systemd user service):
```bash
# Config at ~/.config/ssbnk/remote.env
# Script at ~/.local/bin/ssbnk-remote-upload
# Service at ~/.config/systemd/user/ssbnk-remote-upload.service
systemctl --user enable --now ssbnk-remote-upload
```

**macOS** (launchd):
```bash
# Config at ~/.config/ssbnk/remote.env
# Script at ~/.local/bin/ssbnk-remote-upload
# Plist at ~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist
launchctl load ~/Library/LaunchAgents/sh.delo.ss.remote-upload.plist
```

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
| `scripts/remote-screenshot-upload.sh` | Reference uploader script for remote machines |
| `scripts/cleanup.sh` | Retention-based file cleanup (runs via cron container) |

## License

MIT License - see [LICENSE](https://github.com/delorenj/ssbnk/blob/main/LICENSE) for details.
