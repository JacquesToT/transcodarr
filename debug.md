# Jellyfin Debug Session - 2026-01-05

---

# Issue 1: Jellyfin Startup Failure

## Status: ✅ OPGELOST

## Probleem
Jellyfin start niet meer na het runnen van de installer.

## Root Cause
```
[ERR] FFmpeg: Failed version check: /usr/local/bin/ffmpeg
[FTL] Error while starting server - Failed to find valid ffmpeg
```

De rffmpeg wrapper kan geen verbinding maken met de Mac, waardoor ffmpeg validatie faalt.

---

## Debug Stappen

### Stap 1: Check rffmpeg symlink
```bash
sudo docker exec jellyfin ls -la /usr/local/bin/ffmpeg
```
**Resultaat:** ✅ OK
```
lrwxrwxrwx 1 root root 7 Jan  4 20:09 /usr/local/bin/ffmpeg -> rffmpeg
```

### Stap 2: Check geregistreerde nodes
```bash
sudo docker exec jellyfin rffmpeg status
```
**Resultaat:** ✅ Node bestaat
```
Hostname        Servername      ID  Weight  State  Active Commands
192.168.175.43  192.168.175.43  1   4       idle   N/A
```

### Stap 3: Test SSH verbinding vanuit container
```bash
sudo docker exec -u abc jellyfin ssh -i /config/rffmpeg/.ssh/id_rsa -o StrictHostKeyChecking=no -o BatchMode=yes nick@192.168.175.43 "echo OK"
```
**Resultaat:** ❌ HANGT - SSH verbinding faalt/timeout

### Stap 4: Check SSH key permissions
```bash
sudo docker exec jellyfin ls -la /config/rffmpeg/.ssh/
```
**Resultaat:** ⚠️ Mogelijk probleem
```
-rw------- 1 911   911 411 Jan  5 13:23 id_rsa
-rw-r--r-- 1 911   911 101 Jan  4 16:34 id_rsa.pub
```
Key ownership is `911:911`, maar abc user uid kan anders zijn.

### Stap 5: Check abc user uid
```bash
sudo docker exec jellyfin id abc
```
**Resultaat:**
```
uid=1026(abc) gid=100(users) groups=100(users)
```

### Stap 6: Test of abc user key kan lezen
```bash
sudo docker exec -u abc jellyfin cat /config/rffmpeg/.ssh/id_rsa | head -1
```
**Resultaat:** ❌ PERMISSION DENIED
```
cat: /config/rffmpeg/.ssh/id_rsa: Permission denied
```

---

## ROOT CAUSE GEVONDEN

**De SSH key is eigendom van uid 911, maar abc user heeft uid 1026!**

De key heeft `chmod 600` (alleen owner kan lezen), dus abc user kan de private key niet lezen.

## OPLOSSING

```bash
# Fix ownership naar correcte abc user
sudo chown -R 1026:100 /volume1/docker/jellyfin/rffmpeg

# Verifieer dat abc nu kan lezen
sudo docker exec -u abc jellyfin cat /config/rffmpeg/.ssh/id_rsa | head -1
# Moet tonen: -----BEGIN OPENSSH PRIVATE KEY-----

# Test SSH verbinding
sudo docker exec -u abc jellyfin ssh -o ConnectTimeout=5 -o BatchMode=yes -i /config/rffmpeg/.ssh/id_rsa nick@192.168.175.43 "echo OK"

# Als dat werkt, restart Jellyfin
sudo docker restart jellyfin
```

---

## Volgende Debug Stappen (indien nodig)

### Stap 5: Check abc user uid in container
```bash
sudo docker exec jellyfin id abc
```

### Stap 6: Test SSH met verbose output (naar correcte IP!)
```bash
sudo docker exec -u abc jellyfin ssh -vvv -i /config/rffmpeg/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 nick@192.168.175.43 "echo OK"
```

### Stap 7: Check of Mac SSH port open is
```bash
nc -zv 192.168.175.43 22
```

### Stap 8: Check of key readable is door abc user
```bash
sudo docker exec -u abc jellyfin cat /config/rffmpeg/.ssh/id_rsa | head -1
```

---

## Mogelijke Oorzaken

