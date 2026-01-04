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

    ssh -o StrictHostKeyChecking=accept-new \
        "${mac_user}@${mac_ip}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'SSH key installed successfully'"
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
ssh_exec_sudo() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"
    local command="$4"
    ssh -t -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$key_path" \
        "${mac_user}@${mac_ip}" "sudo $command"
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

    show_info "Please reboot your Mac now."
    show_info "The installer will wait for it to come back."
    echo ""

    if ask_confirm "Wait for Mac to reboot?"; then
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

    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
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

    # Media mount script
    ssh_exec "$mac_user" "$mac_ip" "$key_path" "sudo mkdir -p /usr/local/bin"

    ssh_exec "$mac_user" "$mac_ip" "$key_path" "sudo tee /usr/local/bin/mount-nfs-media.sh > /dev/null << 'EOF'
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
EOF"

    ssh_exec "$mac_user" "$mac_ip" "$key_path" "sudo chmod +x /usr/local/bin/mount-nfs-media.sh"

    # Cache mount script
    ssh_exec "$mac_user" "$mac_ip" "$key_path" "sudo tee /usr/local/bin/mount-synology-cache.sh > /dev/null << 'EOF'
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

if [[ ! -L /config/cache ]]; then
    ln -sf \"\$MOUNT_POINT\" /config/cache 2>/dev/null || true
fi
EOF"

    ssh_exec "$mac_user" "$mac_ip" "$key_path" "sudo chmod +x /usr/local/bin/mount-synology-cache.sh"

    show_result true "Mount scripts created"
}

remote_create_launch_daemons() {
    local mac_user="$1"
    local mac_ip="$2"
    local key_path="$3"

    show_info "Creating LaunchDaemons on Mac..."

    # Media mount daemon
    ssh_exec "$mac_user" "$mac_ip" "$key_path" 'sudo tee /Library/LaunchDaemons/com.transcodarr.nfs-media.plist > /dev/null << '\''EOF'\''
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
EOF'

    # Cache mount daemon
    ssh_exec "$mac_user" "$mac_ip" "$key_path" 'sudo tee /Library/LaunchDaemons/com.transcodarr.nfs-cache.plist > /dev/null << '\''EOF'\''
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
EOF'

    # Load the daemons
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "sudo launchctl load /Library/LaunchDaemons/com.transcodarr.nfs-media.plist 2>/dev/null || true"
    ssh_exec "$mac_user" "$mac_ip" "$key_path" \
        "sudo launchctl load /Library/LaunchDaemons/com.transcodarr.nfs-cache.plist 2>/dev/null || true"

    show_result true "LaunchDaemons created and loaded"
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
