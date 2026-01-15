#!/bin/bash
#
# Transcodarr Uninstaller
# Removes all Transcodarr components from Mac
#
# Run this on your Mac to completely remove Transcodarr
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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
style 196 "╔══════════════════════════════════════════════════════════════╗"
style 196 "║             TRANSCODARR UNINSTALLER                          ║"
style 196 "╚══════════════════════════════════════════════════════════════╝"
echo ""
style 252 "This will remove the following from your Mac:"
echo ""
echo "  Core components:"
echo "  - jellyfin-ffmpeg (/opt/jellyfin-ffmpeg/)"
echo "  - ffmpeg wrapper script"
echo "  - SSH authorized key for rffmpeg"
echo ""
echo "  NFS & Mounts:"
echo "  - LaunchDaemons (com.transcodarr.*)"
echo "  - NFS mount scripts (/usr/local/bin/mount-*.sh)"
echo "  - NFS mounts (/data/media, /Users/Shared/jellyfin-cache)"
echo ""
echo "  Optional:"
echo "  - Synthetic links (/data, /config) - requires reboot"
echo "  - Energy settings reset"
echo "  - State file (~/.transcodarr)"
echo ""

if ! confirm "Continue with uninstall?"; then
    echo "Cancelled."
    exit 0
fi

echo ""
style 212 "Uninstalling Transcodarr components..."
echo ""

# ============================================================================
# 1. Remove jellyfin-ffmpeg
# ============================================================================
style 252 "Removing jellyfin-ffmpeg..."
if [[ -d "/opt/jellyfin-ffmpeg" ]]; then
    sudo rm -rf /opt/jellyfin-ffmpeg
    style 46 "  ✓ Removed /opt/jellyfin-ffmpeg"
else
    style 252 "  - jellyfin-ffmpeg not found (already removed)"
fi

# ============================================================================
# 2. Remove SSH authorized key
# ============================================================================
style 252 "Removing SSH authorized key..."
if [[ -f ~/.ssh/authorized_keys ]]; then
    # Remove the transcodarr-rffmpeg key
    if grep -q "transcodarr-rffmpeg" ~/.ssh/authorized_keys 2>/dev/null; then
        grep -v "transcodarr-rffmpeg" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp
        mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        style 46 "  ✓ Removed transcodarr-rffmpeg SSH key"
    else
        style 252 "  - No transcodarr SSH key found"
    fi
fi

# ============================================================================
# 3. Unload and remove LaunchDaemons
# ============================================================================
style 252 "Removing LaunchDaemons..."
FOUND_DAEMONS=false
for plist in /Library/LaunchDaemons/com.transcodarr.*.plist /Library/LaunchDaemons/com.jellyfin.*.plist; do
    if [[ -f "$plist" ]]; then
        FOUND_DAEMONS=true
        sudo launchctl unload "$plist" 2>/dev/null || true
        sudo rm -f "$plist"
        style 46 "  ✓ Removed $(basename "$plist")"
    fi
done
if [[ "$FOUND_DAEMONS" == false ]]; then
    style 252 "  - No LaunchDaemons found"
fi

# ============================================================================
# 4. Unmount NFS mounts
# ============================================================================
style 252 "Unmounting NFS shares..."
for mount_point in "/data/media" "/Users/Shared/jellyfin-cache" "/config/cache"; do
    if mount | grep -q "$mount_point"; then
        sudo umount "$mount_point" 2>/dev/null || sudo umount -f "$mount_point" 2>/dev/null || true
        style 46 "  ✓ Unmounted $mount_point"
    fi
done

# ============================================================================
# 5. Remove mount scripts
# ============================================================================
style 252 "Removing mount scripts..."
FOUND_SCRIPTS=false
for script in /usr/local/bin/mount-nfs-media.sh /usr/local/bin/mount-synology-cache.sh /usr/local/bin/nfs-watchdog.sh; do
    if [[ -f "$script" ]]; then
        FOUND_SCRIPTS=true
        sudo rm -f "$script"
        style 46 "  ✓ Removed $script"
    fi
done
if [[ "$FOUND_SCRIPTS" == false ]]; then
    style 252 "  - No mount scripts found"
fi

# ============================================================================
# 6. Remove log files
# ============================================================================
style 252 "Removing log files..."
sudo rm -f /var/log/mount-nfs-media.log /var/log/mount-synology-cache.log /var/log/nfs-watchdog.log 2>/dev/null || true
style 46 "  ✓ Removed log files"

# ============================================================================
# 7. Remove Transcodarr state file
# ============================================================================
style 252 "Removing state file..."
if [[ -d ~/.transcodarr ]]; then
    rm -rf ~/.transcodarr 2>/dev/null || true
    style 46 "  ✓ Removed ~/.transcodarr"
else
    style 252 "  - State directory not found"
fi

# ============================================================================
# 8. Optional: Remove synthetic links (requires reboot)
# ============================================================================
echo ""
style 226 "Synthetic links (/data, /config) require a reboot to remove"
if confirm "Remove synthetic links? (requires reboot)"; then
    if [[ -f /etc/synthetic.conf ]]; then
        sudo rm -f /etc/synthetic.conf
        style 46 "  ✓ Removed /etc/synthetic.conf"
        style 226 "  Note: Reboot required to remove /data and /config"

        NEEDS_REBOOT=true
    else
        style 252 "  - /etc/synthetic.conf not found"
    fi
fi

# ============================================================================
# 9. Optional: Reset energy settings
# ============================================================================
echo ""
if confirm "Reset energy settings to defaults?"; then
    sudo pmset -a sleep 1 displaysleep 10 disksleep 10 powernap 1 2>/dev/null || true
    style 46 "  ✓ Reset energy settings"
fi

# ============================================================================
# 10. Optional: Remove Homebrew FFmpeg (legacy)
# ============================================================================
if command -v brew &>/dev/null; then
    if brew list ffmpeg &>/dev/null 2>&1 || brew list homebrew-ffmpeg/ffmpeg/ffmpeg &>/dev/null 2>&1; then
        echo ""
        if confirm "Remove Homebrew FFmpeg (legacy, if installed)?"; then
            brew uninstall homebrew-ffmpeg/ffmpeg/ffmpeg 2>/dev/null || true
            brew uninstall ffmpeg 2>/dev/null || true
            brew untap homebrew-ffmpeg/ffmpeg 2>/dev/null || true
            style 46 "  ✓ Removed Homebrew FFmpeg"
        fi
    fi
fi

# ============================================================================
# Done
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
style 46 "✓ Uninstall complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$NEEDS_REBOOT" == true ]]; then
    style 226 "A reboot is required to complete removal of synthetic links."
    echo ""
    if confirm "Reboot now?"; then
        sudo reboot
    fi
fi

echo ""
style 252 "Note: To remove Transcodarr from Synology, run:"
echo -e "  ${CYAN}sudo docker exec \$JELLYFIN_CONTAINER rffmpeg remove <MAC_IP>${NC}"
echo -e "  ${CYAN}rm -rf ~/Transcodarr${NC}"
echo ""
style 252 "To reinstall: git clone + ./install.sh on Synology"
echo ""