1. **SSH key permission probleem** - abc user kan key niet lezen (uid mismatch)
2. **Mac SSH niet bereikbaar** - firewall, Remote Login uit, netwerk
3. **SSH key niet geautoriseerd op Mac** - public key niet in ~/.ssh/authorized_keys
4. **Verkeerd IP adres** - Mac heeft ander IP dan geregistreerd

---

## Oplossingen

### Als SSH key permissions fout zijn:
```bash
# Get abc uid from container
ABC_UID=$(sudo docker exec jellyfin id -u abc)
ABC_GID=$(sudo docker exec jellyfin id -g abc)

# Fix ownership op host
sudo chown -R ${ABC_UID}:${ABC_GID} /volume1/docker/jellyfin/rffmpeg
```

### Als Mac niet bereikbaar is:
1. Check of Mac aan staat
2. Check of Remote Login aan staat (System Settings > General > Sharing)
3. Check firewall settings op Mac

### Als SSH key niet geautoriseerd is op Mac:
```bash
# Op de Mac, voeg public key toe:
cat /volume1/docker/jellyfin/rffmpeg/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

---
---

# Issue 2: Transcoding Fails (Return Code 254)

## Status: 🔍 ONDERZOEK

## Probleem
Film starten in Jellyfin werkt niet. rffmpeg geeft return code 254.

## Symptomen
```
2026-01-05 19:31:02 - rffmpeg - INFO - Running command on host '192.168.175.43'
2026-01-05 19:31:05 - rffmpeg - ERROR - Finished rffmpeg with return code 254
```

Return code 254 = SSH/remote command failure

## Analyse

Het ffmpeg commando probeert:
- **Input:** `file:/data/media/movies/A Real Pain (2024)...mkv`
- **Output:** `/config/cache/transcodes/...`

Deze paden moeten op de **Mac** beschikbaar zijn via NFS mounts:
- `/data/media` → NAS media folder
- `/config/cache` → NAS cache folder

---

## Debug Stappen

### Stap 1: Test SSH verbinding + ffmpeg
```bash
sudo docker exec -u abc jellyfin ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i /config/rffmpeg/.ssh/id_rsa nick@192.168.175.43 "echo SSH_OK && /opt/homebrew/bin/ffmpeg -version 2>&1 | head -1"
```
**Resultaat:** ✅ OK
```
SSH_OK
ffmpeg version 8.0.1 Copyright (c) 2000-2025 the FFmpeg developers
```

### Stap 2: Check /data directory op Mac
```bash
sudo docker exec -u abc jellyfin ssh ... "ls -la /data 2>&1"
```
**Resultaat:** ⚠️ Synthetic link bestaat, maar leeg
```
lrwxr-xr-x  1 root  wheel  24 Jan  5 13:21 /data -> System/Volumes/Data/data
```

### Stap 3: Check NFS mounts op Mac
```bash
sudo docker exec -u abc jellyfin ssh ... "mount | grep nfs"
```
**Resultaat:** ❌ GEEN OUTPUT - Geen NFS mounts actief!

### Stap 4: Check /data/media/movies/
```bash
sudo docker exec -u abc jellyfin ssh ... "ls '/data/media/movies/' 2>&1 | head -3"
```
**Resultaat:** ❌ NIET GEVONDEN
```
ls: /data/media/movies/: No such file or directory
```

### Stap 5: Check /config/cache
```bash
sudo docker exec -u abc jellyfin ssh ... "ls -la /config/cache 2>&1 | head -5"
```
**Resultaat:** ⚠️ Wijst naar lokale directory, niet NFS
```
/config/cache -> /Users/Shared/jellyfin-cache
```

---

## ROOT CAUSE GEVONDEN

**NFS mounts zijn niet actief op de Mac!**

- `/data` synthetic link bestaat, maar `/data/media` is leeg (geen NFS mount)
- `/config/cache` wijst naar lokale `/Users/Shared/jellyfin-cache` ipv NFS mount
- `mount | grep nfs` toont geen actieve NFS mounts

ffmpeg kan de bronbestanden niet vinden en kan output niet naar Synology schrijven.

---

## OPLOSSING

### Stap 1: Check LaunchDaemons op Mac
```bash
# SSH naar Mac
ssh nick@192.168.175.43

# Check of mount scripts bestaan
ls -la /usr/local/bin/mount-*.sh

