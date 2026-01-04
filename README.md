# Transcodarr

**Distributed Live Transcoding for Jellyfin using Apple Silicon Macs**

Offload live video transcoding from your NAS to Apple Silicon Macs with hardware-accelerated VideoToolbox encoding. Get 7-13x realtime transcoding speeds.

## What It Does

```
┌─────────────────┐         ┌─────────────────┐
│    Jellyfin     │   SSH   │   Apple Mac     │
│   (Synology)    │ ──────> │  (VideoToolbox) │
│                 │         │                 │
│  Requests       │         │  Transcodes     │
│  transcode      │         │  with hardware  │
└────────┬────────┘         └────────┬────────┘
         │                           │
         │         NFS               │
         └───────────────────────────┘
              Shared cache folder
```

## Quick Start

### On Synology (via SSH):

**First (one-time setup):**

1. Open **Control Panel** → **User & Group** → **Advanced**
2. Check **"Enable user home service"** → Apply
3. Open **Package Center** → search "Git" → Install
4. Install Homebrew + Gum (via SSH):
   ```bash
   git clone https://github.com/MrCee/Synology-Homebrew.git ~/Synology-Homebrew
   ~/Synology-Homebrew/install-synology-homebrew.sh
   # Choose option 1 (Minimal), close terminal, reconnect SSH
   brew install gum
   ```

**Then:**
```bash
git clone https://github.com/JacquesToT/Transcodarr.git ~/Transcodarr
cd ~/Transcodarr && ./install.sh
```

### On Mac (via Terminal):
```bash
git clone https://github.com/JacquesToT/Transcodarr.git ~/Transcodarr
cd ~/Transcodarr && ./install.sh
```

The installer guides you step by step through all configuration.

## Requirements

### Mac (Transcode Node)
- macOS Sequoia 15.x or later
- Apple Silicon (M1/M2/M3/M4)
- Network connection to NAS

### Server (Jellyfin Host)
- Synology NAS with Container Manager (Docker)
- Jellyfin in Docker container (linuxserver/jellyfin)
- NFS enabled

## Performance

| Input | Output | Speed |
|-------|--------|-------|
| 1080p BluRay REMUX (33 Mbps) | H.264 4 Mbps | 7.5x realtime |
| 720p video | H.264 2 Mbps | 13.8x realtime |
| 720p video | HEVC 1.5 Mbps | 12x realtime |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      Synology NAS                        │
│  ┌─────────────────┐    ┌─────────────────────────────┐ │
│  │    Jellyfin     │    │         NFS Shares          │ │
│  │   + rffmpeg     │    │  • /volume1/data/media      │ │
│  │     mod         │    │  • /volume1/.../cache       │ │
│  └────────┬────────┘    └─────────────────────────────┘ │
└───────────│─────────────────────────────────────────────┘
            │ SSH (FFmpeg commands)
            ▼
┌─────────────────────────────────────────────────────────┐
│                    Mac Mini / Mac Studio                 │
│  ┌─────────────────┐    ┌─────────────────────────────┐ │
│  │     FFmpeg      │    │       NFS Mounts            │ │
│  │  VideoToolbox   │    │  • /data/media              │ │
│  │                 │    │  • /config/cache            │ │
│  └─────────────────┘    └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Troubleshooting

### "Permission denied" SSH error
1. Check if Remote Login is enabled on Mac (System Settings → Sharing)
2. Verify the SSH key is in `~/.ssh/authorized_keys`
3. Check permissions: `chmod 600 ~/.ssh/authorized_keys`

### "Host marked as bad" in rffmpeg
```bash
docker exec jellyfin rffmpeg clear
docker exec jellyfin rffmpeg add <MAC_IP> --weight 2
```

### Mac not reachable
- Check if Mac is not sleeping
- Check firewall settings (port 22 for SSH)
- Ping test: `ping <MAC_IP>`

### NFS mount fails
1. Verify NFS service is enabled on Synology
2. Check NFS permissions on the shared folder
3. Test mount manually: `mount -t nfs <NAS_IP>:/volume1/data/media /data/media`

## Commands

### Check status
```bash
docker exec jellyfin rffmpeg status
```

### Add node
```bash
docker exec jellyfin rffmpeg add <MAC_IP> --weight 2
```

### Remove node
```bash
docker exec jellyfin rffmpeg remove <MAC_IP>
```

## Uninstall

On Mac:
```bash
cd ~/Transcodarr && ./uninstall.sh
```

## License

MIT

## Credits

- [rffmpeg](https://github.com/joshuaboniface/rffmpeg) - Remote FFmpeg wrapper
- [linuxserver/mods:jellyfin-rffmpeg](https://github.com/linuxserver/docker-mods) - Docker mod
