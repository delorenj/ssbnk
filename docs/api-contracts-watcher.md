# HTTP API contract

`ssbnk serve` exposes the API, hosted assets, and embedded UI on
`SSBNK_API_PORT`, which defaults to 80. Production routes this server through
Traefik at `https://ss.delo.sh`.

## Common response behavior

Every route receives these headers:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: SAMEORIGIN`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, PUT, POST, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type, X-Upload-Key, X-API-Key, Upload-Offset, Upload-Chunk-SHA256`

API, health, upload, and retrieval responses use `Cache-Control: no-store`.
Hosted images use `public, max-age=86400, immutable`; fingerprinted Astro
assets use `public, max-age=31536000, immutable`; UI HTML uses `no-cache`.

`POST /upload` and **every `/api/uploads` request**, including capabilities
and status, require `X-Upload-Key`. The server hashes the presented key and
`SSBNK_UPLOAD_KEY` with SHA-256 and compares them in constant time. Gallery,
health, retrieval, and hosted assets remain public. `X-API-Key` is not an
alternative upload credential.

`OPTIONS` outside `/api/uploads` returns 200. Within `/api/uploads`, it goes
through authentication and routing/method validation: recognized v2 endpoints
return 405 for authenticated preflight. The native clients do not use browser
preflight; the advertised CORS headers alone do not make v2 a cross-origin
browser upload API.

Unknown `/api/` routes or versions return JSON 404 rather than the UI. v2 JSON
responses carry `version: 2`; unsupported descriptor versions return 400.
Use the final HTTPS origin without redirects. Both native clients refuse
upload redirects; HTTP is allowed only for explicit loopback development
origins. `/health` alone does not establish v2 compatibility.

The sections below describe the candidate source contract, not evidence that
production has been upgraded. See the [deployment guide](./deployment-guide.md)
for server-first ordering and outstanding qualification.

## `GET /api/screenshots`

This endpoint returns metadata for the gallery.

| Query parameter | Default | Validation |
| --- | ---: | --- |
| `limit` | 50 | Positive integer |
| `offset` | 0 | Nonnegative integer |

Invalid values fall back to their defaults. Results sort by timestamp in
descending order. Hosted files without metadata receive synthesized entries.

```json
{
  "screenshots": [
    {
      "id": "92ef3c67-b7d8-4fd2-b58e-4ccfb8521800",
      "original_name": "Screenshot.png",
      "filename": "20260827-1430.png",
      "url": "https://ss.delo.sh/20260827-1430.png",
      "timestamp": "2026-08-27T14:30:00-04:00",
      "preserve": false,
      "size": 12345
    }
  ],
  "total": 1,
  "offset": 0,
  "limit": 50
}
```

## `GET /latest` and `GET /latest/{offset}`

This endpoint sorts decoded root metadata by stored timestamp and returns a
302 redirect to the selected record's URL. It doesn't validate the hosted file
before redirecting.

- An out-of-range offset returns status 404.
- An unreadable metadata directory returns status 500.

## `GET /hybrid` and `GET /hybrid/{offset}`

This endpoint tries metadata first and verifies that the referenced file
exists. If metadata is missing or inconsistent, it scans hosted images by file
modification time. Success returns a 302 redirect. A missing offset returns
status 404 with the available file count.

## `GET /stateless` and `GET /stateless/{offset}`

This endpoint ignores metadata and selects directly from hosted image files by
modification time. It returns the same redirect and 404 forms as `/hybrid`.

## Authenticated resumable uploads (`/api/uploads`, v2)

This is application-level raw-body chunking, not multipart, tus, or HTTP
`Transfer-Encoding: chunked`. Keep one UUID and one immutable descriptor for
each staged capture. Parallel clients may use different UUIDs, but send only
one mutation at a time per UUID.

### Capabilities and session creation

`GET /api/uploads/capabilities` returns `version`, `kinds`, `profiles`,
`limits`, `processing_ready`, and `expiry`. The profiles are:

| Input `kind` | `profile` | Hosted result |
| --- | --- | --- |
| `image` | `original` | Sniffed PNG, JPEG, GIF, or WebP, preserving bytes |
| `video` | `gif-30s-10fps-640` | Looping GIF: first 30 seconds, 10 fps, width 640 |

