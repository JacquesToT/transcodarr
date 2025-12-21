#!/bin/bash
#
# Transcodarr Installer
# Distributed Live Transcoding for Jellyfin using Apple Silicon Macs
#
# Requirements: gum (brew install gum)
#

# Don't use set -e, we handle errors ourselves

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.0.0"

# Colors for non-gum fallback
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check for gum
check_gum() {
    if ! command -v gum &> /dev/null; then
        echo -e "${YELLOW}Gum is not installed. Installing via Homebrew...${NC}"
        if ! command -v brew &> /dev/null; then
            echo -e "${RED}Homebrew is required. Please install it first:${NC}"
            echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            exit 1
        fi
        brew install gum
    fi
}

# Show banner
show_banner() {
    gum style \
        --foreground 212 \
        --border-foreground 212 \
        --border double \
        --align center \
        --width 60 \
        --margin "1 2" \
        --padding "1 2" \
        "🎬 TRANSCODARR v${VERSION}" \
        "" \
        "Distributed Live Transcoding for Jellyfin" \
        "Using Apple Silicon Macs with VideoToolbox"
}

# Detect system type
detect_system() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if [[ $(uname -m) == "arm64" ]]; then
            SYSTEM_TYPE="mac_apple_silicon"
        else
            SYSTEM_TYPE="mac_intel"
        fi
    elif [[ -f /etc/synoinfo.conf ]]; then
        SYSTEM_TYPE="synology"
    elif [[ -f /etc/os-release ]]; then
        SYSTEM_TYPE="linux"
    else
        SYSTEM_TYPE="unknown"
    fi
    echo "$SYSTEM_TYPE"
}

# Verify Mac setup prerequisites
verify_mac_setup() {
    local nas_ip="$1"
    local media_path="$2"
    local all_passed=true

    # Check 1: NAS IP provided
    gum spin --spinner dot --title "Checking NAS IP..." -- sleep 0.5
    if [[ -z "$nas_ip" ]]; then
        gum style --foreground 196 "  ❌ NAS IP address is required"
        all_passed=false
    else
        gum style --foreground 46 "  ✅ NAS IP provided: $nas_ip"
    fi

    # Check 2: Ping NAS
    gum spin --spinner dot --title "Pinging NAS ($nas_ip)..." -- sleep 0.3
    if ping -c 1 -W 2 "$nas_ip" &> /dev/null; then
        gum style --foreground 46 "  ✅ NAS is reachable"
    else
        gum style --foreground 196 "  ❌ Cannot reach NAS at $nas_ip"
        gum style --foreground 252 "     Check: Is the NAS powered on? Is the IP correct?"
        all_passed=false
    fi

    # Check 3: Test NFS mount
    gum spin --spinner dot --title "Testing NFS access..." -- sleep 0.3
    local test_mount="/tmp/transcodarr-nfs-test-$$"
    mkdir -p "$test_mount"

    if sudo mount -t nfs -o resvport,ro,nolock,timeo=5 "${nas_ip}:${media_path}" "$test_mount" 2>/dev/null; then
        gum style --foreground 46 "  ✅ NFS mount successful"
        # Check if we can read files
        if ls "$test_mount" &>/dev/null; then
            local file_count=$(ls -1 "$test_mount" 2>/dev/null | wc -l | tr -d ' ')
            gum style --foreground 46 "  ✅ Can read NFS share ($file_count items found)"
        fi
        sudo umount "$test_mount" 2>/dev/null
    else
        gum style --foreground 196 "  ❌ NFS mount failed"
        gum style --foreground 252 "     Check: Is NFS enabled on Synology?"
        gum style --foreground 252 "     Check: Does path $media_path exist?"
        gum style --foreground 252 "     Check: Are NFS permissions set correctly?"
        all_passed=false
    fi
    rmdir "$test_mount" 2>/dev/null

    # Check 4: Homebrew
    gum spin --spinner dot --title "Checking Homebrew..." -- sleep 0.3
    if command -v brew &> /dev/null; then
        gum style --foreground 46 "  ✅ Homebrew is installed"
    else
        gum style --foreground 226 "  ⚠️  Homebrew not installed (will be installed)"
    fi

    # Check 5: Check if this is Apple Silicon
    gum spin --spinner dot --title "Checking Apple Silicon..." -- sleep 0.3
    if [[ $(uname -m) == "arm64" ]]; then
        gum style --foreground 46 "  ✅ Apple Silicon detected ($(sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -o 'M[0-9].*' || echo 'ARM64'))"
    else
        gum style --foreground 226 "  ⚠️  Intel Mac detected (no VideoToolbox hardware acceleration)"
    fi

    # Check 6: Remote Login (SSH) enabled
    gum spin --spinner dot --title "Checking Remote Login..." -- sleep 0.3
    if sudo systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
        gum style --foreground 46 "  ✅ Remote Login (SSH) is enabled"
    else
        gum style --foreground 196 "  ❌ Remote Login (SSH) is not enabled"
        gum style --foreground 252 "     Enable in: System Settings → General → Sharing → Remote Login"
        all_passed=false
    fi

    echo ""

    if [[ "$all_passed" == true ]]; then
        return 0
    else
        return 1
    fi
}

