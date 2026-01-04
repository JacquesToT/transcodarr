#!/bin/bash
#
# Mac Setup Module for Transcodarr
# Refactored with idempotency and state persistence
#

# Source dependencies (if not already sourced)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$STATE_DIR" ]] && source "$SCRIPT_DIR/state.sh"
[[ -z "$RED" ]] && source "$SCRIPT_DIR/ui.sh"

# ============================================================================
# HOMEBREW
# ============================================================================

check_homebrew() {
    command -v brew &> /dev/null
}

install_homebrew() {
    if check_homebrew; then
        show_skip "Homebrew is already installed"
        return 0
    fi

    show_what_this_does "Homebrew is a package manager for macOS. We use it to install FFmpeg."

    if command -v gum &> /dev/null; then
        gum spin --spinner dot --title "Installing Homebrew..." -- \
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    # Add to PATH for Apple Silicon
    if [[ $(uname -m) == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"

        # Add to .zprofile for future sessions
        if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile 2>/dev/null; then
            echo '' >> ~/.zprofile
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        fi
    fi

    if check_homebrew; then
        show_result true "Homebrew installed"
        mark_step_complete "homebrew"
        return 0
    else
        show_result false "Homebrew installation failed"
        return 1
    fi
}

# ============================================================================
# FFMPEG
# ============================================================================

check_ffmpeg() {
    [[ -f "/opt/homebrew/bin/ffmpeg" ]] && \
        /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q "videotoolbox"
}

check_ffmpeg_fdk_aac() {
    [[ -f "/opt/homebrew/bin/ffmpeg" ]] && \
        /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q "libfdk_aac"
}

install_ffmpeg() {
    if check_ffmpeg; then
        show_skip "FFmpeg with VideoToolbox is already installed"
        if check_ffmpeg_fdk_aac; then
            show_info "libfdk-aac encoder available"
        fi
        return 0
    fi

    show_what_this_does "FFmpeg converts video. We install a version with Apple's VideoToolbox for hardware acceleration."

    echo ""
    show_info "This may take a few minutes..."
    echo ""

    # Add the tap
    show_info "Adding homebrew-ffmpeg tap..."
    if ! brew tap homebrew-ffmpeg/ffmpeg 2>&1; then
        show_warning "Could not add homebrew-ffmpeg tap, trying standard FFmpeg..."
    fi

    # Try to install with fdk-aac first
    show_info "Installing FFmpeg..."
    if brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac 2>&1; then
        show_result true "FFmpeg installed with fdk-aac"
    else
        # Try upgrade if already installed
        show_warning "Trying upgrade..."
        if ! brew upgrade homebrew-ffmpeg/ffmpeg/ffmpeg 2>&1; then
            # Last resort: try regular ffmpeg
            show_warning "Trying standard FFmpeg..."
            brew install ffmpeg 2>&1 || true
        fi
    fi

    echo ""

    # Verify installation
    if check_ffmpeg; then
        show_result true "FFmpeg with VideoToolbox installed"
        mark_step_complete "ffmpeg"

        if check_ffmpeg_fdk_aac; then
            show_info "libfdk-aac encoder available"
        else
            show_warning "libfdk-aac not available (aac will be used)"
        fi
        return 0
    else
        if [[ -f "/opt/homebrew/bin/ffmpeg" ]]; then
            show_warning "FFmpeg installed but VideoToolbox not found"
            show_info "Software encoding will be used"
            mark_step_complete "ffmpeg"
            return 0
        else
            show_result false "FFmpeg not found"
            show_info "Try manually: brew install ffmpeg"
            return 1
        fi
    fi
}

# ============================================================================
# SSH (REMOTE LOGIN)
# ============================================================================

check_ssh_enabled() {
    # Check if sshd is running
    pgrep -x sshd &> /dev/null || \
    sudo systemsetup -getremotelogin 2>/dev/null | grep -q "On"
}

enable_ssh() {
    if check_ssh_enabled; then
        show_skip "Remote Login (SSH) is already enabled"
        return 0
    fi

    show_what_this_does "Remote Login allows Jellyfin to send FFmpeg commands to your Mac."

    if sudo systemsetup -setremotelogin on 2>/dev/null; then
        show_result true "Remote Login enabled"
        mark_step_complete "ssh_enabled"
        return 0
    else
        show_warning "Could not automatically enable Remote Login"
        show_remote_login_instructions
        if wait_for_user "Have you enabled Remote Login?"; then
            mark_step_complete "ssh_enabled"
            return 0
        fi
        return 1
    fi
}

# ============================================================================
# SYNTHETIC LINKS (/data, /config)
# ============================================================================

check_synthetic_links() {
    [[ -d "/data" ]] && [[ -d "/config" ]]
}

check_synthetic_conf() {
    [[ -f "/etc/synthetic.conf" ]] && \
        grep -q "^data" "/etc/synthetic.conf" && \
        grep -q "^config" "/etc/synthetic.conf"
}

setup_synthetic_links() {
    if check_synthetic_links; then
        show_skip "/data and /config already exist"
        return 0
    fi

    if check_synthetic_conf; then
        show_info "synthetic.conf is configured, reboot required"
        set_pending_reboot
        return 2  # Special return code for "needs reboot"
    fi

    show_what_this_does "We create /data and /config mount points. This requires a reboot."

    show_explanation "Why synthetic links?" \
        "macOS doesn't allow creating folders in /." \
        "Synthetic links are a special way to do this." \
        "After a reboot, /data and /config will appear automatically."

    if ask_confirm "Create synthetic links? (requires sudo)"; then
        # Create the backing directories
        sudo mkdir -p /System/Volumes/Data/data/media
        sudo mkdir -p /System/Volumes/Data/config/cache

        # Add synthetic links
        {
            echo -e "data\tSystem/Volumes/Data/data"
            echo -e "config\tSystem/Volumes/Data/config"
        } | sudo tee /etc/synthetic.conf > /dev/null

        show_result true "Synthetic links configured"
        mark_step_complete "synthetic_links"
        set_pending_reboot

        return 2  # Needs reboot
    else
        show_warning "Synthetic links skipped"
        return 1
    fi
}

# ============================================================================
# NFS MOUNT SCRIPTS
# ============================================================================

check_mount_scripts() {
    [[ -f "/usr/local/bin/mount-nfs-media.sh" ]] && \
    [[ -f "/usr/local/bin/mount-synology-cache.sh" ]]
}

create_media_mount_script() {
    local nas_ip="$1"
    local media_path="$2"
    local script_path="/usr/local/bin/mount-nfs-media.sh"

    if [[ -f "$script_path" ]]; then
        show_skip "Media mount script already exists"
        return 0
    fi

    show_info "Creating media mount script..."
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
    show_result true "Media mount script created"
}

create_cache_mount_script() {
    local nas_ip="$1"
    local cache_path="$2"
    local script_path="/usr/local/bin/mount-synology-cache.sh"

    if [[ -f "$script_path" ]]; then
        show_skip "Cache mount script already exists"
        return 0
    fi

    show_info "Creating cache mount script..."

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
    show_result true "Cache mount script created"
}

# ============================================================================
# LAUNCHDAEMONS
# ============================================================================

check_launch_daemons() {
    [[ -f "/Library/LaunchDaemons/com.transcodarr.nfs-media.plist" ]] && \
    [[ -f "/Library/LaunchDaemons/com.transcodarr.nfs-cache.plist" ]]
}

create_launch_daemons() {
    local plist_dir="/Library/LaunchDaemons"

    if check_launch_daemons; then
        show_skip "LaunchDaemons already exist"
        return 0
    fi

    show_info "Creating LaunchDaemons for auto-mount..."

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

    show_result true "LaunchDaemons created and loaded"
    mark_step_complete "launch_daemons"
}

# ============================================================================
# ENERGY SETTINGS
# ============================================================================

check_energy_settings() {
    local sleep_val
    sleep_val=$(pmset -g 2>/dev/null | grep -E "^\s*sleep\s+" | awk '{print $2}')
    [[ "$sleep_val" == "0" ]]
}

configure_energy_settings() {
    if check_energy_settings; then
        show_skip "Energy settings are already configured"
        return 0
    fi

    show_what_this_does "We disable sleep mode so your Mac is always available for transcoding."

    sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 autorestart 1 womp 1

    show_result true "Energy settings configured"
    show_info "sleep=0, autorestart=1, Wake-on-LAN=1"
    mark_step_complete "energy_settings"
}

# ============================================================================
# SSH KEY CHECK
# ============================================================================

check_transcodarr_ssh_key() {
    [[ -f "$HOME/.ssh/authorized_keys" ]] && \
        grep -q "transcodarr" "$HOME/.ssh/authorized_keys" 2>/dev/null
}

# ============================================================================
# MAIN SETUP FUNCTION
# ============================================================================

run_mac_setup() {
    local nas_ip="$1"
    local media_path="$2"
    local cache_path="$3"
    local errors=0
    local needs_reboot=false

    # Check if running on Mac
    if [[ "$OSTYPE" != "darwin"* ]]; then
        show_error "This script must run on macOS"
        return 1
    fi

    # Initialize state
    if ! state_exists; then
        create_state "mac"
    fi
    set_machine_type "mac"

    # Save config to state
    set_config "nas_ip" "$nas_ip"
    set_config "media_path" "$media_path"
    set_config "cache_path" "$cache_path"

    echo ""

    # Step 1: Homebrew
    install_homebrew || ((errors++))
    echo ""

    # Step 2: FFmpeg
    install_ffmpeg || ((errors++))
    echo ""

    # Step 3: SSH
    enable_ssh || ((errors++))
    echo ""

    # Step 4: Synthetic Links (may require reboot)
    local synth_result
    setup_synthetic_links
    synth_result=$?
    if [[ $synth_result -eq 2 ]]; then
        needs_reboot=true
    elif [[ $synth_result -ne 0 ]]; then
        ((errors++))
    fi
    echo ""

    # If reboot needed, stop here
    if [[ "$needs_reboot" == true ]]; then
        show_reboot_instructions "$(pwd)"
        if ask_confirm "Reboot now?"; then
            show_info "Rebooting in 3 seconds..."
            sleep 3
            sudo reboot
        else
            show_warning "Don't forget to reboot before continuing!"
        fi
        return 2  # Special return code
    fi

    # Step 5: Mount scripts (only if synthetic links exist)
    if check_synthetic_links; then
        create_media_mount_script "$nas_ip" "$media_path" || ((errors++))
        create_cache_mount_script "$nas_ip" "$cache_path" || ((errors++))
        create_launch_daemons || ((errors++))
        echo ""
    else
        show_warning "Synthetic links not found, mount scripts skipped"
        echo ""
    fi

    # Step 6: Energy settings
    configure_energy_settings || ((errors++))
    echo ""

    # Summary
    if [[ $errors -eq 0 ]]; then
        show_mac_summary "$nas_ip"
    else
        show_warning "Setup completed with $errors warning(s)"
        show_info "Check the messages above for details"
    fi

    # Show DOCKER_MODS instructions
    local mac_ip
    mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "<MAC_IP>")
    echo ""
    show_docker_mods_instructions "$mac_ip"

    return $errors
}

# Run setup after reboot (continues where we left off)
run_mac_setup_after_reboot() {
    # Load config from state
    local nas_ip
    local media_path
    local cache_path

    nas_ip=$(get_config "nas_ip")
    media_path=$(get_config "media_path")
    cache_path=$(get_config "cache_path")

    if [[ -z "$nas_ip" ]]; then
        show_error "No saved configuration found"
        show_info "Run the installer again"
        return 1
    fi

    show_info "Continuing with saved configuration..."
    show_info "NAS IP: $nas_ip"

    clear_pending_reboot
    run_mac_setup "$nas_ip" "$media_path" "$cache_path"
}
