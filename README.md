# Transcodarr

**Distributed Live Transcoding for Jellyfin using Apple Silicon Macs**

Offload live video transcoding from your NAS to Apple Silicon Macs with hardware-accelerated VideoToolbox encoding.

> ⚠️ **Backup First!** Before proceeding, backup your Jellyfin configuration folder and docker-compose file.

---

## Security Considerations

This project creates network pathways between your NAS and Mac(s). Understand the risks:

| Risk | Description |
|------|-------------|
| **SSH keys in container** | Private key stored in Jellyfin container. If container is compromised, attacker has SSH access to all Mac nodes. |
| **Remote code execution** | Jellyfin can execute FFmpeg commands on Mac nodes. Compromised Jellyfin = arbitrary code execution on Macs. |
| **NFS "Map all to admin"** | Default NFS config maps all connections to admin. Compromised Mac = full read (or write for cache) access. |
| **NFS open to network** | Default NFS permissions allow any IP (`*`). Restrict to Mac IP(s) for better security. |
| **Sudo on Mac** | Installer requires root access for mount points, LaunchDaemons, and energy settings. |
| **Sleep disabled** | Mac sleep is disabled, increasing exposure time. |
| **NFS at folder level** | Synology NFS permissions are set per shared folder, not subfolders. Enabling NFS on `docker` exposes the entire folder. |

**Recommendations:**
- Use a dedicated user account on Mac nodes
- Restrict NFS permissions to specific Mac IPs instead of `*`
- Create dedicated shared folders for media/cache instead of exposing `docker`
- Keep Jellyfin and Docker updated
- Use a firewall to limit access to NFS ports

---

