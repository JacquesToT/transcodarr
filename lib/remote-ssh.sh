#!/bin/bash
#
# Remote SSH Module for Transcodarr
# Executes Mac setup commands remotely from Synology
#

# Source dependencies (if not already sourced)
# Use local variable to avoid overwriting parent SCRIPT_DIR
_REMOTE_SSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$STATE_DIR" ]] && source "$_REMOTE_SSH_DIR/state.sh"
[[ -z "$RED" ]] && source "$_REMOTE_SSH_DIR/ui.sh"

# ============================================================================
# SSH CONNECTION MANAGEMENT
# ============================================================================

# Test if Mac is reachable by checking if SSH port responds
# Checks the SSH output for signs of connectivity
test_mac_reachable() {
    local mac_ip="$1"
    local timeout="${2:-5}"

    # Try SSH connection and capture stderr
    local output
    output=$(ssh -o BatchMode=yes \
        -o ConnectTimeout="$timeout" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "nobody@${mac_ip}" "exit" 2>&1)

    # If we get "Permission denied" or "publickey" - host IS reachable (SSH responded)
    # If we get "Connection refused" - host reachable but SSH not running
    # If we get "timed out" or "No route" - host NOT reachable
    if echo "$output" | grep -qi "permission denied\|publickey\|password"; then
        return 0  # Reachable - got auth error means SSH is responding
    elif echo "$output" | grep -qi "connection refused"; then
        return 1  # Reachable but SSH not enabled
    else
        return 1  # Not reachable
    fi
}

# Test if SSH port is open on Mac
test_ssh_port() {
    local mac_ip="$1"
    local timeout="${2:-5}"
    if command -v nc &>/dev/null; then
        nc -z -w"$timeout" "$mac_ip" 22 &>/dev/null
    else
        return 0
    fi
}

# Test if SSH key authentication works
test_ssh_key_auth() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" "echo ok" &>/dev/null
}

# Install SSH key on Mac (requires password once)
install_ssh_key_interactive() {
    local mac_user="$1"
    local mac_ip="$2"
    local pubkey_path="$3"
    local pubkey
    pubkey=$(cat "$pubkey_path")

    echo ""
    show_ssh_password_prompt "$mac_user" "$mac_ip"
    echo ""

    if ssh -o StrictHostKeyChecking=accept-new \
        "${mac_user}@${mac_ip}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'SSH key installed successfully'"; then
        echo ""
        show_result true "SSH key installed on Mac"
        return 0
    else
        echo ""
        show_error "SSH key installation failed"
        show_info "Check that the password was correct"
        return 1
    fi
}

# ============================================================================
# REMOTE COMMAND EXECUTION
# ============================================================================

# Execute a command on the Mac via SSH
ssh_exec() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local command="$4"
    ssh -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" "$command"
}

# Execute a command with sudo on the Mac
# Uses -tt to force TTY allocation even when stdin isn't a terminal (needed on Synology)
ssh_exec_sudo() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local command="$4"
    ssh -tt \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" "sudo $command"
}

# Execute multiple sudo commands in a single SSH session
# This minimizes password prompts by running all commands under one sudo session
# Usage: ssh_exec_sudo_script user ip key_path <<'SCRIPT'
#   command1
#   command2
# SCRIPT
ssh_exec_sudo_script() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local script
    script=$(cat)  # Read from stdin

    # Wrap commands in a single sudo bash -c call
    ssh -tt \
        -o ConnectTimeout=30 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" "sudo bash -c '$script'"
}

# Execute a command and capture output
ssh_exec_capture() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local command="$4"
    ssh -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" "$command" 2>/dev/null
}

# ============================================================================
# REBOOT HANDLING
# ============================================================================

# Wait for Mac to go down (become unreachable)
wait_for_mac_down() {
    local mac_ip="$1"
    local timeout="${2:-120}"
    local elapsed=0

    show_info "Waiting for Mac to shut down..."

    while test_mac_reachable "$mac_ip" 1; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [[ $elapsed -ge $timeout ]]; then
            show_warning "Mac still reachable after ${timeout}s"
            return 1
        fi
        printf "\r  Waiting... %ds  " "$elapsed"
    done

    printf "\r  Mac is down after %ds     \n" "$elapsed"
    return 0
}

# Wait for Mac to come back up (become reachable via SSH)
wait_for_mac_up() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local timeout="${4:-300}"
    local elapsed=0

    show_info "Waiting for Mac to come back online..."

    # First wait for ping
    while ! test_mac_reachable "$mac_ip" 2; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $elapsed -ge $timeout ]]; then
            show_error "Mac not reachable after ${timeout}s"
            return 1
        fi
        printf "\r  Waiting for network... %ds  " "$elapsed"
    done

    printf "\r  Mac network up after %ds, waiting for SSH...     \n" "$elapsed"

    # Then wait for SSH
    while ! test_ssh_key_auth "$mac_user" "$mac_ip" "$key_path"; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $elapsed -ge $timeout ]]; then
            show_error "SSH not available after ${timeout}s"
            return 1
        fi
        printf "\r  Waiting for SSH... %ds  " "$elapsed"
    done

    printf "\r  Mac SSH available after %ds     \n" "$elapsed"
    return 0
}

