# Transcodarr Quick Start Guide

Get distributed transcoding working in 15 minutes.

---

## What You Need

| Machine | Purpose |
|---------|---------|
| **Mac** (Apple Silicon) | Does the transcoding (M1/M2/M3/M4) |
| **Server** (Synology/NAS/PC) | Runs Jellyfin in Docker |

Both machines need to be on the same network.

---

## Step 1: Download Transcodarr

On your Mac, open Terminal and run:

```bash
# Download
git clone https://github.com/JacquesToT/Transcodarr.git
cd Transcodarr

# Make executable
chmod +x install.sh
```

---

## Step 2: Run the Installer on Your Mac

```bash
./install.sh
```

You'll see:

```
╔══════════════════════════════════════════════════╗
║                                                  ║
║         🎬 TRANSCODARR v1.0.0                   ║
║                                                  ║
║    Distributed Live Transcoding for Jellyfin    ║
║    Using Apple Silicon Macs with VideoToolbox   ║
║                                                  ║
╚══════════════════════════════════════════════════╝
```

### Choose: 🚀 First Time Setup

Then choose: **🖥️ On the Mac (that will do transcoding)**

The installer will:
1. Install Homebrew (if needed)
2. Install FFmpeg with VideoToolbox
3. Configure energy settings (prevent sleep)
4. Setup NFS mounts for media access

---

## Step 3: Generate Server Config Files

After the Mac setup completes, choose:

**🐳 Continue to Jellyfin Setup**

Enter:
- Your Mac's IP (shown automatically)
- Your Mac's username (run `whoami` to find it)
- Your server/NAS IP

This generates all config files in the `output/` folder.

---

## Step 4: Setup Your Mac for SSH Access

The installer shows a command like this. Run it **on your Mac**:

```bash
mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

Also make sure **Remote Login** is enabled:
1. System Settings → General → Sharing
2. Turn ON **Remote Login**

---

## Step 5: Copy Files to Your Server

Copy the generated files to your server:

```bash
# Create folder on server (run via SSH on server):
ssh YOUR_USER@YOUR_SERVER_IP "mkdir -p /volume2/docker/jellyfin/rffmpeg/.ssh"

# Copy files (run on Mac):
scp -r output/rffmpeg/* YOUR_USER@YOUR_SERVER_IP:/volume2/docker/jellyfin/rffmpeg/
```

---

## Step 6: Configure Jellyfin

### New Jellyfin Installation?

Copy `output/docker-compose.yml` to your server and run:

```bash
docker compose up -d
```

### Already Have Jellyfin?

Just add these 2 lines to your existing docker-compose.yml under `environment:`:

```yaml
- DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg
- FFMPEG_PATH=/usr/local/bin/ffmpeg
```

Then restart:

```bash
docker compose down && docker compose up -d
```

---

## Step 7: Add Your Mac as Transcode Node

Wait 30 seconds for Jellyfin to fully start, then run on your server:

```bash
docker exec jellyfin rffmpeg add YOUR_MAC_IP --weight 2
```

Verify it works:

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

## Step 8: Test It!

1. Open Jellyfin in a browser
2. Play a video
3. Force transcoding (change quality to something lower)
4. Check rffmpeg status - it should show "active"

```bash
docker exec jellyfin rffmpeg status
```

---

## Done! 🎉

Your Mac is now handling all transcoding for Jellyfin!

---

## Adding More Macs

Want to add a second Mac?

1. Run the installer on the new Mac
2. Choose **➕ Add Another Mac to Existing Setup**
3. Follow the prompts

---

## Troubleshooting

### "Permission denied" when SSH connecting

```bash
# On your Mac, check Remote Login is enabled:
# System Settings → General → Sharing → Remote Login

# Check the SSH key is added:
cat ~/.ssh/authorized_keys
```

### "Host marked as bad" in rffmpeg status

```bash
# Clear and re-add:
docker exec -u abc jellyfin rffmpeg clear
docker exec jellyfin rffmpeg add YOUR_MAC_IP --weight 2
```

### Mac goes to sleep

```bash
# On your Mac:
sudo pmset -a sleep 0
sudo pmset -a disablesleep 1
```

### FFmpeg not found on Mac

```bash
# On your Mac:
brew install ffmpeg
which ffmpeg  # Should show /opt/homebrew/bin/ffmpeg
```

---

## Requirements

### Mac (Transcode Node)
- macOS Sequoia 15.x or later
- Apple Silicon (M1, M2, M3, M4)
- Homebrew
- Network connection to server

### Server (Jellyfin Host)
- Docker with docker-compose
- linuxserver/jellyfin image
- Network connection to Mac

---

## Need Help?

- [Full Documentation](LIVE_TRANSCODING_GUIDE.md)
- [Prerequisites](docs/PREREQUISITES.md)
- [Issues](https://github.com/JacquesToT/Transcodarr/issues)
