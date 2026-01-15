# Transcodarr

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)

**Distributed Live Transcoding for Jellyfin using Apple Silicon Macs**

Offload live video transcoding from your NAS to Apple Silicon Macs with hardware-accelerated VideoToolbox encoding.

> ⚠️ **Backup First!** Before proceeding, backup your Jellyfin configuration folder and docker-compose file.

Tested on a DS1821+ Synology, DSM 7.3.2-86009
Mac mini M1, Mac mini M4, Mac Studio M4.
Test video:
  -  Native 4K UHD (not upscaled)
  -  HDR10 with wide color gamut
  -  10-bit color depth
  -  Dolby Atmos immersive audio
  -  Lossless video and audio (REMUX)
  -  Multiple audio tracks + subtitles
  
<table>
<tr>
<td align="center">
<img src="screenshots/Schermafbeelding 2026-01-15 13.21.11.png" width="100%"><br>
<small><i>Original (auto quality)</i></small>
</td>
<td align="center">
<img src="screenshots/Schermafbeelding 2026-01-15 13.31.16.png" width="100%"><br>
<small><i>No Transcodarr - 11 fps transcode frames</i></small>
</td>
<td align="center">
<img src="screenshots/Schermafbeelding 2026-01-15 13.23.54.png" width="100%"><br>
<small><i>With Transcodarr - 70 fps transcode frames</i></small>
</td>
</tr>
</table>  
Tested on de mac mini M1 - 8 cores - 16gb ram 

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
| **World-Writable Cache** | The script sets `chmod 777` on the `transcodes` directory. Any user on the system (Mac or NAS) can read/write/delete these files. |
| **MITM Vulnerability** | SSH connections use `StrictHostKeyChecking=no`. If an attacker spoofs the Mac's IP, the script will connect without warning. |
| **Piping to Bash** | The script executes downloaded code directly (`curl ... | bash`), which bypasses local inspection. |
| **Unverified Downloads** | External scripts (Homebrew) and binaries (FFmpeg) are downloaded without checksum verification. |
| **No Uninstaller** | There is no automatic rollback or uninstall feature. System changes (LaunchDaemons, synthetic.conf) must be reverted manually. |

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
---
**Known Limitations:**
- rffmpeg uses SQLite to track active transcoding jobs. Starting 4+ streams at the exact same moment can cause database lock conflicts, resulting in nodes being marked as "bad" and streams falling back to localhost or will not start.
- Loading times can be long
- **Multi-node weight configuration:** rffmpeg doesn't actively load balance based on current CPU usage. It distributes transcodes sequentially, roughly following the weight ratio. If both nodes have equal weight but different capabilities, the slower Mac may become overloaded while the faster one sits idle, resulting in stuttering video. **Recommendation:** Give your faster Mac a higher weight (e.g., M4 = weight 4, M1 = weight 2).

---
## Requirements

**Synology NAS:**
- Docker / Container Manager
- NFS enabled
- Jellyfin using `linuxserver/jellyfin` image (required for rffmpeg)

**Mac (Apple Silicon):**
- M1/M2/M3/M4
- macOS Sequoia 15.x or later

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

## Step 1.1: Enable Remote Login on your Mac

1. Open **System Settings** → **General** → **Sharing**
2. Enable **"Remote Login"**
<img src="screenshots/Schermafbeelding 2026-01-15 11.37.46 copy.png" width="25%">


Open the terminal and install homebrew:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```
And then install gum:
```bash
brew install gum
```
## Step 1.2: Enable SSH login on your Synology
Go to DSM

1. Open **Control Panel** → **Terminal & SNMP**
2. Enable **"SSH Service"**
<img src="screenshots/Schermafbeelding 2026-01-15 11.33.58.png" width="50%">
---

## Step 2: Setup Jellyfin

Create or update your Jellyfin container with rffmpeg support:

```yaml
services:
  jellyfin:
    image: linuxserver/jellyfin
    container_name: jellyfin
    environment:
      - PUID=1026                                     # Your user ID (run: id)
      - PGID=100                                      # Your group ID (run: id)
      - TZ=Europe/Amsterdam                           # Your timezone
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

Start the container and wait for FFmpeg to install.
(can take a while, for me it took about 8 minutes)

Now check if Jellyfin will start
### Fix Permissions (if Jellyfin won't start)

If Jellyfin fails to start, fix the folder permissions:
Login through SSH on your Synology and run the following commands:

```bash
# Stop the container
sudo docker stop jellyfin

# Fix ownership (replace 1026:100 with your PUID:PGID, and the correct paths)
sudo chown -R 1026:100 /volume1/docker/jellyfin
sudo chmod -R 755 /volume1/docker/jellyfin
sudo chmod -R 755 /volume1/data/media

# Verify - should show your user and "users" group
ls -la /volume1/docker/jellyfin

# Start container
sudo docker start jellyfin
```

<img src="screenshots/Schermafbeelding 2026-01-15 11.56.02.png" width="50%">

Make sure that Jellyfin is running.

---

## Step 3: Configure NFS on your Synology

### Enable User Home Service

