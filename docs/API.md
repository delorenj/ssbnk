# Legacy API document

This filename is retained so older links don't break. It previously described
the retired Nginx layout and `/hosted/{filename}` routes.

Use the current [HTTP API contract](./api-contracts-watcher.md). Hosted assets
now use root-level URLs, and the Go service directly provides upload, gallery,
health, latest, hybrid, and stateless endpoints.