# Handle full reboot cycle
handle_mac_reboot() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    echo ""
    show_reboot_wait_message

    echo ""
    show_warning "╔═══════════════════════════════════════════════════════════╗"
    show_warning "║  MAC REBOOT REQUIRED                                      ║"
    show_warning "║                                                           ║"
    show_warning "║  The /data and /config mount points need a reboot         ║"
    show_warning "║  to become active. Without this, transcoding will         ║"
    show_warning "║  NOT work!                                                ║"
    show_warning "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    if ask_confirm "Reboot Mac now?"; then
        set_state_value "reboot_in_progress" "true"
        set_state_value "reboot_mac_ip" "$mac_ip"
        set_state_value "reboot_mac_user" "$mac_user"

        show_info "Sending reboot command to Mac..."
        ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" "reboot" 2>/dev/null || true

        show_info "Waiting for Mac to go offline..."
        sleep 5

        if wait_for_mac_down "$mac_ip" 180; then
            show_result true "Mac is rebooting"
        else
            show_warning "Mac didn't go offline - maybe already rebooted?"
        fi

        if wait_for_mac_up "$mac_user" "$mac_ip" "$key_path" 300; then
            clear_state_value "reboot_in_progress"
            show_result true "Mac is back online!"
            return 0
        else
            show_error "Mac did not come back online"
            show_info "Check your Mac and re-run the installer"
            return 1
        fi
    else
        echo ""
        show_error "╔═══════════════════════════════════════════════════════════╗"
        show_error "║  WARNING: Transcoding will NOT work without reboot!       ║"
        show_error "║                                                           ║"
        show_error "║  The synthetic links (/data, /config) are not active.     ║"
        show_error "║  FFmpeg cannot access media files without these paths.    ║"
        show_error "║                                                           ║"
        show_error "║  To complete setup later:                                 ║"
        show_error "║  1. Reboot your Mac manually                              ║"
        show_error "║  2. Re-run ./install.sh on Synology                       ║"
        show_error "╚═══════════════════════════════════════════════════════════╝"
        echo ""
        set_state_value "reboot_in_progress" "true"
        set_state_value "reboot_mac_ip" "$mac_ip"
        set_state_value "reboot_mac_user" "$mac_user"
        return 2
    fi
}

# ============================================================================
# REMOTE MAC DETECTION
# ============================================================================

remote_check_homebrew() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "command -v brew &>/dev/null || [[ -f /opt/homebrew/bin/brew ]] || [[ -f /usr/local/bin/brew ]]"
}

remote_check_ffmpeg() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    # Check jellyfin-ffmpeg first (has HDR support)
    if remote_check_jellyfin_ffmpeg "$mac_user" "$mac_ip" "$key_path"; then
        return 0
    fi

    # Check Homebrew FFmpeg
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -f /opt/homebrew/bin/ffmpeg ]] && /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q videotoolbox"
}

# Check for jellyfin-ffmpeg specifically (with tonemapx for HDR)
remote_check_jellyfin_ffmpeg() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -f /opt/jellyfin-ffmpeg/ffmpeg ]] && /opt/jellyfin-ffmpeg/ffmpeg -filters 2>&1 | grep -q tonemapx && /opt/jellyfin-ffmpeg/ffmpeg -encoders 2>&1 | grep -q videotoolbox"
}

# Check for Homebrew FFmpeg specifically
remote_check_homebrew_ffmpeg() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -f /opt/homebrew/bin/ffmpeg ]] && /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q videotoolbox"
}

remote_check_synthetic_links() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -d /data ]] && [[ -d /config ]]"
}

remote_check_synthetic_conf() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -f /etc/synthetic.conf ]] && grep -q '^data' /etc/synthetic.conf && grep -q '^config' /etc/synthetic.conf"
}

remote_check_nfs_mounts() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -f /Library/LaunchDaemons/com.transcodarr.nfs-media.plist ]]"
}

remote_check_energy_settings() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "pmset -g 2>/dev/null | grep -E '^\s*sleep\s+' | awk '{print \$2}' | grep -q '^0$'"
}

# ============================================================================
# REMOTE MAC SETUP COMMANDS
# ============================================================================

remote_install_homebrew() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    if remote_check_homebrew "$mac_user" "$mac_ip" "$key_path"; then
        show_skip "Homebrew is already installed on Mac"
        return 0
    fi

    show_info "Installing Homebrew on Mac..."
    show_info "This may take a few minutes..."
    echo ""
    show_warning ">>> Enter your MAC password when prompted <<<"
    echo ""

    # Use -tt for TTY allocation so sudo can prompt for password
    # Note: Don't use NONINTERACTIVE=1 as it makes sudo use -n (no password prompt)
    ssh -tt \
        -o ConnectTimeout=30 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" \
        '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        'if [[ $(uname -m) == "arm64" ]]; then
            echo '\''eval "$(/opt/homebrew/bin/brew shellenv)"'\'' >> ~/.zprofile
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi'

    if remote_check_homebrew "$mac_user" "$mac_ip" "$key_path"; then
        show_result true "Homebrew installed"
        return 0
    else
        show_result false "Homebrew installation failed"
        return 1
    fi
}

