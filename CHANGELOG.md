# Changelog

All notable changes to this project will be documented in this file.

## [1.0.1] - 2026-01-16

### Fixed
- Fixed bug where hardware transcoding (VideoToolbox) was not being used, system fell back to software transcoding
- VideoToolbox wrapper is now fully integrated in remote installation via lib/remote-ssh.sh

### Changed
- Removed outdated debug and documentation files
- Cleaned up codebase for better maintainability

## [1.0.0] - 2026-01-15

### Initial Release
- Distributed live transcoding for Jellyfin with Apple Silicon Macs
- Hardware-accelerated VideoToolbox encoding support
- HDR/HDR10+/Dolby Vision tone mapping via jellyfin-ffmpeg
- Automatic installation wizard for Synology NAS and Mac
- Multi-node load balancing via rffmpeg
- NFS mount configuration for media and cache
