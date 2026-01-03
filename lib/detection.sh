#!/bin/bash
#
# Transcodarr Auto-Detection
# Detects system type and installation status
#

# Detect if running on Synology NAS
is_synology() {
    [[ -f /etc/synoinfo.conf ]] || [[ -d /volume1 ]] || [[ -d /volume2 ]]
}

# Detect if running on macOS
is_mac() {
    [[ "$OSTYPE" == "darwin"* ]]
}

# Detect if Mac has Apple Silicon
is_apple_silicon() {
    is_mac && [[ "$(uname -m)" == "arm64" ]]
}

# Detect if Mac has Intel processor
is_intel_mac() {
    is_mac && [[ "$(uname -m)" == "x86_64" ]]
}

# Get system type as string
get_system_type() {
    if is_synology; then
        echo "synology"
    elif is_apple_silicon; then
        echo "mac_apple_silicon"
    elif is_intel_mac; then
        echo "mac_intel"
    elif is_mac; then
        echo "mac_unknown"
    else
        echo "unknown"
    fi
}

# Get friendly system name for display
get_system_name() {
    case "$(get_system_type)" in
        synology)
            echo "Synology NAS"
            ;;
        mac_apple_silicon)
            local chip
            chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -o "M[0-9][^,]*" | head -1)
            if [[ -n "$chip" ]]; then
                echo "Mac met $chip chip"
            else
                echo "Apple Silicon Mac"
            fi
            ;;
        mac_intel)
            echo "Intel Mac"
            ;;
        *)
            echo "Onbekend systeem"
            ;;
    esac
}

# ============================================================================
# SYNOLOGY DETECTION
# ============================================================================

# Check if NFS is enabled on Synology
is_nfs_enabled() {
    if ! is_synology; then
        return 0  # Not Synology, skip check
    fi

    # Check if NFS service is running
    if pgrep -x "nfsd" &> /dev/null; then
        return 0  # NFS is running
    fi

    # Alternative check: look for NFS exports
    if [[ -f /etc/exports ]] && [[ -s /etc/exports ]]; then
        return 0  # Exports file exists and is not empty
    fi

    # Check via synology service status
    if command -v synoservice &> /dev/null; then
        if synoservice --status nfsd 2>/dev/null | grep -q "running"; then
            return 0
        fi
    fi

    return 1  # NFS not enabled
}

# Check if this is first-time setup on Synology
# Returns 0 (true) if first time, 1 (false) if already set up
is_first_time_synology() {
    local jellyfin_config="${1:-}"

    # Try common Jellyfin config paths if not provided
    if [[ -z "$jellyfin_config" ]]; then
        for path in /volume1/docker/jellyfin /volume2/docker/jellyfin /volume1/docker/Jellyfin; do
            if [[ -d "$path" ]]; then
                jellyfin_config="$path"
                break
            fi
        done
    fi

    # Check if rffmpeg SSH key already exists
    if [[ -f "$jellyfin_config/rffmpeg/.ssh/id_rsa" ]]; then
        return 1  # Not first time - already configured
    fi

    return 0  # First time setup
}

