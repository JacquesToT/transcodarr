#!/bin/bash
#
# Mac Setup Module for Transcodarr
# Refactored with idempotency and state persistence
#

# Source dependencies (if not already sourced)
# Use local variable to avoid overwriting parent SCRIPT_DIR
_MAC_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$STATE_DIR" ]] && source "$_MAC_SETUP_DIR/state.sh"
[[ -z "$RED" ]] && source "$_MAC_SETUP_DIR/ui.sh"

# ============================================================================
# FFMPEG CONSTANTS
# ============================================================================

# jellyfin-ffmpeg paths (HDR/Dolby Vision support)
JELLYFIN_FFMPEG_DIR="/opt/jellyfin-ffmpeg"
JELLYFIN_FFMPEG_BIN="${JELLYFIN_FFMPEG_DIR}/ffmpeg"
JELLYFIN_FFPROBE_BIN="${JELLYFIN_FFMPEG_DIR}/ffprobe"

# Homebrew FFmpeg paths (standard, no HDR tone mapping)
HOMEBREW_FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
HOMEBREW_FFPROBE_BIN="/opt/homebrew/bin/ffprobe"

# GitHub API for jellyfin-ffmpeg releases
JELLYFIN_RELEASES_URL="https://api.github.com/repos/jellyfin/jellyfin-server-macos/releases/latest"
JELLYFIN_KNOWN_GOOD_VERSION="v10.10.3"  # Fallback if API fails

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
# JELLYFIN-FFMPEG (HDR/Dolby Vision Support)
# ============================================================================

# Get native architecture (handles Rosetta correctly)
get_native_arch() {
    # Check for Apple Silicon even if running under Rosetta
    if [[ $(sysctl -n hw.optional.arm64 2>/dev/null) == "1" ]]; then
        echo "arm64"
    else
        uname -m
    fi
}

# Check if jellyfin-ffmpeg is installed and working
check_jellyfin_ffmpeg() {
    # Check 1: Binary exists
    [[ -f "$JELLYFIN_FFMPEG_BIN" ]] || return 1

    # Check 2: Can execute (no quarantine/permission issues)
    "$JELLYFIN_FFMPEG_BIN" -version &>/dev/null || return 1

    # Check 3: Has tonemapx filter (the reason we want jellyfin-ffmpeg)
    "$JELLYFIN_FFMPEG_BIN" -filters 2>&1 | grep -q "tonemapx" || return 1

    # Check 4: Has VideoToolbox (hardware acceleration)
    "$JELLYFIN_FFMPEG_BIN" -encoders 2>&1 | grep -q "videotoolbox" || return 1

    return 0
}

# Get latest jellyfin-ffmpeg version from GitHub (with rate limit fallback)
get_jellyfin_ffmpeg_latest_version() {
    local response http_code body

    # Fetch with HTTP code
    response=$(curl -sL -w "\n%{http_code}" "$JELLYFIN_RELEASES_URL" 2>/dev/null)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    # Check for rate limiting or other errors
    if [[ "$http_code" != "200" ]]; then
        show_warning "GitHub API unavailable (HTTP $http_code), using fallback version"
        echo "$JELLYFIN_KNOWN_GOOD_VERSION"
        return
    fi

    # Parse tag_name from JSON
    local version
    version=$(echo "$body" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')

    if [[ -z "$version" ]]; then
        show_warning "Could not parse version, using fallback"
        echo "$JELLYFIN_KNOWN_GOOD_VERSION"
        return
    fi

    echo "$version"
}

# Download jellyfin-ffmpeg DMG for current architecture
download_jellyfin_ffmpeg() {
    local version="${1:-$(get_jellyfin_ffmpeg_latest_version)}"
    local arch=$(get_native_arch)
    local download_url=""
    local dmg_file="/tmp/jellyfin-${version}-$$.dmg"

    # Determine download URL based on architecture
    case "$arch" in
        arm64)
            download_url="https://github.com/jellyfin/jellyfin-server-macos/releases/download/${version}/jellyfin_${version#v}-arm64.dmg"
            ;;
        x86_64)
            download_url="https://github.com/jellyfin/jellyfin-server-macos/releases/download/${version}/jellyfin_${version#v}-x64.dmg"
            ;;
        *)
            show_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    show_info "Downloading jellyfin-ffmpeg ${version} for ${arch}..."
    show_info "This is ~300MB, please wait..."

    if curl -L --progress-bar -o "$dmg_file" "$download_url" 2>&1; then
        if [[ -f "$dmg_file" ]] && [[ $(stat -f%z "$dmg_file" 2>/dev/null || stat -c%s "$dmg_file" 2>/dev/null) -gt 1000000 ]]; then
            echo "$dmg_file"
            return 0
        else
            show_error "Download incomplete or corrupted"
            rm -f "$dmg_file"
            return 1
        fi
    else
        show_error "Download failed"
        rm -f "$dmg_file"
        return 1
    fi
}