# Install jellyfin-ffmpeg on remote Mac (HDR/Dolby Vision support)
remote_install_jellyfin_ffmpeg() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    # Check if already installed
    if remote_check_jellyfin_ffmpeg "$mac_user" "$mac_ip" "$key_path"; then
        show_skip "jellyfin-ffmpeg is already installed on Mac"
        set_config "ffmpeg_variant" "jellyfin"
        return 0
    fi

    show_info "Installing jellyfin-ffmpeg on Mac..."
    show_info "This will download ~300MB and may take several minutes..."
    echo ""
    show_warning "╔═══════════════════════════════════════════════════════════╗"
    show_warning "║  IMPORTANT: Enter your MAC password (not Synology!)       ║"
    show_warning "║  This is needed to install FFmpeg to /opt/jellyfin-ffmpeg ║"
    show_warning "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    # Remote installation script - use TTY allocation for sudo prompts
    # NOTE: ssh_exec uses BatchMode=yes which blocks password prompts
    # We need -tt for TTY allocation so sudo can prompt for password
    ssh -tt \
        -o ConnectTimeout=120 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" '
        set -e

        JELLYFIN_FFMPEG_DIR="/opt/jellyfin-ffmpeg"

        # Get native architecture (handles Rosetta)
        if [[ $(sysctl -n hw.optional.arm64 2>/dev/null) == "1" ]]; then
            ARCH="arm64"
        else
            ARCH=$(uname -m)
        fi

        # Fetch latest version from jellyfin-ffmpeg repo (NOT jellyfin-server-macos!)
        echo "Fetching latest jellyfin-ffmpeg version..."
        RESPONSE=$(curl -sL "https://api.github.com/repos/jellyfin/jellyfin-ffmpeg/releases/latest" 2>/dev/null)
        VERSION=$(echo "$RESPONSE" | grep -o "\"tag_name\": *\"[^\"]*\"" | head -1 | sed "s/.*\"\([^\"]*\)\".*/\1/")

        if [[ -z "$VERSION" ]]; then
            VERSION="v7.1.3-1"  # Fallback
            echo "Using fallback version: $VERSION"
        fi

        echo "Version: $VERSION"

        # Determine download URL (tar.xz format from jellyfin-ffmpeg repo)
        VERSION_NUM="${VERSION#v}"  # Remove v prefix: v7.1.3-1 -> 7.1.3-1
        if [[ "$ARCH" == "arm64" ]]; then
            URL="https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/${VERSION}/jellyfin-ffmpeg_${VERSION_NUM}_portable_macarm64-gpl.tar.xz"
        else
            URL="https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/${VERSION}/jellyfin-ffmpeg_${VERSION_NUM}_portable_mac64-gpl.tar.xz"
        fi

        echo "Downloading from: $URL"
        ARCHIVE="/tmp/jellyfin-ffmpeg-$$.tar.xz"
        if ! curl -L --progress-bar -o "$ARCHIVE" "$URL"; then
            echo "ERROR: Download failed"
            rm -f "$ARCHIVE"
            exit 1
        fi

        # Verify download (should be at least 30MB)
        FILE_SIZE=$(stat -f%z "$ARCHIVE" 2>/dev/null || stat -c%s "$ARCHIVE" 2>/dev/null || echo 0)
        if [[ ! -f "$ARCHIVE" ]] || [[ "$FILE_SIZE" -lt 30000000 ]]; then
            echo "ERROR: Download incomplete (size: ${FILE_SIZE} bytes)"
            rm -f "$ARCHIVE"
            exit 1
        fi

        echo "Download complete (${FILE_SIZE} bytes)"

        # Extract archive
        echo "Extracting..."
        EXTRACT_DIR="/tmp/jellyfin-ffmpeg-extract-$$"
        mkdir -p "$EXTRACT_DIR"
        tar -xf "$ARCHIVE" -C "$EXTRACT_DIR"

        # Find ffmpeg binary in extracted files
        FFMPEG_BIN=$(find "$EXTRACT_DIR" -name "ffmpeg" -type f | head -1)
        FFPROBE_BIN=$(find "$EXTRACT_DIR" -name "ffprobe" -type f | head -1)

        if [[ -z "$FFMPEG_BIN" ]] || [[ -z "$FFPROBE_BIN" ]]; then
            echo "ERROR: ffmpeg/ffprobe not found in archive"
            rm -rf "$ARCHIVE" "$EXTRACT_DIR"
            exit 1
        fi

        echo "Found: $FFMPEG_BIN"

        # Install to /opt/jellyfin-ffmpeg
        echo "Installing to $JELLYFIN_FFMPEG_DIR..."
        sudo mkdir -p "$JELLYFIN_FFMPEG_DIR"
        sudo cp "$FFMPEG_BIN" "${JELLYFIN_FFMPEG_DIR}/ffmpeg"
        sudo cp "$FFPROBE_BIN" "${JELLYFIN_FFMPEG_DIR}/ffprobe"

        # Cleanup
        echo "Cleaning up..."
        rm -rf "$ARCHIVE" "$EXTRACT_DIR"

        # Remove quarantine and set permissions
        echo "Configuring permissions..."
        sudo xattr -rd com.apple.quarantine "$JELLYFIN_FFMPEG_DIR" 2>/dev/null || true
        sudo chmod +x "${JELLYFIN_FFMPEG_DIR}/ffmpeg" "${JELLYFIN_FFMPEG_DIR}/ffprobe"

        # Create wrapper script to fix libfdk_aac incompatibility
        # Jellyfin may request libfdk_aac but jellyfin-ffmpeg has --disable-libfdk-aac
        # Wrapper replaces libfdk_aac with native aac encoder
        echo "Creating ffmpeg wrapper for codec compatibility..."
        sudo mv "${JELLYFIN_FFMPEG_DIR}/ffmpeg" "${JELLYFIN_FFMPEG_DIR}/ffmpeg.real"
        sudo tee "${JELLYFIN_FFMPEG_DIR}/ffmpeg" > /dev/null << '"'"'WRAPPER'"'"'
#!/bin/bash
# Transcodarr ffmpeg wrapper
# Replaces libfdk_aac with aac (native encoder) for compatibility
# jellyfin-ffmpeg is built with --disable-libfdk-aac
args=()
for arg in "$@"; do
    args+=("${arg/libfdk_aac/aac}")
done
exec /opt/jellyfin-ffmpeg/ffmpeg.real "${args[@]}"
WRAPPER
        sudo chmod +x "${JELLYFIN_FFMPEG_DIR}/ffmpeg"

        # Verification (use ffmpeg.real for version check)
        echo "Verifying installation..."
        if "${JELLYFIN_FFMPEG_DIR}/ffmpeg.real" -filters 2>&1 | grep -q tonemapx; then
            echo "SUCCESS: jellyfin-ffmpeg installed with HDR/tonemapx support"
            echo "Wrapper: libfdk_aac -> aac (native encoder)"
            "${JELLYFIN_FFMPEG_DIR}/ffmpeg.real" -version | head -1
        else
            echo "WARNING: tonemapx filter not detected (may still work for SDR)"
            "${JELLYFIN_FFMPEG_DIR}/ffmpeg.real" -version | head -1
        fi
    '

    # Verify installation from Synology side
    if remote_check_jellyfin_ffmpeg "$mac_user" "$mac_ip" "$key_path"; then
        show_result true "jellyfin-ffmpeg installed on Mac"
        set_config "ffmpeg_variant" "jellyfin"
        return 0
    else
        show_error "jellyfin-ffmpeg installation failed on Mac"
        echo ""
        show_info "Common causes:"
        echo "  • Wrong password - make sure you enter your MAC password (not Synology)"
        echo "  • Sudo timeout - try running the installer again"
        echo "  • Network issue - check SSH connection to Mac"
        echo ""
        return 1
    fi
}

