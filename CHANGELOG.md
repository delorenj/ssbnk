# Changelog

All notable changes to ssbnk will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Native `cleanup` command with independent hosted/archive retention, locking,
  collision protection, metadata validation, and dry-run support.
- `clipboard-bridge` command backed by atomic state markers and a narrowly
  scoped Wayland sidecar.
- Dev-only Compose stack and same-origin Astro development proxy.
- Immutable multi-architecture image metadata and SHA tags in CI.

### Changed

- Consolidated the Go service, Astro frontend, cleanup, and clipboard helper
  into the canonical `delorenj/ssbnk` image.
- Moved production Compose, routing, secret injection, and scheduling policy to
  the DeLoContainers infrastructure hub.
- Updated Astro and frontend dependencies; `npm audit` reports zero known
  vulnerabilities.
- Pinned the build and local toolchain to patched Go 1.26.7 and updated the
  transitive `x/sys` dependency.

### Fixed

- Preserved content-derived PNG/JPEG/GIF/WebP extensions for watched images
  instead of relabeling every asset as PNG.
- Made watched-image and converted-video publication collision-safe and durable;
  a metadata failure now rolls back the hosted asset and leaves the source in
  place for recovery.

### Security

- Bounded upload bodies and files, rejected MIME-spoofed uploads, used a
  constant-time credential comparison, and removed partial uploads on failure.

### Removed

- Legacy Nginx/supervisor image, shell cleanup cron, mutable watcher-only image,
  X11 integration, and broad desktop-runtime mounts.

## [1.0.0] - 2025-07-14

### Added
- Initial stable release
- Complete documentation suite
- MIT License
- Contributing guidelines
- Troubleshooting guide
- API documentation

### Changed
- Renamed from "bloodbank" to "ssbnk"
- Removed personal paths and configurations
- Updated all references to use generic examples
- Improved error handling in cleanup script
- Enhanced Alpine Linux compatibility

### Fixed
- Cleanup script archiving files immediately
- Date command compatibility in Alpine Linux
- File timestamp comparison logic
- Clipboard bridge naming consistency

### Security
- Removed personal API keys and hostnames
- Added security headers to nginx configuration
- Disabled directory listing
- Custom error pages to prevent information disclosure