`processing_ready` currently checks that `ffprobe` and `ffmpeg` are on PATH;
it is not a successful conversion or storage/proxy qualification. Images also
pass through the bounded media probe. A legacy server or invalid capabilities
response means **upgrade required**, never implicit SSH or `/upload` fallback.

For a capabilities check, replace the vault placeholder with the actual
existing DeLoSecrets item reference. This passes the resolved header through
stdin, without writing the key to a file. Don't enable shell tracing or curl
verbose/trace output.

```bash
UPLOAD_REF='op://DeLoSecrets/<existing-item-id>/credential'
printf 'header = "X-Upload-Key: %s"\n' "$(op read "$UPLOAD_REF")" |
  curl --config - --silent --show-error --fail-with-body \
    https://ss.delo.sh/api/uploads/capabilities
```

`PUT /api/uploads/{uuid}` accepts one JSON descriptor, at most 8 KiB. UUIDs
must be canonical lowercase, nonzero UUID strings. `original_name` is a UTF-8
basename of at most 255 bytes, not a path; `size` must be positive and within
the kind's limit; `sha256` is the full staged input's 64-digit hex digest;
`capture_time` is a nonzero RFC 3339 timestamp. Unknown JSON fields and trailing
JSON values are rejected. The server canonicalizes the hash to lowercase and
the timestamp to UTC before comparing descriptors.

Illustrative request; replace all test placeholders and resolve the header in
process memory, not from a plaintext configuration file:

```http
PUT /api/uploads/12345678-1234-4234-8234-123456789abc
X-Upload-Key: <resolved test credential>
Content-Type: application/json

{"version":2,"original_name":"test.png","kind":"image","size":12345,"sha256":"<64-hex staged-input digest>","capture_time":"2026-10-05T12:00:00Z","profile":"original"}
```

- **201**: new durable reservation, `state: "receiving"`, `offset: 0`, `attempt: 1`.
- **200**: identical descriptor already reserved; returns its current receipt.
- **409 `UUID_CONFLICT`**: the UUID was used with a different descriptor.
- **410 `UPLOAD_EXPIRED`**: permanent tombstone; UUID reuse is prohibited.

### Chunks and durable offsets

`PUT /api/uploads/{uuid}/chunks` requires a raw body and these headers:

```http
PUT /api/uploads/12345678-1234-4234-8234-123456789abc/chunks
X-Upload-Key: <resolved test credential>
Content-Length: 12345
Upload-Offset: 0
Upload-Chunk-SHA256: <64-hex digest of these 12345 bytes>

<raw test.png bytes>
```

The example is a valid single short final chunk for the descriptor above.
Use the advertised default chunk size (normally 1 MiB), never more than the
advertised maximum (at most 4 MiB). The 64 KiB minimum applies only to
**non-final** chunks. A positive shorter chunk is valid exactly when
`offset + Content-Length == size`. Zero length, missing/unknown length, HTTP
transfer encoding, gaps, overlaps, overruns, and invalid hashes are rejected.

Append only at the receipt's committed `offset`. A 200 acknowledges both
synced input bytes and the synced, atomically replaced journal checkpoint,
including directory sync. It is not just a count of bytes received in memory.
The server retains the last committed `(offset, length, sha256)` tuple. An
exact replay of that chunk re-hashes the body and returns the current receipt
without appending again. Older replays return 409 `OFFSET_CONFLICT`.

Busy same-UUID mutations return promptly with 409 `BUSY`; globally occupied
receivers return 503 `BUSY`. Status reads use the committed snapshot and do
not wait for a slow chunk body. A failed body/hash is rolled back to the old
offset when rollback durability can be confirmed. `STORAGE_UNCERTAIN` means
repair/reconciliation is required; do not send more bytes or create a new UUID
to bypass it.

### Completion, status, and processor retry