# Check if wrapper is installed (ffmpeg.real exists)
remote_check_ffmpeg_wrapper() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "[[ -f /opt/jellyfin-ffmpeg/ffmpeg.real ]]"
}

# Install wrapper on existing jellyfin-ffmpeg installation
remote_install_ffmpeg_wrapper() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    show_progress "Installing ffmpeg wrapper for codec compatibility..."

    ssh -tt \
        -o ConnectTimeout=60 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" '
        JELLYFIN_FFMPEG_DIR="/opt/jellyfin-ffmpeg"

        # Rename real ffmpeg
        sudo mv "${JELLYFIN_FFMPEG_DIR}/ffmpeg" "${JELLYFIN_FFMPEG_DIR}/ffmpeg.real"

        # Create wrapper script
        sudo tee "${JELLYFIN_FFMPEG_DIR}/ffmpeg" > /dev/null << '"'"'WRAPPER'"'"'
#!/bin/bash
# Transcodarr ffmpeg wrapper
# Replaces libfdk_aac with aac (native encoder) for compatibility
# jellyfin-ffmpeg is built with --disable-libfdk-aac
args=()
for arg in "$@"; do
    args+=("${arg/libfdk_aac/aac}")
done
exec /opt/jellyfin-ffmpeg/ffmpeg.real "${args[@]}"
WRAPPER
        sudo chmod +x "${JELLYFIN_FFMPEG_DIR}/ffmpeg"
        echo "Wrapper installed: libfdk_aac -> aac"
    '

    if remote_check_ffmpeg_wrapper "$mac_user" "$mac_ip" "$key_path"; then
        show_result true "ffmpeg wrapper installed"
        return 0
    else
        show_warning "wrapper installation may have failed"
        return 1
    fi
}

# Main FFmpeg installation - always installs jellyfin-ffmpeg
# jellyfin-ffmpeg provides HDR/HDR10+/Dolby Vision support via tonemapx filter
remote_install_ffmpeg() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    # Check if jellyfin-ffmpeg is already installed
    if remote_check_jellyfin_ffmpeg "$mac_user" "$mac_ip" "$key_path"; then
        show_skip "jellyfin-ffmpeg is already installed (HDR support enabled)"
        set_config "ffmpeg_variant" "jellyfin"

        # Ensure wrapper is installed for existing installations
        if ! remote_check_ffmpeg_wrapper "$mac_user" "$mac_ip" "$key_path"; then
            remote_install_ffmpeg_wrapper "$mac_user" "$mac_ip" "$key_path"
        fi
        return 0
    fi

    # Always install jellyfin-ffmpeg (Homebrew FFmpeg no longer supported)
    remote_install_jellyfin_ffmpeg "$mac_user" "$mac_ip" "$key_path"
}

remote_setup_synthetic_links() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    if remote_check_synthetic_links "$mac_user" "$mac_ip" "$key_path"; then
        show_skip "/data and /config already exist on Mac"
        return 0
    fi

    if remote_check_synthetic_conf "$mac_user" "$mac_ip" "$key_path"; then
        show_info "synthetic.conf is configured, reboot required"
        return 2
    fi

    show_info "Creating synthetic links on Mac..."
    echo ""
    show_warning ">>> Enter the MAC password for '$mac_user' (not Synology!) <<<"
    echo ""

    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "mkdir -p /System/Volumes/Data/data/media /System/Volumes/Data/config/cache"

    # Create synthetic.conf - need sudo for /etc
    # Use sh -c to ensure the redirect happens with sudo privileges
    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "sh -c 'printf \"data\tSystem/Volumes/Data/data\nconfig\tSystem/Volumes/Data/config\n\" > /etc/synthetic.conf'"

    # Verify synthetic.conf was created
    echo ""
    if ssh_exec "$mac_user" "$mac_ip" "$key_path" "test -f /etc/synthetic.conf"; then
        show_result true "synthetic.conf created"
    else
        show_error "Failed to create /etc/synthetic.conf"
        show_info "Try manually on Mac: sudo nano /etc/synthetic.conf"
        show_info "Add these lines:"
        echo "  data    System/Volumes/Data/data"
        echo "  config  System/Volumes/Data/config"
        return 1
    fi

    show_result true "Synthetic links configured (reboot required)"
    return 2
}

remote_create_mount_scripts() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local nas_ip="$4"
    local media_path="$5"
    local cache_path="$6"

    show_info "Creating NFS mount scripts on Mac..."
    echo ""
    show_warning ">>> Enter your MAC password multiple times when prompted <<<"
    echo ""

    # Create directory
    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" "mkdir -p /usr/local/bin"

    # Media mount script - use base64 to avoid escaping issues
    local media_script="#!/bin/bash
MOUNT_POINT=\"/data/media\"
NFS_SHARE=\"${nas_ip}:${media_path}\"
LOG_FILE=\"/var/log/mount-nfs-media.log\"

