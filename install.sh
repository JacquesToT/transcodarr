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

# Detect if running on Synology
is_synology() {
    [[ -f /etc/synoinfo.conf ]] || [[ -d /volume1 ]]
}

# Setup Homebrew in PATH (needed after fresh install)
setup_brew_path() {
    # Check if brew is already in PATH
    if command -v brew &> /dev/null; then
        return 0
    fi

    # Check Synology-Homebrew / Linuxbrew location (installed via MrCee/Synology-Homebrew)
    if [[ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        return 0
    fi

    # Check if Homebrew is installed but not in PATH (Apple Silicon location)
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        echo -e "${YELLOW}Homebrew is installed but not in your PATH.${NC}"
        echo -e "${YELLOW}Adding Homebrew to PATH...${NC}"

        # Add to current session
        eval "$(/opt/homebrew/bin/brew shellenv)"

        # Add to .zprofile for future sessions
        if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile 2>/dev/null; then
            echo '' >> ~/.zprofile
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
            echo -e "${GREEN}✓ Added Homebrew to ~/.zprofile for future sessions${NC}"
        fi

        return 0
    fi

    # Check Intel Mac location
    if [[ -f "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
        return 0
    fi

    # Homebrew not installed at all
    return 1
}

# Check for gum
check_gum() {
    # First make sure Homebrew is in PATH
    if ! setup_brew_path; then
        # On Synology, don't try to install standard Homebrew - it won't work
        if is_synology; then
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo -e "${RED}  Homebrew is not installed on your Synology!${NC}"
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${YELLOW}Synology requires a special version of Homebrew.${NC}"
            echo -e "${YELLOW}Please install it first by running these commands:${NC}"
            echo ""
            echo -e "${GREEN}git clone https://github.com/MrCee/Synology-Homebrew.git ~/Synology-Homebrew${NC}"
            echo -e "${GREEN}~/Synology-Homebrew/install-synology-homebrew.sh${NC}"
            echo ""
            echo -e "${YELLOW}When asked, select option 1 (Minimal installation).${NC}"
            echo -e "${YELLOW}After installation, run: ${GREEN}brew install gum${NC}"
            echo ""
            echo -e "${YELLOW}Then close your terminal, reconnect via SSH, and run ./install.sh again.${NC}"
            echo ""
            exit 1
        fi

        # On Mac, we can install standard Homebrew
        echo -e "${YELLOW}Homebrew is not installed.${NC}"
        echo -e "${YELLOW}Installing Homebrew (this may take a few minutes)...${NC}"
        echo ""
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Setup PATH after install
        if ! setup_brew_path; then
            echo -e "${RED}Homebrew installation failed. Please install manually:${NC}"
            echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            exit 1
        fi
        echo -e "${GREEN}✓ Homebrew installed successfully!${NC}"
        echo ""
    fi

    # Now install gum if needed
    if ! command -v gum &> /dev/null; then
        echo -e "${YELLOW}Installing gum (for the interactive UI)...${NC}"
        brew install gum
        echo -e "${GREEN}✓ Gum installed successfully!${NC}"
        echo ""
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

# Ask to return to main menu or exit
return_or_exit() {
    echo ""
    local choice
    choice=$(gum choose \
        --header "What would you like to do?" \
        --cursor.foreground 212 \
        "⬅️  Return to main menu" \
        "❌ Exit installer")

    case "$choice" in
        "⬅️  Return to main menu")
            main_menu
            ;;
        "❌ Exit installer")
            exit 0
            ;;
    esac
}

# Show backup warning
show_backup_warning() {
    echo ""
    gum style \
        --foreground 226 \
        --border-foreground 226 \
        --border normal \
        --padding "1 2" \
        "⚠️  BACKUP REMINDER" \
        "" \
        "Before continuing, make sure you have backups of:" \
        "  • Jellyfin config folder" \
        "  • Docker compose files" \
        "  • Current Mac energy settings (pmset -g)"
    echo ""

    if ! gum confirm "I have created backups or understand the risks"; then
        gum style --foreground 252 "Please create backups first, then run the installer again."
        exit 0
    fi
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
        "First Time Setup (start here if this is your first node)" \
        "➕ Add Another Mac to Existing Setup" \
        "📊 Setup Monitoring (Prometheus/Grafana)" \
        "📖 View Documentation" \
        "🗑️  Uninstall from this Mac" \
        "❌ Exit")

    case "$choice" in
        "First Time Setup (start here if this is your first node)")
            first_time_setup
            ;;
        "➕ Add Another Mac to Existing Setup")
            add_another_node
            ;;
        "📊 Setup Monitoring (Prometheus/Grafana)")
            setup_monitoring
            ;;
        "📖 View Documentation")
            view_docs
            ;;
        "🗑️  Uninstall from this Mac")
            uninstall_transcodarr
            ;;
        "❌ Exit")
            gum style --foreground 212 "Goodbye! 👋"
            exit 0
            ;;
    esac
}

