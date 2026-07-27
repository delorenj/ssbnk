# Architecture — Web (Nginx static hosting, legacy)

## Executive summary

`web/` contains the Nginx configuration from ssbnk's retired 3-container architecture (Nginx frontend → watcher on :31243) plus `web/html/`, the directory of live hosted assets (~136 files). In the current `compose.yml` stack **no Nginx container exists** — the watcher serves assets itself. These configs remain in use only inside the packaged all-in-one image (root `Dockerfile`, supervisord).

## Technology stack

| Category | Technology | Justification |
|---|---|---|
| Server | Nginx (alpine) | Static hosting + reverse proxy |
| TLS/routing | Traefik (external) | Terminates TLS in both architectures |

## Configuration

### `web/nginx.conf` (http level)

- `worker_processes auto`, gzip, sendfile, `keepalive_timeout 65`
- Security headers (always): `X-Frame-Options SAMEORIGIN`, `X-Content-Type-Options nosniff`, `X-XSS-Protection`, `Referrer-Policy no-referrer-when-downgrade`, permissive CSP (`default-src 'self' http: https: data: blob: 'unsafe-inline'`)
- CORS `Access-Control-Allow-Origin *` (commented "for LLM access")
- Rate limit zone: `limit_req_zone $binary_remote_addr zone=ss:10m rate=10r/s`

### `web/default.conf` (server block)

`listen 80`, `server_name ss.delo.sh`, `root /usr/share/nginx/html`, `server_tokens off`, `limit_req zone=ss burst=20 nodelay`.

| Location | Behavior |
|---|---|
| `~* \.(png\|jpg\|jpeg\|gif\|webp\|mp3\|wav\|m4a\|ogg)$` | Static, `expires 1d` + `Cache-Control public, immutable`, `try_files $uri =404` |
| `/latest` | `proxy_pass http://host.docker.internal:31243` (watcher) |
| `/upload` | Same proxy, `client_max_body_size 50m` |
| `/health` | Answered by Nginx itself (`200 "OK"`, no access log) — **not** the watcher's health JSON |
| `/api/` | 403 without `X-API-Key` header, otherwise 404 ("Future" stub) |
| `/` | 403 either way (directory listing not implemented) |
| `~* \.json$`, `~ /\.` | 403 (blocks metadata and dotfiles) |

## Deployment role

Only the packaged all-in-one image (root `Dockerfile`) runs Nginx, under supervisord alongside the watcher and cleanup cron. `web/html/` is bind-mounted as hosted storage in older stacks; current stack uses `/home/delorenj/data/ssbnk/hosted` mounted directly into the watcher.

## Known drift

- AGENTS.md claims Nginx proxies `/hybrid`, `/stateless`, `/health` to the watcher — it never did; only `/latest` and `/upload` are proxied, `/health` is local, and `/hybrid`/`/stateless`/`/api/screenshots` are unreachable through this config.
- The UI's `/api/screenshots` call would 403/404 through this Nginx — another sign this layer predates the current UI.
- `docker-compose.packaged.yml` sets `network_mode: host` together with Traefik labels, so its labeled routing can't work.
