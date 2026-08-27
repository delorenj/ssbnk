# Integration architecture

ssbnk uses one image for three narrowly scoped runtime roles. The public
service publishes files and state. Network-disabled maintenance and desktop
services consume only the directories or socket that they need.

```text
 remote uploader -- HTTPS POST /upload --+
 browser -------- HTTPS GET ------------+--> Traefik --> ssbnk serve :80
 local screenshot -- bind mount/fsnotify-+                  |
                                                            +--> /data/hosted
                                                            +--> /data/metadata
                                                            +--> /data/state
                                                                   |
                              +------------------------------------+---------+
                              |                                              |
                    clipboard-bridge                               cleanup
                    network: none                                  network: none
                    state: read-only                         data: read/write
                    exact Wayland socket                           systemd timer
                              |
                              +--> wl-copy --> desktop clipboard
```

The Astro build is inside the same image and HTTP origin as the API. There is
no frontend container, Nginx tier, supervisor process, or shell cleanup image.

## Integration points

The following boundaries are part of the supported runtime contract:

| From | To | Channel | Contract |
| --- | --- | --- | --- |
| Browser | `ssbnk serve` | HTTPS | Loads the embedded UI and calls same-origin `/api/screenshots` |
| Remote uploader | `POST /upload` | HTTPS | Multipart `file`, `X-Upload-Key`, 50 MB maximum |
| Local media folders | `ssbnk serve` | Bind mount and `fsnotify` | Create or rename events trigger ingestion |
| `ssbnk serve` | Data tree | Filesystem | Writes hosted bytes, JSON metadata, and atomic state markers |
| `ssbnk clipboard-bridge` | State tree | Read-only bind mount | Watches `latest-url` with `fsnotify` plus polling |
| Clipboard bridge | Wayland compositor | Exact socket bind mount | Runs `wl-copy`; receives no network access |
| `ssbnk cleanup` | Data tree | Read-write bind mount | Applies retention under an exclusive data-directory lock |
| Traefik | `ssbnk serve` | Docker `proxy` network | Routes the production hostname to port 80 |
| systemd | Docker Compose | Service and timer units | Starts the stack and runs the maintenance profile |

## Local ingestion flow

Local screenshots follow this sequence:

1. A file appears in `/media/screenshots` or `/media/screencasts`.
2. `serve` waits for the file, normalizes its name, and copies or converts it
   into `/data/hosted`.
3. `serve` writes a JSON sidecar into `/data/metadata`.
4. `serve` removes the local source after successful storage.
5. `serve` atomically writes `/data/state/last-screenshot`, then
   `/data/state/latest-url`.
6. The bridge notices `latest-url` and copies the URL with `wl-copy`.
7. The browser gallery reads the new record from `/api/screenshots`.

State publication failures don't fail ingestion. This property keeps desktop
availability separate from the public screenshot service.

## Remote upload flow

Remote uploads use the same storage path as local ingestion:

1. The client posts an accepted image to `/upload` with `X-Upload-Key`.
2. `serve` validates the request, stores the file, and writes metadata.
3. `serve` publishes the two state markers and returns the hosted URL.
4. The remote uploader copies the returned URL to its own local clipboard.

## Cleanup flow

The deployment hub's systemd timer starts the Compose maintenance profile. The
job runs the same pinned image with `ssbnk cleanup`, no network, and read-write
access to `/data`.

Cleanup first parses and validates the relevant metadata and creates a complete
plan. It then archives expired hosted files and their sidecars, deletes only
expired archive directories named `YYYY-MM-DD`, removes orphaned metadata, and
repairs state markers if they point at an archived file. Use `--dry-run` to
print the plan without changing data.

## Repository ownership flow

A release moves in one direction:

1. Source changes land in `/home/delorenj/code/ssbnk`.
2. CI tests the Go code, builds the Astro UI, and publishes the canonical
   multi-architecture image.
3. The image digest is promoted into the Compose file in
   `/home/delorenj/docker/stacks/utils/ssbnk`.
4. The deployment hub commit becomes the complete, reviewable production
   configuration and rollback point.