# Check LaunchDaemons
ls -la /Library/LaunchDaemons/com.transcodarr.*
```

### Stap 2: Handmatig NFS mounten (test)

Op de Mac:
```bash
# Maak mount points aan
sudo mkdir -p /data/media
sudo mkdir -p /config/cache

# Mount NFS shares (vervang NAS_IP met je Synology IP)
sudo mount -t nfs -o resvport,rw,nolock NAS_IP:/volume1/data/media /data/media
sudo mount -t nfs -o resvport,rw,nolock NAS_IP:/volume1/docker/jellyfin/cache /config/cache

# Verifieer
ls /data/media/movies/
ls /config/cache/
```

### Stap 3: Als mounts werken, maak ze persistent
De installer zou LaunchDaemons moeten hebben aangemaakt. Check of ze bestaan en actief zijn.

---

## Verdere Debug Stappen (uitgevoerd)

### Stap 6: NFS mounts handmatig gefixed
```bash
# Op de Mac:
sudo mkdir -p /data/media
sudo mkdir -p /Users/Shared/jellyfin-cache

# Mount scripts gemaakt en uitgevoerd
sudo /usr/local/bin/mount-nfs-media.sh
sudo /usr/local/bin/mount-synology-cache.sh
```
**Resultaat:** ✅ NFS mounts werken
```
192.168.175.49:/volume1/data/media on /System/Volumes/Data/data/media (nfs)
192.168.175.49:/volume1/docker/jellyfin/cache on /Users/Shared/jellyfin-cache (nfs)
```

### Stap 7: Transcoding faalt nog steeds (254)

**Probleem:** `/config/cache` was een directory met daarin een symlink:
```
/config/cache/
└── jellyfin-cache -> /Users/Shared/jellyfin-cache   ❌ FOUT
```

rffmpeg verwacht `/config/cache/transcodes/` maar die bestond niet.

### Stap 8: Fix /config/cache symlink
```bash
# Op de Mac:
sudo rm -rf /config/cache
sudo ln -sf /Users/Shared/jellyfin-cache /config/cache
```
**Resultaat:** ✅ Correct
```
/config/cache -> /Users/Shared/jellyfin-cache   ✅ GOED
/config/cache/transcodes/                        ✅ Bestaat nu
```

---

## Status: ✅ ISSUE 2 OPGELOST

### Verificatie
```
# rffmpeg status toont actieve transcoding:
Hostname        State   Active Commands
192.168.175.43  active  PID 8307: ffmpeg -analyzeduration 200M ...

# Mac CPU gebruik: 644.7% (alle cores!)
# Film speelt correct af
```

---

## ROOT CAUSES SAMENVATTING

### Issue 1: Jellyfin start niet
- **Oorzaak:** SSH key ownership 911:911 maar abc user heeft uid 1026
- **Fix:** `sudo chown -R 1026:100 /volume1/docker/jellyfin/rffmpeg`
- **Installer fix:** ✅ Dynamische uid lookup toegevoegd

### Issue 2: Transcoding faalt (254)
- **Oorzaak 1:** NFS mounts niet actief op Mac (scripts niet aangemaakt)
- **Oorzaak 2:** `/config/cache` was directory ipv directe symlink
- **Fix:** Mount scripts uitvoeren + symlink correct maken
- **Installer fix:** ❌ NOG TE DOEN

---

## INSTALLER BUGS TE FIXEN

1. **SSH key ownership:** ✅ GEFIXED
   - Was: hardcoded 911:911
   - Nu: dynamisch abc uid detecteren

2. **/config/cache symlink:** ❌ TE FIXEN
   - Probleem: `ln -sf` in bestaande directory maakt sublink
   - Fix: Eerst `rm -rf /config/cache` voordat symlink wordt gemaakt

3. **SSH key niet in rffmpeg default location:** ✅ GEFIXED
   - Probleem: rffmpeg zoekt standaard naar `/var/lib/jellyfin/.ssh/id_rsa`
   - Fix: `finalize_rffmpeg_setup()` kopieert key naar beide locaties

4. **Persist directory ontbreekt:** ✅ GEFIXED
   - Probleem: `/config/rffmpeg/persist/` voor SSH ControlMaster ontbrak
   - Fix: `finalize_rffmpeg_setup()` maakt directory aan

---
---

# Issue 3: Monitor UI Toont Geen Nodes - 2026-01-06

## Status: 🔍 ONDERZOEK

## Probleem
De verbeterde monitor toont geen node cards, ondanks dat:
- Status bar werkt (LOCAL, Docker, Media, Cache alle groen)
- Tabs werken (Dashboard, Logs, Config)
- `rffmpeg status` toont wel de Mac node met actieve transcodes

## Nieuwe Monitor Features (geïmplementeerd)
1. Per-node cards met CPU/Memory gauges
2. Tabbed interface (Dashboard/Logs/Config)
3. Detail toggle (D key) compact/detailed view
4. SSH via container naar Mac voor stats

---

## Debug Sessie

### Poging 1: Basis implementatie
**Probleem:** Dashboard bleef leeg
**Oorzaak:** Monitor draaide op Synology host, maar SSH keys alleen in container
**Fix:** SSH commands via `docker exec jellyfin ssh ...` uitvoeren

### Poging 2: SSH via container
**Test:**
```bash
sudo docker exec jellyfin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -i /config/rffmpeg/.ssh/id_rsa nick@192.168.175.43 "echo OK"
```
**Resultaat:** Host key verification failed
**Fix:** Added StrictHostKeyChecking=no (was al in code, werkte daarna)

### Poging 3: Parsing error
**Error:** `invalid literal for int with base 10: '-analyzeduration'`
**Oorzaak:** rffmpeg status output heeft multi-line Active Commands
```
192.168.175.43  192.168.175.43  1   4       active  PID 4384: ffmpeg -h
                                                    PID 918: ffmpeg -analyzeduration...