# Install jellyfin-ffmpeg from DMG
install_jellyfin_ffmpeg() {
    # Check if already installed
    if check_jellyfin_ffmpeg; then
        show_skip "jellyfin-ffmpeg is already installed"
        # Update state for consistency
        set_config "ffmpeg_variant" "jellyfin"
        set_config "ffmpeg_path" "$JELLYFIN_FFMPEG_BIN"
        return 0
    fi

    show_what_this_does "Installing jellyfin-ffmpeg for full HDR/Dolby Vision support."

    # Step 1: Get version
    local version
    version=$(get_jellyfin_ffmpeg_latest_version)
    show_info "Version: $version"

    # Step 2: Download DMG
    local dmg_file
    dmg_file=$(download_jellyfin_ffmpeg "$version")

    if [[ -z "$dmg_file" ]] || [[ ! -f "$dmg_file" ]]; then
        show_error "Download failed"
        return 1
    fi

    # Step 3: Mount DMG (with flags to prevent UI dialogs)
    local mount_point="/tmp/jellyfin_mount_$$"
    mkdir -p "$mount_point"

    show_info "Mounting disk image..."
    if ! hdiutil attach "$dmg_file" -nobrowse -noverify -noautoopen -mountpoint "$mount_point" 2>/dev/null; then
        show_error "Failed to mount DMG"
        rm -f "$dmg_file"
        rmdir "$mount_point" 2>/dev/null || true
        return 1
    fi

    # Step 4: Find and copy binaries
    # FFmpeg is in Contents/MacOS/, not Contents/Frameworks/
    local app_macos="${mount_point}/Jellyfin.app/Contents/MacOS"

    if [[ ! -f "${app_macos}/ffmpeg" ]]; then
        show_error "FFmpeg binaries not found in DMG at ${app_macos}"
        show_info "Checking alternative locations..."
        # Try alternative locations
        if [[ -f "${mount_point}/Jellyfin.app/Contents/Frameworks/ffmpeg" ]]; then
            app_macos="${mount_point}/Jellyfin.app/Contents/Frameworks"
            show_info "Found in Frameworks/"
        else
            hdiutil detach "$mount_point" -force 2>/dev/null || true
            rm -f "$dmg_file"
            rmdir "$mount_point" 2>/dev/null || true
            return 1
        fi
    fi

    show_info "Extracting FFmpeg binaries from ${app_macos}..."
    sudo mkdir -p "$JELLYFIN_FFMPEG_DIR"

    # Copy ffmpeg and ffprobe
    sudo cp "${app_macos}/ffmpeg" "$JELLYFIN_FFMPEG_BIN"
    sudo cp "${app_macos}/ffprobe" "$JELLYFIN_FFPROBE_BIN"

    # Step 5: Unmount and cleanup
    hdiutil detach "$mount_point" -force 2>/dev/null || true
    rm -f "$dmg_file"
    rmdir "$mount_point" 2>/dev/null || true

    # Step 6: Remove quarantine
    show_info "Removing macOS quarantine..."
    sudo xattr -rd com.apple.quarantine "$JELLYFIN_FFMPEG_DIR" 2>/dev/null || true

    # Step 7: Set permissions
    sudo chmod +x "$JELLYFIN_FFMPEG_BIN" "$JELLYFIN_FFPROBE_BIN" 2>/dev/null || true

    # Step 8: Verification - MUST succeed before saving state
    echo ""
    if check_jellyfin_ffmpeg; then
        show_result true "jellyfin-ffmpeg installed"

        # Show capabilities
        if "$JELLYFIN_FFMPEG_BIN" -filters 2>&1 | grep -q "tonemapx"; then
            show_info "HDR tone mapping (tonemapx): available"
        fi
        if "$JELLYFIN_FFMPEG_BIN" -encoders 2>&1 | grep -q "hevc_videotoolbox"; then
            show_info "HEVC VideoToolbox encoder: available"
        fi

        # NOW save state (only after successful verification)
        set_config "ffmpeg_variant" "jellyfin"
        set_config "ffmpeg_path" "$JELLYFIN_FFMPEG_BIN"
        set_config "ffprobe_path" "$JELLYFIN_FFPROBE_BIN"
        set_config "jellyfin_ffmpeg_version" "$version"
        mark_step_complete "jellyfin_ffmpeg"

        return 0
    else
        show_result false "jellyfin-ffmpeg verification failed"
        show_info "Cleaning up partial installation..."
        sudo rm -rf "$JELLYFIN_FFMPEG_DIR"
        return 1
    fi
}