# First time setup - guided flow for new users
first_time_setup() {
    gum style \
        --foreground 212 \
        --border-foreground 212 \
        --border double \
        --padding "1 2" \
        "First Time Setup"

    echo ""
    gum style --foreground 252 "This will guide you through setting up Transcodarr for the first time."
    gum style --foreground 252 "You'll need to run this installer on TWO machines, in this order:"
    echo ""
    gum style --foreground 39 "  1. Synology/NAS  → FIRST: generate SSH keys and config files"
    gum style --foreground 39 "  2. Your Mac      → SECOND: install FFmpeg and setup NFS mounts"
    echo ""

    local where_am_i
    where_am_i=$(gum choose \
        --header "Where are you running this installer right now?" \
        --cursor.foreground 212 \
        "🐳 On the Synology/NAS (do this FIRST)" \
        "🖥️  On the Mac (do this SECOND)" \
        "⬅️  Back to main menu" \
        "❌ Exit installer")

    case "$where_am_i" in
        "🐳 On the Synology/NAS (do this FIRST)")
            setup_jellyfin
            ;;
        "🖥️  On the Mac (do this SECOND)")
            setup_apple_silicon
            ;;
        "⬅️  Back to main menu")
            main_menu
            ;;
        "❌ Exit installer")
            exit 0
            ;;
    esac
}

# Add another Mac node to existing setup
add_another_node() {
    gum style \
        --foreground 212 \
        --border-foreground 212 \
        --border normal \
        --padding "1 2" \
        "➕ Add Another Mac"

    echo ""
    gum style --foreground 252 "You already have Transcodarr working and want to add another Mac."
    gum style --foreground 252 "This will use the EXISTING SSH key from your first setup."
    echo ""

    local where_am_i
    where_am_i=$(gum choose \
        --header "Where are you running this right now?" \
        --cursor.foreground 212 \
        "🖥️  On the NEW Mac (that I want to add)" \
        "🐳 On the NAS/Server (to register the new Mac)" \
        "⬅️  Back to main menu" \
        "❌ Exit installer")

    case "$where_am_i" in
        "🖥️  On the NEW Mac (that I want to add)")
            setup_additional_mac
            ;;
        "🐳 On the NAS/Server (to register the new Mac)")
            register_new_mac
            ;;
        "⬅️  Back to main menu")
            main_menu
            ;;
        "❌ Exit installer")
            exit 0
            ;;
    esac
}

# Complete first setup - copy SSH key to Synology when first setup wasn't finished
complete_first_setup() {
    local nas_ip="$1"
    local nas_user="$2"
    local jellyfin_config="$3"

    gum style \
        --foreground 212 \
        --border-foreground 212 \
        --border normal \
        --padding "1 2" \
        "🔧 Complete First Setup"

    echo ""
    gum style --foreground 252 "I'll help you copy the SSH key to your Synology."
    echo ""

    # Check if we have a local output folder with keys
    local local_key_path="${SCRIPT_DIR}/output/rffmpeg/.ssh/id_rsa.pub"
    local public_key=""

    if [[ -f "$local_key_path" ]]; then
        gum style --foreground 46 "✅ Found existing SSH key in output folder"
        public_key=$(cat "$local_key_path")
    else
        gum style --foreground 226 "⚠️  No SSH key found in output folder."
        echo ""

        if gum confirm "Generate a new SSH key?"; then
            gum style --foreground 212 "Generating new SSH key..."
            mkdir -p "${SCRIPT_DIR}/output/rffmpeg/.ssh"
            ssh-keygen -t ed25519 -f "${SCRIPT_DIR}/output/rffmpeg/.ssh/id_rsa" -N "" -C "transcodarr-rffmpeg"
            chmod 600 "${SCRIPT_DIR}/output/rffmpeg/.ssh/id_rsa"
            chmod 644 "${SCRIPT_DIR}/output/rffmpeg/.ssh/id_rsa.pub"
            public_key=$(cat "${SCRIPT_DIR}/output/rffmpeg/.ssh/id_rsa.pub")
            gum style --foreground 46 "✅ SSH key generated"
        else
            main_menu
            return
        fi
    fi

    echo ""
    gum style --foreground 212 "📤 Copying files to Synology..."
    gum style --foreground 252 "This will:"
    gum style --foreground 252 "  1. Create the rffmpeg folder on Synology"
    gum style --foreground 252 "  2. Copy the SSH key and config files"
    echo ""

    # Step 1: Create directory on Synology
    gum style --foreground 245 "Step 1/3: Creating folder on Synology..."
    if ssh -t -o ConnectTimeout=10 "${nas_user}@${nas_ip}" "sudo mkdir -p ${jellyfin_config}/rffmpeg/.ssh && sudo chmod 755 ${jellyfin_config}/rffmpeg && sudo chmod 700 ${jellyfin_config}/rffmpeg/.ssh" 2>/dev/null; then
        gum style --foreground 46 "✅ Folder created"
    else
        gum style --foreground 196 "❌ Failed to create folder"
        gum style --foreground 252 "Try running manually:"
        gum style --foreground 39 "  ssh -t ${nas_user}@${nas_ip} \"sudo mkdir -p ${jellyfin_config}/rffmpeg/.ssh\""
        echo ""
        return_or_exit
        return
    fi

    # Step 2: Copy files via tar to home, then move with sudo
    gum style --foreground 245 "Step 2/3: Copying files to Synology..."

    # First copy to home directory (no sudo needed)
    if cd "${SCRIPT_DIR}/output" && tar czf - rffmpeg | ssh "${nas_user}@${nas_ip}" "tar xzf -" 2>/dev/null; then
        gum style --foreground 46 "✅ Files copied to home folder"
    else
        gum style --foreground 196 "❌ Failed to copy files"
        echo ""
        return_or_exit
        return
    fi

    # Step 3: Move files to final location with sudo
    # Note: use cp -a to preserve hidden folders like .ssh
    gum style --foreground 245 "Step 3/3: Moving files to Jellyfin folder (needs sudo)..."
    if ssh -t "${nas_user}@${nas_ip}" "sudo cp -a ~/rffmpeg/. ${jellyfin_config}/rffmpeg/ && sudo chmod 600 ${jellyfin_config}/rffmpeg/.ssh/id_rsa && sudo chmod 644 ${jellyfin_config}/rffmpeg/.ssh/id_rsa.pub && rm -rf ~/rffmpeg" 2>/dev/null; then
        gum style --foreground 46 "✅ Files moved to ${jellyfin_config}/rffmpeg/"
    else
        gum style --foreground 196 "❌ Failed to move files"
        gum style --foreground 252 "Try running manually on Synology:"
        gum style --foreground 39 "  sudo cp -a ~/rffmpeg/. ${jellyfin_config}/rffmpeg/"
        gum style --foreground 39 "  sudo chmod 600 ${jellyfin_config}/rffmpeg/.ssh/id_rsa"
        echo ""
        return_or_exit
        return
    fi

    echo ""
    gum style --foreground 46 --border double --padding "1 2" \
        "✅ First setup completed!"

    echo ""
    gum style --foreground 252 "The SSH key is now on your Synology."
    gum style --foreground 252 "You can now add this Mac (and any other Macs) as transcode nodes."
    echo ""

    # Add key to this Mac's authorized_keys
    gum style --foreground 212 "Adding SSH key to this Mac..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    if grep -q "$public_key" ~/.ssh/authorized_keys 2>/dev/null; then
        gum style --foreground 46 "✅ SSH key already in authorized_keys"
    else
        echo "$public_key" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        gum style --foreground 46 "✅ SSH key added to ~/.ssh/authorized_keys"
    fi

    # Show command to register this Mac
    local mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "THIS_MAC_IP")

    echo ""
    gum style --foreground 212 "📋 Next: Register this Mac with rffmpeg"
    gum style --foreground 245 "SSH into your Synology and run:"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" \
        "sudo docker exec jellyfin rffmpeg add ${mac_ip} --weight 2"

    echo ""
    return_or_exit
}