# Show current node status (visual)
show_node_status() {
    echo ""
    gum style --foreground 212 "📊 Current Transcode Nodes"
    echo ""

    # Check if this is a Mac
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local hostname=$(hostname)
        local ip=$(ipconfig getifaddr en0 2>/dev/null || echo "unknown")
        local chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -o 'M[0-9].*' | head -1 || echo "Unknown")

        # Check if FFmpeg is installed
        if [[ -f "/opt/homebrew/bin/ffmpeg" ]]; then
            local ffmpeg_status="✅ Installed"
        else
            local ffmpeg_status="❌ Not installed"
        fi

        # Check NFS mounts
        if mount | grep -q "/data/media"; then
            local nfs_status="✅ Mounted"
        else
            local nfs_status="❌ Not mounted"
        fi

        gum style --border normal --padding "1 2" --border-foreground 39 \
            "🖥️  This Mac: $hostname" \
            "   IP: $ip" \
            "   Chip: $chip" \
            "   FFmpeg: $ffmpeg_status" \
            "   NFS: $nfs_status"
    fi
    echo ""
}

# Main menu
main_menu() {
    # Show node status first
    show_node_status

    local choice
    choice=$(gum choose \
        --header "What would you like to do?" \
        --cursor.foreground 212 \
        --selected.foreground 212 \
        "🖥️  Setup Apple Silicon Mac as Transcode Node" \
        "🐳 Setup Jellyfin with rffmpeg (Docker)" \
        "🔧 Configure Existing Installation" \
        "📊 Setup Monitoring (Prometheus/Grafana)" \
        "📖 View Documentation" \
        "🗑️  Uninstall Transcodarr" \
        "❌ Exit")

    case "$choice" in
        "🖥️  Setup Apple Silicon Mac as Transcode Node")
            setup_apple_silicon
            ;;
        "🐳 Setup Jellyfin with rffmpeg (Docker)")
            setup_jellyfin
            ;;
        "🔧 Configure Existing Installation")
            configure_existing
            ;;
        "📊 Setup Monitoring (Prometheus/Grafana)")
            setup_monitoring
            ;;
        "📖 View Documentation")
            view_docs
            ;;
        "🗑️  Uninstall Transcodarr")
            uninstall_transcodarr
            ;;
        "❌ Exit")
            gum style --foreground 212 "Goodbye! 👋"
            exit 0
            ;;
    esac
}

# Uninstall Transcodarr
uninstall_transcodarr() {
    if [[ -f "$SCRIPT_DIR/uninstall.sh" ]]; then
        "$SCRIPT_DIR/uninstall.sh"
    else
        gum style --foreground 196 "Uninstall script not found"
    fi
    main_menu
}

