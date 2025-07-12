# ssbnk (ScreenShot Bank)

**Screenshot sharing that hits different**

> *Pronounced "spank" - because your screenshots deserve a good hosting!*

A dead simple, lightning-fast screenshot hosting service designed for developers, content creators, and anyone who needs instant screenshot sharing.

## ✨ Features

- 📸 **Instant hosting**: Screenshots are immediately available via HTTPS
- 📋 **Auto-clipboard**: URLs automatically copied to clipboard  
- 🗑️ **Smart cleanup**: Configurable retention with intelligent daily cleanup
- 🖥️ **Display server agnostic**: Supports both X11 and Wayland seamlessly
- 🔒 **Secure by default**: Hosted behind reverse proxy with automatic TLS
- ⚡ **Lightning fast**: Go-powered file watcher with minimal overhead
- 🎯 **Zero configuration**: Works out of the box with sensible defaults

## 🚀 Quick Start

```bash
# Simple one-liner
curl -sSL https://raw.githubusercontent.com/delorenj/ssbnk/main/scripts/run-ssbnk.sh | bash

# Or run manually
docker run -d \
  --name ssbnk \
  --network host \
  --privileged \
  -v $HOME/screenshots:/watch \
  -v ssbnk_data:/data \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v /run/user/1000:/run/user/1000:rw \
  -e SSBNK_URL=https://screenshots.example.com \
  -e DISPLAY=$DISPLAY \
  -e WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
  -e XDG_RUNTIME_DIR=/run/user/1000 \
  ssbnk/ssbnk:latest
```

## 🔄 Workflow

1. Screenshot saved to your configured watch directory
2. Watcher detects new file instantly
3. File moved to hosted directory with timestamp-based naming
4. URL copied to clipboard automatically
5. Daily cleanup archives old files based on retention policy

## 📚 Documentation

- [GitHub Repository](https://github.com/delorenj/ssbnk)
- [Configuration Guide](https://github.com/delorenj/ssbnk/blob/main/docs/CONFIGURATION.md)
- [Troubleshooting](https://github.com/delorenj/ssbnk/blob/main/docs/TROUBLESHOOTING.md)
- [API Documentation](https://github.com/delorenj/ssbnk/blob/main/docs/API.md)

## 🏷️ Tags

- `latest` - Latest stable release
- `v1.0.0` - Specific version tags
- `main` - Latest development build

## 📄 License

MIT License - see [LICENSE](https://github.com/delorenj/ssbnk/blob/main/LICENSE) for details.

---

**Made with 📸 and ☕ by developers, for developers.**
