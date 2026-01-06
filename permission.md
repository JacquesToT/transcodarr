# Permission Issues: jellyfin/jellyfin → linuxserver/jellyfin Migration

## Overview
When switching from `jellyfin/jellyfin` to `linuxserver/jellyfin`, several issues can occur.
This document tracks all known issues and their solutions.

---

## Issue 1: Config Directory Permission Denied

### Symptom
```
System.UnauthorizedAccessException: Access to the path '/config/data/data' is denied.
System.IO.IOException: Permission denied
```

### Cause
LinuxServer images run as user defined by PUID/PGID environment variables.
The existing config directory may have different ownership from the previous image.

### Solution
```bash
sudo chown -R 1026:100 /volume1/docker/jellyfin
sudo chmod -R 755 /volume1/docker/jellyfin
```

---

## Issue 2: Marker File Conflict

### Symptom
```
System.InvalidOperationException: Expected to find only .jellyfin-config but found marker for /config/.jellyfin-data.
```

### Cause
- `jellyfin/jellyfin` uses `.jellyfin-data` marker files
- `linuxserver/jellyfin` expects `.jellyfin-config` marker files

### Solution
Remove the old marker files:
```bash
sudo rm /volume1/docker/jellyfin/.jellyfin-data
sudo rm /volume1/docker/jellyfin/data/.jellyfin-data
sudo docker restart jellyfin
```

---

## Issue 3: Media Library Not Visible

### Symptom
- Jellyfin starts but shows empty libraries
- Films/TV shows not found

### Cause
Media directory has no permissions (shows as `d---------` in container)

### Diagnosis
```bash
sudo docker exec jellyfin ls -la /data/media
# Shows: d--------- ... movies
```

### Solution
```bash
sudo chmod -R 755 /volume1/data/media
# Or for write access (metadata):
sudo chmod -R 775 /volume1/data/media
```

---

## Issue 4: rffmpeg Directory Permissions

### Symptom
rffmpeg cannot access SSH keys or config

### Cause
rffmpeg directory has restrictive permissions after migration

### Solution
```bash
sudo chmod -R 755 /volume1/docker/jellyfin/rffmpeg
sudo chown -R 1026:100 /volume1/docker/jellyfin/rffmpeg
```

---

## Complete Migration Checklist

Run these commands in order when migrating from `jellyfin/jellyfin` to `linuxserver/jellyfin`:

```bash
# 1. Stop container
sudo docker stop jellyfin

# 2. Fix config ownership and permissions
sudo chown -R 1026:100 /volume1/docker/jellyfin
sudo chmod -R 755 /volume1/docker/jellyfin

# 3. Remove old marker files
sudo rm -f /volume1/docker/jellyfin/.jellyfin-data
sudo rm -f /volume1/docker/jellyfin/data/.jellyfin-data

# 4. Fix media permissions
sudo chmod -R 755 /volume1/data/media

# 5. Start container with new image
sudo docker start jellyfin
```

---

---

## Issue 5: SSH Key Ownership (abc user UID varies)

### Symptom
```
Load key "/config/rffmpeg/.ssh/id_rsa": Permission denied
```

### Cause
The abc user UID varies between container instances (e.g., 911 vs 1026).
Hardcoding `chown 911:911` doesn't work.

### Solution
Dynamically get abc user UID from container:
```bash
abc_uid=$(sudo docker exec jellyfin id -u abc)
abc_gid=$(sudo docker exec jellyfin id -g abc)
sudo chown -R "${abc_uid}:${abc_gid}" /path/to/files
```

### Status: ✅ FIXED in `lib/jellyfin-setup.sh` (all functions now use dynamic UID lookup)

---

## Issue 6: Default SSH Key Path (CRITICAL!)

### Symptom
SSH works when testing with custom path, but rffmpeg still fails with retcode 255.

### Cause
rffmpeg uses `/var/lib/jellyfin/.ssh/id_rsa` as DEFAULT path,
NOT the custom path specified in `rffmpeg.yml` config.

Evidence from rffmpeg source:
```python
"args", ["-i", "/var/lib/jellyfin/.ssh/id_rsa"]
```

### Solution
Copy SSH key to BOTH locations:
```bash
sudo docker exec jellyfin bash -c '
    mkdir -p /var/lib/jellyfin/.ssh
    cp /config/rffmpeg/.ssh/id_rsa /var/lib/jellyfin/.ssh/id_rsa
    cp /config/rffmpeg/.ssh/id_rsa.pub /var/lib/jellyfin/.ssh/id_rsa.pub
    chown -R abc:abc /var/lib/jellyfin/.ssh
    chmod 700 /var/lib/jellyfin/.ssh
    chmod 600 /var/lib/jellyfin/.ssh/id_rsa
'
```

### Status: ✅ FIXED in `finalize_rffmpeg_setup()` function

