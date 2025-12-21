# Live Distributed Transcoding met Mac Mini's

**Doel:** Live video transcoding voor Jellyfin offloaden naar een cluster van Mac Mini's met Apple Silicon hardware acceleration (VideoToolbox).

**Status:** ✅ VOLLEDIG WERKEND - PRODUCTIE KLAAR
**Datum:** 2025-12-20
**Laatste Update:** NFS architectuur omgedraaid voor stabiliteit
**Synology IP:** 192.168.175.141
**Mac Mini M4 IP:** 192.168.175.42

---

## Inhoudsopgave

1. [Executive Summary](#executive-summary)
2. [Architectuur](#architectuur)
3. [Componenten](#componenten)
4. [Hardware Requirements](#hardware-requirements)
5. [Implementatie Details](#implementatie-details)
6. [Configuratie Bestanden](#configuratie-bestanden)
7. [Mac Mini SSD Cache Setup](#mac-mini-ssd-cache-setup)
8. [Monitoring Setup](#monitoring-setup)
9. [Beheer & Troubleshooting](#beheer--troubleshooting)
10. [Jellyfin Encoding Settings](#jellyfin-encoding-settings)
11. [Toekomstige Uitbreidingen](#toekomstige-uitbreidingen)
12. [Referenties](#referenties)

---

## Executive Summary

### Huidige Status

| Component | Status | Details |
|-----------|--------|---------|
| FFmpeg + VideoToolbox op macOS | ✅ Actief | FFmpeg 8.0.1 (homebrew) met VideoToolbox + libfdk_aac |
| SSH van Synology naar Mac Mini | ✅ Actief | ED25519 key, user "Nick Roodenrijs" |
| NFS mount Mac → Synology media | ✅ Persistent | Auto-mount via LaunchDaemon voor /data/media |
| NFS mount Mac → Synology cache | ✅ **NIEUW** | Mac Mini mount Synology cache (omgekeerde richting) |
| rffmpeg load balancing | ✅ **ACTIEF** | Mac Mini registered met weight 2 |
| Prometheus monitoring | ✅ Actief | node_exporter op Mac Mini |
| Grafana dashboard | ✅ Beschikbaar | Import JSON handmatig |
| Jellyfin transcoding | ✅ Werkt | Distributed via Mac Mini M4 |
| Mac Mini stabiliteit | ✅ **NIEUW** | Sleep uitgeschakeld, NFS watchdog actief |

### Recente Fixes (December 2025)

1. **libfdk_aac opgelost:** FFmpeg geïnstalleerd via `homebrew-ffmpeg/ffmpeg` tap met `--with-fdk-aac`
2. **NFS architectuur omgedraaid (20 dec):** Synology is nu NFS server voor cache, Mac Mini is client
3. **Jellyfin hang gefixt:** Lokale cache op Synology voorkomt stale NFS mount problemen
4. **Mac Mini stabiliteit:** Sleep=0, autorestart=1, NFS watchdog service
5. **Throttling geoptimaliseerd:** Buffer opbouw versneld (30 sec i.p.v. 180 sec)

### Performance Benchmarks (Getest op M4)

| Input | Output | Speed | Betekenis |
|-------|--------|-------|-----------|
| 1080p BluRay REMUX (33 Mbps) | H.264 4 Mbps | 7.5x realtime | 1 uur → 8 min |
| 720p test video | H.264 2 Mbps | 13.8x realtime | Zeer snel |
| 720p test video | HEVC 1.5 Mbps | 12x realtime | Zeer snel |

---

## Architectuur

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    LIVE TRANSCODING ARCHITECTUUR (v2)                        │
│                     NFS: Synology = Server, Mac = Client                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│    SYNOLOGY NAS (192.168.175.141)                                           │
│    ┌──────────────────────────────────────────────────────────────────┐     │
│    │                         Jellyfin Container                        │     │
│    │                  (linuxserver/jellyfin:latest)                   │     │
│    │                                                                   │     │
│    │    Transcoding      ┌─────────────────────────────────────┐      │     │
│    │    Request          │  LOKALE CACHE (stabiel!)            │      │     │
│    │        │            │  /volume2/docker/jellyfin/cache     │      │     │
│    │        ▼            │  └─► bind mount: /config/cache      │      │     │
│    │  ┌──────────┐       └─────────────────────────────────────┘      │     │
│    │  │ rffmpeg  │───SSH──────────────────────────────────────────┐   │     │
│    │  │ wrapper  │                                                │   │     │
│    │  └──────────┘                                                │   │     │
│    └──────────────────────────────────────────────────────────────┼───┘     │
│                                                                   │          │
│    NFS EXPORTS (Synology = Server):                              │          │
│    ├─► /volume1/data/media     (films, series)                   │          │
│    └─► /volume2/docker         (incl. jellyfin cache)            │          │
│                                                                   │          │
│    ════════════════════════════════════════════════════════════════          │
│                              │                                    │          │
│                              │ NFS Mount                         │          │
│                              ▼                                    ▼          │
│    ┌─────────────────────────────────────────────────────────────────┐      │
│    │                    MAC MINI M4 (192.168.175.42)                  │      │
│    │                                                                  │      │
│    │   NFS Mounts (Mac = Client):                                    │      │
│    │   ├─► /data/media ──────────► 192.168.175.141:/volume1/data/media│     │
│    │   └─► /config/cache ────────► 192.168.175.141:/volume2/docker/   │      │
│    │                                jellyfin/cache (symlink)          │      │
│    │                                                                  │      │
│    │   ┌────────────────┐    ┌─────────────────┐                     │      │
│    │   │    FFmpeg      │    │  VideoToolbox   │                     │      │
│    │   │    8.0.1       │───►│  H.264/HEVC     │                     │      │
│    │   │  +libfdk_aac   │    │  HW Acceleration│                     │      │
│    │   └────────────────┘    └─────────────────┘                     │      │
│    │                                                                  │      │
│    │   Services:                                                      │      │
│    │   ├─► com.jellyfin.nfs-mount      (media mount)                 │      │
│    │   ├─► com.jellyfin.synology-cache (cache mount) ◄── NIEUW       │      │
│    │   └─► com.jellyfin.nfs-watchdog   (health check)                │      │
│    │                                                                  │      │
│    │   Stabiliteit:                                                   │      │
│    │   ├─► sleep=0, disksleep=0, powernap=0                          │      │
│    │   ├─► autorestart=1 (na stroomuitval)                           │      │
│    │   └─► womp=1 (Wake-on-LAN)                                      │      │
│    │                                                                  │      │
│    │   Weight: 2  │  node_exporter :9100                             │      │
│    └─────────────────────────────────────────────────────────────────┘      │
│                                                                              │
│    DATAFLOW:                                                                 │
│    1. Jellyfin vraagt transcode via rffmpeg                                 │
│    2. rffmpeg SSH naar Mac Mini, start FFmpeg                               │
│    3. FFmpeg leest input van /data/media (NFS → Synology)                   │
│    4. FFmpeg schrijft output naar /config/cache (NFS → Synology)            │
│    5. Jellyfin leest transcode van lokale /config/cache                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Componenten

### 1. rffmpeg (Remote FFmpeg Wrapper)

**Wat het doet:**
- Vervangt de standaard FFmpeg binary met een Python wrapper
- Onderschept alle FFmpeg/FFprobe calls van Jellyfin
- Stuurt commando's via SSH naar remote hosts
- Balanceert load over meerdere hosts
- Fallback naar localhost als alle remotes falen

**Installatie:** Via linuxserver Docker mod (`linuxserver/mods:jellyfin-rffmpeg`)

### 2. Mac Mini M4 (192.168.175.42)

**Geïnstalleerde software:**
| Component | Versie | Pad |
|-----------|--------|-----|
| macOS | Sequoia 15.x | - |
| Homebrew | Latest | /opt/homebrew/bin/brew |
| FFmpeg | 7.1.1 (homebrew-ffmpeg) | /opt/homebrew/bin/ffmpeg |
| node_exporter | 1.10.2 | /opt/homebrew/bin/node_exporter |

**Configuratie:**
- SSH user: `Nick Roodenrijs`
- SSH key: ED25519 (zie /config/rffmpeg/.ssh/id_rsa)
- NFS mount (input): `/data/media` → `192.168.175.141:/volume1/data/media`
- NFS export (output): `/Users/Shared/jellyfin-cache` → Synology Docker volume
- Synthetic links: `/data` en `/config` via `/etc/synthetic.conf`
- VideoToolbox: h264_videotoolbox, hevc_videotoolbox
- Audio encoder: libfdk_aac (Fraunhofer FDK AAC)

**Stabiliteit instellingen (BELANGRIJK):**
```bash
# Energie instellingen - NOOIT slapen!
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 autorestart 1 womp 1

# Verificatie:
pmset -g
# Moet tonen: sleep=0, disksleep=0, autorestart=1
```

**Services:**
| Service | Functie | Locatie |
|---------|---------|---------|
| com.jellyfin.nfs-mount | Mount Synology media | /Library/LaunchDaemons/ |
| com.jellyfin.nfs-watchdog | Monitort NFS server elke 60s | /Library/LaunchDaemons/ |

**NFS Watchdog script:** `/usr/local/bin/nfs-watchdog.sh`
- Controleert elke 60 seconden of nfsd draait
- Herstart automatisch als nfsd crasht
- Logt naar `/var/log/nfs-watchdog.log`

### 3. Jellyfin Container

**Docker image:** `linuxserver/jellyfin:latest`
**Poorten:** 8096 (web), 8920 (HTTPS), 7359 (discovery)

**Environment variables:**
```yaml
- PUID=1032
- PGID=65537
- TZ=Europe/Amsterdam
- JELLYFIN_PublishedServerUrl=192.168.175.141
- DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg
- FFMPEG_PATH=/usr/local/bin/ffmpeg
```

---

## Implementatie Details

### Fase 1: Mac Mini Preparatie ✅

1. **SSH toegang configureren**
   ```bash
   # Remote Login aanzetten in System Preferences > Sharing
   # SSH key genereren en kopiëren
   ssh-keygen -t ed25519 -f macmini_ssh_key -C "claude-macmini-access"
   ssh-copy-id -i macmini_ssh_key.pub "Nick Roodenrijs@192.168.175.42"
   ```

2. **Homebrew installeren**
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   eval "$(/opt/homebrew/bin/brew shellenv)"
   ```

3. **FFmpeg met VideoToolbox installeren**
   ```bash
   brew install ffmpeg
   # Verificatie:
   ffmpeg -encoders | grep videotoolbox
   # Moet tonen: h264_videotoolbox, hevc_videotoolbox
   ```

4. **Synthetic links voor /data en /config**
   ```bash
   # In /etc/synthetic.conf (TAB-separated, niet spaties!):
   data	System/Volumes/Data/data
   config	System/Volumes/Data/config
   # Reboot vereist na elke wijziging
   ```

5. **NFS mount configureren**
   ```bash
   sudo mkdir -p /data/media
   sudo mount -t nfs -o resvport,rw,nolock 192.168.175.141:/volume1/data/media /data/media
   ```

### Fase 2: Persistent NFS Mount ✅

**Mount script:** `/usr/local/bin/mount-nfs-media.sh`
```bash
#!/bin/bash
MOUNT_POINT="/data/media"
NFS_SHARE="192.168.175.141:/volume1/data/media"
LOG_FILE="/var/log/mount-nfs-media.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Wait for network
for i in {1..30}; do
    if ping -c1 -W1 192.168.175.141 >/dev/null 2>&1; then
        log "Network available after $i seconds"
        break
    fi
    sleep 1
done

# Check if already mounted
if mount | grep -q "$MOUNT_POINT"; then
    log "NFS already mounted"
    exit 0
fi

# Mount NFS
/sbin/mount -t nfs -o resvport,rw,nolock "$NFS_SHARE" "$MOUNT_POINT"
```

**LaunchDaemon:** `/Library/LaunchDaemons/com.jellyfin.nfs-mount.plist`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jellyfin.nfs-mount</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/mount-nfs-media.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

### Fase 3: rffmpeg op Synology ✅

**Jellyfin compose.yaml:**
```yaml
services:
  jellyfin:
    image: linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1032
      - PGID=65537
      - TZ=Europe/Amsterdam
      - JELLYFIN_PublishedServerUrl=192.168.175.141
      - UMASK=022
      - DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg
      - FFMPEG_PATH=/usr/local/bin/ffmpeg
    volumes:
      - /volume2/docker/jellyfin:/config
      - /volume1/data/media:/data/media
      # Mac Mini SSD cache via NFS voor snelle transcoding
      - macmini-cache:/config/cache
    ports:
      - 8096:8096/tcp
      - 8920:8920/tcp
      - 7359:7359/udp
    networks:
      - traefik-network
    security_opt:
      - no-new-privileges:true
    restart: always

networks:
  traefik-network:
    external: true

volumes:
  macmini-cache:
    external: true
```

**Docker NFS Volume aanmaken (eenmalig op Synology):**
```bash
# BELANGRIJK: soft,timeo,retrans opties voorkomen dat Jellyfin hangt
# als de Mac Mini tijdelijk onbereikbaar is!
docker volume create \
  --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.175.42,rw,nolock,vers=3,soft,timeo=10,retrans=3 \
  --opt device=:/Users/Shared/jellyfin-cache \
  macmini-cache

# Opties uitleg:
# - soft: geef error bij timeout (ipv eeuwig wachten)
# - timeo=10: timeout na 1 seconde (10 × 0.1s)
# - retrans=3: probeer 3× voordat je opgeeft
```

**rffmpeg.yml:** `/volume2/docker/jellyfin/rffmpeg/rffmpeg.yml`
```yaml
rffmpeg:
    logging:
        log_to_file: true
        logfile: "/config/log/rffmpeg.log"
        debug: false

    directories:
        state: "/config/rffmpeg"
        persist: "/config/rffmpeg/persist"
        owner: abc
        group: abc

    remote:
        user: "Nick Roodenrijs"
        persist: 300
        args:
            - "-o"
            - "StrictHostKeyChecking=no"
            - "-o"
            - "UserKnownHostsFile=/dev/null"
            - "-i"
            - "/config/rffmpeg/.ssh/id_rsa"

    commands:
        ssh: "/usr/bin/ssh"
        ffmpeg: "/opt/homebrew/bin/ffmpeg"
        ffprobe: "/opt/homebrew/bin/ffprobe"
        fallback_ffmpeg: "/usr/lib/jellyfin-ffmpeg/ffmpeg"
        fallback_ffprobe: "/usr/lib/jellyfin-ffmpeg/ffprobe"
```

### Fase 4: Host Registratie ✅

```bash
# In Jellyfin container:
docker exec jellyfin rffmpeg add 192.168.175.42 --weight 2

# Verificatie:
docker exec jellyfin rffmpeg status
# Output:
# Hostname        Servername      ID  Weight  State  Active Commands
# 192.168.175.42  192.168.175.42  1   2       idle   N/A
```

### Fase 5: Synology Cache met Mac Mini NFS Mount ✅

**NIEUWE ARCHITECTUUR (December 2025):**
De originele setup (Mac Mini als NFS server → Synology) was instabiel. De nieuwe setup draait dit om:
- **Synology** = NFS server (stabieler)
- **Mac Mini** = NFS client (mount de Synology cache)

**Waarom deze verandering:**
- Synology DSM heeft een robuustere NFS implementatie dan macOS
- Voorkomt "stale NFS mount" problemen die Jellyfin lieten hangen
- Mac Mini schrijft direct naar Synology cache → Jellyfin ziet output meteen

**Architectuur:**
```
Mac Mini (FFmpeg)
      │
      │ NFS mount: 192.168.175.141:/volume2/docker/jellyfin/cache
      │            → /Users/Shared/jellyfin-cache
      ▼
      │ Symlink: /config/cache → /Users/Shared/jellyfin-cache
      │
      ▼ Schrijft transcode output
      │
Synology (/volume2/docker/jellyfin/cache)
      │
      │ Bind mount in container
      ▼
Jellyfin Container (/config/cache) ← Leest transcode output
```

**Setup op Synology:**

Synology exporteert al `/volume2/docker` via NFS (standaard DSM config).
Jellyfin gebruikt een lokale bind mount:

```bash
# Jellyfin container met lokale cache
docker run -d \
  --name jellyfin \
  -v /volume2/docker/jellyfin:/config \
  -v /volume1/data/media:/data/media \
  -v /volume2/docker/jellyfin/cache:/config/cache \
  linuxserver/jellyfin:latest
```

**Setup op Mac Mini:**

1. **Mount script aanmaken:** `/usr/local/bin/mount-synology-cache.sh`
   ```bash
   #!/bin/bash
   MOUNT_POINT="/Users/Shared/jellyfin-cache"
   NFS_SHARE="192.168.175.141:/volume2/docker/jellyfin/cache"
   LOG_FILE="/var/log/mount-synology-cache.log"

   log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

   # Wait for network
   for i in {1..30}; do
       ping -c1 -W1 192.168.175.141 >/dev/null 2>&1 && break
       sleep 1
   done

   # Mount if not already mounted
   if ! mount | grep -q "$MOUNT_POINT"; then
       /sbin/mount -t nfs -o resvport,rw,nolock "$NFS_SHARE" "$MOUNT_POINT"
       log "Mounted Synology cache"
   fi
   ```

2. **LaunchDaemon:** `/Library/LaunchDaemons/com.jellyfin.synology-cache.plist`
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
   <plist version="1.0">
   <dict>
       <key>Label</key>
       <string>com.jellyfin.synology-cache</string>
       <key>ProgramArguments</key>
       <array>
           <string>/usr/local/bin/mount-synology-cache.sh</string>
       </array>
       <key>RunAtLoad</key>
       <true/>
   </dict>
   </plist>
   ```

3. **Synthetic link (reeds aanwezig):** `/config/cache` → `/Users/Shared/jellyfin-cache`

**Verificatie:**
```bash
# Op Mac Mini - check mount
mount | grep jellyfin-cache
# Moet tonen: 192.168.175.141:/volume2/docker/jellyfin/cache on /Users/Shared/jellyfin-cache

# Test schrijven
echo "test" > /Users/Shared/jellyfin-cache/transcodes/test.txt
rm /Users/Shared/jellyfin-cache/transcodes/test.txt

# Op Synology - check of Jellyfin cache ziet
docker exec jellyfin ls -la /config/cache/transcodes/
```

---

## Configuratie Bestanden

### Locaties op Synology

```
/volume2/docker/jellyfin/
├── rffmpeg/
│   ├── rffmpeg.yml           # Hoofdconfiguratie
│   ├── rffmpeg.db            # SQLite database (hosts, processen)
│   ├── persist/              # SSH control sockets
│   └── .ssh/
│       └── id_rsa            # Private key voor Mac Mini (chmod 600)
├── log/
│   └── rffmpeg.log           # rffmpeg logs
└── cache/                    # Gemount van Mac Mini via NFS (macmini-cache volume)
    └── transcodes/           # Actieve transcode bestanden

/volume2/docker/projects/jellyfin-compose/
└── compose.yaml              # Docker compose config (zie ook dit bestand)

# Docker volume (NFS naar Mac Mini)
docker volume inspect macmini-cache
# Mountpoint: addr=192.168.175.42,rw,nolock,vers=3
# Device: :/Users/Shared/jellyfin-cache
```

### Locaties op Mac Mini

```
/usr/local/bin/
└── mount-nfs-media.sh        # NFS mount script voor /data/media

/Library/LaunchDaemons/
└── com.jellyfin.nfs-mount.plist  # Auto-mount service

/opt/homebrew/bin/
├── ffmpeg                    # FFmpeg 7.1.1 (homebrew-ffmpeg met libfdk_aac)
├── ffprobe
└── node_exporter             # Prometheus exporter

/etc/
├── synthetic.conf            # Root-level symbolic links (/data, /config)
└── exports                   # NFS exports configuratie

/var/log/
└── mount-nfs-media.log       # Mount logs

/data/media/                  # NFS mount point (input van Synology)
├── movies/
└── tv/

/config/cache/                # Symlink naar /Users/Shared/jellyfin-cache
└── transcodes/               # Transcode output directory

/Users/Shared/jellyfin-cache/ # Gedeeld via NFS naar Synology
└── transcodes/               # Actieve transcode bestanden
```

---

## Monitoring Setup

### Prometheus Configuratie

**prometheus.yml** (op Synology):
```yaml
scrape_configs:
  - job_name: 'transcode-nodes'
    static_configs:
      - targets: ['192.168.175.42:9100']
        labels:
          node: 'macmini-m4'
          chip: 'm4'
```

### Grafana Dashboard

Een dashboard JSON is beschikbaar in: `grafana-dashboard.json`

**Importeren:**
1. Open Grafana (http://192.168.175.141:4001)
2. Ga naar Dashboards → Import
3. Upload `grafana-dashboard.json`
4. Selecteer de Prometheus datasource

**Dashboard toont:**
- CPU Usage per transcode node
- Memory Usage
- Network Traffic (RX/TX)
- Node Status (UP/DOWN)
- Uptime
- CPU Cores

### node_exporter op Mac Mini

Geïnstalleerd via Homebrew en draait als service:
```bash
brew services start node_exporter
# Metrics beschikbaar op http://192.168.175.42:9100/metrics
```

---

## Beheer & Troubleshooting

### rffmpeg Commando's

```bash
# Status bekijken
docker exec jellyfin rffmpeg status

# Alle processen en states clearen (bij problemen)
docker exec -u abc jellyfin rffmpeg clear

# Logs bekijken
docker exec jellyfin cat /config/log/rffmpeg.log | tail -50

# Host toevoegen
docker exec jellyfin rffmpeg add "user@ip" --weight 2

# Host verwijderen
docker exec jellyfin rffmpeg remove hostname
```

### SSH Testen vanuit Container

```bash
docker exec -u abc jellyfin ssh -o StrictHostKeyChecking=no \
  -i /config/rffmpeg/.ssh/id_rsa \
  "Nick Roodenrijs@192.168.175.42" \
  "/opt/homebrew/bin/ffmpeg -version"
```

### Mac Mini Beheer

```bash
# SSH verbinding
ssh -i macmini_ssh_key "Nick Roodenrijs@192.168.175.42"

# Check NFS mount
mount | grep /data/media

# Herstart NFS mount
sudo /usr/local/bin/mount-nfs-media.sh

# Check FFmpeg processen
ps aux | grep ffmpeg

# Check node_exporter
brew services list | grep node_exporter
```

### Veelvoorkomende Problemen

| Probleem | Oorzaak | Oplossing |
|----------|---------|-----------|
| "Host marked as bad" | SSH connection faalt | `rffmpeg clear`, check SSH permissions |
| "Permission denied" SSH key | Verkeerde ownership | `chown abc:abc /config/rffmpeg/.ssh/id_rsa` |
| "No such file" bij transcode | NFS niet gemount | Check `/data/media` op Mac Mini |
| Fallback naar localhost | Alle remotes falen | Check SSH, check NFS, check rffmpeg status |
| "unix_listener: cannot bind" | persist directory missing | `mkdir -p /config/rffmpeg/persist` |
| **FFmpeg exit code 8** | **libfdk_aac ontbreekt** | **Installeer FFmpeg via homebrew-ffmpeg tap** |
| **FFmpeg exit code 254** | **Kan niet schrijven naar output** | **Setup Mac Mini SSD cache (zie Fase 5)** |
| Prometheus node "down" | Firewall of timeout | Check macOS firewall, wacht op retry |

### libfdk-aac Probleem (OPGELOST ✅)

**Symptoom:** FFmpeg exit code 8, video speelt niet af

**Oorzaak:** Jellyfin verwacht `libfdk_aac` audio encoder, maar standaard Homebrew FFmpeg heeft deze niet (non-free license).

**Oplossing (toegepast):** Installeer FFmpeg via homebrew-ffmpeg tap met libfdk-aac:
```bash
# Op Mac Mini:
brew tap homebrew-ffmpeg/ffmpeg
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac

# Verificatie:
ffmpeg -encoders 2>&1 | grep fdk
# Output moet tonen: libfdk_aac
```

**Na installatie:** Mac Mini weer toevoegen aan rffmpeg:
```bash
docker exec jellyfin rffmpeg add 192.168.175.42 --weight 2
```

### Exit Code 254 Probleem (OPGELOST ✅)

**Symptoom:** FFmpeg exit code 254, video speelt niet af ondanks dat Mac Mini bereikbaar is

**Oorzaak:** FFmpeg kan niet schrijven naar `/config/cache/transcodes/` omdat dit pad niet bestaat op de Mac Mini.

**Oplossing (toegepast):** Mac Mini SSD als cache gebruiken via NFS. Zie sectie "Fase 5: Mac Mini SSD Cache" voor complete setup.

### Log Locaties

| Component | Log Path |
|-----------|----------|
| rffmpeg | `/config/log/rffmpeg.log` (in Jellyfin container) |
| Jellyfin | `/volume2/docker/jellyfin/log/` |
| NFS Mount (Mac) | `/var/log/mount-nfs-media.log` |
| Prometheus | Docker logs voor prometheus container |

### NFS Cache Mount Hangt (OPGELOST ✅)

**Symptoom:** Jellyfin laadt traag, wordt uitgelogd, video's laden niet, web interface hangt na ~30 min

**Oorzaak:** De NFS mount naar Mac Mini's cache hangt (bijv. na Mac Mini reboot of netwerk glitch). Zonder `soft,timeo` opties wacht een "hard" mount EEUWIG.

**Diagnose:**
```bash
# Test of cache mount reageert (timeout = probleem)
timeout 5 sudo docker exec jellyfin ls -la /config/cache/
# Als dit HANGT of timeout geeft → NFS probleem!

# Check huidige volume opties
sudo docker volume inspect macmini-cache
# Moet bevatten: "soft,timeo=10,retrans=3"
```

**Oplossing:**
```bash
# 1. Stop en verwijder Jellyfin container
sudo docker stop jellyfin
sudo docker rm jellyfin

# 2. Verwijder oude NFS volume (kan even duren bij stale mount)
sudo docker volume rm macmini-cache

# 3. Check Mac Mini NFS server
ssh -i macmini_ssh_key "Nick Roodenrijs@192.168.175.42" "sudo nfsd status && showmount -e localhost"

# 4. Herstart Mac Mini NFS indien nodig
ssh -i macmini_ssh_key "Nick Roodenrijs@192.168.175.42" "sudo nfsd restart"

# 5. Maak nieuw NFS volume MET SOFT TIMEOUT OPTIES
sudo docker volume create \
  --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.175.42,rw,nolock,vers=3,soft,timeo=10,retrans=3 \
  --opt device=:/Users/Shared/jellyfin-cache \
  macmini-cache

# Opties uitleg:
# - soft: geef error bij timeout (ipv eeuwig wachten)
# - timeo=10: timeout na 1 seconde (10 × 0.1s)
# - retrans=3: probeer 3× voordat je opgeeft

# 6. Test volume
sudo docker run --rm -v macmini-cache:/test alpine ls -la /test

# 7. Start Jellyfin opnieuw
sudo docker run -d \
  --name jellyfin \
  --restart always \
  --security-opt no-new-privileges:true \
  --network traefik-network \
  -p 8096:8096/tcp -p 8920:8920/tcp -p 7359:7359/udp \
  -e PUID=1032 -e PGID=65537 -e TZ=Europe/Amsterdam \
  -e JELLYFIN_PublishedServerUrl=192.168.175.141 \
  -e UMASK=022 \
  -e DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg \
  -e FFMPEG_PATH=/usr/local/bin/ffmpeg \
  -v /volume2/docker/jellyfin:/config \
  -v /volume1/data/media:/data/media \
  -v macmini-cache:/config/cache \
  linuxserver/jellyfin:latest
```

**Preventie:** Zorg dat het NFS volume ALTIJD de `soft,timeo=10,retrans=3` opties heeft. Dit voorkomt dat Jellyfin hangt als de Mac Mini tijdelijk onbereikbaar is.

---

## Jellyfin Encoding Settings

### Huidige Configuratie

Bestand: `/volume2/docker/jellyfin/encoding.xml`

| Setting | Waarde | Uitleg |
|---------|--------|--------|
| EnableThrottling | true | Bouwt buffer vooruit na delay |
| ThrottleDelaySeconds | 30 | Start buffering na 30 sec |
| SegmentKeepSeconds | 720 | Houdt 12 min aan segments |
| HardwareAccelerationType | none | Gebruikt rffmpeg (Mac Mini) |
| H264Crf | 23 | Kwaliteit (lager = beter) |
| EncoderPreset | auto | FFmpeg preset |

### Adaptive Bitrate Streaming (ABR) - Limitaties

**Belangrijk:** Jellyfin heeft **GEEN automatische adaptive bitrate** zoals Netflix/YouTube.

| Netflix | Jellyfin |
|---------|----------|
| Pre-encoded meerdere kwaliteiten | On-demand transcoding |
| Detecteert bandbreedte automatisch | Gebruiker moet zelf kiezen |
| Milliseconden switch | Seconden switch (nieuwe transcode) |
| Seamless quality changes | Buffer onderbreking mogelijk |

**Gevolg voor gebruikers:**
- Als video hapert door langzaam internet → gebruiker moet **zelf** lagere kwaliteit kiezen
- Quality switch tijdens afspelen veroorzaakt korte buffer (normaal gedrag)
- Direct Stream (geen transcode) geeft beste kwaliteit maar vereist voldoende bandbreedte

**Opties voor admins:**
1. **Per-user bitrate limiet**: Dashboard → Users → [user] → Playback → "Internet streaming bitrate limit"
2. **Remote vs Local**: Aparte limieten voor thuis (LAN) vs buitenshuis (WAN)
3. **Educatie**: Gebruikers informeren over quality selector in player

### Synology Hardware Encoding

**Status:** ❌ Niet beschikbaar

De Synology DS1621+ heeft een AMD Ryzen Embedded V1500B CPU, maar:
- Geen `/dev/dri` device beschikbaar in DSM
- AMD AMF/VAAPI niet toegankelijk voor Docker
- **Daarom is Mac Mini essentieel voor snelle transcoding**

Zonder Mac Mini valt Jellyfin terug op software encoding (libx264) wat ~1x realtime is voor 1080p.

---

## Toekomstige Uitbreidingen

### Nieuwe Mac Mini Toevoegen

1. **Preparatie (op nieuwe Mac):**
   ```bash
   # Enable Remote Login in System Preferences > Sharing

   # Install Homebrew
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   eval "$(/opt/homebrew/bin/brew shellenv)"

   # Install FFmpeg en node_exporter
   brew install ffmpeg node_exporter
   brew services start node_exporter
   ```

2. **Synthetic link voor /data:**
   ```bash
   echo "data	System/Volumes/Data/data" | sudo tee /etc/synthetic.conf
   sudo reboot

   # Na reboot:
   sudo mkdir -p /System/Volumes/Data/data/media
   ```

3. **NFS Mount setup:**
   ```bash
   # Kopieer mount script en LaunchDaemon van huidige Mac
   # Pas IP aan indien nodig
   sudo launchctl load /Library/LaunchDaemons/com.jellyfin.nfs-mount.plist
   ```

4. **SSH Key (op development machine):**
   ```bash
   ssh-keygen -t ed25519 -f macminiX_ssh_key -C "macmini-X-access"
   ssh-copy-id -i macminiX_ssh_key.pub user@IP

   # Kopieer private key naar Jellyfin container
   cat macminiX_ssh_key | ssh ssh@synology "cat > /tmp/key"
   # Dan in container kopiëren naar /config/rffmpeg/.ssh/
   ```

5. **Registreer bij rffmpeg:**
   ```bash
   docker exec jellyfin rffmpeg add "user@IP" --weight 2
   ```

6. **Prometheus configuratie uitbreiden:**
   ```yaml
   - job_name: 'transcode-nodes'
     static_configs:
       - targets: ['192.168.175.42:9100', 'NEW_IP:9100']
         labels:
           node: 'macmini-m4'
   ```

---

## Referenties

### Officiële Documentatie

- [rffmpeg GitHub](https://github.com/joshuaboniface/rffmpeg)
- [Jellyfin Hardware Acceleration - Apple](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/apple/)
- [LinuxServer Jellyfin rffmpeg Mod](https://github.com/linuxserver/docker-mods/tree/jellyfin-rffmpeg)
- [Prometheus node_exporter](https://github.com/prometheus/node_exporter)

### VideoToolbox Encoders

```bash
# H.264 encoding
ffmpeg -i input.mkv -c:v h264_videotoolbox -b:v 8M -c:a aac output.mp4

# HEVC encoding
ffmpeg -i input.mkv -c:v hevc_videotoolbox -b:v 6M -c:a aac output.mp4

# HLS streaming (voor live)
ffmpeg -i input.mkv -c:v h264_videotoolbox -b:v 8M -f hls -hls_time 2 output.m3u8
```

---

## Snelle Referentie

### SSH Verbindingen

```bash
# Mac Mini M4
ssh -i macmini_ssh_key "Nick Roodenrijs@192.168.175.42"

# Synology
ssh -i synology_ssh_key ssh@192.168.175.141
```

### Docker Commando's (op Synology)

```bash
# Jellyfin restart
sudo docker restart jellyfin

# Jellyfin logs
sudo docker logs jellyfin | tail -50

# rffmpeg status
sudo docker exec jellyfin rffmpeg status

# rffmpeg clear (reset bad states)
sudo docker exec -u abc jellyfin rffmpeg clear
```

### Mac Mini Control

```bash
# Check FFmpeg
/opt/homebrew/bin/ffmpeg -encoders | grep videotoolbox

# Check NFS mounts (beide moeten actief zijn!)
mount | grep -E '/data/media|jellyfin-cache'
# Verwacht:
# 192.168.175.141:/volume1/data/media on /data/media
# 192.168.175.141:/volume2/docker/jellyfin/cache on /Users/Shared/jellyfin-cache

# Restart media mount
sudo /usr/local/bin/mount-nfs-media.sh

# Restart cache mount (NIEUW)
sudo /usr/local/bin/mount-synology-cache.sh

# Check alle Jellyfin services
sudo launchctl list | grep jellyfin
# Moet tonen: nfs-mount, synology-cache, nfs-watchdog

# Energie instellingen (moet allemaal 0 zijn behalve autorestart/womp)
pmset -g | grep -E 'sleep|autorestart|womp'

# node_exporter status
brew services list | grep node_exporter
```

### Prometheus/Grafana

- Prometheus: http://192.168.175.141:9090
- Grafana: http://192.168.175.141:4001
- Mac Mini metrics: http://192.168.175.42:9100/metrics

---

**Document Version:** 4.0
**Last Updated:** 2025-12-20
**Author:** Claude Code
**Status:** ✅ Fully Working - Production Ready

**Changelog:**
- v4.0 (2025-12-20): **MAJOR** NFS architectuur omgedraaid - Synology is nu NFS server, Mac Mini is client
  - Jellyfin hang probleem opgelost (stale NFS mount)
  - Mac Mini stabiliteit verbeterd (sleep=0, watchdog service)
  - Nieuwe LaunchDaemon: com.jellyfin.synology-cache
  - Architectuur diagram volledig herschreven
- v3.1 (2025-12-19): Throttling geoptimaliseerd (30s), NFS troubleshooting, ABR limitaties gedocumenteerd
- v3.0 (2025-12-19): libfdk-aac fix, Mac Mini SSD cache via NFS, volledig werkend
- v2.1 (2025-12-19): Troubleshooting toegevoegd, rffmpeg tijdelijk uitgeschakeld
- v2.0 (2025-12-18): rffmpeg configuratie, monitoring setup
- v1.0 (2025-12-17): Initiële documentatie
