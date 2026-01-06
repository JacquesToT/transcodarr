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
    show_warning "║  ACTION REQUIRED: Reboot your Mac now!                    ║"
    show_warning "║                                                           ║"
    show_warning "║  On your Mac: Apple menu → Restart                        ║"
    show_warning "║  Or run: sudo reboot                                      ║"
    show_warning "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    show_info "After clicking 'Yes', the installer will wait for Mac to restart."
    echo ""

    if ask_confirm "Is the Mac rebooting? Click Yes to continue"; then
        set_state_value "reboot_in_progress" "true"
        set_state_value "reboot_mac_ip" "$mac_ip"
        set_state_value "reboot_mac_user" "$mac_user"

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
        show_warning "Installer paused. Re-run after Mac reboot."
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
    ssh -tt \
        -o ConnectTimeout=30 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" \
        'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

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

remote_install_ffmpeg() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    if remote_check_ffmpeg "$mac_user" "$mac_ip" "$key_path"; then
        show_skip "FFmpeg with VideoToolbox is already installed"
        return 0
    fi

    show_info "Installing FFmpeg on Mac..."
    show_info "This may take several minutes (compiling from source)..."

    ssh_exec "$mac_user" "$mac_ip" "$key_path" '
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        brew tap homebrew-ffmpeg/ffmpeg 2>&1 || true
        brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac 2>&1 || brew install ffmpeg 2>&1 || true
    '

    if remote_check_ffmpeg "$mac_user" "$mac_ip" "$key_path"; then
        show_result true "FFmpeg with VideoToolbox installed"
        return 0
    else
        if ssh_exec "$mac_user" "$mac_ip" "$key_path" "[[ -f /opt/homebrew/bin/ffmpeg ]]"; then
            show_warning "FFmpeg installed but VideoToolbox not detected"
            return 0
        fi
        show_result false "FFmpeg installation failed"
        return 1
    fi
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

if mount | grep -q \"\$MOUNT_POINT\"; then
    log \"NFS already mounted\"
    exit 0
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

# === Test Mount ===
/usr/local/bin/mount-nfs-media.sh 2>/dev/null || true

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

        # Verify NFS mount
        if ssh_exec "$mac_user" "$mac_ip" "$key_path" "mount | grep -q '/data/media'"; then
            show_result true "NFS media mount working"
        else
            show_warning "NFS mount not active yet (will mount on next boot)"
            show_info "Run manually on Mac: sudo /usr/local/bin/mount-nfs-media.sh"
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
                # FFmpeg removal runs as user, not root
                uninstall_script+="
echo 'REMOVED: FFmpeg (manual step needed)'
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

    local temp_output
    temp_output=$(mktemp)

    # Write script to temp file on Mac, then execute with sudo
    # This keeps stdin free for the password prompt
    ssh -tt \
        -o ConnectTimeout=30 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" \
        "TMPSCRIPT=\$(mktemp) && echo '$script_b64' | base64 -d > \"\$TMPSCRIPT\" && sudo bash \"\$TMPSCRIPT\" && rm -f \"\$TMPSCRIPT\"" \
        2>&1 | tee "$temp_output"

    # Show results from captured output
    grep "^REMOVED:" "$temp_output" 2>/dev/null | while read -r line; do
        show_result true "${line#REMOVED: }"
    done
    rm -f "$temp_output"

    # Handle FFmpeg removal (as user via brew)
    if echo "$components" | grep -q "ffmpeg"; then
        show_info "Removing FFmpeg via Homebrew..."
        ssh_exec "$mac_user" "$mac_ip" "$key_path" '
            if [[ -f /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [[ -f /usr/local/bin/brew ]]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
            brew uninstall homebrew-ffmpeg/ffmpeg/ffmpeg 2>/dev/null || brew uninstall ffmpeg 2>/dev/null || true
            brew untap homebrew-ffmpeg/ffmpeg 2>/dev/null || true
        ' 2>/dev/null
        show_result true "FFmpeg removed"
    fi

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
