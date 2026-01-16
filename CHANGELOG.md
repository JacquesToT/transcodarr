# Changelog

Alle belangrijke wijzigingen aan dit project worden gedocumenteerd in dit bestand.

## [1.0.1] - 2026-01-16

### Bugfixes
- Opgelost: Hardware transcoding (VideoToolbox) werd niet gebruikt, systeem viel terug op software transcoding
- VideoToolbox wrapper is nu volledig geïntegreerd in de remote installatie via lib/remote-ssh.sh

### Verbeteringen
- Verwijderde oude debug en documentatie bestanden
- Opgeschoonde codebase voor betere onderhoudbaarheid

## [1.0.0] - 2026-01-15

### Eerste release
- Distributed live transcoding voor Jellyfin met Apple Silicon Macs
- Hardware-accelerated VideoToolbox encoding support
- HDR/HDR10+/Dolby Vision tone mapping via jellyfin-ffmpeg
- Automatische installatie wizard voor Synology NAS en Mac
- Multi-node load balancing via rffmpeg
- NFS mount configuratie voor media en cache