1. Open **Control Panel** → **User & Group** → **Advanced**
2. Check **"Enable user home service"**
3. Click **Apply**
<img src="screenshots/Schermafbeelding 2026-01-15 12.00.29.png" width="35%">
### Enable NFS Service

1. Open **Control Panel** → **File Services** → **NFS**
2. Check **"Enable NFS service"**
3. Set Maximum NFS protocol to **NFSv4.1**
4. Click **Apply**
<img src="screenshots/Schermafbeelding 2026-01-15 12.01.46.png" width="35%">
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

For the Data folder:
<img src="screenshots/Schermafbeelding 2026-01-15 12.03.36.png" width="35%">

For the Docker folder:
<img src="screenshots/Schermafbeelding 2026-01-15 12.06.03.png" width="35%">
---

## Step 4: Install Git on your Synology

1. Open **Package Center**
2. Search for **"Git"**
3. Click **Install**

---

## Step 5: Install Homebrew on your Synology

Synology requires a special version of Homebrew:

SSH into your Synology and run: 

```bash
git clone https://github.com/MrCee/Synology-Homebrew.git ~/Synology-Homebrew
~/Synology-Homebrew/install-synology-homebrew.sh
```

When prompted, select **option 1 (Minimal installation)**. This can take some time.
<img src="screenshots/Schermafbeelding 2026-01-15 12.08.11.png" width="35%">

When asked `Prune these back to minimal now? [y/N]:` select **N** (no).
<img src="screenshots/Schermafbeelding 2026-01-15 12.17.01.png" width="35%">

After installation:
```bash
brew install gum
```
<img src="screenshots/Schermafbeelding 2026-01-15 12.17.54.png" width="35%">

Then **close your terminal, reconnect via SSH**, **or type `exit` and press Enter** and continue to the next step.

---

## Step 6: Install Transcodarr

SSH into your Synology and run:

```bash
git clone https://github.com/JacquesToT/Transcodarr.git ~/Transcodarr
cd ~/Transcodarr && ./install.sh
```
Now follow the steps in the installer.
<img src="screenshots/Schermafbeelding 2026-01-15 12.23.43.png" width="35%">

The installer will:
1. Connect to your Mac via SSH
2. Install Homebrew and FFmpeg with VideoToolbox
3. Create mount points and configure NFS
4. Handle Mac reboot if needed
5. Register the Mac with rffmpeg

**That's it!** Start a video in Jellyfin and watch it transcode on your Mac.

---
## Monitoring

Use ./install.sh or ./monitor.sh to monitor the status of your nodes
It will install TUI framework and terminal formatting
It will ask for your Synology password.
<img src="screenshots/Schermafbeelding 2026-01-15 13.06.42.png" width="35%">
<img src="screenshots/Schermafbeelding 2026-01-15 13.09.15.png" width="35%">

---
## Adding Another Mac

To add more Macs to your transcoding cluster:

> **Important:** All Macs must use the **same username** for SSH.
> rffmpeg uses a single SSH user configuration for all nodes.
If the username on the macs is different, you need to make a new admin account on the mac you want to add.  

1. Enable **Remote Login** on the new Mac (System Settings → Sharing)
2. Open the terminal and install homebrew on the new mac 
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
``` 
And then install gum:
```bash
brew install gum
```

3. Run the installer on your Synology: `cd ~/Transcodarr && ./install.sh` 
4. Select **"➕ Add a new Mac node"**

The installer will configure everything automatically.
When asked for the weight choose what the second Mac should be able to handle.
Check the monitor to see if the second Mac is registered.
<img src="screenshots/Schermafbeelding 2026-01-15 13.16.05.png" width="35%">

- **Multi-node weight configuration:** rffmpeg doesn't actively load balance based on current CPU usage. It distributes transcodes sequentially, roughly following the weight ratio. If both nodes have equal weight but different capabilities, the slower Mac may become overloaded while the faster one sits idle, resulting in stuttering video. **Recommendation:** Give your faster Mac a higher weight (e.g., M4 = weight 4, M1 = weight 2).

---

## Commands

### Check status
```bash
docker exec jellyfin rffmpeg status
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

### Change Node Weight
Change the weight of a node to adjust its capacity in rffmpeg. Higher weight means the node takes more concurrent transcodes.

### Uninstall Transcodarr
Here you can uninstall Transcodarr on your Synology, a node or both.

### Monitor
Here you can monitor the status of your nodes. note: not always 100% accurate.

---

## Tested On

**Synology NAS:**
- DS1821+
- DS916+

**Mac (Apple Silicon):**
- Mac Mini M1
- Mac Mini M4
- Mac Studio M4

---

## Documentation

- [CHANGELOG](CHANGELOG.md) - Release history and version changes
- [CONTRIBUTING](CONTRIBUTING.md) - How to contribute to Transcodarr
- [SECURITY](SECURITY.md) - Security policy and best practices
- [rFFmpeg Load Balancing](docs/RFFMPEG_LOAD_BALANCING.md) - Technical architecture details

## License

MIT

## Credits

- [rffmpeg](https://github.com/joshuaboniface/rffmpeg) - Remote FFmpeg wrapper
- [linuxserver/mods:jellyfin-rffmpeg](https://github.com/linuxserver/docker-mods) - Docker mod