# Setup an additional Mac (uses existing SSH key from Synology)
setup_additional_mac() {
    gum style \
        --foreground 212 \
        --border-foreground 212 \
        --border normal \
        --padding "1 2" \
        "🖥️ Setup Additional Mac"

    echo ""
    gum style --foreground 252 "I'll set up this Mac and fetch the existing SSH key from your Synology."
    echo ""

    # First, get Synology details to fetch the existing key
    gum style --foreground 226 "First, I need your Synology details to fetch the existing SSH key:"
    echo ""

    gum style --foreground 252 "What is your Synology's IP address?"
    local nas_ip=$(gum input --placeholder "192.168.1.100" --prompt "Synology IP: ")

    echo ""
    gum style --foreground 252 "What is your SSH username for the Synology?"
    local nas_user=$(gum input --placeholder "admin" --prompt "Synology username: ")

    echo ""
    gum style --foreground 252 "Where is your Jellyfin config folder?"
    local jellyfin_config=$(gum input --placeholder "/volume1/docker/jellyfin" --prompt "Jellyfin config: " --value "/volume1/docker/jellyfin")

    echo ""
    gum style --foreground 212 "🔑 Fetching existing SSH key from Synology..."
    echo ""

    # Try to fetch the existing public key
    local ssh_key_path="${jellyfin_config}/rffmpeg/.ssh/id_rsa.pub"
    local public_key=""

    public_key=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${nas_user}@${nas_ip}" "cat ${ssh_key_path}" 2>/dev/null)

    if [[ -z "$public_key" ]]; then
        echo ""
        gum style --foreground 226 "⚠️  Could not fetch the SSH key from Synology."
        gum style --foreground 252 "This usually means the first setup was not completed."
        echo ""

        local recovery_choice
        recovery_choice=$(gum choose \
            --header "What would you like to do?" \
            --cursor.foreground 212 \
            "🔧 Complete first setup (copy SSH key to Synology)" \
            "📝 Enter the SSH key manually" \
            "⬅️  Back to main menu" \
            "❌ Exit installer")

        case "$recovery_choice" in
            "🔧 Complete first setup (copy SSH key to Synology)")
                complete_first_setup "$nas_ip" "$nas_user" "$jellyfin_config"
                return
                ;;
            "📝 Enter the SSH key manually")
                echo ""
                gum style --foreground 252 "Get the key from your first Mac's output folder:"
                gum style --foreground 39 "  cat ~/Transcodarr/output/rffmpeg/.ssh/id_rsa.pub"
                echo ""
                gum style --foreground 252 "Paste the SSH public key (starts with 'ssh-ed25519' or 'ssh-rsa'):"
                public_key=$(gum input --placeholder "ssh-ed25519 AAAA..." --prompt "SSH key: " --width 80)

                if [[ -z "$public_key" ]] || [[ ! "$public_key" =~ ^ssh- ]]; then
                    gum style --foreground 196 "Invalid SSH key format"
                    return_or_exit
                    return
                fi
                ;;
            "⬅️  Back to main menu")
                main_menu
                return
                ;;
            "❌ Exit installer")
                exit 0
                return
                ;;
        esac
    fi

    gum style --foreground 46 "✅ SSH key fetched successfully!"
    echo ""

    # Add the key to this Mac's authorized_keys
    gum style --foreground 212 "Adding SSH key to this Mac..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # Check if key already exists
    if grep -q "$public_key" ~/.ssh/authorized_keys 2>/dev/null; then
        gum style --foreground 46 "✅ SSH key already in authorized_keys"
    else
        echo "$public_key" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        gum style --foreground 46 "✅ SSH key added to ~/.ssh/authorized_keys"
    fi

    echo ""
    gum style --foreground 212 "Do you also want to install FFmpeg and configure this Mac?"
    echo ""

    if gum confirm "Run Mac setup (FFmpeg, NFS, energy settings)?"; then
        # Get NAS details for NFS
        echo ""
        gum style --foreground 252 "Enter the NFS path to your media files on the NAS:"
        local media_path=$(gum input --placeholder "/volume1/data/media" --prompt "Media path: " --value "/volume1/data/media")

        echo ""
        gum style --foreground 252 "Enter the NFS path for the transcode cache:"
        local cache_path=$(gum input --placeholder "${jellyfin_config}/cache" --prompt "Cache path: " --value "${jellyfin_config}/cache")

        source "$SCRIPT_DIR/lib/mac-setup.sh"
        run_mac_setup "$nas_ip" "$media_path" "$cache_path"
    fi

    # Show final instructions
    local mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "THIS_MAC_IP")

    echo ""
    gum style --foreground 46 --border double --padding "1 2" \
        "✅ This Mac is ready!"

    echo ""
    gum style --foreground 212 "📋 Final step - Register this Mac on your Synology:"
    echo ""
    gum style --foreground 245 "SSH into your Synology:"
    gum style --foreground 39 --border normal --padding "0 1" \
        "ssh ${nas_user}@${nas_ip}"
    echo ""
    gum style --foreground 245 "Then run these commands:"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" \
        "sudo docker exec jellyfin rffmpeg add ${mac_ip} --weight 2"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" \
        "sudo docker exec jellyfin rffmpeg status"

    echo ""
    return_or_exit
}

