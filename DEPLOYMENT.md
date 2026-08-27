# ssbnk deployment contract

Production orchestration is intentionally owned by the infrastructure hub, not
by this application checkout.

```text
application source:  /home/delorenj/code/ssbnk
production stack:    /home/delorenj/docker/stacks/utils/ssbnk
```

The source repository publishes one multi-architecture image. The hub promotes
an exact digest and records the host-specific policy around it.

## Release and promotion

1. Run `mise run test` and `mise run build` in the source repository.
2. Merge and push the source commit to `main`.
3. Let `.github/workflows/docker-build.yml` publish `delorenj/ssbnk` with
   `sha-<commit>`, optional semver, and OCI revision labels.
4. Resolve and explicitly pull `delorenj/ssbnk@sha256:<digest>`.
5. Verify the OCI revision equals the promoted source commit.
6. Commit that digest to the DeLoContainers stack before restarting anything.

Never deploy `latest`. Tags are discovery aliases; the Compose digest is the
release lock.

## Production topology

The hub Compose file defines three services from the same digest:

- `ssbnk`: public long-running service behind Traefik.
- `cleanup`: maintenance-profile one-shot invoked by a systemd timer.
- `clipboard`: desktop-profile sidecar invoked by a systemd user unit.

The public service is non-root, read-only, capability-free, and receives only
the screenshot, screencast, and `/data` binds it needs. It gets no display
socket. Cleanup has no network. Clipboard has no network and receives only:

```text
/home/delorenj/data/ssbnk/state -> /data/state (read-only)
$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY -> exact same socket path (read-only bind)
```

Because a Wayland socket is replaced across graphical sessions, the clipboard
container must be recreated by a `graphical-session.target` user unit. It must
not be started by the boot-time system stack unit.

## Persistent data

Keep all application data on one host filesystem and mount the ssbnk data root
as `/data` where possible:

```text
/home/delorenj/data/ssbnk/
├── archive/
├── hosted/
├── metadata/
└── state/
```

This lets cleanup move assets atomically. Separate filesystems require a safe
copy/fsync/remove fallback and make rollback harder.

Relevant variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SSBNK_URL` | `https://ss.yourdomain.com` | Public URL used in metadata and clipboard state |
| `SSBNK_UPLOAD_KEY` | none | Required secret for `POST /upload` |
| `SSBNK_HOSTED_RETENTION_DAYS` | `SSBNK_RETENTION_DAYS` or `30` | Days before archiving hosted files |
| `SSBNK_ARCHIVE_RETENTION_DAYS` | `30` | Days before deleting dated archive directories |
| `SSBNK_STATE_DIR` | `/data/state` | Atomic desktop state markers |

Production secrets stay as `op://DeLoSecrets/...` references in the hub's
tracked `.env.op`; `op run` injects them at runtime.

## Cleanup safety

Before enabling the timer, take an out-of-repository data snapshot and run:

```bash
docker compose --profile maintenance run --rm --no-deps cleanup
```

The hub's `cleanup` service defaults to `ssbnk cleanup --dry-run`; the systemd
timer is the deliberately explicit path that overrides it with mutating
`ssbnk cleanup`.

Cleanup parses all metadata before mutation, honors `preserve`, never replaces
an existing archive destination, ignores archive directories not named exactly
`YYYY-MM-DD`, and uses a lock to reject concurrent runs.

## Cutover verification

Require all of the following before calling a release healthy:

- Compose config validation and systemd unit verification pass.
- The running image digest and OCI revision match the committed promotion.
- The public app container has no Wayland/X11 mount.
- `/health`, `/`, an Astro asset, and a hosted image succeed through Traefik.
- A controlled screenshot increases the API count and produces a reachable URL.
- `wl-paste` returns that URL after the user clipboard unit processes it.
- Cleanup dry-run reports a plan without changing hosted data.

Rollback is a hub commit revert to the prior digest followed by a service
restart. Image rollback does not restore files deleted by cleanup; retain the
pre-cutover data snapshot until the new timer has completed safely.