log() { echo \"\$(date '+%Y-%m-%d %H:%M:%S') - \$1\" >> \"\$LOG_FILE\"; }

for i in {1..30}; do
    ping -c1 -W1 ${nas_ip} >/dev/null 2>&1 && break
    sleep 1
done

if mount | grep -q \"\$MOUNT_POINT\"; then
    log \"NFS already mounted\"
    exit 0
fi

mkdir -p \"\$MOUNT_POINT\"
/sbin/mount -t nfs -o resvport,rw,nolock \"\$NFS_SHARE\" \"\$MOUNT_POINT\"
log \"NFS mounted: \$NFS_SHARE -> \$MOUNT_POINT\"
"
    local media_b64
    media_b64=$(echo "$media_script" | base64)

    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "sh -c \"echo '$media_b64' | base64 -d > /usr/local/bin/mount-nfs-media.sh && chmod +x /usr/local/bin/mount-nfs-media.sh\""

    # Cache mount script
    local cache_script="#!/bin/bash
MOUNT_POINT=\"/Users/Shared/jellyfin-cache\"
NFS_SHARE=\"${nas_ip}:${cache_path}\"
LOG_FILE=\"/var/log/mount-synology-cache.log\"

log() { echo \"\$(date '+%Y-%m-%d %H:%M:%S') - \$1\" >> \"\$LOG_FILE\"; }

for i in {1..30}; do
    ping -c1 -W1 ${nas_ip} >/dev/null 2>&1 && break
    sleep 1
done

mkdir -p \"\$MOUNT_POINT\"
if ! mount | grep -q \"\$MOUNT_POINT\"; then
    /sbin/mount -t nfs -o resvport,rw,nolock \"\$NFS_SHARE\" \"\$MOUNT_POINT\"
    log \"Mounted Synology cache\"
fi

# Remove /config/cache if it's a directory (ln -sf doesn't replace directories)
if [[ -d /config/cache && ! -L /config/cache ]]; then
    rm -rf /config/cache
fi
if [[ ! -L /config/cache ]]; then
    ln -sf \"\$MOUNT_POINT\" /config/cache 2>/dev/null || true
fi
"
    local cache_b64
    cache_b64=$(echo "$cache_script" | base64)

    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "sh -c \"echo '$cache_b64' | base64 -d > /usr/local/bin/mount-synology-cache.sh && chmod +x /usr/local/bin/mount-synology-cache.sh\""

    # Verify scripts were created
    if ssh_exec "$mac_user" "$mac_ip" "$key_path" "test -f /usr/local/bin/mount-nfs-media.sh && test -f /usr/local/bin/mount-synology-cache.sh"; then
        show_result true "Mount scripts created"
    else
        show_error "Failed to create mount scripts"
        return 1
    fi
}

remote_create_launch_daemons() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    show_info "Creating LaunchDaemons on Mac..."
    echo ""
    show_warning ">>> Enter your MAC password when prompted <<<"
    echo ""

    # Media mount daemon - use base64 to avoid escaping issues
    local media_plist='<?xml version="1.0" encoding="UTF-8"?>
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
</plist>'
    local media_b64
    media_b64=$(echo "$media_plist" | base64)

    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "sh -c \"echo '$media_b64' | base64 -d > /Library/LaunchDaemons/com.transcodarr.nfs-media.plist\""

    # Cache mount daemon
    local cache_plist='<?xml version="1.0" encoding="UTF-8"?>
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
</plist>'
    local cache_b64
    cache_b64=$(echo "$cache_plist" | base64)

    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "sh -c \"echo '$cache_b64' | base64 -d > /Library/LaunchDaemons/com.transcodarr.nfs-cache.plist\""

    # Load the daemons
    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "launchctl load /Library/LaunchDaemons/com.transcodarr.nfs-media.plist 2>/dev/null || true"
    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "launchctl load /Library/LaunchDaemons/com.transcodarr.nfs-cache.plist 2>/dev/null || true"

    # Verify
    if ssh_exec "$mac_user" "$mac_ip" "$key_path" "test -f /Library/LaunchDaemons/com.transcodarr.nfs-media.plist"; then
        show_result true "LaunchDaemons created and loaded"
    else
        show_error "Failed to create LaunchDaemons"
        return 1
    fi
}

remote_configure_energy() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    if remote_check_energy_settings "$mac_user" "$mac_ip" "$key_path"; then
        show_skip "Energy settings already configured"
        return 0
    fi

    show_info "Configuring energy settings on Mac..."

    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 autorestart 1 womp 1"

    show_result true "Energy settings configured (sleep disabled, Wake-on-LAN enabled)"
}

# ============================================================================
# COMBINED NFS SETUP (SINGLE SUDO SESSION)
# ============================================================================

# Combined function that does all NFS setup in one sudo session
# This minimizes password prompts by running all commands together
remote_setup_nfs_complete() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local nas_ip="$4"
    local media_path="$5"
    local cache_path="$6"

    show_info "Setting up NFS on Mac (single sudo session)..."
    echo ""
    show_warning ">>> Enter your MAC password ONCE when prompted <<<"
    echo ""

    # Build the complete setup script
    # All commands run in a single sudo session
    local setup_script="
# === Cleanup Old Config ===
echo 'Cleaning up old NFS configuration...'

# Unmount existing NFS mounts (ignore errors if not mounted)
umount -f /data/media 2>/dev/null || true
umount -f /System/Volumes/Data/data/media 2>/dev/null || true
umount -f /Users/Shared/jellyfin-cache 2>/dev/null || true

# Remove old mount scripts (will be recreated with correct IPs)
rm -f /usr/local/bin/mount-nfs-media.sh
rm -f /usr/local/bin/mount-synology-cache.sh

# Fix /config/cache - remove if directory, will be recreated as symlink
if [[ -d /config/cache && ! -L /config/cache ]]; then
    rm -rf /config/cache
    echo 'Removed old /config/cache directory'
fi

echo 'Cleanup complete'

# Create directories
mkdir -p /usr/local/bin

# === Mount Scripts ===
cat > /usr/local/bin/mount-nfs-media.sh << 'MEDIA_SCRIPT'
#!/bin/bash
MOUNT_POINT=\"/data/media\"
NFS_SHARE=\"${nas_ip}:${media_path}\"
LOG_FILE=\"/var/log/mount-nfs-media.log\"

