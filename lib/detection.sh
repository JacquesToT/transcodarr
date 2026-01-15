#!/bin/bash
#
# Transcodarr Auto-Detection
# Detects system type and installation status
#

# Global container name - set by detect_jellyfin_container()
JELLYFIN_CONTAINER="${JELLYFIN_CONTAINER:-jellyfin}"

# Detect and set the Jellyfin container name
# Checks state.json first, then tries to auto-detect
detect_jellyfin_container() {
    # 1. Check if already set in state.json
    local saved_container
    saved_container=$(get_config "jellyfin_container" 2>/dev/null)
    if [[ -n "$saved_container" ]]; then
        JELLYFIN_CONTAINER="$saved_container"
        return 0
    fi

    # 2. Auto-detect: find containers with rffmpeg installed
    local containers=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && containers+=("$name")
    done < <(sudo docker ps --format '{{.Names}}' 2>/dev/null | while read -r c; do
        if sudo docker exec "$c" which rffmpeg &>/dev/null 2>&1; then
            echo "$c"
        fi
    done)

    case ${#containers[@]} in
        0)
            # No container found with rffmpeg - look for jellyfin-like names
            local jellyfin_containers=()
            while IFS= read -r name; do
                [[ -n "$name" ]] && jellyfin_containers+=("$name")
            done < <(sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -i jellyfin)

            if [[ ${#jellyfin_containers[@]} -eq 1 ]]; then
                JELLYFIN_CONTAINER="${jellyfin_containers[0]}"
            elif [[ ${#jellyfin_containers[@]} -gt 1 ]]; then
                # Multiple - ask user
                echo "Multiple Jellyfin containers found:"
                for i in "${!jellyfin_containers[@]}"; do
                    echo "  $((i+1)). ${jellyfin_containers[$i]}"
                done
                read -rp "Select container (1-${#jellyfin_containers[@]}): " choice
                JELLYFIN_CONTAINER="${jellyfin_containers[$((choice-1))]}"
            fi
            # else: keep default "jellyfin"
            ;;
        1)
            JELLYFIN_CONTAINER="${containers[0]}"
            ;;
        *)
            # Multiple containers with rffmpeg - ask user
            echo "Multiple containers with rffmpeg found:"
            for i in "${!containers[@]}"; do
                echo "  $((i+1)). ${containers[$i]}"
            done
            read -rp "Select container (1-${#containers[@]}): " choice
            JELLYFIN_CONTAINER="${containers[$((choice-1))]}"
            ;;
    esac

    # Save for future use
    if [[ -n "$JELLYFIN_CONTAINER" ]]; then
        set_config "jellyfin_container" "$JELLYFIN_CONTAINER" 2>/dev/null || true
    fi
}

# Get the Jellyfin container name (for use in scripts)
get_jellyfin_container() {
    echo "$JELLYFIN_CONTAINER"
}

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
                echo "Mac with $chip chip"
            else
                echo "Apple Silicon Mac"
            fi
            ;;
        mac_intel)
            echo "Intel Mac"
            ;;
        *)
            echo "Unknown system"
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

# Check if a path has NFS exports configured
# Returns 0 if path (or parent shared folder) is in /etc/exports
check_nfs_export() {
    local path="$1"

    # Extract the shared folder (e.g., /volume1/data from /volume1/data/media)
    local shared_folder
    shared_folder=$(echo "$path" | sed -E 's|^(/volume[0-9]+/[^/]+).*|\1|')

    # Method 1: Check /etc/exports (may need sudo on Synology)
    if [[ -f /etc/exports ]]; then
        if sudo cat /etc/exports 2>/dev/null | grep -q "${shared_folder}"; then
            return 0
        fi
    fi

    # Method 2: Use showmount to list exports
    if command -v showmount &> /dev/null; then
        if showmount -e localhost 2>/dev/null | grep -q "${shared_folder}"; then
            return 0
        fi
    fi

    # Method 3: Check Synology-specific NFS config
    if [[ -f /etc/exports.d/synology.exports ]]; then
        if sudo cat /etc/exports.d/synology.exports 2>/dev/null | grep -q "${shared_folder}"; then
            return 0
        fi
    fi

    # Method 4: Check via synoshare (Synology CLI tool)
    if command -v synoshare &> /dev/null; then
        local share_name
        share_name=$(basename "$shared_folder")
        if synoshare --get "$share_name" 2>/dev/null | grep -qi "nfs"; then
            return 0
        fi
    fi

    return 1
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

# Check if jellyfin-ffmpeg is installed (with HDR support)
is_jellyfin_ffmpeg_installed() {
    [[ -f "/opt/jellyfin-ffmpeg/ffmpeg" ]] && \
        /opt/jellyfin-ffmpeg/ffmpeg -filters 2>&1 | grep -q "tonemapx"
}

# Check if Homebrew FFmpeg is installed
is_homebrew_ffmpeg_installed() {
    [[ -f "/opt/homebrew/bin/ffmpeg" ]]
}

# Check if any FFmpeg is installed (jellyfin-ffmpeg or Homebrew)
is_ffmpeg_installed() {
    is_jellyfin_ffmpeg_installed || is_homebrew_ffmpeg_installed || command -v ffmpeg &> /dev/null
}

# Check if FFmpeg has VideoToolbox support
has_videotoolbox() {
    local ffmpeg_path="${1:-}"

    # Check jellyfin-ffmpeg first (has HDR support)
    if [[ -f "/opt/jellyfin-ffmpeg/ffmpeg" ]]; then
        /opt/jellyfin-ffmpeg/ffmpeg -encoders 2>&1 | grep -q "videotoolbox" && return 0
    fi

    # Check Homebrew FFmpeg
    if [[ -f "/opt/homebrew/bin/ffmpeg" ]]; then
        /opt/homebrew/bin/ffmpeg -encoders 2>&1 | grep -q "videotoolbox" && return 0
    fi

    # Check PATH ffmpeg
    if command -v ffmpeg &>/dev/null; then
        ffmpeg -encoders 2>&1 | grep -q "videotoolbox" && return 0
    fi

    return 1
}

# Check if HDR tone mapping (tonemapx) is available
has_hdr_tonemapping() {
    if [[ -f "/opt/jellyfin-ffmpeg/ffmpeg" ]]; then
        /opt/jellyfin-ffmpeg/ffmpeg -filters 2>&1 | grep -q "tonemapx"
    else
        return 1
    fi
}

# Get installed FFmpeg variant
get_ffmpeg_variant() {
    if is_jellyfin_ffmpeg_installed; then
        echo "jellyfin"
    elif is_homebrew_ffmpeg_installed; then
        echo "homebrew"
    else
        echo "none"
    fi
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
        local ffmpeg_variant=$(get_ffmpeg_variant)
        echo "Mac Components:"
        echo "  - Homebrew: $(is_homebrew_installed && echo "Yes" || echo "No")"
        echo "  - FFmpeg: $(is_ffmpeg_installed && echo "Yes ($ffmpeg_variant)" || echo "No")"
        echo "  - VideoToolbox: $(has_videotoolbox && echo "Yes" || echo "No")"
        echo "  - HDR Support: $(has_hdr_tonemapping && echo "Yes (tonemapx)" || echo "No")"
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