---

## Issue 7: Persist Directory Missing

### Symptom
```
unix_listener: cannot bind to path /config/rffmpeg/persist/ssh-nick@192.168.175.159:22...: No such file or directory
```

### Cause
rffmpeg's persist directory doesn't exist, causing SSH ControlMaster to fail.

### Solution
Create persist directory with correct permissions:
```bash
sudo docker exec jellyfin mkdir -p /config/rffmpeg/persist
sudo docker exec jellyfin chown abc:abc /config/rffmpeg/persist
sudo docker exec jellyfin chmod 755 /config/rffmpeg/persist
```

### Status: ✅ FIXED in `finalize_rffmpeg_setup()` function

---

## Issue 8: Bad Host State Caching

### Symptom
Hosts immediately marked as "bad" even after fixing permissions.
Debug log shows:
```
DEBUG - Host previously marked bad by PID 1235
```

### Cause
rffmpeg caches "bad" host state in SQLite database. This persists across
container restarts and even after fixing the underlying SSH issues.

### Solution
Clear database and re-add hosts after fixing issues:
```bash
sudo docker exec -i jellyfin rffmpeg init <<< "y"
sudo docker exec jellyfin rffmpeg add <IP> --weight 2
```

### Status: Manual step (document in troubleshooting)

---

## Issue 9: Testing SSH as Wrong User

### Symptom
SSH test passes but rffmpeg still fails.

### Cause
Testing SSH as root passes, but rffmpeg runs as abc user which may not
have access to the SSH key.

### Solution
Always test SSH as abc user:
```bash
# WRONG (runs as root)
sudo docker exec jellyfin ssh -i /path/to/key user@host "echo ok"

# CORRECT (runs as abc)
sudo docker exec -u abc jellyfin ssh -i /path/to/key user@host "echo ok"
```

### Status: ✅ FIXED in `test_container_ssh_to_mac()`

---

## Complete rffmpeg SSH Setup Checklist

When setting up rffmpeg SSH keys, ensure ALL of the following:

1. [ ] SSH key exists at `/config/rffmpeg/.ssh/id_rsa`
2. [ ] SSH key ALSO exists at `/var/lib/jellyfin/.ssh/id_rsa` (rffmpeg default!)
3. [ ] Both key locations owned by abc:abc with correct UID
4. [ ] Key permissions are 600
5. [ ] Directory permissions are 700
6. [ ] Persist directory exists: `/config/rffmpeg/persist/`
7. [ ] Persist directory owned by abc:abc
8. [ ] Public key installed on all Mac nodes
9. [ ] Test SSH as abc user, not root

---

## Updated ensure_container_ssh_key() Function

```bash
ensure_container_ssh_key() {
    local jellyfin_config="${1:-/volume1/docker/jellyfin}"

    # Get actual abc user UID/GID from container
    local abc_uid abc_gid
    abc_uid=$(sudo docker exec jellyfin id -u abc 2>/dev/null || echo "1000")
    abc_gid=$(sudo docker exec jellyfin id -g abc 2>/dev/null || echo "1000")

    # 1. Ensure key exists in config location
    # ... existing code ...

    # 2. Copy key to default rffmpeg location (CRITICAL!)
    sudo docker exec jellyfin bash -c "
        mkdir -p /var/lib/jellyfin/.ssh
        cp /config/rffmpeg/.ssh/id_rsa /var/lib/jellyfin/.ssh/id_rsa
        cp /config/rffmpeg/.ssh/id_rsa.pub /var/lib/jellyfin/.ssh/id_rsa.pub
        chown -R abc:abc /var/lib/jellyfin/.ssh
        chmod 700 /var/lib/jellyfin/.ssh
        chmod 600 /var/lib/jellyfin/.ssh/id_rsa
    "

    # 3. Create persist directory
    sudo docker exec jellyfin bash -c "
        mkdir -p /config/rffmpeg/persist
        chown abc:abc /config/rffmpeg/persist
        chmod 755 /config/rffmpeg/persist
    "

    # 4. Verify abc user can read key
    if sudo docker exec -u abc jellyfin test -r /var/lib/jellyfin/.ssh/id_rsa; then
        return 0
    else
        return 1
    fi
}
```

---

## TODO for installer
- [ ] Detect if user is using jellyfin/jellyfin image
- [ ] Warn user that linuxserver/jellyfin is required for rffmpeg
- [ ] Provide automated migration script
- [ ] Fix permissions automatically on config directory
- [ ] Remove old marker files automatically
- [ ] Verify media directory permissions
- [ ] Copy SSH key to `/var/lib/jellyfin/.ssh/` (rffmpeg default path)
- [ ] Create `/config/rffmpeg/persist/` directory
- [ ] Set correct abc:abc ownership using dynamic UID lookup
- [ ] Test SSH as abc user, not root
