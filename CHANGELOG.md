# Changelog

All notable changes to ssbnk will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release of ssbnk (ScreenShot Bank)
- Automatic screenshot detection and hosting
- Cross-platform clipboard support (X11 and Wayland)
- Smart cleanup with configurable retention
- Docker Compose deployment
- Traefik integration with automatic TLS
- Comprehensive documentation

### Features
- 📸 Instant screenshot hosting via HTTPS
- 📋 Automatic URL copying to clipboard
- 🗑️ Smart cleanup with daily archiving
- 🖥️ Display server agnostic (X11/Wayland)
- 🔒 Secure by default with reverse proxy
- 🐳 Containerized deployment
- ⚡ Lightning-fast Go-powered file watcher
- 🎯 Zero configuration setup

### Technical Details
- Go-based file watcher with fsnotify
- Nginx static file serving with optimized caching
- Alpine Linux containers for minimal footprint
- Automatic display server detection
- Multiple clipboard access methods with fallbacks
- Metadata tracking for all screenshots
- Configurable retention policies

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