# Uninstall jellyfin-ffmpeg (for switching back to Homebrew)
uninstall_jellyfin_ffmpeg() {
    if [[ -d "$JELLYFIN_FFMPEG_DIR" ]]; then
        show_info "Removing jellyfin-ffmpeg..."
        sudo rm -rf "$JELLYFIN_FFMPEG_DIR"
        set_config "ffmpeg_variant" ""
        set_config "ffmpeg_path" ""
        show_result true "jellyfin-ffmpeg removed"
    else
        show_skip "jellyfin-ffmpeg not installed"
    fi
}

# User choice between FFmpeg variants
choose_ffmpeg_variant() {
    echo ""
    show_explanation "FFmpeg Variant Selection" \
        "jellyfin-ffmpeg: Full HDR/HDR10+/Dolby Vision support (recommended)" \
        "Homebrew FFmpeg: Standard version, SDR transcoding only"

    local choice

    if command -v gum &>/dev/null; then
        choice=$(gum choose \
            "jellyfin-ffmpeg (Recommended - HDR support)" \
            "Homebrew FFmpeg (Standard - SDR only)")

        case "$choice" in
            "jellyfin-ffmpeg"*)
                echo "jellyfin"
                ;;
            "Homebrew"*)
                echo "homebrew"
                ;;
            *)
                echo "jellyfin"  # Default to recommended
                ;;
        esac
    else
        echo ""
        echo "Choose FFmpeg variant:"
        echo "  1) jellyfin-ffmpeg (Recommended - HDR support)"
        echo "  2) Homebrew FFmpeg (Standard - SDR only)"
        read -p "Choice [1]: " choice

        case "$choice" in
            2)
                echo "homebrew"
                ;;
            *)
                echo "jellyfin"
                ;;
        esac
    fi
}

# Get the path to the active ffmpeg binary
get_ffmpeg_path() {
    if check_jellyfin_ffmpeg; then
        echo "$JELLYFIN_FFMPEG_BIN"
    elif [[ -f "$HOMEBREW_FFMPEG_BIN" ]]; then
        echo "$HOMEBREW_FFMPEG_BIN"
    else
        echo ""
    fi
}

# Get the path to the active ffprobe binary
get_ffprobe_path() {
    if check_jellyfin_ffmpeg; then
        echo "$JELLYFIN_FFPROBE_BIN"
    elif [[ -f "$HOMEBREW_FFPROBE_BIN" ]]; then
        echo "$HOMEBREW_FFPROBE_BIN"
    else
        echo ""
    fi
}

# ============================================================================
# FFMPEG (Homebrew)
# ============================================================================