# Apple Silicon Mac Setup
setup_apple_silicon() {
    gum style \
        --foreground 39 \
        --border-foreground 39 \
        --border normal \
        --padding "0 1" \
        "🖥️ Apple Silicon Mac Setup"

    local system=$(detect_system)
    if [[ "$system" != "mac_apple_silicon" ]]; then
        if [[ "$system" == "mac_intel" ]]; then
            gum style --foreground 196 "⚠️  This Mac has an Intel chip (no VideoToolbox hardware acceleration)"
            if ! gum confirm "Continue anyway?"; then
                main_menu
                return
            fi
        else
            gum style --foreground 196 "⚠️  This must be run on a Mac!"
            gum confirm "Return to main menu?" && main_menu
            return
        fi
    fi

    # Show what will be installed
    gum style --foreground 252 "This will install and configure:"
    echo ""
    gum style --foreground 39 "  • Homebrew (if not installed)"
    gum style --foreground 39 "  • FFmpeg with VideoToolbox + libfdk-aac"
    gum style --foreground 39 "  • NFS mount configuration for media"
    gum style --foreground 39 "  • LaunchDaemons for persistent mounts"
    gum style --foreground 39 "  • Energy settings (prevent sleep)"
    gum style --foreground 39 "  • node_exporter for monitoring"
    echo ""

    if ! gum confirm "Continue with Apple Silicon Mac setup?"; then
        main_menu
        return
    fi

    # Get configuration
    echo ""
    gum style --foreground 212 "📝 Configuration"

    NAS_IP=$(gum input --placeholder "192.168.1.100" --prompt "Synology/NAS IP address: ")
    MEDIA_PATH=$(gum input --placeholder "/volume1/data/media" --prompt "NAS media path: " --value "/volume1/data/media")
    CACHE_PATH=$(gum input --placeholder "/volume2/docker/jellyfin/cache" --prompt "NAS cache path: " --value "/volume2/docker/jellyfin/cache")

    echo ""
    gum style --foreground 212 "🔍 Running pre-flight checks..."
    echo ""

    # Run verification
    if ! verify_mac_setup "$NAS_IP" "$MEDIA_PATH"; then
        echo ""
        gum style --foreground 196 "❌ Pre-flight checks failed. Please fix the issues above."
        echo ""
        if gum confirm "View Prerequisites documentation?"; then
            gum pager < "$SCRIPT_DIR/docs/PREREQUISITES.md"
        fi
        gum confirm "Return to main menu?" && main_menu
        return
    fi

    echo ""
    gum style --foreground 46 "✅ All pre-flight checks passed!"
    echo ""

    if ! gum confirm "Continue with installation?"; then
        main_menu
        return
    fi

    echo ""
    gum style --foreground 212 "🔧 Starting installation..."
    echo ""

    # Run installation steps with spinners
    source "$SCRIPT_DIR/lib/mac-setup.sh"

    run_mac_setup "$NAS_IP" "$MEDIA_PATH" "$CACHE_PATH"

    echo ""
    gum style --foreground 46 "✅ Apple Silicon Mac setup complete!"
    echo ""
    gum confirm "Return to main menu?" && main_menu
}

# Jellyfin/Docker Setup
setup_jellyfin() {
    gum style \
        --foreground 39 \
        --border-foreground 39 \
        --border normal \
        --padding "0 1" \
        "🐳 Jellyfin + rffmpeg Setup"

    gum style --foreground 252 "This will configure:"
    echo ""
    gum style --foreground 39 "  • Docker compose for Jellyfin with rffmpeg"
    gum style --foreground 39 "  • SSH key generation for transcode node access"
    gum style --foreground 39 "  • rffmpeg.yml configuration"
    gum style --foreground 39 "  • NFS volume for transcode cache"
    echo ""

    if ! gum confirm "Continue with Jellyfin setup?"; then
        main_menu
        return
    fi

    # Get configuration
    echo ""
    gum style --foreground 212 "📝 Configuration"

    MAC_IP=$(gum input --placeholder "192.168.1.50" --prompt "Transcode node IP: ")
    MAC_USER=$(gum input --placeholder "username" --prompt "Transcode node SSH user: ")
    JELLYFIN_PATH=$(gum input --placeholder "/volume2/docker/jellyfin" --prompt "Jellyfin config path: " --value "/volume2/docker/jellyfin")

    echo ""
    gum style --foreground 212 "🔧 Starting configuration..."
    echo ""

    source "$SCRIPT_DIR/lib/jellyfin-setup.sh"

    run_jellyfin_setup "$MAC_IP" "$MAC_USER" "$JELLYFIN_PATH"

    echo ""
    gum style --foreground 46 "✅ Jellyfin setup complete!"
    echo ""
    gum confirm "Return to main menu?" && main_menu
}

# Configure existing installation
configure_existing() {
    local choice
    choice=$(gum choose \
        --header "What would you like to configure?" \
        --cursor.foreground 212 \
        "🔑 Add new transcode node" \
        "📋 View rffmpeg status" \
        "🔄 Reset rffmpeg state" \
        "⬅️  Back to main menu")

    case "$choice" in
        "🔑 Add new transcode node")
            add_transcode_node
            ;;
        "📋 View rffmpeg status")
            view_rffmpeg_status
            ;;
        "🔄 Reset rffmpeg state")
            reset_rffmpeg
            ;;
        "⬅️  Back to main menu")
            main_menu
            ;;
    esac
}