# Register a new Mac on the server (run from Synology)
register_new_mac() {
    gum style --foreground 212 "📝 Add Another Mac (from Synology)"
    echo ""
    gum style --foreground 252 "I'll help you add a new Mac to your existing setup."
    gum style --foreground 252 "This will install the SSH key and register it with rffmpeg."
    echo ""

    # Get Jellyfin config path
    gum style --foreground 252 "Where is your Jellyfin config folder?"
    local jellyfin_config=$(gum input --placeholder "/volume1/docker/jellyfin" --prompt "Jellyfin config: " --value "/volume1/docker/jellyfin")

    # Check if SSH key exists
    local ssh_key_path="${jellyfin_config}/rffmpeg/.ssh/id_rsa.pub"
    local public_key=""

    if [[ -f "$ssh_key_path" ]]; then
        public_key=$(cat "$ssh_key_path")
        gum style --foreground 46 "✅ Found existing SSH key"
    else
        # Try output folder
        local output_key="${SCRIPT_DIR}/output/rffmpeg/.ssh/id_rsa.pub"
        if [[ -f "$output_key" ]]; then
            public_key=$(cat "$output_key")
            gum style --foreground 46 "✅ Found SSH key in output folder"
        else
            gum style --foreground 196 "❌ No SSH key found!"
            gum style --foreground 252 "Run 'First Time Setup' first to generate the SSH key."
            echo ""
            return_or_exit
            return
        fi
    fi

    # Get new Mac details
    echo ""
    gum style --foreground 252 "Enter the IP address of the NEW Mac you want to add:"
    local mac_ip=$(gum input --placeholder "192.168.1.51" --prompt "New Mac IP: ")

    echo ""
    gum style --foreground 252 "Enter the username on the new Mac:"
    gum style --foreground 245 "(Run 'whoami' on the Mac to find it)"
    local mac_user=$(gum input --placeholder "nick" --prompt "Mac username: ")

    echo ""
    gum style --foreground 252 "Enter the weight for this node (higher = more jobs, 1-10):"
    local weight=$(gum input --placeholder "2" --prompt "Weight: " --value "2")

    # Step 1: Install SSH key on new Mac
    echo ""
    gum style --foreground 212 "STEP 1: Installing SSH key on new Mac..."
    gum style --foreground 252 "Make sure Remote Login is enabled on the Mac first!"
    gum style --foreground 245 "(System Settings → General → Sharing → Remote Login)"
    echo ""

    if gum confirm "Install SSH key on ${mac_ip} now?"; then
        gum style --foreground 252 "Connecting to Mac... Enter the Mac password when prompted:"
        echo ""

        if ssh -o StrictHostKeyChecking=accept-new "${mac_user}@${mac_ip}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${public_key}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
            echo ""
            gum style --foreground 46 "✅ SSH key installed on Mac!"
        else
            echo ""
            gum style --foreground 196 "❌ Failed to install SSH key"
            gum style --foreground 252 "You can install it manually on the Mac:"
            echo ""
            gum style --foreground 39 --border normal --padding "0 1" \
                "mkdir -p ~/.ssh && echo '${public_key}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
            echo ""

            if ! gum confirm "Continue anyway?"; then
                return_or_exit
                return
            fi
        fi
    else
        gum style --foreground 252 "Run this command ON THE NEW MAC:"
        echo ""
        gum style --foreground 39 --border normal --padding "0 1" \
            "mkdir -p ~/.ssh && echo '${public_key}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    fi

    # Step 2: Add Mac to rffmpeg
    echo ""
    gum style --foreground 212 "STEP 2: Adding Mac to rffmpeg..."
    echo ""

    # Check if rffmpeg is available
    if docker exec jellyfin ls /usr/local/bin/rffmpeg &>/dev/null; then
        if gum confirm "Add ${mac_ip} to rffmpeg now?"; then
            if docker exec jellyfin rffmpeg add "${mac_ip}" --weight "${weight}" 2>&1; then
                echo ""
                gum style --foreground 46 "✅ Mac added to rffmpeg!"
                echo ""
                gum style --foreground 212 "Current status:"
                docker exec jellyfin rffmpeg status
            else
                echo ""
                gum style --foreground 196 "❌ Failed to add Mac. Try manually:"
                gum style --foreground 39 --border normal --padding "0 1" \
                    "docker exec jellyfin rffmpeg add ${mac_ip} --weight ${weight}"
            fi
        else
            gum style --foreground 252 "Run this command when ready:"
            echo ""
            gum style --foreground 39 --border normal --padding "0 1" \
                "docker exec jellyfin rffmpeg add ${mac_ip} --weight ${weight}"
        fi
    else
        gum style --foreground 226 "⚠️  rffmpeg not found in Jellyfin container"
        gum style --foreground 252 "Make sure Jellyfin has the rffmpeg mod installed, then run:"
        echo ""
        gum style --foreground 39 --border normal --padding "0 1" \
            "docker exec jellyfin rffmpeg add ${mac_ip} --weight ${weight}"
    fi

    # Step 3: Remind about Mac setup
    echo ""
    gum style --foreground 212 "STEP 3: Setup the new Mac (if not done yet)"
    gum style --foreground 252 "The new Mac needs FFmpeg and NFS mounts configured."
    gum style --foreground 252 "Run the installer on the new Mac:"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" \
        "cd ~/Transcodarr && ./install.sh"
    gum style --foreground 245 "Choose: Add Another Mac → On the NEW Mac"

    echo ""
    gum style --foreground 46 --border double --padding "1 2" \
        "✅ Done! New Mac added to your setup."

    echo ""
    return_or_exit
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
            return_or_exit
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
    echo ""

    gum style --foreground 252 "Enter the IP address of your Synology/NAS (where your media is stored):"
    NAS_IP=$(gum input --placeholder "192.168.1.100" --prompt "NAS IP: ")

    echo ""
    gum style --foreground 252 "Enter the NFS export path to your media files on the NAS:"
    gum style --foreground 245 "(Example: /volume1/data/media - this is where your movies/shows are stored)"
    MEDIA_PATH=$(gum input --placeholder "/volume1/data/media" --prompt "Media path: " --value "/volume1/data/media")

    echo ""
    gum style --foreground 212 "📂 What is the transcode cache?"
    gum style --foreground 252 "When the Mac transcodes a video, it writes the output to a 'cache' folder."
    gum style --foreground 252 "Jellyfin then reads from this folder to stream to you."
    gum style --foreground 252 "Both Mac and Jellyfin need access to the SAME folder (via NFS)."
    echo ""
    gum style --foreground 252 "Enter the NFS export path for the transcode cache on the NAS:"
    gum style --foreground 245 "(This is usually inside your Jellyfin config folder, e.g., /volume1/docker/jellyfin/cache)"
    CACHE_PATH=$(gum input --placeholder "/volume1/docker/jellyfin/cache" --prompt "Cache path: " --value "/volume1/docker/jellyfin/cache")

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
        return_or_exit
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

    # mac-setup.sh shows the next steps (add SSH key, go back to Synology)
    # Just offer to return to menu or exit
    return_or_exit
}

