#!/bin/bash
#
# Transcodarr UI Helpers
# User interface functions with embedded instructions
#

# Colors for fallback (when gum is not available)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# PROGRESS & STEPS
# ============================================================================

# Show step header with progress
# Usage: show_step 1 5 "Configure NFS"
show_step() {
    local current="$1"
    local total="$2"
    local title="$3"

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 212 \
            --border-foreground 212 \
            --border double \
            --padding "0 2" \
            --width 60 \
            "Step $current of $total: $title"
    else
        echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
        echo -e "${MAGENTA}  Step $current of $total: $title${NC}"
        echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
    fi
    echo ""
}

# Show what just happened (success/failure)
# Usage: show_result true "Homebrew installed"
show_result() {
    local success="$1"
    local message="$2"

    if [[ "$success" == "true" ]]; then
        if command -v gum &> /dev/null; then
            gum style --foreground 46 "  [DONE] $message"
        else
            echo -e "  ${GREEN}[DONE]${NC} $message"
        fi
    else
        if command -v gum &> /dev/null; then
            gum style --foreground 196 "  [FAILED] $message"
        else
            echo -e "  ${RED}[FAILED]${NC} $message"
        fi
    fi
}

# Show skip message (when step is already done)
# Usage: show_skip "Homebrew is already installed"
show_skip() {
    local message="$1"

    if command -v gum &> /dev/null; then
        gum style --foreground 226 "  [SKIP] $message"
    else
        echo -e "  ${YELLOW}[SKIP]${NC} $message"
    fi
}

# Show info message
# Usage: show_info "Please wait..."
show_info() {
    local message="$1"

    if command -v gum &> /dev/null; then
        gum style --foreground 39 "  [INFO] $message"
    else
        echo -e "  ${BLUE}[INFO]${NC} $message"
    fi
}

# Show warning message
# Usage: show_warning "This may take a while"
show_warning() {
    local message="$1"

    if command -v gum &> /dev/null; then
        gum style --foreground 226 "  [!] $message"
    else
        echo -e "  ${YELLOW}[!]${NC} $message"
    fi
}

# Show error message
# Usage: show_error "Could not connect"
show_error() {
    local message="$1"

    if command -v gum &> /dev/null; then
        gum style --foreground 196 "  [ERROR] $message"
    else
        echo -e "  ${RED}[ERROR]${NC} $message"
    fi
}

# ============================================================================
# EXPLANATIONS (for beginners)
# ============================================================================

# Show explanation box
# Usage: show_explanation "What is NFS?" "NFS is a protocol..." "It works like..."
show_explanation() {
    local title="$1"
    shift
    local lines=("$@")

    echo ""
    if command -v gum &> /dev/null; then
        gum style --foreground 226 --bold "$title"
        for line in "${lines[@]}"; do
            gum style --foreground 252 "  $line"
        done
    else
        echo -e "${YELLOW}${BOLD}$title${NC}"
        for line in "${lines[@]}"; do
            echo -e "  ${line}"
        done
    fi
    echo ""
}

# Show what this step does
# Usage: show_what_this_does "This installs FFmpeg with hardware acceleration..."
show_what_this_does() {
    local explanation="$1"

    echo ""
    if command -v gum &> /dev/null; then
        gum style --foreground 245 --italic "  What this does: $explanation"
    else
        echo -e "  ${CYAN}What this does:${NC} $explanation"
    fi
    echo ""
}

# ============================================================================
# USER INTERACTION
# ============================================================================

# Wait for user to confirm they've completed a manual step
# Usage: wait_for_user "Have you enabled NFS in DSM?"
wait_for_user() {
    local message="$1"

    echo ""
    if command -v gum &> /dev/null; then
        gum style --foreground 39 "$message"
        gum confirm "Yes, this is done" && return 0 || return 1
    else
        echo -e "${BLUE}$message${NC}"
        read -p "Press Enter to continue (or Ctrl+C to stop)..."
        return 0
    fi
}