*This project was 95% built with [Claude Code](https://claude.com/claude-code).*

---

## How It Works

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
              Shared media & cache
```

## Requirements

**Synology NAS:**
- Docker / Container Manager
- NFS enabled
- Jellyfin using `linuxserver/jellyfin` image (required for rffmpeg)

**Mac (Apple Silicon):**
- M1/M2/M3/M4
- macOS Sequoia 15.x or later
- Remote Login (SSH) enabled

## Before You Start

Collect these values:

| What | Example | Where to find |
|------|---------|---------------|
| **Synology IP** | `192.168.1.100` | Control Panel → Network |
| **Mac IP** | `192.168.1.50` | System Settings → Network |
| **Mac Username** | `user_name` | Terminal: `whoami` |
| **Media Path** | `/volume1/data/media` | File Station → Right-click → Properties |
| **Jellyfin Config** | `/volume1/docker/jellyfin` | Your docker-compose volume |

---

## Step 1: Enable Remote Login on your Mac

1. Open **System Settings** → **General** → **Sharing**
2. Enable **"Remote Login"**

---

## Step 2: Setup Jellyfin

Create or update your Jellyfin container with rffmpeg support:

```yaml
services:
  jellyfin:
    image: linuxserver/jellyfin
    container_name: jellyfin
    environment:
      - PUID=1026                                      # Your user ID (run: id)
      - PGID=100                                       # Your group ID (run: id)
      - TZ=Europe/Amsterdam                            # Your timezone
      - JELLYFIN_PublishedServerUrl=192.168.1.100     # Your Synology IP
      - DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg # Required for remote transcoding
      - FFMPEG_PATH=/usr/local/bin/ffmpeg             # Required for rffmpeg
    volumes:
      - /volume1/docker/jellyfin:/config
      - /volume1/data/media:/data/media
      - /volume1/docker/jellyfin/cache:/cache         # Transcode cache (needs NFS)
    ports:
      - 8096:8096/tcp
      - 7359:7359/udp
    network_mode: bridge
    security_opt:
      - no-new-privileges:true
    restart: always
```

> **Note:** Find your PUID/PGID by running `id` in SSH on your Synology.

### Fix Permissions (if Jellyfin won't start)

If Jellyfin fails to start, fix the folder permissions:

```bash
# Stop the container
sudo docker stop jellyfin

# Fix ownership (replace 1026:100 with your PUID:PGID)
sudo chown -R 1026:100 /volume1/docker/jellyfin
sudo chmod -R 755 /volume1/docker/jellyfin

# Verify - should show your user and "users" group
ls -la /volume1/docker/jellyfin

# Start container
sudo docker start jellyfin
```

> ⏳ **FFmpeg takes a while to install** (compiling from source). Be patient and make sure Jellyfin is started before running the installer.

---

## Step 3: Configure NFS on your Synology

### Enable User Home Service

1. Open **Control Panel** → **User & Group** → **Advanced**
2. Check **"Enable user home service"**
3. Click **Apply**

### Enable NFS Service

1. Open **Control Panel** → **File Services** → **NFS**
2. Check **"Enable NFS service"**
3. Set Maximum NFS protocol to **NFSv4.1**
4. Click **Apply**

### Set NFS Permissions

> **Note:** Synology NFS permissions work at the **shared folder level**, not subfolders. You need to enable NFS on the parent shared folders (`data` and `docker`), or create dedicated shared folders for more granular control.

Go to **Control Panel** → **Shared Folder**, select each shared folder, click **Edit** → **NFS Permissions** → **Create**:

| Shared Folder | Privilege | Squash |
|---------------|-----------|--------|
| `data` (contains your media) | Read Only | Map all users to admin |
| `docker` (contains jellyfin/cache) | **Read/Write** | Map all users to admin |

**For both folders, also enable:**
- ✓ Allow connections from non-privileged ports
- ✓ Allow users to access mounted subfolders

> **Tip:** For better security, create a dedicated shared folder (e.g., `jellyfin-cache`) instead of exposing the entire `docker` folder via NFS.

---

## Step 4: Install Git on your Synology

1. Open **Package Center**
2. Search for **"Git"**
3. Click **Install**

---

## Step 5: Install Homebrew on your Synology

Synology requires a special version of Homebrew:

```bash
git clone https://github.com/MrCee/Synology-Homebrew.git ~/Synology-Homebrew
~/Synology-Homebrew/install-synology-homebrew.sh
```

When prompted, select **option 1 (Minimal installation)**.

After installation:
```bash
brew install gum
```

Then **close your terminal, reconnect via SSH**, and continue to the next step.

---

## Step 6: Install Transcodarr

SSH into your Synology and run:

```bash
git clone https://github.com/JacquesToT/Transcodarr.git ~/Transcodarr
cd ~/Transcodarr && ./install.sh
```

The installer will:
1. Connect to your Mac via SSH
2. Install Homebrew and FFmpeg with VideoToolbox
3. Create mount points and configure NFS
4. Handle Mac reboot if needed
5. Register the Mac with rffmpeg

**That's it!** Start a video in Jellyfin and watch it transcode on your Mac.

---

## Adding Another Mac

To add more Macs to your transcoding cluster:

> **Important:** All Macs must use the **same username** for SSH.
> rffmpeg uses a single SSH user configuration for all nodes.

1. Enable **Remote Login** on the new Mac (System Settings → Sharing)
2. Run the installer on your Synology: `cd ~/Transcodarr && ./install.sh`
3. Select **"➕ Add a new Mac node"**

The installer will configure everything automatically.

---

## Commands

### Check status
```bash
docker exec jellyfin rffmpeg status
```

### Add node manually
```bash
docker exec jellyfin rffmpeg add <MAC_IP> --weight 2
```

### Remove node
```bash
docker exec jellyfin rffmpeg remove <MAC_IP>
```

### Clear bad host status
```bash
docker exec jellyfin rffmpeg clear
```

---

## Troubleshooting

### "Permission denied" SSH error
1. Check Remote Login is enabled on Mac (System Settings → Sharing)
2. Run **"Fix SSH Keys"** from the installer menu
3. Verify permissions: `chmod 600 ~/.ssh/authorized_keys`

### "Host marked as bad" in rffmpeg
```bash
docker exec jellyfin rffmpeg clear
docker exec jellyfin rffmpeg status
```

### NFS mount fails on Mac
1. Verify NFS is enabled on Synology
2. Check NFS permissions include "non-privileged ports"
3. Test manually: `sudo mount -t nfs <NAS_IP>:/volume1/data/media /data/media`

### Mac not reachable
- Ensure Mac is not sleeping (Energy settings)
- Check firewall allows SSH (port 22)
- Test: `ping <MAC_IP>`

---

## Installer Menu Reference

### Fix SSH Keys

Repairs SSH key authentication between Jellyfin and Mac nodes:
1. Checks the SSH key in the container has correct permissions
2. Tests SSH connectivity to each registered Mac
3. Reinstalls keys where authentication is failing

**Use when:** rffmpeg shows connection errors, after recreating the Jellyfin container, or after restoring from backup.

### Configure Monitor

Configures SSH settings for the Transcodarr Monitor (TUI dashboard):
- **NAS IP** - Your Synology's IP address
- **NAS User** - SSH username for the Synology

---

## Performance

| Input | Output | Speed |
|-------|--------|-------|
| 1080p BluRay (33 Mbps) | H.264 4 Mbps | ~7x realtime |
| 720p video | H.264 2 Mbps | ~13x realtime |

---

## Tested On

**Synology NAS:**
- DS1821+
- DS916+

**Mac (Apple Silicon):**
- Mac mini M1
- Mac mini M4
- Mac Studio M4

---

## License

MIT

## Credits

- [rffmpeg](https://github.com/joshuaboniface/rffmpeg) - Remote FFmpeg wrapper
- [linuxserver/mods:jellyfin-rffmpeg](https://github.com/linuxserver/docker-mods) - Docker mod