# Show manual next steps after Mac setup
show_manual_next_steps() {
    local nas_ip="$1"
    local mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "YOUR_MAC_IP")
    local mac_user=$(whoami)

    echo ""
    gum style --foreground 212 --border normal --padding "1 2" \
        "📋 Manual Next Steps"

    echo ""
    gum style --foreground 226 "On your Synology/Server, you need to:"
    echo ""
    gum style --foreground 252 "1. Install Jellyfin with the rffmpeg Docker mod"
    gum style --foreground 252 "2. Generate an SSH key and copy it to this Mac"
    gum style --foreground 252 "3. Create rffmpeg.yml config pointing to this Mac"
    gum style --foreground 252 "4. Add this Mac as a transcode node"

    echo ""
    gum style --foreground 226 "This Mac's details:"
    gum style --foreground 39 "  IP Address: ${mac_ip}"
    gum style --foreground 39 "  Username:   ${mac_user}"

    echo ""
    gum style --foreground 226 "Command to add this Mac to rffmpeg (run on server):"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" \
        "docker exec jellyfin rffmpeg add ${mac_ip} --weight 2"

    echo ""
    gum style --foreground 252 "For detailed instructions, run the Jellyfin Setup option"
    gum style --foreground 252 "or read the documentation."

    echo ""
    return_or_exit
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
    gum style --foreground 252 "I'll ask for 5 things, then generate all config files for you."
    echo ""

    gum style --foreground 226 "1/5 - Mac (transcode node)"
    gum style --foreground 252 "This is the Apple Silicon Mac that will do the transcoding."
    gum style --foreground 252 "To find the IP: System Settings → Network → look for your IP address"
    MAC_IP=$(gum input --placeholder "192.168.1.50" --prompt "Mac IP address: ")

    echo ""
    gum style --foreground 252 "To find your username, run 'whoami' in Terminal on your Mac."
    MAC_USER=$(gum input --placeholder "nick" --prompt "Mac username: ")

    echo ""
    gum style --foreground 226 "2/5 - Synology/NAS (where Jellyfin runs)"
    gum style --foreground 252 "This is where your Jellyfin Docker container runs."
    gum style --foreground 252 "To find the IP: Synology DSM → Control Panel → Network"
    NAS_IP=$(gum input --placeholder "192.168.1.100" --prompt "NAS IP address: ")

    echo ""
    gum style --foreground 252 "What is your SSH username for the Synology?"
    gum style --foreground 245 "(This is the account you use to log into DSM or SSH)"
    NAS_USER=$(gum input --placeholder "admin" --prompt "Synology username: ")

    echo ""
    gum style --foreground 226 "3/5 - Cache folder path"
    gum style --foreground 212 "📂 What is the transcode cache?"
    gum style --foreground 252 "When the Mac transcodes, it writes output to a 'cache' folder."
    gum style --foreground 252 "Jellyfin reads from this folder to stream to you."
    gum style --foreground 252 "Both need access to the SAME folder."
    echo ""
    gum style --foreground 252 "Where is (or will be) your Jellyfin cache folder on the NAS?"
    gum style --foreground 245 "(Usually inside your Jellyfin config folder)"
    CACHE_PATH=$(gum input --placeholder "/volume1/docker/jellyfin/cache" --prompt "Cache path: " --value "/volume1/docker/jellyfin/cache")

    echo ""
    gum style --foreground 226 "4/5 - Jellyfin config path"
    gum style --foreground 252 "Where is your Jellyfin config folder on the Synology?"
    gum style --foreground 245 "(This is where Jellyfin stores its database, settings, etc.)"
    JELLYFIN_CONFIG=$(gum input --placeholder "/volume1/docker/jellyfin" --prompt "Jellyfin config path: " --value "/volume1/docker/jellyfin")

    # Confirmation loop - let user review and change values
    while true; do
        echo ""
        gum style --foreground 212 --border normal --padding "1 2" \
            "📋 Please confirm your settings:"
        echo ""
        gum style --foreground 252 "1. Mac IP:           ${MAC_IP}"
        gum style --foreground 252 "2. Mac username:     ${MAC_USER}"
        gum style --foreground 252 "3. Synology IP:      ${NAS_IP}"
        gum style --foreground 252 "4. Synology user:    ${NAS_USER}"
        gum style --foreground 252 "5. Cache path:       ${CACHE_PATH}"
        gum style --foreground 252 "6. Jellyfin config:  ${JELLYFIN_CONFIG}"
        echo ""

        local confirm_choice
        confirm_choice=$(gum choose \
            --header "Is this correct?" \
            --cursor.foreground 212 \
            "✅ Yes, generate the files" \
            "✏️  Change a value" \
            "❌ Cancel and return to menu")

        case "$confirm_choice" in
            "✅ Yes, generate the files")
                break
                ;;
            "✏️  Change a value")
                local change_choice
                change_choice=$(gum choose \
                    --header "Which value do you want to change?" \
                    --cursor.foreground 212 \
                    "1. Mac IP (${MAC_IP})" \
                    "2. Mac username (${MAC_USER})" \
                    "3. Synology IP (${NAS_IP})" \
                    "4. Synology username (${NAS_USER})" \
                    "5. Cache path (${CACHE_PATH})" \
                    "6. Jellyfin config path (${JELLYFIN_CONFIG})" \
                    "⬅️  Back")

                case "$change_choice" in
                    "1."*) MAC_IP=$(gum input --placeholder "$MAC_IP" --prompt "Mac IP: " --value "$MAC_IP") ;;
                    "2."*) MAC_USER=$(gum input --placeholder "$MAC_USER" --prompt "Mac username: " --value "$MAC_USER") ;;
                    "3."*) NAS_IP=$(gum input --placeholder "$NAS_IP" --prompt "Synology IP: " --value "$NAS_IP") ;;
                    "4."*) NAS_USER=$(gum input --placeholder "$NAS_USER" --prompt "Synology username: " --value "$NAS_USER") ;;
                    "5."*) CACHE_PATH=$(gum input --placeholder "$CACHE_PATH" --prompt "Cache path: " --value "$CACHE_PATH") ;;
                    "6."*) JELLYFIN_CONFIG=$(gum input --placeholder "$JELLYFIN_CONFIG" --prompt "Jellyfin config: " --value "$JELLYFIN_CONFIG") ;;
                esac
                ;;
            "❌ Cancel and return to menu")
                main_menu
                return
                ;;
        esac
    done

    echo ""
    gum style --foreground 226 "Generating files..."
    echo ""

    source "$SCRIPT_DIR/lib/jellyfin-setup.sh"

    run_jellyfin_setup "$MAC_IP" "$MAC_USER" "$NAS_IP" "$NAS_USER" "$CACHE_PATH" "$JELLYFIN_CONFIG"

    echo ""
    gum style --foreground 46 "✅ Jellyfin setup complete!"
    echo ""
    return_or_exit
}