# Detect Jellyfin config path on Synology
detect_jellyfin_config() {
    local paths=(
        "/volume1/docker/jellyfin"
        "/volume2/docker/jellyfin"
        "/volume1/docker/Jellyfin"
        "/volume2/docker/Jellyfin"
    )

    for path in "${paths[@]}"; do
        if [[ -d "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    # Default suggestion
    echo "/volume1/docker/jellyfin"
    return 1
}

# Detect media path on Synology
detect_media_path() {
    local paths=(
        "/volume1/data/media"
        "/volume2/data/media"
        "/volume1/Media"
        "/volume2/Media"
        "/volume1/video"
        "/volume2/video"
    )

    for path in "${paths[@]}"; do
        if [[ -d "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    # Default suggestion
    echo "/volume1/data/media"
    return 1
}

# ============================================================================
# MAC DETECTION
# ============================================================================

# Check if Homebrew is installed
is_homebrew_installed() {
    command -v brew &> /dev/null
}

# Check if FFmpeg is installed
is_ffmpeg_installed() {
    command -v ffmpeg &> /dev/null || [[ -f "/opt/homebrew/bin/ffmpeg" ]]
}

# Check if FFmpeg has VideoToolbox support
has_videotoolbox() {
    local ffmpeg_path="${1:-ffmpeg}"

    if [[ -f "/opt/homebrew/bin/ffmpeg" ]]; then
        ffmpeg_path="/opt/homebrew/bin/ffmpeg"
    fi

    "$ffmpeg_path" -encoders 2>&1 | grep -q "videotoolbox"
}

# Check if SSH key is installed in authorized_keys
has_transcodarr_ssh_key() {
    [[ -f "$HOME/.ssh/authorized_keys" ]] && \
        grep -q "transcodarr" "$HOME/.ssh/authorized_keys" 2>/dev/null
}

# Check if Remote Login (SSH) is enabled on Mac
is_ssh_enabled() {
    if is_mac; then
        # Check if sshd is running
        pgrep -x sshd &> /dev/null || \
        launchctl list 2>/dev/null | grep -q "com.openssh.sshd"
    else
        return 0  # Not Mac, assume SSH is available
    fi
}

# Check if synthetic links exist (/data, /config)
has_synthetic_links() {
    [[ -d "/data" ]] && [[ -d "/config" ]]
}

# Check if NFS mounts are configured
has_nfs_mounts() {
    # Check for LaunchDaemons
    [[ -f "/Library/LaunchDaemons/com.transcodarr.nfs-media.plist" ]] && \
    [[ -f "/Library/LaunchDaemons/com.transcodarr.nfs-cache.plist" ]]
}

# Check if energy settings are configured
has_energy_settings() {
    # Check if sleep is disabled
    local sleep_val
    sleep_val=$(pmset -g 2>/dev/null | grep -E "^\s*sleep\s+" | awk '{print $2}')
    [[ "$sleep_val" == "0" ]]
}

# Check if this is first-time setup on Mac
# Returns 0 (true) if first time, 1 (false) if already set up
is_first_time_mac() {
    # Check if FFmpeg with VideoToolbox is installed
    if is_ffmpeg_installed && has_videotoolbox; then
        return 1  # Not first time
    fi
    return 0  # First time
}

# Check if this Mac is being added as additional node
# (FFmpeg exists but no SSH key configured)
is_adding_node_mac() {
    # FFmpeg must be installed with VideoToolbox
    if ! is_ffmpeg_installed || ! has_videotoolbox; then
        return 1  # No FFmpeg = first time setup, not adding node
    fi

    # SSH key should NOT be present yet
    if has_transcodarr_ssh_key; then
        return 1  # SSH key exists = already fully configured
    fi

    return 0  # Adding as new node
}

# Check if Mac is fully configured
is_mac_fully_configured() {
    is_ffmpeg_installed && \
    has_videotoolbox && \
    has_transcodarr_ssh_key && \
    has_synthetic_links && \
    has_nfs_mounts
}

# ============================================================================
# DETECTION SUMMARY
# ============================================================================

# Get installation status as string
get_install_status() {
    if is_synology; then
        if is_first_time_synology; then
            echo "first_time"
        else
            echo "configured"
        fi
    elif is_mac; then
        if is_first_time_mac; then
            echo "first_time"
        elif is_adding_node_mac; then
            echo "adding_node"
        elif is_mac_fully_configured; then
            echo "fully_configured"
        else
            echo "partial"
        fi
    else
        echo "unknown"
    fi
}

# Show detection summary (for debugging)
show_detection_summary() {
    echo "=== System Detection Summary ==="
    echo ""
    echo "System Type: $(get_system_name)"
    echo "Install Status: $(get_install_status)"
    echo ""

    if is_mac; then
        echo "Mac Components:"
        echo "  - Homebrew: $(is_homebrew_installed && echo "Yes" || echo "No")"
        echo "  - FFmpeg: $(is_ffmpeg_installed && echo "Yes" || echo "No")"
        echo "  - VideoToolbox: $(has_videotoolbox && echo "Yes" || echo "No")"
        echo "  - SSH Enabled: $(is_ssh_enabled && echo "Yes" || echo "No")"
        echo "  - SSH Key: $(has_transcodarr_ssh_key && echo "Yes" || echo "No")"
        echo "  - Synthetic Links: $(has_synthetic_links && echo "Yes" || echo "No")"
        echo "  - NFS Mounts: $(has_nfs_mounts && echo "Yes" || echo "No")"
        echo "  - Energy Settings: $(has_energy_settings && echo "Yes" || echo "No")"
    fi

    if is_synology; then
        echo "Synology Components:"
        echo "  - Jellyfin Config: $(detect_jellyfin_config)"
        echo "  - Media Path: $(detect_media_path)"
        echo "  - First Time: $(is_first_time_synology && echo "Yes" || echo "No")"
    fi

    echo ""
}
