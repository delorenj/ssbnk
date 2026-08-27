# Retired Nginx architecture

This page preserves the boundary of the removed web tier without presenting it
as a supported deployment. The current `ssbnk serve` process delivers hosted
assets, the HTTP API, and the embedded Astro UI directly.

## Historical role

Earlier versions kept Nginx configuration and hosted files under `web/`. A
packaged image ran Nginx, the watcher, and cron under supervisor, while another
Compose path used a separate watcher image. These paths drifted: the packaged
image omitted the current frontend and endpoint set, and runtime behavior was
split between source and deployment scripts.

## Replacement

The single-image architecture removes the `web/` source tree, Nginx,
supervisor, and the packaged Compose file. Their responsibilities moved as
follows:

- The Go server handles API, static files, and Astro fallback routing.
- The root `Dockerfile` embeds both the Go binary and UI.
- `ssbnk cleanup` replaces shell cleanup and in-container cron.
- A systemd timer in the deployment hub schedules the one-shot cleanup role.
- Traefik connects directly to the public Go service.

For current behavior, read the
[integration architecture](./integration-architecture.md) and
[deployment guide](./deployment-guide.md).
