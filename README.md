# Transcodarr

**Distributed Live Transcoding for Jellyfin using Mac Mini's with Apple Silicon**

Offload live video transcoding from your NAS/server to Mac Mini's with hardware-accelerated VideoToolbox encoding. Get 7-13x realtime transcoding speeds with Apple Silicon.

## Features

- **Hardware Acceleration**: Uses Apple Silicon VideoToolbox (H.264/HEVC)
- **Distributed Transcoding**: Offload transcoding from your NAS to Mac Mini's
- **Load Balancing**: Distribute workload across multiple Mac Mini's
- **Automatic Fallback**: Falls back to local transcoding if Mac Mini is unavailable
- **Easy Setup**: Interactive installer with step-by-step guidance
- **Monitoring**: Prometheus + Grafana dashboard included

## Performance

| Input | Output | Speed |
|-------|--------|-------|
| 1080p BluRay REMUX (33 Mbps) | H.264 4 Mbps | 7.5x realtime |
| 720p video | H.264 2 Mbps | 13.8x realtime |
| 720p video | HEVC 1.5 Mbps | 12x realtime |

## Requirements

### Mac Mini (Transcode Node)
- macOS Sequoia 15.x or later
- Apple Silicon (M1/M2/M3/M4)
- Network connection to NAS

### Server (Jellyfin Host)
- Docker with docker-compose
- NFS server capability (for media sharing)
- Network connection to Mac Mini

## Quick Start

### 1. Install Gum (required for installer UI)

```bash
brew install gum
```

### 2. Clone the repository

```bash
git clone https://github.com/yourusername/transcodarr.git
cd transcodarr
```

### 3. Run the installer

```bash
./install.sh
```

The interactive installer will guide you through:
- Mac Mini setup (FFmpeg, NFS, LaunchDaemons)
- Jellyfin/Docker configuration (rffmpeg, SSH keys)
- Monitoring setup (Prometheus/Grafana)

## Manual Setup

See the full setup guide: [LIVE_TRANSCODING_GUIDE.md](LIVE_TRANSCODING_GUIDE.md)

### Mac Mini Quick Setup

```bash
# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install FFmpeg with VideoToolbox + libfdk-aac
brew tap homebrew-ffmpeg/ffmpeg
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac

# Verify
ffmpeg -encoders | grep videotoolbox
ffmpeg -encoders | grep fdk

# Prevent sleep
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 autorestart 1
```

### Jellyfin Quick Setup

```yaml
# docker-compose.yml
services:
  jellyfin:
    image: linuxserver/jellyfin:latest
    environment:
      - DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg
      - FFMPEG_PATH=/usr/local/bin/ffmpeg
    volumes:
      - /path/to/config:/config
      - /path/to/media:/data/media
```

```bash
# Add Mac Mini to rffmpeg
docker exec jellyfin rffmpeg add 192.168.1.50 --weight 2
docker exec jellyfin rffmpeg status
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    TRANSCODARR                           │
├─────────────────────────────────────────────────────────┤
│                                                          │
│   SERVER (Synology/Docker)         MAC MINI (M1/M4)     │
│   ┌──────────────────┐            ┌──────────────────┐  │
│   │    Jellyfin      │            │     FFmpeg       │  │
│   │    Container     │───SSH────▶│   VideoToolbox   │  │
│   │    + rffmpeg     │            │   H.264/HEVC     │  │
│   └────────┬─────────┘            └────────┬─────────┘  │
│            │                               │            │
│            │         NFS                   │            │
│            ▼                               ▼            │
│   ┌──────────────────────────────────────────────────┐  │
│   │              Media & Cache Storage               │  │
│   └──────────────────────────────────────────────────┘  │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## File Structure

```
transcodarr/
├── install.sh              # Interactive installer
├── lib/
│   ├── mac-setup.sh        # Mac Mini setup module
│   └── jellyfin-setup.sh   # Jellyfin/Docker setup module
├── scripts/
│   ├── add-mac-node.sh     # Add Mac Mini to rffmpeg
│   └── test-ssh.sh         # Test SSH connection
├── rffmpeg/
│   └── rffmpeg.yml         # rffmpeg configuration template
├── docs/
│   ├── MAC_SETUP.md        # Detailed Mac setup guide
│   └── JELLYFIN_SETUP.md   # Detailed Jellyfin guide
├── grafana-dashboard.json  # Grafana monitoring dashboard
└── docker-compose.yml      # Generated Docker Compose
```

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| SSH connection fails | Check Remote Login is enabled on Mac |
| Video doesn't play | Verify libfdk-aac is installed |
| Transcoding is slow | Check if using hardware encoder |
| NFS mount hangs | Use `soft,timeo=10` mount options |

### Useful Commands

```bash
# Check rffmpeg status
docker exec jellyfin rffmpeg status

# Clear bad host state
docker exec -u abc jellyfin rffmpeg clear

# Test SSH from container
docker exec -u abc jellyfin ssh -i /config/rffmpeg/.ssh/id_rsa user@mac-ip

# Check FFmpeg on Mac
/opt/homebrew/bin/ffmpeg -encoders | grep videotoolbox
```

## Monitoring

Import the included Grafana dashboard (`grafana-dashboard.json`) to monitor:
- CPU usage per transcode node
- Memory usage
- Network traffic
- Node status (UP/DOWN)

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [rffmpeg](https://github.com/joshuaboniface/rffmpeg) - Remote FFmpeg wrapper
- [Gum](https://github.com/charmbracelet/gum) - Terminal UI toolkit
- [LinuxServer.io](https://linuxserver.io) - Jellyfin Docker image with rffmpeg mod