log() { echo \"\$(date '+%Y-%m-%d %H:%M:%S') - \$1\" >> \"\$LOG_FILE\"; }

for i in {1..30}; do
    ping -c1 -W1 ${nas_ip} >/dev/null 2>&1 && break
    sleep 1
done

# Check if already mounted to CORRECT share (not just any mount)
if mount | grep -q \"\$NFS_SHARE on\"; then
    log \"NFS already mounted correctly\"
    exit 0
fi

# If mounted to WRONG share, unmount first
if mount | grep -q \"\$MOUNT_POINT\"; then
    log \"Unmounting old/incorrect mount\"
    umount -f \"\$MOUNT_POINT\" 2>/dev/null || true
fi

mkdir -p \"\$MOUNT_POINT\"
/sbin/mount -t nfs -o resvport,rw,nolock \"\$NFS_SHARE\" \"\$MOUNT_POINT\"
log \"NFS mounted: \$NFS_SHARE -> \$MOUNT_POINT\"
MEDIA_SCRIPT

chmod +x /usr/local/bin/mount-nfs-media.sh

cat > /usr/local/bin/mount-synology-cache.sh << 'CACHE_SCRIPT'
#!/bin/bash
MOUNT_POINT=\"/Users/Shared/jellyfin-cache\"
NFS_SHARE=\"${nas_ip}:${cache_path}\"
LOG_FILE=\"/var/log/mount-synology-cache.log\"

log() { echo \"\$(date '+%Y-%m-%d %H:%M:%S') - \$1\" >> \"\$LOG_FILE\"; }

for i in {1..30}; do
    ping -c1 -W1 ${nas_ip} >/dev/null 2>&1 && break
    sleep 1
done

mkdir -p \"\$MOUNT_POINT\"

# Check if already mounted to CORRECT share (not just any mount)
if mount | grep -q \"\$NFS_SHARE on\"; then
    log \"Cache already mounted correctly\"
else
    # If mounted to WRONG share, unmount first
    if mount | grep -q \"\$MOUNT_POINT\"; then
        log \"Unmounting old/incorrect cache mount\"
        umount -f \"\$MOUNT_POINT\" 2>/dev/null || true
    fi
    /sbin/mount -t nfs -o resvport,rw,nolock \"\$NFS_SHARE\" \"\$MOUNT_POINT\"
    log \"Mounted Synology cache\"
fi

# Remove /config/cache if it's a directory (ln -sf doesn't replace directories)
if [[ -d /config/cache && ! -L /config/cache ]]; then
    rm -rf /config/cache
fi
if [[ ! -L /config/cache ]]; then
    ln -sf \"\$MOUNT_POINT\" /config/cache 2>/dev/null || true
fi
CACHE_SCRIPT

chmod +x /usr/local/bin/mount-synology-cache.sh

# === LaunchDaemons ===
cat > /Library/LaunchDaemons/com.transcodarr.nfs-media.plist << 'MEDIA_PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
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
MEDIA_PLIST

cat > /Library/LaunchDaemons/com.transcodarr.nfs-cache.plist << 'CACHE_PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
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
CACHE_PLIST

# Load LaunchDaemons
launchctl load /Library/LaunchDaemons/com.transcodarr.nfs-media.plist 2>/dev/null || true
launchctl load /Library/LaunchDaemons/com.transcodarr.nfs-cache.plist 2>/dev/null || true

# === Energy Settings ===
pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 autorestart 1 womp 1

# === Test Mounts ===
echo 'Running mount scripts...'
/usr/local/bin/mount-nfs-media.sh 2>/dev/null || true
/usr/local/bin/mount-synology-cache.sh 2>/dev/null || true

# === Verify Mounts ===
echo 'Verifying mounts...'
if mount | grep -q '/data/media'; then
    echo 'VERIFY_MEDIA_OK'
else
    echo 'VERIFY_MEDIA_FAILED'
fi

if mount | grep -q 'jellyfin-cache'; then
    echo 'VERIFY_CACHE_OK'
else
    echo 'VERIFY_CACHE_FAILED'
fi

# === Verify /config/cache symlink ===
if [[ -L /config/cache ]]; then
    echo 'VERIFY_SYMLINK_OK'
elif [[ -d /config/cache ]]; then
    # Fix: remove directory and create symlink
    rm -rf /config/cache
    ln -sf /Users/Shared/jellyfin-cache /config/cache
    echo 'VERIFY_SYMLINK_FIXED'
else
    # Create symlink
    ln -sf /Users/Shared/jellyfin-cache /config/cache
    echo 'VERIFY_SYMLINK_CREATED'
fi

# === Ensure transcodes directory exists ===
mkdir -p /Users/Shared/jellyfin-cache/transcodes
chmod 777 /Users/Shared/jellyfin-cache/transcodes
echo 'VERIFY_TRANSCODES_OK'

echo 'SETUP_COMPLETE'
"

    # Execute the entire setup in one sudo session
    # Strategy: Write script to temp file first, then execute with sudo
    # This keeps stdin free for the sudo password prompt
    local script_b64
    script_b64=$(echo "$setup_script" | base64)

    local temp_output
    temp_output=$(mktemp)

    # Step 1: Write the script to a temp file on Mac (no sudo needed)
    # Step 2: Execute with sudo (password prompt works correctly)
    # Step 3: Clean up temp file
    ssh -tt \
        -o ConnectTimeout=60 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" \
        "TMPSCRIPT=\$(mktemp) && echo '$script_b64' | base64 -d > \"\$TMPSCRIPT\" && sudo bash \"\$TMPSCRIPT\" && rm -f \"\$TMPSCRIPT\"" \
        2>&1 | tee "$temp_output"

    local result
    result=$(cat "$temp_output")
    rm -f "$temp_output"

    if echo "$result" | grep -q "SETUP_COMPLETE"; then
        show_result true "Mount scripts created"
        show_result true "LaunchDaemons created and loaded"
        show_result true "Energy settings configured"

        # Show verification results from script output
        local media_ok=false
        local cache_ok=false

        if echo "$result" | grep -q "VERIFY_MEDIA_OK"; then
            show_result true "NFS media mount working"
            media_ok=true
        else
            show_warning "Media mount not active"
        fi

        if echo "$result" | grep -q "VERIFY_CACHE_OK"; then
            show_result true "NFS cache mount working"
            cache_ok=true
        else
            show_warning "Cache mount not active"
        fi

        # If mounts failed, we MUST fix it before continuing
        if [[ "$media_ok" == false ]] || [[ "$cache_ok" == false ]]; then
            echo ""
            show_warning "NFS mounts are not active yet!"
            show_info "Attempting to fix automatically..."
            echo ""

            # Attempt 1: Run mount scripts with TTY for sudo
            show_info "Running mount scripts on Mac..."
            show_warning ">>> Enter your MAC password if prompted <<<"
            echo ""

            local mount_output
            mount_output=$(ssh -tt \
                -o ConnectTimeout=60 \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -i "$key_path" \
                "${mac_user}@${mac_ip}" \
                "sudo /usr/local/bin/mount-nfs-media.sh && sudo /usr/local/bin/mount-synology-cache.sh && mount | grep -E '(/data/media|jellyfin-cache)'" 2>&1)

            # Verify the mounts worked
            if echo "$mount_output" | grep -q "/data/media" && echo "$mount_output" | grep -q "jellyfin-cache"; then
                echo ""
                show_result true "NFS mounts are now active!"
                media_ok=true
                cache_ok=true
            else
                # Attempt 2: Check if mount points exist, create if needed
                echo ""
                show_info "Attempting alternative fix: creating mount points..."
                ssh -tt \
                    -o ConnectTimeout=60 \
                    -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -i "$key_path" \
                    "${mac_user}@${mac_ip}" \
                    "sudo mkdir -p /System/Volumes/Data/data/media /Users/Shared/jellyfin-cache && sudo /usr/local/bin/mount-nfs-media.sh && sudo /usr/local/bin/mount-synology-cache.sh" 2>&1

                # Final verification
                local final_check
                final_check=$(ssh_exec "$mac_user" "$mac_ip" "$key_path" "mount | grep -E '(/data/media|jellyfin-cache)'")

                if echo "$final_check" | grep -q "/data/media" && echo "$final_check" | grep -q "jellyfin-cache"; then
                    echo ""
                    show_result true "NFS mounts fixed!"
                    media_ok=true
                    cache_ok=true
                else
                    echo ""
                    show_error "Could not activate NFS mounts automatically"
                    show_warning "Transcoding will fail until this is fixed!"
                    echo ""
                    show_info "Two options to fix:"
                    echo ""
                    echo "  Option 1: Reboot Mac now (mounts will activate on boot)"
                    echo "    Command: sudo reboot"
                    echo ""
                    echo "  Option 2: Fix manually later"
                    echo "    SSH to Mac and run:"
                    echo "      sudo /usr/local/bin/mount-nfs-media.sh"
                    echo "      sudo /usr/local/bin/mount-synology-cache.sh"
                    echo ""

                    if ask_confirm "Reboot Mac now to activate mounts?"; then
                        show_info "Rebooting Mac..."
                        ssh_exec "$mac_user" "$mac_ip" "$key_path" "sudo reboot" || true

                        show_info "Mac is rebooting. Waiting 30 seconds..."
                        sleep 30

                        show_info "Waiting for Mac to come back online..."
                        local max_wait=60
                        local waited=0
                        while [[ $waited -lt $max_wait ]]; do
                            if ssh_exec "$mac_user" "$mac_ip" "$key_path" "echo ok" &>/dev/null; then
                                show_result true "Mac is back online!"

                                # Final check after reboot
                                local reboot_check
                                reboot_check=$(ssh_exec "$mac_user" "$mac_ip" "$key_path" "mount | grep -E '(/data/media|jellyfin-cache)'")

                                if echo "$reboot_check" | grep -q "/data/media" && echo "$reboot_check" | grep -q "jellyfin-cache"; then
                                    show_result true "NFS mounts active after reboot!"
                                    media_ok=true
                                    cache_ok=true
                                else
                                    show_warning "Mounts still not active - manual intervention needed"
                                fi
                                break
                            fi
                            sleep 5
                            ((waited+=5))
                        done

                        if [[ $waited -ge $max_wait ]]; then
                            show_warning "Mac did not come back online within 60 seconds"
                            show_info "Continue manually when Mac is back up"
                        fi
                    fi
                fi
            fi
        fi

        # Final validation - MUST have working mounts
        if [[ "$media_ok" == false ]] || [[ "$cache_ok" == false ]]; then
            echo ""
            show_error "Setup incomplete: NFS mounts not working"
            show_warning "Transcoding WILL fail with exit code 254 until mounts are fixed"
            echo ""
            show_info "Before using this Mac for transcoding, fix the mounts by:"
            echo "  1. SSH to Mac: ssh $mac_user@$mac_ip"
            echo "  2. Run: sudo /usr/local/bin/mount-nfs-media.sh"
            echo "  3. Run: sudo /usr/local/bin/mount-synology-cache.sh"
            echo "  4. Verify: mount | grep nfs"
            echo ""
        fi

        if echo "$result" | grep -q "VERIFY_SYMLINK_OK"; then
            show_result true "/config/cache symlink correct"
        elif echo "$result" | grep -q "VERIFY_SYMLINK_FIXED"; then
            show_result true "/config/cache symlink fixed (was directory)"
        elif echo "$result" | grep -q "VERIFY_SYMLINK_CREATED"; then
            show_result true "/config/cache symlink created"
        fi

        if echo "$result" | grep -q "VERIFY_TRANSCODES_OK"; then
            show_result true "Transcodes directory ready"
        fi

        return 0
    else
        show_error "Setup failed"
        echo "$result"
        return 1
    fi
}

# ============================================================================
# NFS VERIFICATION
# ============================================================================

remote_verify_nfs() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local nas_ip="$4"
    local media_path="$5"

    show_info "Verifying NFS mounts..."

    # Run the mount script
    ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" \
        "/usr/local/bin/mount-nfs-media.sh" 2>/dev/null || true

    # Check if mounted
    if ssh_exec "$mac_user" "$mac_ip" "$key_path" "mount | grep -q '/data/media'"; then
        show_result true "NFS media mount working"

        if ssh_exec "$mac_user" "$mac_ip" "$key_path" "ls /data/media >/dev/null 2>&1"; then
            show_result true "NFS read access verified"
            return 0
        else
            show_warning "NFS mounted but cannot read - check permissions"
            return 1
        fi
    else
        show_warning "NFS mount not active yet (will mount on next boot)"
        show_info "Run manually on Mac: sudo /usr/local/bin/mount-nfs-media.sh"
        return 0
    fi
}