# Add new transcode node
add_transcode_node() {
    gum style --foreground 212 "🔑 Add New Transcode Node"

    MAC_IP=$(gum input --placeholder "192.168.1.50" --prompt "Node IP address: ")
    MAC_USER=$(gum input --placeholder "username" --prompt "SSH username: ")
    WEIGHT=$(gum input --placeholder "2" --prompt "Node weight (1-10): " --value "2")

    echo ""
    gum spin --spinner dot --title "Adding node..." -- sleep 1

    # Generate command
    CMD="docker exec jellyfin rffmpeg add ${MAC_USER}@${MAC_IP} --weight ${WEIGHT}"

    gum style --foreground 252 "Run this command on your Synology/Docker host:"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" "$CMD"
    echo ""

    gum confirm "Return to configuration menu?" && configure_existing
}

# View rffmpeg status
view_rffmpeg_status() {
    gum style --foreground 212 "📋 rffmpeg Status"
    echo ""
    gum style --foreground 252 "Run this command on your Synology/Docker host:"
    gum style --foreground 39 --border normal --padding "0 1" "docker exec jellyfin rffmpeg status"
    echo ""
    gum confirm "Return to configuration menu?" && configure_existing
}

# Reset rffmpeg state
reset_rffmpeg() {
    gum style --foreground 196 "⚠️  This will clear all rffmpeg state and bad host markers"
    echo ""
    if gum confirm "Are you sure?"; then
        gum style --foreground 252 "Run this command on your Synology/Docker host:"
        gum style --foreground 39 --border normal --padding "0 1" "docker exec -u abc jellyfin rffmpeg clear"
    fi
    echo ""
    gum confirm "Return to configuration menu?" && configure_existing
}

# Setup monitoring
setup_monitoring() {
    gum style \
        --foreground 39 \
        --border-foreground 39 \
        --border normal \
        --padding "0 1" \
        "📊 Monitoring Setup"

    gum style --foreground 252 "This includes:"
    echo ""
    gum style --foreground 39 "  • Prometheus configuration"
    gum style --foreground 39 "  • Grafana dashboard import"
    gum style --foreground 39 "  • node_exporter on transcode nodes"
    echo ""

    gum style --foreground 252 "Grafana dashboard JSON is available at:"
    gum style --foreground 39 --border normal --padding "0 1" "$SCRIPT_DIR/grafana-dashboard.json"
    echo ""

    gum confirm "Return to main menu?" && main_menu
}

# View documentation
view_docs() {
    local choice
    choice=$(gum choose \
        --header "Which documentation?" \
        --cursor.foreground 212 \
        "📋 Prerequisites (Read First!)" \
        "📖 Full Setup Guide" \
        "🖥️  Apple Silicon Mac Quick Start" \
        "🐳 Jellyfin Quick Start" \
        "⬅️  Back to main menu")

    case "$choice" in
        "📋 Prerequisites (Read First!)")
            gum pager < "$SCRIPT_DIR/docs/PREREQUISITES.md"
            view_docs
            ;;
        "📖 Full Setup Guide")
            gum pager < "$SCRIPT_DIR/LIVE_TRANSCODING_GUIDE.md"
            view_docs
            ;;
        "🖥️  Apple Silicon Mac Quick Start")
            if [[ -f "$SCRIPT_DIR/docs/MAC_SETUP.md" ]]; then
                gum pager < "$SCRIPT_DIR/docs/MAC_SETUP.md"
            else
                gum style --foreground 196 "Documentation not found"
            fi
            view_docs
            ;;
        "🐳 Jellyfin Quick Start")
            if [[ -f "$SCRIPT_DIR/docs/JELLYFIN_SETUP.md" ]]; then
                gum pager < "$SCRIPT_DIR/docs/JELLYFIN_SETUP.md"
            else
                gum style --foreground 196 "Documentation not found"
            fi
            view_docs
            ;;
        "⬅️  Back to main menu")
            main_menu
            ;;
    esac
}

# Main entry point
main() {
    check_gum
    clear
    show_banner

    # Show detected system
    local system=$(detect_system)
    case "$system" in
        "mac_apple_silicon")
            gum style --foreground 46 "✓ Detected: Mac with Apple Silicon"
            ;;
        "mac_intel")
            gum style --foreground 226 "⚠ Detected: Mac with Intel (no hardware acceleration)"
            ;;
        "synology")
            gum style --foreground 46 "✓ Detected: Synology NAS"
            ;;
        "linux")
            gum style --foreground 39 "ℹ Detected: Linux system"
            ;;
        *)
            gum style --foreground 196 "⚠ Unknown system type"
            ;;
    esac
    echo ""

    main_menu
}

# Run main
main "$@"