| Endpoint | Successful response | Meaning |
| --- | --- | --- |
| `POST /api/uploads/{uuid}/complete` | 202 receipt | Empty body (clients send `Content-Length: 0`); requires `offset == size`. Acceptance and `verifying` are persisted before reply. Repeated completion returns existing state, without another processing submission. |
| `GET /api/uploads/{uuid}` | 200 receipt | Current committed state, including `failed`; 404 `UPLOAD_UNKNOWN` for unknown UUID, 410 receipt for an expired tombstone. |
| `POST /api/uploads/{uuid}/retry` | 202 receipt | JSON `{"expectedAttempt":1}` (use the current attempt), at most 8 KiB. Only a retryable processor failure with attempts remaining is eligible. |

Full-input hash, image sniffing, and media probing happen asynchronously after
completion. States are `receiving → verifying → queued → processing → ready`,
with `failed` on processing failure. Polling or duplicate completion never
restarts failed processing. Retry persists the incremented attempt before
replying: a stale `expectedAttempt` returns current state without incrementing
again; a future attempt returns 409 `ATTEMPT_CONFLICT`. The default budget is
three persistent attempts, including the initial one; interrupted processing
may consume an attempt on restart.

Receipts include the descriptor plus `uuid`, `offset`, `state`, `attempt`,
`created_at`, and `progress_at`. `accepted_at`, `first_failure_at`, `expires_at`,
and structured `error: {code,message,retryable}` appear when applicable.
Only `ready` includes a result:

```json
{
  "url": "https://ss.delo.sh/12345678-1234-4234-8234-123456789abc.gif",
  "filename": "12345678-1234-4234-8234-123456789abc.gif",
  "metadata_id": "12345678-1234-4234-8234-123456789abc",
  "media_type": "image/gif",
  "size": 54321,
  "sha256": "<64-hex hosted-output digest>",
  "availability": "available"
}
```

This is an illustrative `result`, not a full receipt. The receipt's `kind`
remains `video` even though the result is `image/gif`. Remote v2 outputs use
UUID stems and matching metadata IDs, avoiding basename collisions across
clients. `ready` follows durable hosted publication and matching metadata;
copy **that receipt's exact `result.url`**, not `/latest` or a gallery guess.

If hosted bytes are missing or their size differs, or matching metadata is
missing, result reads report `availability: "expired"`. The receipt stays
`ready` and keeps its historical URL. This existence/size check is not a fresh
full-output integrity hash. An expired result is not clipboard-ready.

### Recovery and expiry

After a timeout, connection reset, lost reply, or proxy error, GET the **same
UUID** before sending more bytes. Resume from the returned offset, not the
client's last attempted offset. Non-JSON proxy failures are possible; do not
assume every upstream error is a receipt. Back off transient failures; fix
credentials on 401 rather than retrying indefinitely. Never silently assign
a new UUID to accepted, missing accepted, or expired work.

The spool lives at `<SSBNK_DATA_DIR>/spool`, not container `/tmp`. One serve
process owns it. Startup validates versioned journals and committed inputs,
truncates only uncommitted overlong tails, and fails closed on short/missing
input, corrupt/future journals, or conflicting prepared publication. It never
zero-fills missing bytes. Prepared output is retained for roll-forward
publication rather than re-encoded after a potentially visible commit.

Expiry is checked approximately once per minute:

- Receiving: 24 hours without **new committed bytes**, or seven days from
  creation. GET, descriptor repeats, and chunk replays do not refresh progress.
- Accepted verification/queued/processing work does not expire while active.
- Failed input: seven days from the first failure; retry does not reset this
  timestamp.
- Expired inputs are durably cleaned up, retaining permanent UUID tombstones.
  `expires_at` records tombstone creation, not a predicted deadline on every
  receiving receipt.
- Ready availability follows actual hosted retention (normally 30 days), not
  client capture time. Receipt/tombstone capacity is reserved at admission;
  records are not evicted to admit new UUIDs.

For machine-readable examples, see `clients/protocol/upload-v2.schema.json`
and `clients/protocol/fixtures/receipts.json`. The server additionally enforces
cross-field bounds such as `offset <= size`, canonical UUIDs and byte-length
basename limits; schema validation alone is not sufficient.

### Effective limits and server settings

Capabilities advertise effective limits. The defaults below are implemented
application limits, **not** a claim about the current Cloudflare/Traefik path.
Verify request-body limits and timeouts through the real route before rollout.