```
De continuation lines werden als nieuwe hosts geparsed.
**Fix:** Skip lines die met whitespace beginnen, valideer ID/weight als integers

### Poging 4: zsh marker interpretatie
**Error:** `zsh:1: ==CPU=== not found`
**Oorzaak:** Markers `===CPU===` werden door zsh als comparison operators gezien
**Fix:** Markers veranderd naar `STATS_CPU_START` etc.

### Poging 5: Rich markup error
**Error:** `MarkupError: Expected markup value (found '== not found][/red]').`
**Oorzaak:** Error messages bevatten `[` en `]` die als Rich tags worden geïnterpreteerd
**Fix:** Escape `[` naar `\\[` in error messages

### Poging 6: SSH return code
**Debug log toonde:**
```
SSH returncode: 1
SSH stdout: STATS_CPU_START
CPU usage: 1.58% user, 11.11% sys, 87.30% idle
STATS_MEM_START
...
```
**Oorzaak:** `grep ffmpeg | grep -v grep` geeft exit 1 als geen ffmpeg processen draaien
**Fix:** Check alleen op `STATS_CPU_START` marker in output, negeer return code

### Poging 7: Gauge brackets
**Error:** `MarkupError: closing tag '[/green]' does not match any open tag`
**Oorzaak:** `CPU [{gauge}]` - de `[` rond de gauge conflicteert met Rich markup
**Fix:** Escape brackets: `CPU \\[{gauge}\\]`

### Poging 8: NOG STEEDS LEEG
**Status:** Data wordt correct opgehaald (zie debug log), maar UI toont niets

**Debug log bevestigt:**
```
parsed hosts: [{'hostname': '192.168.175.43', ...}]
filtered node_stats: [NodeStats(hostname='nick@192.168.175.43', ip='192.168.175.43',
                      cpu_percent=21.7, memory_percent=43.2, is_online=True, ...)]
```

---

## Huidige Status

**Wat werkt:**
- ✅ rffmpeg status wordt correct geparsed
- ✅ SSH naar Mac werkt (via container)
- ✅ CPU/Memory stats worden opgehaald
- ✅ NodeStats objects worden correct aangemaakt
- ✅ Status bar werkt

**Wat niet werkt:**
- ❌ NodeCard widgets worden niet gerenderd in de UI

## Volgende Debug Stappen

1. Check of `_update_node_cards()` wordt aangeroepen
2. Check of NodeCard widgets daadwerkelijk worden gemount
3. Check of er een exception wordt gegooid tijdens render
4. Voeg debug logging toe aan `_update_node_cards()` in transcodarr_monitor.py
