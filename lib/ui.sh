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
# Usage: show_step 1 5 "NFS Configureren"
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
            "Stap $current van $total: $title"
    else
        echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
        echo -e "${MAGENTA}  Stap $current van $total: $title${NC}"
        echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
    fi
    echo ""
}

# Show what just happened (success/failure)
# Usage: show_result true "Homebrew geïnstalleerd"
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
# Usage: show_skip "Homebrew is al geïnstalleerd"
show_skip() {
    local message="$1"

    if command -v gum &> /dev/null; then
        gum style --foreground 226 "  [SKIP] $message"
    else
        echo -e "  ${YELLOW}[SKIP]${NC} $message"
    fi
}

# Show info message
# Usage: show_info "Even geduld..."
show_info() {
    local message="$1"

    if command -v gum &> /dev/null; then
        gum style --foreground 39 "  [INFO] $message"
    else
        echo -e "  ${BLUE}[INFO]${NC} $message"
    fi
}

# Show warning message
# Usage: show_warning "Dit kan even duren"
show_warning() {
    local message="$1"

    if command -v gum &> /dev/null; then
        gum style --foreground 226 "  [!] $message"
    else
        echo -e "  ${YELLOW}[!]${NC} $message"
    fi
}

# Show error message
# Usage: show_error "Kon niet verbinden"
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
# Usage: show_explanation "Wat is NFS?" "NFS is een protocol..." "Het werkt zoals..."
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
# Usage: show_what_this_does "Dit installeert FFmpeg met hardware acceleratie..."
show_what_this_does() {
    local explanation="$1"

    echo ""
    if command -v gum &> /dev/null; then
        gum style --foreground 245 --italic "  Wat dit doet: $explanation"
    else
        echo -e "  ${CYAN}Wat dit doet:${NC} $explanation"
    fi
    echo ""
}

# ============================================================================
# USER INTERACTION
# ============================================================================

# Wait for user to confirm they've completed a manual step
# Usage: wait_for_user "Heb je NFS ingeschakeld in DSM?"
wait_for_user() {
    local message="$1"

    echo ""
    if command -v gum &> /dev/null; then
        gum style --foreground 39 "$message"
        gum confirm "Ja, dit is gedaan" && return 0 || return 1
    else
        echo -e "${BLUE}$message${NC}"
        read -p "Druk Enter om door te gaan (of Ctrl+C om te stoppen)..."
        return 0
    fi
}

