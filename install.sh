#!/bin/bash
#
# Transcodarr Installer
# Distributed Live Transcoding for Jellyfin using Mac Mini's with Apple Silicon
#
# Requirements: gum (brew install gum)
#

set -e

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
        "Using Mac Mini's with Apple Silicon VideoToolbox"
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
        "🖥️  Setup This Mac as Transcode Node" \
        "🐳 Setup Jellyfin with rffmpeg (Docker)" \
        "🔧 Configure Existing Installation" \
        "📊 Setup Monitoring (Prometheus/Grafana)" \
        "📖 View Documentation" \
        "🗑️  Uninstall Transcodarr" \
        "❌ Exit")

    case "$choice" in
        "🖥️  Setup This Mac as Transcode Node")
            setup_mac_mini
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

# Mac Mini Setup
setup_mac_mini() {
    gum style \
        --foreground 39 \
        --border-foreground 39 \
        --border normal \
        --padding "0 1" \
        "🖥️ Mac Mini Setup"

    local system=$(detect_system)
    if [[ "$system" != "mac_apple_silicon" && "$system" != "mac_intel" ]]; then
        gum style --foreground 196 "⚠️  This must be run on a Mac!"
        gum confirm "Return to main menu?" && main_menu
        return
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

    if ! gum confirm "Continue with Mac Mini setup?"; then
        main_menu
        return
    fi

    # Get configuration
    echo ""
    gum style --foreground 212 "📝 Configuration"

    NAS_IP=$(gum input --placeholder "192.168.1.100" --prompt "Synology/NAS IP address: " --value "192.168.175.141")
    MEDIA_PATH=$(gum input --placeholder "/volume1/data/media" --prompt "NAS media path: " --value "/volume1/data/media")
    CACHE_PATH=$(gum input --placeholder "/volume2/docker/jellyfin/cache" --prompt "NAS cache path: " --value "/volume2/docker/jellyfin/cache")

    echo ""
    gum style --foreground 212 "🔧 Starting installation..."
    echo ""

    # Run installation steps with spinners
    source "$SCRIPT_DIR/lib/mac-setup.sh"

    run_mac_setup "$NAS_IP" "$MEDIA_PATH" "$CACHE_PATH"

    echo ""
    gum style --foreground 46 "✅ Mac Mini setup complete!"
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
    gum style --foreground 39 "  • SSH key generation for Mac Mini access"
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

    MAC_IP=$(gum input --placeholder "192.168.1.50" --prompt "Mac Mini IP address: " --value "192.168.175.42")
    MAC_USER=$(gum input --placeholder "username" --prompt "Mac Mini username: ")
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
        "🔑 Add new Mac Mini node" \
        "📋 View rffmpeg status" \
        "🔄 Reset rffmpeg state" \
        "⬅️  Back to main menu")

    case "$choice" in
        "🔑 Add new Mac Mini node")
            add_mac_node
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

# Add new Mac Mini node
add_mac_node() {
    gum style --foreground 212 "🔑 Add New Mac Mini Node"

    MAC_IP=$(gum input --placeholder "192.168.1.50" --prompt "Mac Mini IP address: ")
    MAC_USER=$(gum input --placeholder "username" --prompt "Mac Mini username: ")
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
    gum style --foreground 39 "  • node_exporter on Mac Mini"
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
        "📖 Full Setup Guide" \
        "🖥️  Mac Mini Quick Start" \
        "🐳 Jellyfin Quick Start" \
        "⬅️  Back to main menu")

    case "$choice" in
        "📖 Full Setup Guide")
            gum pager < "$SCRIPT_DIR/LIVE_TRANSCODING_GUIDE.md"
            view_docs
            ;;
        "🖥️  Mac Mini Quick Start")
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