# ============================================================================
# REMOTE UNINSTALL
# ============================================================================

# Uninstall Transcodarr components from Mac via SSH
# Arguments:
#   $1 - mac_user
#   $2 - mac_ip
#   $3 - key_path
#   $4 - components (space-separated list of: launchdaemons mount_scripts synthetic ffmpeg energy ssh_key)
# Returns:
#   0 - success
#   1 - failure
#   2 - reboot required (synthetic links removed)
remote_uninstall_components() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    shift 3
    local components="$*"

    local needs_reboot=false
    local uninstall_script=""

    # Build uninstall script based on selected components
    for component in $components; do
        case "$component" in
            launchdaemons)
                uninstall_script+="
# Unload and remove LaunchDaemons
launchctl unload /Library/LaunchDaemons/com.transcodarr.*.plist 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/com.jellyfin.*.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.transcodarr.*.plist
rm -f /Library/LaunchDaemons/com.jellyfin.*.plist
echo 'REMOVED: LaunchDaemons'
"
                ;;
            mount_scripts)
                uninstall_script+="
# Unmount NFS shares
umount /data/media 2>/dev/null || true
umount /Users/Shared/jellyfin-cache 2>/dev/null || true
# Remove mount scripts
rm -f /usr/local/bin/mount-nfs-media.sh
rm -f /usr/local/bin/mount-synology-cache.sh
rm -f /usr/local/bin/nfs-watchdog.sh
# Remove logs
rm -f /var/log/mount-nfs-media.log
rm -f /var/log/mount-synology-cache.log
rm -f /var/log/nfs-watchdog.log
echo 'REMOVED: Mount scripts'
"
                ;;
            synthetic)
                uninstall_script+="
