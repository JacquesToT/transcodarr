# Jellyfin Setup Guide

Complete guide for setting up Jellyfin with rffmpeg for distributed transcoding.

## Prerequisites

- Docker and docker-compose installed
- Network access to Mac Mini transcode node
- SSH access configured

## Step 1: Create Directory Structure

```bash
# Create Jellyfin config directory
sudo mkdir -p /volume2/docker/jellyfin
sudo mkdir -p /volume2/docker/jellyfin/rffmpeg
sudo mkdir -p /volume2/docker/jellyfin/rffmpeg/.ssh
sudo mkdir -p /volume2/docker/jellyfin/cache
```

## Step 2: Generate SSH Key

Generate an SSH key pair for rffmpeg to connect to Mac Mini:

```bash
ssh-keygen -t ed25519 -f /volume2/docker/jellyfin/rffmpeg/.ssh/id_rsa -N "" -C "transcodarr"
chmod 600 /volume2/docker/jellyfin/rffmpeg/.ssh/id_rsa
```

Copy the public key to your Mac Mini:

```bash
cat /volume2/docker/jellyfin/rffmpeg/.ssh/id_rsa.pub
# Add this to ~/.ssh/authorized_keys on the Mac Mini
```

## Step 3: Create rffmpeg Configuration

Create `/volume2/docker/jellyfin/rffmpeg/rffmpeg.yml`:

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
        # Replace with your Mac Mini username
        user: "Your Username"
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

## Step 4: Docker Compose

Create `docker-compose.yml`:

```yaml
services:
  jellyfin:
    image: linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000                    # Your user ID
      - PGID=1000                    # Your group ID
      - TZ=Europe/Amsterdam
      - JELLYFIN_PublishedServerUrl=YOUR_SERVER_IP
      - UMASK=022
      - DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg
      - FFMPEG_PATH=/usr/local/bin/ffmpeg
    volumes:
      - /volume2/docker/jellyfin:/config
      - /volume1/data/media:/data/media
      - /volume2/docker/jellyfin/cache:/config/cache
    ports:
      - 8096:8096/tcp
      - 8920:8920/tcp
      - 7359:7359/udp
    restart: unless-stopped
```

Start the container:

```bash
docker compose up -d
```

## Step 5: Add Mac Mini Node

Wait for the container to fully start, then add your Mac Mini:

```bash
# Replace IP with your Mac Mini's IP
docker exec jellyfin rffmpeg add 192.168.1.50 --weight 2

# Verify
docker exec jellyfin rffmpeg status
```

## Step 6: Test SSH Connection

```bash
docker exec -u abc jellyfin ssh \
    -o StrictHostKeyChecking=no \
    -i /config/rffmpeg/.ssh/id_rsa \
    "Your Username@192.168.1.50" \
    "/opt/homebrew/bin/ffmpeg -version"
```

## Step 7: Configure Jellyfin Encoding Settings

In Jellyfin Dashboard → Playback → Transcoding:

| Setting | Value | Notes |
|---------|-------|-------|
| Hardware acceleration | None | rffmpeg handles this |
| Enable throttling | Yes | Builds buffer ahead |
| Throttle delay | 30 seconds | When to start buffering |
| Segment keep | 720 seconds | Keep 12 min of segments |
| H264 CRF | 23 | Lower = better quality |
| Encoder preset | auto | Let FFmpeg decide |

## Jellyfin Encoding Settings (encoding.xml)

Location: `/volume2/docker/jellyfin/encoding.xml`

Key settings:

```xml
<EncodingOptions>
    <EnableThrottling>true</EnableThrottling>
    <ThrottleDelaySeconds>30</ThrottleDelaySeconds>
    <HardwareAccelerationType>none</HardwareAccelerationType>
    <H264Crf>23</H264Crf>
    <EncoderPreset>auto</EncoderPreset>
</EncodingOptions>
```

## Troubleshooting

### rffmpeg shows "Host marked as bad"

```bash
# Clear all states
docker exec -u abc jellyfin rffmpeg clear

# Re-add the host
docker exec jellyfin rffmpeg add 192.168.1.50 --weight 2
```

### SSH permission denied

```bash
# Check key permissions
ls -la /volume2/docker/jellyfin/rffmpeg/.ssh/

# Should be:
# -rw------- id_rsa
# -rw-r--r-- id_rsa.pub

# Fix ownership
sudo chown -R 1000:1000 /volume2/docker/jellyfin/rffmpeg/.ssh/
```

### Video playback fails

Check rffmpeg logs:

```bash
docker exec jellyfin cat /config/log/rffmpeg.log | tail -50
```

Common issues:
- `libfdk_aac` not installed on Mac → Install FFmpeg with fdk-aac
- NFS mount stale → Remount on Mac Mini
- SSH connection timeout → Check firewall/network

### Fallback to localhost

If all remotes fail, rffmpeg falls back to local transcoding. Check:

1. SSH connectivity to Mac Mini
2. FFmpeg path on Mac Mini
3. NFS mounts are working

## User Bitrate Limits

For users on slow connections, set per-user limits:

1. Dashboard → Users → [username]
2. Playback → "Internet streaming bitrate limit"
3. Set appropriate limit (e.g., 8 Mbps for 1080p)

## NFS Volume Option (Advanced)

If you want Mac Mini to handle the cache, create an NFS volume:

```bash
docker volume create \
    --driver local \
    --opt type=nfs \
    --opt o=addr=192.168.1.50,rw,nolock,vers=3,soft,timeo=10,retrans=3 \
    --opt device=:/Users/Shared/jellyfin-cache \
    macmini-cache
```

The `soft,timeo=10,retrans=3` options prevent hangs if Mac Mini is unreachable.