# Check if any FFmpeg (jellyfin or Homebrew) is installed
check_ffmpeg() {
    # Prioritize jellyfin-ffmpeg (has HDR support)
    if check_jellyfin_ffmpeg; then
        return 0
    fi

    # Fall back to Homebrew FFmpeg
    [[ -f "$HOMEBREW_FFMPEG_BIN" ]] && \
        "$HOMEBREW_FFMPEG_BIN" -encoders 2>&1 | grep -q "videotoolbox"
}

# Check for homebrew ffmpeg specifically
check_homebrew_ffmpeg() {
    [[ -f "$HOMEBREW_FFMPEG_BIN" ]] && \
        "$HOMEBREW_FFMPEG_BIN" -encoders 2>&1 | grep -q "videotoolbox"
}

check_ffmpeg_fdk_aac() {
    [[ -f "$HOMEBREW_FFMPEG_BIN" ]] && \
        "$HOMEBREW_FFMPEG_BIN" -encoders 2>&1 | grep -q "libfdk_aac"
}

# Install Homebrew FFmpeg (original function, renamed)
install_homebrew_ffmpeg() {
    if check_homebrew_ffmpeg; then
        show_skip "Homebrew FFmpeg with VideoToolbox is already installed"
        if check_ffmpeg_fdk_aac; then
            show_info "libfdk-aac encoder available"
        fi
        set_config "ffmpeg_variant" "homebrew"
        set_config "ffmpeg_path" "$HOMEBREW_FFMPEG_BIN"
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
    if check_homebrew_ffmpeg; then
        show_result true "FFmpeg with VideoToolbox installed"
        set_config "ffmpeg_variant" "homebrew"
        set_config "ffmpeg_path" "$HOMEBREW_FFMPEG_BIN"
        mark_step_complete "ffmpeg"

        if check_ffmpeg_fdk_aac; then
            show_info "libfdk-aac encoder available"
        else
            show_warning "libfdk-aac not available (aac will be used)"
        fi
        return 0
    else
        if [[ -f "$HOMEBREW_FFMPEG_BIN" ]]; then
            show_warning "FFmpeg installed but VideoToolbox not found"
            show_info "Software encoding will be used"
            set_config "ffmpeg_variant" "homebrew"
            set_config "ffmpeg_path" "$HOMEBREW_FFMPEG_BIN"
            mark_step_complete "ffmpeg"
            return 0
        else
            show_result false "FFmpeg not found"
            show_info "Try manually: brew install ffmpeg"
            return 1
        fi
    fi
}

# Main FFmpeg installation (with variant choice)
install_ffmpeg() {
    local variant="${1:-}"
    local force="${2:-false}"

    # Auto-detect existing installation (unless force=true)
    if [[ "$force" != "true" ]]; then
        if check_jellyfin_ffmpeg; then
            show_skip "jellyfin-ffmpeg is already installed (HDR support enabled)"
            set_config "ffmpeg_variant" "jellyfin"
            set_config "ffmpeg_path" "$JELLYFIN_FFMPEG_BIN"
            return 0
        fi

        if check_homebrew_ffmpeg; then
            show_skip "Homebrew FFmpeg with VideoToolbox is already installed"
            set_config "ffmpeg_variant" "homebrew"
            set_config "ffmpeg_path" "$HOMEBREW_FFMPEG_BIN"

            # Offer upgrade to jellyfin-ffmpeg
            echo ""
            show_info "Note: For HDR/Dolby Vision support, consider jellyfin-ffmpeg"
            if ask_confirm "Upgrade to jellyfin-ffmpeg for HDR support?"; then
                install_jellyfin_ffmpeg
                return $?
            fi
            return 0
        fi
    fi

    # Ask user for variant if not specified
    if [[ -z "$variant" ]]; then
        variant=$(choose_ffmpeg_variant)
    fi

    echo ""
    show_info "Installing: $variant"
    echo ""

    case "$variant" in
        jellyfin)
            install_jellyfin_ffmpeg
            ;;
        homebrew|*)
            install_homebrew_ffmpeg
            ;;
    esac
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
# Remove if it's a directory (not a symlink) - ln -sf doesn't replace directories
if [[ -d /config/cache && ! -L /config/cache ]]; then
    rm -rf /config/cache
fi
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