# Remove synthetic.conf (requires reboot)
rm -f /etc/synthetic.conf
echo 'REMOVED: Synthetic links (reboot required)'
"
                needs_reboot=true
                ;;
            ffmpeg)
                # jellyfin-ffmpeg removal requires sudo
                uninstall_script+="
# Remove jellyfin-ffmpeg
if [[ -d /opt/jellyfin-ffmpeg ]]; then
    rm -rf /opt/jellyfin-ffmpeg
    echo 'REMOVED: jellyfin-ffmpeg'
else
    echo 'SKIP: jellyfin-ffmpeg not found'
fi
"
                ;;
            energy)
                uninstall_script+="
# Reset energy settings to defaults
pmset -a sleep 1 displaysleep 10 disksleep 10 powernap 1
echo 'REMOVED: Energy settings (sleep re-enabled)'
"
                ;;
            ssh_key)
                # SSH key removal runs as user, not root - handled separately
                uninstall_script+="
echo 'REMOVED: SSH key (manual step needed)'
"
                ;;
        esac
    done

    if [[ -z "$uninstall_script" ]]; then
        show_warning "No components selected for removal"
        return 0
    fi

    show_info "Removing components from Mac..."
    echo ""
    show_warning ">>> Enter your MAC password when prompted <<<"
    echo ""

    # Execute sudo parts using base64 + temp file to avoid stdin conflicts
    local script_b64
    script_b64=$(echo "$uninstall_script" | base64)

    # Write script to temp file on Mac, execute with sudo, capture output to file on Mac
    # This way the password prompt works correctly and output is captured separately
    ssh -t \
        -o ConnectTimeout=30 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" \
        "TMPSCRIPT=\$(mktemp) && TMPOUT=\$(mktemp) && echo '$script_b64' | base64 -d > \"\$TMPSCRIPT\" && sudo bash \"\$TMPSCRIPT\" > \"\$TMPOUT\" 2>&1 && cat \"\$TMPOUT\" && rm -f \"\$TMPSCRIPT\" \"\$TMPOUT\""

    # Show generic success since we can't easily capture the output
    echo ""
    show_result true "Mac cleanup commands executed"

    # FFmpeg (jellyfin-ffmpeg) is now removed via sudo in the uninstall script above

    # Handle SSH key removal (as user)
    if echo "$components" | grep -q "ssh_key"; then
        show_info "Removing SSH key..."
        ssh_exec "$mac_user" "$mac_ip" "$key_path" \
            "sed -i '' '/transcodarr/d' ~/.ssh/authorized_keys 2>/dev/null || true"
        show_result true "SSH key removed"
    fi

    # Handle Transcodarr state directory
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "rm -rf ~/.transcodarr 2>/dev/null || true"

    if $needs_reboot; then
        echo ""
        show_warning "Mac needs to reboot for synthetic links to be fully removed"
        return 2
    fi

    return 0
}
