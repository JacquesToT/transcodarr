# Manual Setup Guide

This guide walks you through setting up Transcodarr manually, without using the interactive installer.

---

## Overview

You need to configure two machines:

| Machine | What to do |
|---------|------------|
| **Mac** (transcode node) | Install FFmpeg, enable SSH, mount media via NFS |
| **Server** (Jellyfin host) | Configure rffmpeg, generate SSH keys, add Mac as node |

---

# Part 1: Mac Setup

## Step 1: Install Homebrew

If you don't have Homebrew yet:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, add to your path:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

## Step 2: Install FFmpeg with VideoToolbox

```bash
# Add the FFmpeg tap with extra options
brew tap homebrew-ffmpeg/ffmpeg

# Install FFmpeg with libfdk-aac (high quality AAC encoder)
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac
```

Verify it works:

```bash
# Check VideoToolbox (hardware encoding)
ffmpeg -encoders 2>/dev/null | grep videotoolbox

# Should show:
# V..... h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
# V..... hevc_videotoolbox    VideoToolbox HEVC Encoder (codec hevc)

# Check libfdk_aac
ffmpeg -encoders 2>/dev/null | grep fdk

# Should show:
# A..... libfdk_aac           Fraunhofer FDK AAC (codec aac)
```

## Step 3: Enable Remote Login (SSH)

Your server needs to connect to this Mac via SSH.

1. Open **System Settings**
2. Go to **General** → **Sharing**
3. Turn ON **Remote Login**
4. Note which users have access (your username should be listed)

Verify SSH works:

```bash
# From another computer, try:
ssh YOUR_USERNAME@YOUR_MAC_IP
```

## Step 4: Prevent Mac from Sleeping

The Mac needs to stay awake to handle transcoding jobs:

```bash
sudo pmset -a sleep 0
sudo pmset -a displaysleep 0
sudo pmset -a disksleep 0
sudo pmset -a autorestart 1
```

Verify settings:

```bash
pmset -g
```

## Step 5: Mount Media via NFS

Your Mac needs access to the same media files as Jellyfin.

### On your Synology/NAS:

1. Go to **Control Panel** → **File Services** → **NFS**
2. Enable NFS
3. Go to **Shared Folder** → Select your media folder → **Edit** → **NFS Permissions**
4. Add a rule:
   - Hostname: `*` or your Mac's IP
   - Privilege: Read-only
   - Squash: Map all users to admin

### On your Mac:

```bash
# Create mount point
sudo mkdir -p /data/media

# Test mount
sudo mount -t nfs -o resvport,rw YOUR_NAS_IP:/volume1/data/media /data/media

# Verify
ls /data/media
```

### Make it permanent (auto-mount on boot):

```bash
# Add to /etc/auto_master
sudo nano /etc/auto_master

# Add this line at the end:
/data    auto_nfs    -nobrowse

# Create /etc/auto_nfs
sudo nano /etc/auto_nfs

# Add this line:
media    -fstype=nfs,resvport,rw,soft,timeo=10    YOUR_NAS_IP:/volume1/data/media

# Restart automount
sudo automount -cv
```

---

# Part 2: Jellyfin/Server Setup

## Step 1: Generate SSH Keys

On your server, create an SSH key pair that Jellyfin will use to connect to your Mac:

```bash
# Create directory
mkdir -p /volume2/docker/jellyfin/rffmpeg/.ssh

# Generate key (no passphrase)
ssh-keygen -t ed25519 -f /volume2/docker/jellyfin/rffmpeg/.ssh/id_rsa -N "" -C "transcodarr"

# Set permissions
chmod 600 /volume2/docker/jellyfin/rffmpeg/.ssh/id_rsa
chmod 644 /volume2/docker/jellyfin/rffmpeg/.ssh/id_rsa.pub
```

## Step 2: Copy SSH Key to Mac

Copy the public key to your Mac:

```bash
# Show the public key
cat /volume2/docker/jellyfin/rffmpeg/.ssh/id_rsa.pub
```

On your Mac, add it to authorized_keys:

```bash
mkdir -p ~/.ssh
echo "PASTE_THE_PUBLIC_KEY_HERE" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

## Step 3: Create rffmpeg.yml

Create `/volume2/docker/jellyfin/rffmpeg/rffmpeg.yml`:

```yaml
# rffmpeg Configuration for Transcodarr

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
        # Your Mac username (run 'whoami' on Mac to find it)
        user: "YOUR_MAC_USERNAME"
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
        # FFmpeg paths on Mac (Homebrew on Apple Silicon)
        ffmpeg: "/opt/homebrew/bin/ffmpeg"
        ffprobe: "/opt/homebrew/bin/ffprobe"
        # Fallback to local ffmpeg if Mac is unavailable
        fallback_ffmpeg: "/usr/lib/jellyfin-ffmpeg/ffmpeg"
        fallback_ffprobe: "/usr/lib/jellyfin-ffmpeg/ffprobe"
```

## Step 4: Configure Docker Compose

### New Jellyfin Installation

Create `docker-compose.yml`:

```yaml
services:
  jellyfin:
    image: linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000                    # Your user ID (run 'id' to find it)
      - PGID=1000                    # Your group ID
      - TZ=Europe/Amsterdam          # Your timezone
      - DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg
      - FFMPEG_PATH=/usr/local/bin/ffmpeg
    volumes:
      - /volume2/docker/jellyfin:/config
      - /volume1/data/media:/data/media
    ports:
      - 8096:8096
    restart: unless-stopped
```

### Existing Jellyfin Installation

Just add these 2 lines to your `environment:` section:

```yaml
environment:
  # ... your existing variables ...
  - DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg   # ADD THIS
  - FFMPEG_PATH=/usr/local/bin/ffmpeg                # ADD THIS
```

## Step 5: Start/Restart Jellyfin

```bash
docker compose up -d
```

Wait about 30 seconds for the container to fully start and install rffmpeg.

## Step 6: Add Mac as Transcode Node

```bash
docker exec jellyfin rffmpeg add YOUR_MAC_IP --weight 2
```

Verify:

```bash
docker exec jellyfin rffmpeg status
```

You should see:

```
+------------------+--------+--------+
| Host             | State  | Weight |
+------------------+--------+--------+
| 192.168.1.50     | idle   | 2      |
+------------------+--------+--------+
```

---

# Part 3: Monitoring Setup (Optional)

Want to see CPU/memory usage of your Macs? Set up Prometheus + Grafana.

## On each Mac:

```bash
brew install node_exporter
brew services start node_exporter
```

## On your server:

Create `/volume2/docker/monitoring/docker-compose.yml`:

```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - 9090:9090
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - 3000:3000
    volumes:
      - grafana_data:/var/lib/grafana
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:
```

Create `/volume2/docker/monitoring/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'transcode-nodes'
    static_configs:
      - targets: ['YOUR_MAC_IP:9100']
        labels:
          node: 'mac-1'
      # Add more Macs:
      # - targets: ['192.168.1.51:9100']
      #   labels:
      #     node: 'mac-2'
```

Start monitoring:

```bash
cd /volume2/docker/monitoring
docker compose up -d
```

Open Grafana at `http://YOUR_SERVER_IP:3000` (login: admin/admin).

---

# Testing

1. Open Jellyfin in a browser
2. Play a video
3. Change quality to force transcoding
4. Check rffmpeg status:

```bash
docker exec jellyfin rffmpeg status
```

The state should change from "idle" to "active" when transcoding.

---

# Troubleshooting

## SSH connection fails

```bash
# Test from server:
docker exec -u abc jellyfin ssh -i /config/rffmpeg/.ssh/id_rsa YOUR_MAC_USER@YOUR_MAC_IP

# Check on Mac:
# - Is Remote Login enabled?
# - Is the SSH key in ~/.ssh/authorized_keys?
```

## Host marked as bad

```bash
docker exec -u abc jellyfin rffmpeg clear
docker exec jellyfin rffmpeg add YOUR_MAC_IP --weight 2
```

## FFmpeg not found

```bash
# On Mac, verify path:
which ffmpeg
# Should be: /opt/homebrew/bin/ffmpeg
```

## NFS mount issues

```bash
# On Mac, test mount:
sudo mount -t nfs -o resvport YOUR_NAS_IP:/volume1/data/media /data/media

# Check Synology NFS settings:
# - Is NFS enabled?
# - Does the shared folder have NFS permissions?
```