# Ask a yes/no question
# Usage: ask_confirm "Do you want to continue?"
ask_confirm() {
    local question="$1"

    if command -v gum &> /dev/null; then
        gum confirm "$question"
    else
        read -p "$question [y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# Ask for text input
# Usage: ip=$(ask_input "Mac IP address" "192.168.1.50")
ask_input() {
    local prompt="$1"
    local default="$2"
    local placeholder="${3:-$default}"

    if command -v gum &> /dev/null; then
        gum input --placeholder "$placeholder" --prompt "$prompt: " --value "$default"
    else
        read -p "$prompt [$default]: " value
        echo "${value:-$default}"
    fi
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - NFS SETUP
# ============================================================================

show_nfs_instructions() {
    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 212 \
            --border-foreground 212 \
            --border normal \
            --padding "1 2" \
            --width 65 \
            "SYNOLOGY: Enable NFS"
    else
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  SYNOLOGY: Enable NFS                                         ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  In Synology DSM, follow these steps:"
    echo ""
    echo -e "  ${CYAN}1. Control Panel > File Services > NFS tab${NC}"
    echo "     - Check 'Enable NFS service'"
    echo "     - Click Apply"
    echo ""
    echo -e "  ${CYAN}2. Control Panel > Shared Folder${NC}"
    echo "     - Select your media folder (e.g. 'data')"
    echo "     - Click Edit > NFS Permissions"
    echo "     - Click Create and configure:"
    echo ""
    echo -e "       ${GREEN}Hostname:${NC}      *"
    echo -e "       ${GREEN}Privilege:${NC}     Read/Write"
    echo -e "       ${GREEN}Squash:${NC}        Map all users to admin"
    echo -e "       ${GREEN}[x]${NC}            Allow connections from non-privileged ports"
    echo -e "       ${GREEN}[x]${NC}            Allow users to access mounted subfolders"
    echo ""
    echo -e "  ${CYAN}3. Repeat step 2 for your cache folder${NC}"
    echo "     (e.g. 'docker' or wherever your Jellyfin cache is)"
    echo ""
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - DOCKER_MODS
# ============================================================================

show_docker_mods_instructions() {
    local mac_ip="${1:-<MAC_IP>}"

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 212 \
            --border-foreground 212 \
            --border double \
            --padding "1 2" \
            --width 65 \
            "IMPORTANT: Activate rffmpeg Mod"
    else
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  IMPORTANT: Activate rffmpeg Mod                             ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Add these 2 environment variables to Jellyfin:"
    echo ""
    echo -e "  ${GREEN}DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg${NC}"
    echo -e "  ${GREEN}FFMPEG_PATH=/usr/local/bin/ffmpeg${NC}"
    echo ""
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${CYAN}Method A: Edit docker-compose.yml${NC}"
    echo ""
    echo "    1. Open your docker-compose.yml"
    echo "    2. Add under 'environment:':"
    echo ""
    echo -e "       ${GREEN}environment:${NC}"
    echo -e "         ${GREEN}- DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg${NC}"
    echo -e "         ${GREEN}- FFMPEG_PATH=/usr/local/bin/ffmpeg${NC}"
    echo ""
    echo "    3. Restart the container:"
    echo -e "       ${YELLOW}docker compose down && docker compose up -d${NC}"
    echo ""
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${CYAN}Method B: Container Manager UI${NC}"
    echo ""
    echo "    1. Open Container Manager in DSM"
    echo "    2. Select 'jellyfin' container"
    echo "    3. Click 'Action' > 'Stop'"
    echo "    4. Click 'Action' > 'Edit'"
    echo "    5. Go to 'Environment' tab"
    echo "    6. Add both variables"
    echo "    7. Click 'Save' and start the container"
    echo ""
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${YELLOW}After container restart (wait ~30 seconds):${NC}"
    echo ""
    echo -e "  ${GREEN}docker exec jellyfin rffmpeg add $mac_ip --weight 2${NC}"
    echo ""
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - SSH KEY
# ============================================================================

show_ssh_key_instructions() {
    local mac_user="${1:-<MAC_USER>}"
    local mac_ip="${2:-<MAC_IP>}"

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 212 \
            --border-foreground 212 \
            --border normal \
            --padding "1 2" \
            --width 65 \
            "Install SSH Key on Mac"
    else
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  Install SSH Key on Mac                                       ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo -e "  ${YELLOW}IMPORTANT: You will be asked for a password.${NC}"
    echo ""
    echo -e "  ${GREEN}This is your MAC password${NC} (the one you use to log into your Mac)"
    echo -e "  ${RED}NOT your Synology password!${NC}"
    echo ""
    echo "  What happens:"
    echo "    1. We connect to your Mac ($mac_ip)"
    echo "    2. The SSH key is copied to ~/.ssh/authorized_keys"
    echo "    3. After this, SSH works without a password"
    echo ""
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - MAC REMOTE LOGIN
# ============================================================================

show_remote_login_instructions() {
    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 212 \
            --border-foreground 212 \
            --border normal \
            --padding "1 2" \
            --width 65 \
            "MAC: Enable Remote Login"
    else
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  MAC: Enable Remote Login                                     ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  This is required so Jellyfin can send FFmpeg commands."
    echo ""
    echo -e "  ${CYAN}On your Mac:${NC}"
    echo ""
    echo "    1. Open System Settings"
    echo "    2. Go to General > Sharing"
    echo "    3. Turn ON 'Remote Login'"
    echo "    4. For 'Allow access for': choose 'All users'"
    echo "       (or add your user)"
    echo ""
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - SSH PASSWORD PROMPT (for remote installer)
# ============================================================================

show_ssh_password_prompt() {
    local mac_user="${1:-<MAC_USER>}"
    local mac_ip="${2:-<MAC_IP>}"

    if command -v gum &> /dev/null; then
        gum style \
            --foreground 226 \
            --border-foreground 226 \
            --border normal \
            --padding "1 2" \
            --width 65 \
            "SSH Key Installation"
    else
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  SSH Key Installation                                        ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo -e "  ${YELLOW}You will be asked for a password.${NC}"
    echo ""
    echo -e "  ${GREEN}Enter your MAC password${NC}"
    echo -e "  (the one you use to log into your Mac at ${CYAN}$mac_ip${NC})"
    echo ""
    echo -e "  ${RED}This is NOT your Synology password!${NC}"
    echo ""
    echo "  After this, SSH will work without a password."
    echo ""
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - NAS SSH PASSWORD PROMPT (for monitor)
# ============================================================================

show_nas_ssh_password_prompt() {
    local nas_user="${1:-<NAS_USER>}"
    local nas_ip="${2:-<NAS_IP>}"

    if command -v gum &> /dev/null; then
        gum style \
            --foreground 226 \
            --border-foreground 226 \
            --border normal \
            --padding "1 2" \
            --width 65 \
            "NAS/Synology SSH Authentication"
    else
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  NAS/Synology SSH Authentication                             ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo -e "  ${YELLOW}You are being asked for a password.${NC}"
    echo ""
    echo -e "  ${GREEN}Enter your SYNOLOGY/NAS password${NC}"
    echo -e "  (the one you use to log into your NAS at ${CYAN}$nas_ip${NC})"
    echo ""
    echo -e "  User: ${CYAN}$nas_user${NC}"
    echo ""
    echo -e "  ${RED}This is NOT your Mac password!${NC}"
    echo ""
    echo "  Tip: Set up SSH key auth to avoid this prompt:"
    echo -e "    ${GREEN}ssh-copy-id $nas_user@$nas_ip${NC}"
    echo ""
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - REBOOT WAIT (for remote installer)
# ============================================================================

show_reboot_wait_message() {
    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 226 \
            --border-foreground 226 \
            --border double \
            --padding "1 2" \
            --width 65 \
            "MAC REBOOT REQUIRED"
    else
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  MAC REBOOT REQUIRED                                         ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  The Mac needs to restart for synthetic links to take effect."
    echo "  (/data and /config mount points)"
    echo ""
    echo "  What happens next:"
    echo "    1. You reboot your Mac (manually or via the menu)"
    echo "    2. This installer waits for the Mac to come back"
    echo "    3. Setup continues automatically when Mac is online"
    echo ""
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - COMPLETE SUCCESS (for remote installer)
# ============================================================================

show_remote_install_complete() {
    local mac_ip="${1:-<MAC_IP>}"
    local mac_user="${2:-<MAC_USER>}"

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 46 \
            --border-foreground 46 \
            --border double \
            --padding "1 2" \
            --width 65 \
            "INSTALLATION COMPLETE!"
    else
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  INSTALLATION COMPLETE!                                       ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Your Mac ($mac_user@$mac_ip) is ready to transcode!"
    echo ""
    echo "  Summary:"
    echo "    [x] Homebrew installed"
    echo "    [x] FFmpeg with VideoToolbox installed"
    echo "    [x] Synthetic links created (/data, /config)"
    echo "    [x] NFS mount scripts installed"
    echo "    [x] LaunchDaemons configured"
    echo "    [x] Energy settings optimized"
    echo ""
}

# ============================================================================
# EMBEDDED INSTRUCTIONS - REBOOT
# ============================================================================

show_reboot_instructions() {
    local install_path="${1:-~/Transcodarr}"

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 226 \
            --border-foreground 226 \
            --border double \
            --padding "1 2" \
            --width 65 \
            "REBOOT REQUIRED"
    else
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  REBOOT REQUIRED                                             ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  The /data and /config mount points have been created."
    echo "  Your Mac needs to restart for these to take effect."
    echo ""
    echo -e "  ${CYAN}After restarting:${NC}"
    echo ""
    echo "    1. Open Terminal"
    echo "    2. Run:"
    echo ""
    echo -e "       ${GREEN}cd $install_path && ./install.sh${NC}"
    echo ""
    echo "    The installer will automatically continue where you left off."
    echo ""
}

# ============================================================================
# SUMMARY SCREENS
# ============================================================================

show_synology_summary() {
    local mac_ip="$1"
    local mac_user="$2"
    local jellyfin_config="$3"

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 46 \
            --border-foreground 46 \
            --border double \
            --padding "1 2" \
            --width 65 \
            "Synology Setup Complete!"
    else
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  Synology Setup Complete!                                     ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Configuration saved:"
    echo ""
    echo -e "    Mac:           ${CYAN}$mac_user@$mac_ip${NC}"
    echo -e "    Jellyfin:      ${CYAN}$jellyfin_config${NC}"
    echo ""
    echo "  Next steps:"
    echo ""
    echo "    1. Go to your Mac"
    echo "    2. Open Terminal"
    echo "    3. Run:"
    echo ""
    echo -e "       ${GREEN}cd ~/Transcodarr && ./install.sh${NC}"
    echo ""
}

show_mac_summary() {
    local nas_ip="$1"

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 46 \
            --border-foreground 46 \
            --border double \
            --padding "1 2" \
            --width 65 \
            "Mac Setup Complete!"
    else
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  Mac Setup Complete!                                          ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Your Mac is ready to transcode!"
    echo ""
    echo "  Next steps (on Synology):"
    echo ""
    echo "    1. Add DOCKER_MODS to Jellyfin (see instructions above)"
    echo "    2. Restart Jellyfin container"
    echo "    3. Run:"
    echo ""
    echo -e "       ${GREEN}docker exec jellyfin rffmpeg status${NC}"
    echo ""
    echo "  You should see your Mac in the list!"
    echo ""
}

# Show banner
show_banner() {
    local version="${1:-1.0.0}"

    if command -v gum &> /dev/null; then
        gum style \
            --foreground 212 \
            --border-foreground 212 \
            --border double \
            --align center \
            --width 60 \
            --margin "1 2" \
            --padding "1 2" \
            "TRANSCODARR v${version}" \
            "" \
            "Distributed Live Transcoding for Jellyfin" \
            "Using Apple Silicon VideoToolbox"
    else
        echo ""
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║                    TRANSCODARR v${version}                        ║${NC}"
        echo -e "${MAGENTA}║                                                              ║${NC}"
        echo -e "${MAGENTA}║        Distributed Live Transcoding for Jellyfin            ║${NC}"
        echo -e "${MAGENTA}║           Using Apple Silicon VideoToolbox                  ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
    fi
}
