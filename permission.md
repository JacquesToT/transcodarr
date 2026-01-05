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

## TODO for installer
- [ ] Detect if user is using jellyfin/jellyfin image
- [ ] Warn user that linuxserver/jellyfin is required for rffmpeg
- [ ] Provide automated migration script
- [ ] Fix permissions automatically on config directory
- [ ] Remove old marker files automatically
- [ ] Verify media directory permissions
