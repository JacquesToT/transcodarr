# Mac Mini Setup Guide

Complete guide for setting up a Mac Mini as a transcode node for Transcodarr.

## Requirements

- macOS Sequoia 15.x or later
- Apple Silicon (M1, M2, M3, or M4)
- Network connection to your NAS/server
- Administrator access

## Step 1: Enable Remote Login (SSH)

1. Open **System Settings**
2. Go to **General** → **Sharing**
3. Enable **Remote Login**
4. Note which users have access (or add specific users)

Verify SSH is working:

```bash
# From another computer
ssh your-username@mac-mini-ip
```

## Step 2: Install Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

For Apple Silicon, add Homebrew to your PATH:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Verify:

```bash
brew --version
```

## Step 3: Install FFmpeg with VideoToolbox

Standard Homebrew FFmpeg lacks `libfdk-aac` (required by Jellyfin). Use the homebrew-ffmpeg tap:

```bash
# Add the tap
brew tap homebrew-ffmpeg/ffmpeg

# Install with fdk-aac support
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac
```

Verify encoders:

```bash
# Check VideoToolbox
ffmpeg -encoders 2>&1 | grep videotoolbox
# Should show: h264_videotoolbox, hevc_videotoolbox

# Check libfdk-aac
ffmpeg -encoders 2>&1 | grep fdk
# Should show: libfdk_aac
```

## Step 4: Setup Synthetic Links

macOS doesn't allow creating directories at `/` directly. Use synthetic links:

```bash
# Create the backing directories
sudo mkdir -p /System/Volumes/Data/data/media
sudo mkdir -p /System/Volumes/Data/config/cache

# Create synthetic.conf (use TAB between name and path!)
echo -e "data\tSystem/Volumes/Data/data" | sudo tee /etc/synthetic.conf
echo -e "config\tSystem/Volumes/Data/config" | sudo tee -a /etc/synthetic.conf
```

**Reboot required** for synthetic links to appear.

After reboot, verify:

```bash
ls -la /data
ls -la /config
```

## Step 5: Configure NFS Mounts

### Create mount script for media

Create `/usr/local/bin/mount-nfs-media.sh`:

```bash
sudo tee /usr/local/bin/mount-nfs-media.sh << 'EOF'
#!/bin/bash
MOUNT_POINT="/data/media"
NFS_SHARE="YOUR_NAS_IP:/volume1/data/media"
LOG_FILE="/var/log/mount-nfs-media.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Wait for network
for i in {1..30}; do
    if ping -c1 -W1 YOUR_NAS_IP >/dev/null 2>&1; then
        log "Network available after $i seconds"
        break
    fi
    sleep 1
done

# Mount if not already mounted
if ! mount | grep -q "$MOUNT_POINT"; then
    mkdir -p "$MOUNT_POINT"
    /sbin/mount -t nfs -o resvport,rw,nolock "$NFS_SHARE" "$MOUNT_POINT"
    log "NFS mounted"
fi
EOF

sudo chmod +x /usr/local/bin/mount-nfs-media.sh
```

Replace `YOUR_NAS_IP` with your actual NAS IP address.

### Create mount script for cache

Create `/usr/local/bin/mount-synology-cache.sh`:

```bash
sudo tee /usr/local/bin/mount-synology-cache.sh << 'EOF'
#!/bin/bash
MOUNT_POINT="/Users/Shared/jellyfin-cache"
NFS_SHARE="YOUR_NAS_IP:/volume2/docker/jellyfin/cache"
LOG_FILE="/var/log/mount-synology-cache.log"

mkdir -p "$MOUNT_POINT"

if ! mount | grep -q "$MOUNT_POINT"; then
    /sbin/mount -t nfs -o resvport,rw,nolock "$NFS_SHARE" "$MOUNT_POINT"
fi

# Create symlink for /config/cache
ln -sf "$MOUNT_POINT" /config/cache 2>/dev/null || true
EOF

sudo chmod +x /usr/local/bin/mount-synology-cache.sh
```

## Step 6: Create LaunchDaemons

### Media mount daemon

Create `/Library/LaunchDaemons/com.transcodarr.nfs-media.plist`:

```bash
sudo tee /Library/LaunchDaemons/com.transcodarr.nfs-media.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.transcodarr.nfs-media</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/mount-nfs-media.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
```

### Cache mount daemon

Create `/Library/LaunchDaemons/com.transcodarr.nfs-cache.plist`:

```bash
sudo tee /Library/LaunchDaemons/com.transcodarr.nfs-cache.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.transcodarr.nfs-cache</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/mount-synology-cache.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
```

### Load the daemons

```bash
sudo launchctl load /Library/LaunchDaemons/com.transcodarr.nfs-media.plist
sudo launchctl load /Library/LaunchDaemons/com.transcodarr.nfs-cache.plist
```

## Step 7: Configure Energy Settings

**Critical:** Prevent the Mac from sleeping during transcoding.

```bash
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 autorestart 1 womp 1
```

| Setting | Value | Purpose |
|---------|-------|---------|
| sleep | 0 | Never sleep |
| displaysleep | 0 | Never turn off display |
| disksleep | 0 | Never spin down disks |
| powernap | 0 | Disable Power Nap |
| autorestart | 1 | Restart after power failure |
| womp | 1 | Wake-on-LAN enabled |

Verify:

```bash
pmset -g | grep -E 'sleep|autorestart|womp'
```

## Step 8: Install Monitoring (Optional)

Install node_exporter for Prometheus monitoring:

```bash
brew install node_exporter
brew services start node_exporter
```

Metrics available at: `http://YOUR_MAC_IP:9100/metrics`

## Step 9: Add SSH Public Key

Add the SSH public key from your Jellyfin server to allow rffmpeg access:

```bash
# Create .ssh directory if it doesn't exist
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add the public key (paste from Jellyfin server)
echo "ssh-ed25519 AAAA... transcodarr" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

## Verification

### Check all mounts

```bash
mount | grep -E '/data/media|jellyfin-cache'
```

### Check services

```bash
sudo launchctl list | grep transcodarr
```

### Check FFmpeg

```bash
/opt/homebrew/bin/ffmpeg -version
/opt/homebrew/bin/ffmpeg -encoders | grep -E 'videotoolbox|fdk'
```

### Check energy settings

```bash
pmset -g
```

## Troubleshooting

### NFS mount fails

```bash
# Test manually
sudo mount -t nfs -o resvport,rw,nolock YOUR_NAS_IP:/path /data/media

# Check logs
cat /var/log/mount-nfs-media.log
```

### SSH connection refused

1. Verify Remote Login is enabled in System Settings
2. Check firewall settings (System Settings → Network → Firewall)
3. Ensure the user is allowed SSH access

### FFmpeg not found

Make sure Homebrew bin is in PATH:

```bash
export PATH="/opt/homebrew/bin:$PATH"
which ffmpeg
```

### Mac goes to sleep

Verify energy settings:

```bash
pmset -g
```

All sleep values should be 0.

### Synthetic links don't appear

1. Check `/etc/synthetic.conf` exists and has correct format
2. Reboot the Mac
3. Check for typos (must use TAB, not spaces)

## Adding to rffmpeg

Once the Mac Mini is set up, add it to rffmpeg on your Jellyfin server:

```bash
docker exec jellyfin rffmpeg add YOUR_MAC_IP --weight 2
docker exec jellyfin rffmpeg status
```

The weight determines load balancing (higher = more transcodes).