# Ask a yes/no question
# Usage: ask_confirm "Wil je doorgaan?"
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
# Usage: ip=$(ask_input "Mac IP adres" "192.168.1.50")
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
            "SYNOLOGY: NFS Inschakelen"
    else
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  SYNOLOGY: NFS Inschakelen                                    ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  In Synology DSM, doe deze stappen:"
    echo ""
    echo -e "  ${CYAN}1. Control Panel > File Services > NFS tab${NC}"
    echo "     - Vink 'Enable NFS service' aan"
    echo "     - Klik Apply"
    echo ""
    echo -e "  ${CYAN}2. Control Panel > Shared Folder${NC}"
    echo "     - Selecteer je media folder (bijv. 'data')"
    echo "     - Klik Edit > NFS Permissions"
    echo "     - Klik Create en stel in:"
    echo ""
    echo -e "       ${GREEN}Hostname:${NC}      *"
    echo -e "       ${GREEN}Privilege:${NC}     Read/Write"
    echo -e "       ${GREEN}Squash:${NC}        Map all users to admin"
    echo -e "       ${GREEN}[x]${NC}            Allow connections from non-privileged ports"
    echo -e "       ${GREEN}[x]${NC}            Allow users to access mounted subfolders"
    echo ""
    echo -e "  ${CYAN}3. Herhaal stap 2 voor je cache folder${NC}"
    echo "     (bijv. 'docker' of waar je Jellyfin cache staat)"
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
            "BELANGRIJK: rffmpeg Mod Activeren"
    else
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  BELANGRIJK: rffmpeg Mod Activeren                           ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Voeg deze 2 environment variables toe aan Jellyfin:"
    echo ""
    echo -e "  ${GREEN}DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg${NC}"
    echo -e "  ${GREEN}FFMPEG_PATH=/usr/local/bin/ffmpeg${NC}"
    echo ""
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${CYAN}Methode A: docker-compose.yml bewerken${NC}"
    echo ""
    echo "    1. Open je docker-compose.yml"
    echo "    2. Voeg onder 'environment:' toe:"
    echo ""
    echo -e "       ${GREEN}environment:${NC}"
    echo -e "         ${GREEN}- DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg${NC}"
    echo -e "         ${GREEN}- FFMPEG_PATH=/usr/local/bin/ffmpeg${NC}"
    echo ""
    echo "    3. Herstart de container:"
    echo -e "       ${YELLOW}docker compose down && docker compose up -d${NC}"
    echo ""
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${CYAN}Methode B: Container Manager UI${NC}"
    echo ""
    echo "    1. Open Container Manager in DSM"
    echo "    2. Selecteer 'jellyfin' container"
    echo "    3. Klik 'Action' > 'Stop'"
    echo "    4. Klik 'Action' > 'Edit'"
    echo "    5. Ga naar 'Environment' tab"
    echo "    6. Voeg beide variables toe"
    echo "    7. Klik 'Save' en start de container"
    echo ""
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${YELLOW}Na herstart container (wacht ~30 seconden):${NC}"
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
            "SSH Key Installeren op Mac"
    else
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  SSH Key Installeren op Mac                                  ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo -e "  ${YELLOW}BELANGRIJK: Je wordt zo gevraagd om een wachtwoord.${NC}"
    echo ""
    echo -e "  ${GREEN}Dit is je MAC wachtwoord${NC} (waarmee je inlogt op je Mac)"
    echo -e "  ${RED}NIET je Synology wachtwoord!${NC}"
    echo ""
    echo "  Wat er gebeurt:"
    echo "    1. We maken verbinding met je Mac ($mac_ip)"
    echo "    2. De SSH key wordt gekopieerd naar ~/.ssh/authorized_keys"
    echo "    3. Daarna werkt SSH zonder wachtwoord"
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
            "MAC: Remote Login Inschakelen"
    else
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  MAC: Remote Login Inschakelen                               ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Dit is nodig zodat Jellyfin FFmpeg opdrachten kan sturen."
    echo ""
    echo -e "  ${CYAN}Op je Mac:${NC}"
    echo ""
    echo "    1. Open System Settings (Systeeminstellingen)"
    echo "    2. Ga naar General > Sharing"
    echo "    3. Zet 'Remote Login' AAN"
    echo "    4. Bij 'Allow access for': kies 'All users'"
    echo "       (of voeg je gebruiker toe)"
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
            "HERSTART VEREIST"
    else
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  HERSTART VEREIST                                            ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  De /data en /config mount points zijn aangemaakt."
    echo "  Hiervoor moet je Mac opnieuw opstarten."
    echo ""
    echo -e "  ${CYAN}Na het herstarten:${NC}"
    echo ""
    echo "    1. Open Terminal"
    echo "    2. Voer uit:"
    echo ""
    echo -e "       ${GREEN}cd $install_path && ./install.sh${NC}"
    echo ""
    echo "    De installer gaat automatisch verder waar je gebleven was."
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
            "Synology Setup Voltooid!"
    else
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  Synology Setup Voltooid!                                    ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Configuratie opgeslagen:"
    echo ""
    echo -e "    Mac:           ${CYAN}$mac_user@$mac_ip${NC}"
    echo -e "    Jellyfin:      ${CYAN}$jellyfin_config${NC}"
    echo ""
    echo "  Volgende stappen:"
    echo ""
    echo "    1. Ga naar je Mac"
    echo "    2. Open Terminal"
    echo "    3. Voer uit:"
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
            "Mac Setup Voltooid!"
    else
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  Mac Setup Voltooid!                                         ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Je Mac is klaar om te transcoden!"
    echo ""
    echo "  Volgende stappen (op Synology):"
    echo ""
    echo "    1. Voeg DOCKER_MODS toe aan Jellyfin (zie instructies hierboven)"
    echo "    2. Herstart Jellyfin container"
    echo "    3. Voer uit:"
    echo ""
    echo -e "       ${GREEN}docker exec jellyfin rffmpeg status${NC}"
    echo ""
    echo "  Je zou je Mac moeten zien in de lijst!"
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
            "Distributed Live Transcoding voor Jellyfin" \
            "Met Apple Silicon VideoToolbox"
    else
        echo ""
        echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║                    TRANSCODARR v${version}                        ║${NC}"
        echo -e "${MAGENTA}║                                                              ║${NC}"
        echo -e "${MAGENTA}║        Distributed Live Transcoding voor Jellyfin           ║${NC}"
        echo -e "${MAGENTA}║           Met Apple Silicon VideoToolbox                    ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
    fi
}
