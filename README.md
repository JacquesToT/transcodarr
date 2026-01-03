# Transcodarr

**Distributed Live Transcoding voor Jellyfin met Apple Silicon Macs**

Offload live video transcoding van je NAS naar Apple Silicon Macs met hardware-accelerated VideoToolbox encoding. Krijg 7-13x realtime transcoding snelheden.

## Wat Het Doet

```
┌─────────────────┐         ┌─────────────────┐
│    Jellyfin     │   SSH   │   Apple Mac     │
│   (Synology)    │ ──────> │  (VideoToolbox) │
│                 │         │                 │
│  Vraagt om      │         │  Transcodeert   │
│  transcode      │         │  met hardware   │
└────────┬────────┘         └────────┬────────┘
         │                           │
         │         NFS               │
         └───────────────────────────┘
              Gedeelde cache folder
```

## Quick Start

### Op Synology (via SSH):

**Eerst (eenmalig):** Installeer Git via Package Center als je dat nog niet hebt.

1. Open **Control Panel** → **User & Group** → **Advanced**
2. Vink **"Enable user home service"** aan → Apply
3. Open **Package Center** → zoek "Git" → Install

**Dan:**
```bash
git clone https://github.com/JacquesToT/Transcodarr.git ~/Transcodarr
cd ~/Transcodarr && ./install.sh
```

### Op Mac (via Terminal):
```bash
git clone https://github.com/JacquesToT/Transcodarr.git ~/Transcodarr
cd ~/Transcodarr && ./install.sh
```

De installer begeleidt je stap voor stap door alle configuratie.

## Vereisten

### Mac (Transcode Node)
- macOS Sequoia 15.x of later
- Apple Silicon (M1/M2/M3/M4)
- Netwerkverbinding met NAS

### Server (Jellyfin Host)
- Synology NAS met Container Manager (Docker)
- Jellyfin in Docker container (linuxserver/jellyfin)
- NFS ingeschakeld

## Performance

| Input | Output | Snelheid |
|-------|--------|----------|
| 1080p BluRay REMUX (33 Mbps) | H.264 4 Mbps | 7.5x realtime |
| 720p video | H.264 2 Mbps | 13.8x realtime |
| 720p video | HEVC 1.5 Mbps | 12x realtime |

## Architectuur

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
1. Check of Remote Login aan staat op Mac (System Settings → Sharing)
2. Controleer of de SSH key in `~/.ssh/authorized_keys` staat
3. Check permissies: `chmod 600 ~/.ssh/authorized_keys`

### "Host marked as bad" in rffmpeg
```bash
docker exec jellyfin rffmpeg clear
docker exec jellyfin rffmpeg add <MAC_IP> --weight 2
```

### Mac niet bereikbaar
- Check of Mac niet in slaapstand gaat
- Controleer firewall instellingen (poort 22 voor SSH)
- Ping test: `ping <MAC_IP>`

### NFS mount faalt
1. Controleer of NFS service aan staat op Synology
2. Check NFS permissions op de shared folder
3. Test mount handmatig: `mount -t nfs <NAS_IP>:/volume1/data/media /data/media`

## Commando's

### Status bekijken
```bash
docker exec jellyfin rffmpeg status
```

### Node toevoegen
```bash
docker exec jellyfin rffmpeg add <MAC_IP> --weight 2
```

### Node verwijderen
```bash
docker exec jellyfin rffmpeg remove <MAC_IP>
```

## Uninstall

Op Mac:
```bash
cd ~/Transcodarr && ./uninstall.sh
```

## License

MIT

## Credits

- [rffmpeg](https://github.com/joshuaboniface/rffmpeg) - Remote FFmpeg wrapper
- [linuxserver/mods:jellyfin-rffmpeg](https://github.com/linuxserver/docker-mods) - Docker mod
