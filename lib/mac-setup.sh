#!/bin/bash
#
# Mac Mini Setup Module for Transcodarr
#

# Install Homebrew if needed
install_homebrew() {
    if command -v brew &> /dev/null; then
        gum style --foreground 46 "✓ Homebrew already installed"
        return 0
    fi

    gum spin --spinner dot --title "Installing Homebrew..." -- \
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add to PATH for Apple Silicon
    if [[ $(uname -m) == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    gum style --foreground 46 "✓ Homebrew installed"
}

# Install FFmpeg with VideoToolbox and libfdk-aac
install_ffmpeg() {
    # Check if FFmpeg is already installed with VideoToolbox
    if [[ -f "/opt/homebrew/bin/ffmpeg" ]]; then
        if /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q "videotoolbox"; then
            gum style --foreground 46 "✓ FFmpeg with VideoToolbox already installed"
            return 0
        fi
    fi

    gum style --foreground 212 "Installing FFmpeg with VideoToolbox + libfdk-aac..."
    gum style --foreground 252 "This may take a few minutes..."
    echo ""

    # Add the tap
    gum style --foreground 252 "Adding homebrew-ffmpeg tap..."
    if ! brew tap homebrew-ffmpeg/ffmpeg 2>&1; then
        gum style --foreground 196 "✗ Failed to add homebrew-ffmpeg tap"
        return 1
    fi

    # Install FFmpeg
    gum style --foreground 252 "Installing FFmpeg (this takes a while)..."
    if brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac 2>&1; then
        gum style --foreground 46 "✓ FFmpeg installation completed"
    else
        # Try upgrade if already installed
        gum style --foreground 226 "Trying upgrade instead..."
        if ! brew upgrade homebrew-ffmpeg/ffmpeg/ffmpeg 2>&1; then
            # Last resort: try regular ffmpeg
            gum style --foreground 226 "Trying standard FFmpeg..."
            brew install ffmpeg 2>&1 || true
        fi
    fi

    echo ""

    # Verify installation
    if [[ -f "/opt/homebrew/bin/ffmpeg" ]]; then
        if /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q "videotoolbox"; then
            gum style --foreground 46 "✓ FFmpeg with VideoToolbox verified"
        else
            gum style --foreground 226 "⚠ VideoToolbox not found (software encoding will be used)"
        fi

        if /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q "libfdk_aac"; then
            gum style --foreground 46 "✓ libfdk-aac encoder available"
        else
            gum style --foreground 226 "⚠ libfdk-aac not available (will use aac instead)"
        fi
    else
        gum style --foreground 196 "✗ FFmpeg not found at /opt/homebrew/bin/ffmpeg"
        gum style --foreground 252 "Try running manually: brew install ffmpeg"
        return 1
    fi
}

# Setup synthetic links for /data and /config
setup_synthetic_links() {
    local synthetic_conf="/etc/synthetic.conf"
    local needs_reboot=false

    # Check if synthetic.conf exists and has correct entries
    if [[ -f "$synthetic_conf" ]]; then
        if grep -q "^data" "$synthetic_conf" && grep -q "^config" "$synthetic_conf"; then
            gum style --foreground 46 "✓ Synthetic links already configured"
            return 0
        fi
    fi

    gum style --foreground 212 "Setting up synthetic links for /data and /config..."
    gum style --foreground 226 "⚠ This requires sudo and a reboot"

    if gum confirm "Continue?"; then
        # Create the backing directories
        sudo mkdir -p /System/Volumes/Data/data/media
        sudo mkdir -p /System/Volumes/Data/config/cache

        # Add synthetic links
        {
            echo -e "data\tSystem/Volumes/Data/data"
            echo -e "config\tSystem/Volumes/Data/config"
        } | sudo tee "$synthetic_conf" > /dev/null

        needs_reboot=true
        gum style --foreground 46 "✓ Synthetic links configured"
        gum style --foreground 226 "⚠ A reboot is required for /data and /config to appear"
    fi

    if [[ "$needs_reboot" == true ]]; then
        if gum confirm "Reboot now?"; then
            sudo reboot
        else
            gum style --foreground 226 "Please reboot manually before continuing setup"
        fi
    fi
}

# Create NFS mount script for media
create_media_mount_script() {
    local nas_ip="$1"
    local media_path="$2"
    local script_path="/usr/local/bin/mount-nfs-media.sh"

    gum style --foreground 212 "Creating NFS mount script..."

    sudo mkdir -p /usr/local/bin

    sudo tee "$script_path" > /dev/null << EOF
#!/bin/bash
MOUNT_POINT="/data/media"
NFS_SHARE="${nas_ip}:${media_path}"
LOG_FILE="/var/log/mount-nfs-media.log"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

# Wait for network
for i in {1..30}; do
    if ping -c1 -W1 ${nas_ip} >/dev/null 2>&1; then
        log "Network available after \$i seconds"
        break
    fi
    sleep 1
done

# Check if already mounted
if mount | grep -q "\$MOUNT_POINT"; then
    log "NFS already mounted"
    exit 0
fi

# Create mount point if needed
mkdir -p "\$MOUNT_POINT"

# Mount NFS
/sbin/mount -t nfs -o resvport,rw,nolock "\$NFS_SHARE" "\$MOUNT_POINT"
log "NFS mounted: \$NFS_SHARE -> \$MOUNT_POINT"
EOF

    sudo chmod +x "$script_path"
    gum style --foreground 46 "✓ Media mount script created"
}

# Create NFS mount script for cache
create_cache_mount_script() {
    local nas_ip="$1"
    local cache_path="$2"
    local script_path="/usr/local/bin/mount-synology-cache.sh"

    gum style --foreground 212 "Creating cache mount script..."

    sudo tee "$script_path" > /dev/null << EOF
#!/bin/bash
MOUNT_POINT="/Users/Shared/jellyfin-cache"
NFS_SHARE="${nas_ip}:${cache_path}"
LOG_FILE="/var/log/mount-synology-cache.log"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

# Wait for network
for i in {1..30}; do
    ping -c1 -W1 ${nas_ip} >/dev/null 2>&1 && break
    sleep 1
done

# Create mount point if needed
mkdir -p "\$MOUNT_POINT"

# Mount if not already mounted
if ! mount | grep -q "\$MOUNT_POINT"; then
    /sbin/mount -t nfs -o resvport,rw,nolock "\$NFS_SHARE" "\$MOUNT_POINT"
    log "Mounted Synology cache"
fi

# Create symlink for /config/cache
if [[ ! -L /config/cache ]]; then
    ln -sf "\$MOUNT_POINT" /config/cache 2>/dev/null || true
fi
EOF

    sudo chmod +x "$script_path"
    gum style --foreground 46 "✓ Cache mount script created"
}

# Create LaunchDaemon for persistent mounts
create_launch_daemons() {
    local plist_dir="/Library/LaunchDaemons"

    gum style --foreground 212 "Creating LaunchDaemons for auto-mount..."

    # Media mount daemon
    sudo tee "$plist_dir/com.transcodarr.nfs-media.plist" > /dev/null << 'EOF'
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
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

    # Cache mount daemon
    sudo tee "$plist_dir/com.transcodarr.nfs-cache.plist" > /dev/null << 'EOF'
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
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

    # Load the daemons
    sudo launchctl load "$plist_dir/com.transcodarr.nfs-media.plist" 2>/dev/null || true
    sudo launchctl load "$plist_dir/com.transcodarr.nfs-cache.plist" 2>/dev/null || true

    gum style --foreground 46 "✓ LaunchDaemons created and loaded"
}

# Configure energy settings to prevent sleep
configure_energy_settings() {
    gum style --foreground 212 "Configuring energy settings (prevent sleep)..."

    sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 autorestart 1 womp 1

    gum style --foreground 46 "✓ Energy settings configured"
    gum style --foreground 252 "  • sleep=0, displaysleep=0, disksleep=0"
    gum style --foreground 252 "  • autorestart=1 (after power failure)"
    gum style --foreground 252 "  • womp=1 (Wake-on-LAN enabled)"
}

# Install and configure node_exporter for monitoring
install_node_exporter() {
    gum style --foreground 212 "Installing node_exporter for monitoring..."

    brew install node_exporter 2>/dev/null || true
    brew services start node_exporter 2>/dev/null || true

    gum style --foreground 46 "✓ node_exporter installed and running on port 9100"
}

# Enable Remote Login (SSH)
enable_ssh() {
    gum style --foreground 212 "Enabling Remote Login (SSH)..."

    # Check if already enabled
    if sudo systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
        gum style --foreground 46 "✓ Remote Login already enabled"
        return 0
    fi

    sudo systemsetup -setremotelogin on 2>/dev/null || {
        gum style --foreground 226 "⚠ Please enable Remote Login manually:"
        gum style --foreground 252 "  System Preferences → Sharing → Remote Login"
    }
}

# Main setup function
run_mac_setup() {
    local nas_ip="$1"
    local media_path="$2"
    local cache_path="$3"
    local errors=0

    # Check if running on Mac
    if [[ "$OSTYPE" != "darwin"* ]]; then
        gum style --foreground 196 "Error: This must be run on macOS"
        return 1
    fi

    gum style --foreground 212 "Starting Apple Silicon Mac setup..."
    echo ""

    # Run all setup steps (continue on error)
    install_homebrew || ((errors++))
    echo ""
    install_ffmpeg || ((errors++))
    echo ""
    enable_ssh || ((errors++))
    echo ""

    # Check for synthetic links and offer to set up
    if [[ ! -d "/data" ]]; then
        setup_synthetic_links || ((errors++))
    else
        gum style --foreground 46 "✓ /data directory exists"
    fi

    echo ""
    create_media_mount_script "$nas_ip" "$media_path" || ((errors++))
    create_cache_mount_script "$nas_ip" "$cache_path" || ((errors++))
    create_launch_daemons || ((errors++))
    echo ""
    configure_energy_settings || ((errors++))
    echo ""
    install_node_exporter || ((errors++))

    echo ""
    if [[ $errors -eq 0 ]]; then
        gum style --foreground 46 --border double --padding "1 2" \
            "🎉 Apple Silicon Mac setup complete!" \
            "" \
            "Next steps:" \
            "1. Copy SSH public key from Jellyfin server" \
            "2. Add this Mac to rffmpeg on the server"
    else
        gum style --foreground 226 --border double --padding "1 2" \
            "⚠️  Setup completed with $errors warning(s)" \
            "" \
            "Some components may need manual configuration." \
            "Check the messages above for details."
    fi
}