| Resource | Default | `SSBNK_UPLOAD_` suffixes |
| --- | --- | --- |
| Image / video input | 50 MiB / 1 GiB | `IMAGE_BYTES`, `VIDEO_BYTES` |
| Live reservation / slots / receivers | 4 GiB / 8 / 2 | `RESERVATION_BYTES`, `SLOTS`, `RECEIVERS` |
| Maximum chunk | 4 MiB | `CHUNK_BYTES` (64 KiB..4 MiB) |
| Default / minimum chunk | 1 MiB / 64 KiB non-final | Fixed minimum; default is capped by `CHUNK_BYTES` |
| Video output / per-job overhead | 128 MiB / 32 MiB | `OUTPUT_BYTES`, `OVERHEAD_BYTES` |
| Free-space floor / permanent receipt budget | 512 MiB / 64 MiB | `FREE_FLOOR_BYTES`, `RECEIPT_BYTES` |
| Source dimension / frame pixels | 8192 each / 33,177,600 | `DIMENSION`, `PIXELS` |
| GIF height / pixels at width 640 | 2560 / 1,638,400 | `RESULT_HEIGHT`, `RESULT_PIXELS` |
| Probe / conversion address space | 512 MiB / 1 GiB | `PROBE_MEMORY_BYTES`, `CONVERSION_MEMORY_BYTES` |
| Verification / conversion deadlines | 180 s / 300 s | `VERIFICATION_SECONDS`, `CONVERSION_SECONDS` |
| Persistent processing attempts | 3 | `ATTEMPTS` (maximum 3) |
| Receiving idle / absolute expiry | 86,400 s / 604,800 s | `RECEIVING_IDLE_SECONDS`, `RECEIVING_ABSOLUTE_SECONDS` |
| Failed input retention | 604,800 s | `FAILURE_SECONDS` |

Settings are positive decimal integers, validated at startup along with limit
relationships; invalid values prevent serve startup. Byte/large-integer
settings are capped at 1 TiB, memory settings require at least 64 MiB,
`OVERHEAD_BYTES` at least 32 MiB, and `RECEIPT_BYTES` at least 8 KiB. Receivers
cannot exceed slots; execution deadlines cannot exceed 86,400 seconds.
Clients also have their own fixed staging/media limits; raising a server limit
does not raise those client limits.

Admission reserves `input size + overhead`, plus the video output bound for
videos. It counts remaining unallocated reservations against filesystem free
space, with the floor above; existing hosted/archive/local/legacy data still
consumes real space. Each UUID reserves 8 KiB of permanent journal capacity.
Spool, hosted, and metadata must share a filesystem supporting hard links and
directory sync; unsuitable placement prevents startup. Reservations release
only after durable private-storage cleanup. Retention cleanup does not delete
live spool inputs.

There is one video executor and an independent image executor. Media children
have address-space/file-size bounds before exec, two-thread codec/filter
settings, bounded logs/probe output, and a monitored 16 MiB scratch bound.
Unsupported dimensions/aspect ratios fail rather than changing the GIF profile.
Origin header timeout is five seconds, body timeout 60 seconds, and v2 response
deadline 15 seconds (reset after chunk-body processing).

### v2 error responses

Request errors normally use this shape, with a current `receipt` when known:

```json
{"version":2,"error":{"code":"OFFSET_CONFLICT","message":"chunk does not append at committed offset","retryable":false},"receipt":{"...":"current receipt"}}
```

The `receipt` above is abbreviated. An expired status/chunk/complete/retry
request returns a **410 receipt directly**; an expired descriptor reservation
returns the error envelope. Asynchronous processor failures instead appear in
`error` on a `failed` receipt returned by GET with status 200.

