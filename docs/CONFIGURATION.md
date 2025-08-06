# Configuration Guide

This guide covers all configuration options for ssbnk.

## Environment Variables

### Required Variables

| Variable               | Description                          | Example                      |
| ---------------------- | ------------------------------------ | ---------------------------- |
| `SSBNK_URL`            | Your domain name (without https://)  | `screenshots.yourdomain.com` |
| `SSBNK_SCREENSHOT_DIR` | Directory where you save screenshots | `/home/username/screenshots` |

### Optional Variables

| Variable               | Default          | Description                         |
| ---------------------- | ---------------- | ----------------------------------- |
| `SSBNK_RETENTION_DAYS` | `30`             | Days to keep files before archiving |
| `DISPLAY`              | `:0`             | X11 display server                  |
| `WAYLAND_DISPLAY`      | `wayland-0`      | Wayland display server              |
| `XDG_SESSION_TYPE`     | `wayland`        | Session type                        |
| `XDG_RUNTIME_DIR`      | `/run/user/1000` | Runtime directory                   |

## Docker Compose Configuration

### Traefik Labels

The default configuration assumes you're using Traefik as a reverse proxy. If you're using a different proxy, modify the labels in `compose.yml`:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.ssbnk.entrypoints=websecure"
  - "traefik.http.routers.ssbnk.rule=Host(`${SSBNK_URL}`)"
  - "traefik.http.routers.ssbnk.tls=true"
  - "traefik.http.routers.ssbnk.tls.certresolver=letsencrypt"
```

### Volume Mounts

The watcher service needs access to:

- Your screenshot directory (read/write)
- X11/Wayland sockets for clipboard access
- Runtime directory for Wayland

### Network Configuration

The watcher uses `network_mode: host` to access the clipboard. This is required for clipboard functionality.

## Nginx Configuration

The nginx service serves static files with optimized caching. The configuration includes:

- Gzip compression
- Long-term caching for images
- Security headers
- Custom error pages

## Cleanup Configuration

The cleanup service runs daily at 2:00 AM and:

- Archives files older than `SSBNK_RETENTION_DAYS`
- Removes old archives
- Cleans up orphaned metadata

## Security Considerations

- Files are served with immutable cache headers
- No directory listing is enabled
- Custom error pages prevent information disclosure
- Files are automatically archived based on retention policy

## Customization

### Custom Domain

Update your `.env` file:

```bash
SSBNK_URL=your-custom-domain.com
```

### Custom Screenshot Directory

Update your `.env` file:

```bash
SSBNK_SCREENSHOT_DIR=/path/to/your/screenshots
```

### Custom Retention Period

Update your `.env` file:

```bash
SSBNK_RETENTION_DAYS=60  # Keep files for 60 days
```