# Setup monitoring
setup_monitoring() {
    gum style \
        --foreground 39 \
        --border-foreground 39 \
        --border double \
        --padding "1 2" \
        "📊 Monitoring Setup"

    echo ""
    gum style --foreground 212 "What is monitoring?"
    gum style --foreground 252 "Monitoring lets you see how your Macs are performing:"
    gum style --foreground 39 "  • CPU usage (how hard is the Mac working?)"
    gum style --foreground 39 "  • Memory usage (is there enough RAM?)"
    gum style --foreground 39 "  • Is the Mac online and available?"
    echo ""

    gum style --foreground 212 "How does it work?"
    gum style --foreground 252 "1. Each Mac runs 'node_exporter' (collects stats)"
    gum style --foreground 252 "2. Prometheus (on your server) fetches these stats"
    gum style --foreground 252 "3. Grafana (on your server) shows nice graphs"
    echo ""

    gum style --foreground 226 "⚠️  This is OPTIONAL - Transcodarr works fine without it!"
    echo ""

    local choice
    choice=$(gum choose \
        --header "What do you want to do?" \
        --cursor.foreground 212 \
        "📖 I don't have Prometheus/Grafana yet - show me how to set it up" \
        "✅ I already have Prometheus/Grafana - just configure it" \
        "⬅️  Back to main menu (skip monitoring)" \
        "❌ Exit installer")

    case "$choice" in
        "📖 I don't have Prometheus/Grafana yet - show me how to set it up")
            show_monitoring_full_setup
            ;;
        "✅ I already have Prometheus/Grafana - just configure it")
            show_monitoring_existing_setup
            ;;
        "⬅️  Back to main menu (skip monitoring)")
            main_menu
            ;;
        "❌ Exit installer")
            exit 0
            ;;
    esac
}