| HTTP status | Codes / condition | Action |
| --- | --- | --- |
| 400 | `INVALID_DESCRIPTOR`, invalid UUID (`UUID_CONFLICT`), `CHUNK_CONFLICT`, `INVALID_REQUEST`, invalid `expectedAttempt` (`ATTEMPT_CONFLICT`) | Correct the request; don't change an existing immutable descriptor. |
| 401 / 503 | `UNAUTHORIZED` / `NOT_CONFIGURED` | Repair vault access/key or server authentication configuration. |
| 404 | `NOT_FOUND`, `UPLOAD_UNKNOWN` | Check API version/path; reconcile missing UUID without recreating accepted work. |
| 405 | `METHOD_NOT_ALLOWED` | Use the method listed above. |
| 409 | `UUID_CONFLICT`, `OFFSET_CONFLICT`, `STATE_CONFLICT`, `ATTEMPT_CONFLICT`, `BUSY` | GET current receipt; only `BUSY` is a transient busy response. |
| 410 | `UPLOAD_EXPIRED` or expired receipt | Preserve history; UUID is never reusable. |
| 422 | `HASH_MISMATCH` for a chunk body | Correct bytes/hash; use committed offset. |
| 503 | `BUSY`, `CAPACITY`, `STORAGE_UNAVAILABLE`, `STORAGE_UNCERTAIN` | Back off only retryable failures. Uncertain storage requires repair, not blind replay. |

Processor receipt codes include `HASH_MISMATCH`, `UNSUPPORTED_MEDIA`,
`MEDIA_RESOURCE_LIMIT`, `MEDIA_TIMEOUT`, `STORAGE_UNAVAILABLE`, and
`ATTEMPTS_EXHAUSTED`; publication conflicts fail closed. Honor the structured
`retryable` value and attempt budget rather than retrying by status alone.

## `POST /upload` (legacy compatibility)

This endpoint accepts an authenticated multipart image upload.

The request contract is:

- Header `X-Upload-Key` and `SSBNK_UPLOAD_KEY` are SHA-256 hashed, then compared
  in constant time.
- Multipart field `file` must contain PNG, JPEG, GIF, or WebP bytes.
- The file maximum is 50 MiB, with one additional MiB permitted for multipart
  overhead.
- Server-side content sniffing determines the accepted type and destination
  extension; the client filename and declared MIME type aren't trusted.

Success stores the asset and metadata, atomically publishes
`last-screenshot` and `latest-url`, and returns status 200:

```json
{
  "url": "https://ss.delo.sh/20260827-1430.png",
  "filename": "20260827-1430.png"
}
```

State publication is best-effort. A missing clipboard bridge doesn't turn a
valid upload into a failure. This endpoint remains synchronous and image-only;
it has no resumable offset, capture UUID idempotency, or video support. A lost
success reply followed by another POST can create another hosted image. New
tray clients use v2, not this endpoint. Changing v2 `IMAGE_BYTES` does not
change the legacy endpoint's fixed 50 MiB file limit.

When the v2 spool is active, legacy uploads also undergo transient storage
reservation/free-space admission and share the publication/cleanup lock.
Capacity refusal returns 503 (the admission error can be a v2 JSON envelope);
other legacy errors below are normally plain text.

The main error responses are:

| Status | Condition |
| ---: | --- |
| 400 | Invalid multipart input, missing file, or read failure |
| 401 | Upload key mismatch |
| 405 | Method other than `POST` |
| 413 | Request exceeds 51 MiB or file exceeds 50 MiB |
| 415 | Bytes aren't an accepted image type |
| 500 | Asset or metadata storage failure |
| 503 | Upload authentication isn't configured, reservation capacity is exhausted, or publication is busy |

## `GET /health`

This endpoint compares root metadata with hosted files and always returns
status 200 when the handler runs. `status` is `warning` when inconsistencies
exist and `ok` otherwise.

```json
{
  "status": "ok",
  "metadata_count": 47,
  "actual_file_count": 47,
  "timestamp": "2026-08-27T14:30:00-04:00"
}
```

`consistency_issues` appears only when the check finds missing sidecars or
missing hosted assets.

## Static routes

The same Go server handles static content:

| Path | Content |
| --- | --- |
| `/_astro/*` and `/favicon.svg` | Embedded Astro build from `SSBNK_UI_DIR` |
| Root image paths | Files from `<SSBNK_DATA_DIR>/hosted` |
| Unknown `/api/*` | JSON 404, never UI HTML |
| Other paths | Astro `index.html` fallback |

Hosted assets are root-level URLs, not `/hosted/{filename}`.
