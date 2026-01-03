#!/bin/bash
#
# Transcodarr Installer
# Distributed Live Transcoding for Jellyfin using Apple Silicon Macs
#
# Unified wizard-style installer with auto-detection
#

set +e  # Don't exit on error, we handle errors ourselves

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="2.0.0"

# Source library modules
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/detection.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/mac-setup.sh"
source "$SCRIPT_DIR/lib/jellyfin-setup.sh"

# ============================================================================
# HOMEBREW & GUM SETUP
# ============================================================================

setup_brew_path() {
    if command -v brew &> /dev/null; then
        return 0
    fi

    # Synology-Homebrew / Linuxbrew
    if [[ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        return 0
    fi

    # Apple Silicon
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile 2>/dev/null; then
            echo '' >> ~/.zprofile
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        fi
        return 0
    fi

    # Intel Mac
    if [[ -f "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
        return 0
    fi

    return 1
}

check_and_install_gum() {
    if ! setup_brew_path; then
        if is_synology; then
            echo ""
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo -e "${RED}  Homebrew is niet geïnstalleerd op je Synology!${NC}"
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "Installeer Homebrew eerst met deze commando's:"
            echo ""
            echo -e "${GREEN}git clone https://github.com/MrCee/Synology-Homebrew.git ~/Synology-Homebrew${NC}"
            echo -e "${GREEN}~/Synology-Homebrew/install-synology-homebrew.sh${NC}"
            echo ""
            echo "Kies optie 1 (Minimal installation)."
            echo "Daarna: brew install gum"
            echo ""
            echo "Sluit je terminal, maak opnieuw SSH verbinding, en voer ./install.sh opnieuw uit."
            exit 1
        fi

        # Mac: install Homebrew
        echo "Homebrew installeren..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        setup_brew_path || {
            echo "Homebrew installatie mislukt"
            exit 1
        }
    fi

    # Install gum if needed
    if ! command -v gum &> /dev/null; then
        echo "Gum installeren (voor interactieve UI)..."
        brew install gum
    fi
}

# ============================================================================
# SYNOLOGY WIZARD
# ============================================================================

wizard_synology() {
    local mac_ip=""
    local mac_user=""
    local nas_ip=""
    local cache_path=""
    local jellyfin_config=""

    # Step 1: NFS Setup
    show_step 1 5 "NFS Configureren"

    # Check if NFS is already enabled
    if is_nfs_enabled; then
        show_skip "NFS service is al actief"
        show_info "Controleer of je media en cache folders NFS permissies hebben."
        echo ""
        if ! ask_confirm "Zijn de NFS permissies al ingesteld?"; then
            show_nfs_instructions
            wait_for_user "Heb je de NFS permissies ingesteld?"
        fi
    else
        show_warning "NFS is nog niet ingeschakeld op deze Synology!"
        echo ""
        show_nfs_instructions
        wait_for_user "Heb je NFS ingeschakeld en de permissies ingesteld?"
    fi
    mark_step_complete "nfs_setup"

    # Step 2: Collect configuration
    show_step 2 5 "Configuratie Verzamelen"

    echo ""
    show_what_this_does "We hebben wat informatie nodig over je Mac en je NAS."
    echo ""

    # Get Mac IP
    mac_ip=$(ask_input "Mac IP adres" "192.168.1.50")
    if [[ -z "$mac_ip" ]]; then
        show_error "Mac IP is verplicht"
        return 1
    fi

    # Validate Mac IP
    show_info "Controleren of Mac bereikbaar is..."
    if ! ping -c1 -W2 "$mac_ip" &>/dev/null; then
        show_warning "Mac op $mac_ip niet bereikbaar. Controleer het IP adres."
        if ! ask_confirm "Toch doorgaan?"; then
            return 1
        fi
    else
        show_result true "Mac bereikbaar op $mac_ip"
    fi

    # Get Mac username
    mac_user=$(ask_input "Mac gebruikersnaam" "$(whoami)")
    if [[ -z "$mac_user" ]]; then
        show_error "Mac gebruikersnaam is verplicht"
        return 1
    fi

    # Get NAS IP
    local detected_nas_ip
    detected_nas_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$detected_nas_ip" ]] && detected_nas_ip="192.168.1.100"
    nas_ip=$(ask_input "NAS IP adres" "$detected_nas_ip")

    # Get Jellyfin config path
    local detected_config
    detected_config=$(detect_jellyfin_config)
    jellyfin_config=$(ask_input "Jellyfin config folder" "$detected_config")

    # Get cache path
    cache_path=$(ask_input "Transcode cache folder" "${jellyfin_config}/cache")

    echo ""
    show_info "Configuratie:"
    echo "  Mac:           $mac_user@$mac_ip"
    echo "  NAS:           $nas_ip"
    echo "  Jellyfin:      $jellyfin_config"
    echo "  Cache:         $cache_path"
    echo ""

    if ! ask_confirm "Klopt dit?"; then
        show_info "Start opnieuw om andere waarden in te voeren."
        return 1
    fi

    mark_step_complete "config_collected"

    # Step 3: Generate SSH key and config files
    show_step 3 5 "Configuratie Genereren"
    run_jellyfin_setup "$mac_ip" "$mac_user" "$nas_ip" "$cache_path" "$jellyfin_config"

    # Steps 4-5 are handled inside run_jellyfin_setup (SSH key install, copy instructions)

    echo ""
    show_result true "Synology setup voltooid!"
    echo ""
    show_info "Ga nu naar je Mac en open Terminal:"
    echo ""
    echo "  1. Als je Git nog niet hebt, installeer Xcode Command Line Tools:"
    echo -e "     ${GREEN}xcode-select --install${NC}"
    echo ""
    echo "  2. Clone en start de installer:"
    echo -e "     ${GREEN}git clone https://github.com/JacquesToT/Transcodarr.git ~/Transcodarr${NC}"
    echo -e "     ${GREEN}cd ~/Transcodarr && ./install.sh${NC}"
    echo ""
}

# ============================================================================
# MAC WIZARD
# ============================================================================

wizard_mac() {
    local nas_ip=""
    local media_path=""
    local cache_path=""

    # Check for pending reboot first
    if is_reboot_pending; then
        show_info "Verder na herstart..."
        clear_pending_reboot

        # Check if synthetic links now exist
        if check_synthetic_links; then
            show_result true "/data en /config directories gevonden"
            # Continue with post-reboot setup
            run_mac_setup_after_reboot
            return $?
        else
            show_error "Synthetic links niet gevonden. Herstart je Mac en probeer opnieuw."
            return 1
        fi
    fi

    # Step 1: Prerequisites
    show_step 1 4 "Prerequisites Installeren"

    install_homebrew
    install_ffmpeg
    enable_ssh

    # Step 2: Get NAS info
    show_step 2 4 "NAS Configuratie"

    echo ""
    show_what_this_does "We moeten weten waar je NAS staat en waar je media en cache staan."
    echo ""

    # Try to load from state first
    nas_ip=$(get_config "nas_ip")
    media_path=$(get_config "media_path")
    cache_path=$(get_config "cache_path")

    # If not in state, ask
    if [[ -z "$nas_ip" ]]; then
        nas_ip=$(ask_input "NAS/Synology IP adres" "192.168.1.100")
    else
        show_info "NAS IP uit opgeslagen configuratie: $nas_ip"
        if ! ask_confirm "Klopt dit?"; then
            nas_ip=$(ask_input "NAS/Synology IP adres" "$nas_ip")
        fi
    fi

    # Validate NAS IP
    show_info "Controleren of NAS bereikbaar is..."
    if ! ping -c1 -W2 "$nas_ip" &>/dev/null; then
        show_warning "NAS op $nas_ip niet bereikbaar."
        if ! ask_confirm "Toch doorgaan?"; then
            return 1
        fi
    else
        show_result true "NAS bereikbaar op $nas_ip"
    fi

    if [[ -z "$media_path" ]]; then
        media_path=$(ask_input "Media folder op NAS (NFS export)" "/volume1/data/media")
    fi

    if [[ -z "$cache_path" ]]; then
        cache_path=$(ask_input "Cache folder op NAS (NFS export)" "/volume1/docker/jellyfin/cache")
    fi

    mark_step_complete "nas_config"

    # Step 3: Synthetic links (may require reboot)
    show_step 3 4 "Mount Points Aanmaken"

    local synth_result
    setup_synthetic_links
    synth_result=$?

    if [[ $synth_result -eq 2 ]]; then
        # Needs reboot
        show_reboot_instructions "$(pwd)"
        if ask_confirm "Nu herstarten?"; then
            show_info "Herstarten over 3 seconden..."
            sleep 3
            sudo reboot
        else
            show_warning "Vergeet niet te herstarten!"
            show_info "Na herstart: cd $(pwd) && ./install.sh"
        fi
        return 0  # Exit cleanly, will continue after reboot
    fi

    # Step 4: NFS mounts and LaunchDaemons
    show_step 4 4 "NFS Mounts Configureren"

    create_media_mount_script "$nas_ip" "$media_path"
    create_cache_mount_script "$nas_ip" "$cache_path"
    create_launch_daemons
    configure_energy_settings

    # Summary
    echo ""
    show_mac_summary "$nas_ip"

    # Show DOCKER_MODS instructions
    local mac_ip
    mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "<MAC_IP>")
    echo ""
    show_docker_mods_instructions "$mac_ip"
}

# ============================================================================
# ADD NODE WIZARD
# ============================================================================

wizard_add_node_synology() {
    show_step 1 2 "Nieuwe Mac Toevoegen"

    local mac_ip
    local mac_user

    mac_ip=$(ask_input "Nieuwe Mac IP adres" "192.168.1.51")
    mac_user=$(ask_input "Mac gebruikersnaam" "$(whoami)")

    show_step 2 2 "SSH Key Installeren"
    run_add_node_setup "$mac_ip" "$mac_user"

    echo ""
    show_result true "Node configuratie voltooid!"
}

wizard_add_node_mac() {
    show_step 1 2 "Mac als Node Toevoegen"

    show_info "Deze Mac wordt toegevoegd als transcode node."
    echo ""

    # Check for existing SSH key
    if check_transcodarr_ssh_key; then
        show_skip "SSH key is al geconfigureerd"
    else
        show_warning "Geen SSH key gevonden."
        show_info "Voer de installer uit op je Synology om de SSH key te installeren."
        return 1
    fi

    # Get NAS info
    local nas_ip
    nas_ip=$(get_config "nas_ip")
    if [[ -z "$nas_ip" ]]; then
        nas_ip=$(ask_input "NAS/Synology IP adres" "192.168.1.100")
    fi

    show_step 2 2 "Mac Configureren"

    # Run abbreviated setup (skip already done steps)
    local media_path
    local cache_path

    media_path=$(get_config "media_path")
    [[ -z "$media_path" ]] && media_path=$(ask_input "Media folder op NAS" "/volume1/data/media")

    cache_path=$(get_config "cache_path")
    [[ -z "$cache_path" ]] && cache_path=$(ask_input "Cache folder op NAS" "/volume1/docker/jellyfin/cache")

    # Only run what's needed
    if ! check_synthetic_links; then
        setup_synthetic_links
        if [[ $? -eq 2 ]]; then
            show_reboot_instructions "$(pwd)"
            return 0
        fi
    fi

    if ! check_mount_scripts; then
        create_media_mount_script "$nas_ip" "$media_path"
        create_cache_mount_script "$nas_ip" "$cache_path"
        create_launch_daemons
    fi

    if ! check_energy_settings; then
        configure_energy_settings
    fi

    echo ""
    local mac_ip
    mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "<MAC_IP>")
    show_info "Mac geconfigureerd! Voeg deze Mac toe op je Synology:"
    echo ""
    echo -e "  ${GREEN}docker exec jellyfin rffmpeg add $mac_ip --weight 2${NC}"
    echo ""
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    # Ensure gum is available
    check_and_install_gum

    # Show banner
    show_banner "$VERSION"

    # Detect system
    local system_type
    system_type=$(get_system_type)
    local system_name
    system_name=$(get_system_name)

    echo ""
    show_info "Gedetecteerd systeem: $system_name"

    # Detect install status
    local install_status
    install_status=$(get_install_status)

    case "$install_status" in
        "first_time")
            show_info "Dit lijkt een eerste installatie te zijn."
            ;;
        "adding_node")
            show_info "FFmpeg is geïnstalleerd, SSH key ontbreekt nog."
            ;;
        "partial")
            show_info "Gedeeltelijke installatie gedetecteerd."
            ;;
        "fully_configured")
            show_info "Systeem lijkt volledig geconfigureerd."
            ;;
        "configured")
            show_info "rffmpeg is al geconfigureerd."
            ;;
    esac

    echo ""

    # Route to appropriate wizard
    if is_synology; then
        case "$install_status" in
            "first_time")
                if ask_confirm "Eerste keer setup starten?"; then
                    wizard_synology
                fi
                ;;
            "configured")
                if ask_confirm "Een nieuwe Mac node toevoegen?"; then
                    wizard_add_node_synology
                else
                    show_info "Gebruik de volgende commando's om nodes te beheren:"
                    echo ""
                    echo "  docker exec jellyfin rffmpeg status"
                    echo "  docker exec jellyfin rffmpeg add <IP> --weight 2"
                    echo "  docker exec jellyfin rffmpeg remove <IP>"
                fi
                ;;
        esac
    elif is_mac; then
        case "$install_status" in
            "first_time")
                if ask_confirm "Mac setup starten?"; then
                    wizard_mac
                fi
                ;;
            "adding_node")
                if ask_confirm "Deze Mac als node toevoegen?"; then
                    wizard_add_node_mac
                fi
                ;;
            "partial")
                show_info "Partiële installatie gedetecteerd."
                if is_reboot_pending; then
                    if ask_confirm "Verdergaan na herstart?"; then
                        wizard_mac
                    fi
                else
                    if ask_confirm "Setup voltooien?"; then
                        wizard_mac
                    fi
                fi
                ;;
            "fully_configured")
                show_info "Deze Mac is al volledig geconfigureerd."
                local mac_ip
                mac_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "<MAC_IP>")
                echo ""
                echo "  Voeg deze Mac toe aan rffmpeg:"
                echo -e "  ${GREEN}docker exec jellyfin rffmpeg add $mac_ip --weight 2${NC}"
                echo ""
                echo "  Of voer de uninstaller uit:"
                echo -e "  ${GREEN}./uninstall.sh${NC}"
                ;;
        esac
    else
        show_error "Onbekend systeem. Deze installer werkt alleen op Synology en macOS."
        exit 1
    fi

    echo ""
}

# Run main
main "$@"