# Full monitoring setup for beginners
show_monitoring_full_setup() {
    gum style --foreground 212 --border double --padding "1 2" \
        "📖 Complete Monitoring Setup Guide"

    echo ""
    gum style --foreground 252 "This guide will help you set up monitoring from scratch."
    gum style --foreground 252 "You'll need to do 3 things:"
    echo ""
    gum style --foreground 39 "  STEP 1: Install node_exporter on each Mac"
    gum style --foreground 39 "  STEP 2: Install Prometheus + Grafana on your server"
    gum style --foreground 39 "  STEP 3: Import the dashboard in Grafana"
    echo ""

    if ! gum confirm "Ready to start?"; then
        setup_monitoring
        return
    fi

    # STEP 1
    echo ""
    gum style --foreground 212 --border normal --padding "0 1" "STEP 1: Install node_exporter on this Mac"
    echo ""
    gum style --foreground 252 "node_exporter is a small program that collects stats from your Mac"
    gum style --foreground 252 "(CPU, memory, disk, network) and makes them available for Prometheus."
    echo ""

    # Check if already installed
    if command -v node_exporter &> /dev/null || brew list node_exporter &> /dev/null 2>&1; then
        gum style --foreground 46 "✅ node_exporter is already installed on this Mac!"

        if pgrep -x "node_exporter" > /dev/null; then
            gum style --foreground 46 "✅ It's running!"
        else
            gum style --foreground 226 "⚠️  It's installed but not running. Starting it..."
            brew services start node_exporter
            gum style --foreground 46 "✅ Started!"
        fi
    else
        if gum confirm "Install node_exporter on this Mac now?"; then
            gum style --foreground 212 "Installing..."
            brew install node_exporter
            brew services start node_exporter
            gum style --foreground 46 "✅ Installed and started!"
        else
            gum style --foreground 226 "Skipped. You can install it later with: brew install node_exporter"
        fi
    fi

    local mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "YOUR_MAC_IP")
    echo ""
    gum style --foreground 252 "This Mac's stats are now available at:"
    gum style --foreground 39 "  http://${mac_ip}:9100/metrics"
    echo ""

    gum style --foreground 226 "👉 Repeat this step on every Mac you want to monitor!"
    echo ""

    if ! gum confirm "Continue to Step 2?"; then
        setup_monitoring
        return
    fi

    # STEP 2
    echo ""
    gum style --foreground 212 --border normal --padding "0 1" "STEP 2: Install Prometheus + Grafana on your server"
    echo ""
    gum style --foreground 252 "You need to run Prometheus and Grafana on your Synology/server."
    gum style --foreground 252 "The easiest way is with Docker Compose."
    echo ""

    gum style --foreground 226 "Create this file on your server:"
    gum style --foreground 245 "  /volume1/docker/monitoring/docker-compose.yml"
    echo ""

    gum style --foreground 39 --border normal --padding "1 1" "version: '3'
