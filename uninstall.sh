#!/bin/bash
#
# Transcodarr Uninstaller
# Removes all Transcodarr components from Mac
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check for gum
if command -v gum &> /dev/null; then
    USE_GUM=true
else
    USE_GUM=false
fi

confirm() {
    if [[ "$USE_GUM" == true ]]; then
        gum confirm "$1"
    else
        read -p "$1 [y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

style() {
    if [[ "$USE_GUM" == true ]]; then
        gum style --foreground "$1" "$2"
    else
        echo -e "$2"
    fi
}

echo ""
style 196 "⚠️  TRANSCODARR UNINSTALLER"
echo ""
style 252 "This will remove the following:"
echo ""
echo "  • LaunchDaemons (com.transcodarr.*)"
echo "  • NFS mount scripts (/usr/local/bin/mount-*.sh)"
echo "  • NFS mounts (/data/media, /Users/Shared/jellyfin-cache)"
echo "  • node_exporter service (optional)"
echo "  • FFmpeg (optional)"
echo "  • Energy settings reset (optional)"
echo ""

if ! confirm "Continue with uninstall?"; then
    echo "Cancelled."
    exit 0
fi

echo ""
style 212 "🔧 Uninstalling Transcodarr components..."
echo ""

# 1. Unload and remove LaunchDaemons
style 252 "Removing LaunchDaemons..."
for plist in /Library/LaunchDaemons/com.transcodarr.*.plist /Library/LaunchDaemons/com.jellyfin.*.plist; do
    if [[ -f "$plist" ]]; then
        sudo launchctl unload "$plist" 2>/dev/null || true
        sudo rm -f "$plist"
        style 46 "  ✓ Removed $(basename "$plist")"
    fi
done

# 2. Unmount NFS mounts
style 252 "Unmounting NFS shares..."
for mount_point in "/data/media" "/Users/Shared/jellyfin-cache"; do
    if mount | grep -q "$mount_point"; then
        sudo umount "$mount_point" 2>/dev/null || sudo umount -f "$mount_point" 2>/dev/null || true
        style 46 "  ✓ Unmounted $mount_point"
    fi
done

# 3. Remove mount scripts
style 252 "Removing mount scripts..."
for script in /usr/local/bin/mount-nfs-media.sh /usr/local/bin/mount-synology-cache.sh /usr/local/bin/nfs-watchdog.sh; do
    if [[ -f "$script" ]]; then
        sudo rm -f "$script"
        style 46 "  ✓ Removed $script"
    fi
done

# 4. Remove log files
style 252 "Removing log files..."
sudo rm -f /var/log/mount-nfs-media.log /var/log/mount-synology-cache.log /var/log/nfs-watchdog.log 2>/dev/null || true
style 46 "  ✓ Removed log files"

# 5. Remove Transcodarr state file
style 252 "Removing state file..."
rm -rf ~/.transcodarr 2>/dev/null || true
style 46 "  ✓ Removed ~/.transcodarr"

# 6. Optional: Remove node_exporter
echo ""
if confirm "Remove node_exporter (monitoring)?"; then
    brew services stop node_exporter 2>/dev/null || true
    brew uninstall node_exporter 2>/dev/null || true
    style 46 "  ✓ Removed node_exporter"
fi

# 7. Optional: Remove FFmpeg
echo ""
if confirm "Remove FFmpeg?"; then
    brew uninstall homebrew-ffmpeg/ffmpeg/ffmpeg 2>/dev/null || true
    brew uninstall ffmpeg 2>/dev/null || true
    brew untap homebrew-ffmpeg/ffmpeg 2>/dev/null || true
    style 46 "  ✓ Removed FFmpeg"
fi

# 8. Optional: Reset energy settings
echo ""
if confirm "Reset energy settings to defaults?"; then
    sudo pmset -a sleep 1 displaysleep 10 disksleep 10 powernap 1
    style 46 "  ✓ Reset energy settings"
fi

# 9. Optional: Remove synthetic links
echo ""
style 226 "⚠️  Synthetic links (/data, /config) require a reboot to remove"
if confirm "Remove synthetic links? (requires reboot)"; then
    sudo rm -f /etc/synthetic.conf
    style 46 "  ✓ Removed /etc/synthetic.conf"
    style 226 "  ⚠ Reboot required to remove /data and /config"

    if confirm "Reboot now?"; then
        sudo reboot
    fi
fi

echo ""
style 46 "✅ Uninstall complete!"
echo ""
style 252 "To reinstall, run: ./install.sh"
echo ""
