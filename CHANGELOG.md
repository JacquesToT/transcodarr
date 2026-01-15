# Changelog

All notable changes to Transcodarr will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-01-15

### Initial Release
First public release of Transcodarr - distributed live transcoding infrastructure.

#### Features
- **Automated Installation**: Complete setup wizard voor Synology NAS + Apple Silicon Mac
- **Real-time Monitoring**: TUI dashboard met live transcoding statistieken en node management
- **rffmpeg Integration**: Naadloze integratie met Jellyfin via rffmpeg native load balancing
- **SSH-based Communication**: Veilige remote FFmpeg execution
- **Node Management**: Eenvoudig toevoegen van extra Mac nodes
- **Multi-node Configuration**: Weight-based workload distributie via rffmpeg configuratie

#### Components
- Install/uninstall scripts met volledige rollback support
- Python TUI monitor met Textual framework (real-time statistics en logs)
- Shared shell libraries voor herbruikbare functionaliteit
- Configuratie templates voor rffmpeg
- Screenshot-rijke documentatie

#### Architecture
- rffmpeg gebruikt native host selection (idle-first/LRU algoritme)
- Weight-based node prioritization via config (hogere weights = meer streams)
- Monitor toont real-time CPU, memory, en transcode status per node
- SSH-based communication voor veilige remote FFmpeg execution

#### Known Limitations
- SQLite lock issues bij 4+ simultane streams (workaround: stagger starts)
- Multi-node weight configuratie: rffmpeg distribueert sequentieel per weight, niet dynamisch
- Initial transcode start kan langer duren door node discovery

#### Supported Platforms
- Synology NAS (Jellyfin container host)
- Apple Silicon Mac (transcode nodes via Homebrew FFmpeg)

#### Requirements
- Python 3.6+ met textual>=0.47.0 en rich>=13.0.0 (voor monitor)
- Bash 4.0+
- Docker (op NAS)
- FFmpeg via Homebrew (op Mac)
- SSH access tussen systemen
- NFS mount capabilities