services:
  prometheus:
    image: prom/prometheus
    container_name: prometheus
    ports:
      - 9090:9090
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    restart: unless-stopped

  grafana:
    image: grafana/grafana
    container_name: grafana
    ports:
      - 3000:3000
    volumes:
      - grafana_data:/var/lib/grafana
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:"

    echo ""
    gum style --foreground 226 "Create this file next to it:"
    gum style --foreground 245 "  /volume1/docker/monitoring/prometheus.yml"
    echo ""

    gum style --foreground 39 --border normal --padding "1 1" "global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'transcode-nodes'
    static_configs:
      # Add ALL your Macs here!
      - targets: ['${mac_ip}:9100']
        labels:
          node: 'mac-mini'
      # Example: add a second Mac
      # - targets: ['192.168.1.51:9100']
      #   labels:
      #     node: 'mac-studio'"

    echo ""
    gum style --foreground 226 "⚠️  IMPORTANT: Add ALL your Macs to prometheus.yml!"
    gum style --foreground 252 "Each Mac needs its own entry with IP:9100"

    echo ""
    gum style --foreground 226 "Then start it:"
    gum style --foreground 39 --border normal --padding "0 1" "cd /volume1/docker/monitoring && sudo docker compose up -d"
    echo ""

    if ! gum confirm "Continue to Step 3?"; then
        setup_monitoring
        return
    fi

    # STEP 3
    echo ""
    gum style --foreground 212 --border normal --padding "0 1" "STEP 3: Import the Dashboard in Grafana"
    echo ""
    gum style --foreground 252 "Now let's add a nice dashboard to see your stats!"
    echo ""

    gum style --foreground 226 "3.1 Open Grafana in your browser:"
    gum style --foreground 39 "    http://YOUR_SERVER_IP:3000"
    gum style --foreground 245 "    Default login: admin / admin"
    echo ""

    gum style --foreground 226 "3.2 Add Prometheus as a data source:"
    gum style --foreground 252 "    1. Click the gear icon (⚙️) → 'Data sources'"
    gum style --foreground 252 "    2. Click 'Add data source'"
    gum style --foreground 252 "    3. Select 'Prometheus'"
    gum style --foreground 252 "    4. Set URL to: http://prometheus:9090"
    gum style --foreground 252 "    5. Click 'Save & test'"
    echo ""

    gum style --foreground 226 "3.3 Import the Transcodarr dashboard:"
    gum style --foreground 252 "    1. Click '+' → 'Import'"
    gum style --foreground 252 "    2. Click 'Upload JSON file'"
    gum style --foreground 252 "    3. Select this file:"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" "$SCRIPT_DIR/grafana-dashboard.json"
    echo ""
    gum style --foreground 252 "    4. Select 'Prometheus' as the data source"
    gum style --foreground 252 "    5. Click 'Import'"
    echo ""

    gum style --foreground 46 --border double --padding "1 2" "🎉 Done! You should now see your Mac's stats in Grafana!"

    # Offer to open the file location
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo ""
        if gum confirm "Open the folder with the dashboard file?"; then
            open "$(dirname "$SCRIPT_DIR/grafana-dashboard.json")"
        fi
    fi

    echo ""
    return_or_exit
}

# Quick setup for users who already have Prometheus/Grafana
show_monitoring_existing_setup() {
    gum style --foreground 212 --border normal --padding "0 1" \
        "✅ Quick Setup for Existing Prometheus/Grafana"

    local mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "YOUR_MAC_IP")

    echo ""
    gum style --foreground 226 "1. Install node_exporter on this Mac:"
    echo ""

    if command -v node_exporter &> /dev/null || brew list node_exporter &> /dev/null 2>&1; then
        if pgrep -x "node_exporter" > /dev/null; then
            gum style --foreground 46 "   ✅ Already installed and running!"
        else
            gum style --foreground 226 "   ⚠️  Installed but not running"
            gum style --foreground 39 --border normal --padding "0 1" "brew services start node_exporter"
        fi
    else
        gum style --foreground 39 --border normal --padding "0 1" "brew install node_exporter && brew services start node_exporter"
    fi

    echo ""
    gum style --foreground 226 "2. Add this Mac to your prometheus.yml (under scrape_configs → transcode-nodes):"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" "      - targets: ['${mac_ip}:9100']
        labels:
          node: 'this-mac'"

    echo ""
    gum style --foreground 245 "💡 You can add multiple Macs! Each Mac needs its own entry."
    gum style --foreground 245 "   Example with 2 Macs:"
    echo ""
    gum style --foreground 39 --border normal --padding "0 1" "scrape_configs:
  - job_name: 'transcode-nodes'
    static_configs:
      - targets: ['192.168.1.50:9100']
        labels:
          node: 'mac-mini'
      - targets: ['192.168.1.51:9100']
        labels:
          node: 'mac-studio'"

    echo ""
    gum style --foreground 226 "3. Restart Prometheus:"
    gum style --foreground 39 --border normal --padding "0 1" "sudo docker restart prometheus"

    echo ""
    gum style --foreground 226 "4. Import dashboard in Grafana:"
    gum style --foreground 39 --border normal --padding "0 1" "$SCRIPT_DIR/grafana-dashboard.json"

    # Offer to open the file location
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo ""
        if gum confirm "Open the folder with the dashboard file?"; then
            open "$(dirname "$SCRIPT_DIR/grafana-dashboard.json")"
        fi
    fi

    echo ""
    return_or_exit
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
        "⬅️  Back to main menu" \
        "❌ Exit installer")

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
        "❌ Exit installer")
            exit 0
            ;;
    esac
}

# Main entry point
main() {
    check_gum
    clear
    show_banner
    show_backup_warning

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
