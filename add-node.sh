#!/bin/bash
#
# Transcodarr - Add Node
# Adds a new Mac node to an existing Transcodarr installation
#
# Can be run:
#   1. From the main menu in install.sh
#   2. Standalone: ./add-node.sh
#

set +e  # Don't exit on error, we handle errors ourselves

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="3.0.0"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Source library modules
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/detection.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/remote-ssh.sh"
source "$SCRIPT_DIR/lib/jellyfin-setup.sh"

# ============================================================================
# PREREQUISITES CHECK
# ============================================================================

check_prerequisites() {
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

    # Check SSH key exists from previous installation
    if [[ ! -f "$key_path" ]]; then
        show_error "No SSH key found from previous installation"
        echo ""
        show_info "Run the first-time setup first:"
        echo -e "  ${GREEN}./install.sh${NC}"
        echo ""
        return 1
    fi

    # Check for essential config
    local nas_ip
    nas_ip=$(get_config "nas_ip")
    if [[ -z "$nas_ip" ]]; then
        show_error "NAS configuration not found"
        echo ""
        show_info "Run the first-time setup first:"
        echo -e "  ${GREEN}./install.sh${NC}"
        echo ""
        return 1
    fi

    return 0
}

# ============================================================================
# WIZARD STEPS
# ============================================================================

step_collect_mac_info() {
    show_step 1 4 "Add New Mac"

    MAC_IP=$(ask_input "New Mac IP address" "192.168.1.51")
    MAC_USER=$(ask_input "Mac username" "$(whoami)")
}

step_verify_connectivity() {
    show_step 2 4 "Connect to Mac"

    # Test if Mac is reachable
    if ! test_mac_reachable "$MAC_IP"; then
        show_error "Mac at $MAC_IP is not reachable"
        if ask_confirm "Try again?"; then
            step_verify_connectivity
            return $?
        fi
        return 1
    fi
    show_result true "Mac reachable"

    # Check SSH port
    if ! test_ssh_port "$MAC_IP"; then
        show_warning "SSH port not open on Mac"
        show_remote_login_instructions
        wait_for_user "Have you enabled Remote Login on Mac?"

        if ! test_ssh_port "$MAC_IP"; then
            show_error "SSH port still not accessible"
            return 1
        fi
    fi
    show_result true "SSH port open"

    return 0
}

step_install_ssh_key() {
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

    # Check if key auth already works
    if test_ssh_key_auth "$MAC_USER" "$MAC_IP" "$key_path"; then
        show_skip "SSH key authentication already working"
        return 0
    fi

    # Install SSH key
    show_info "Installing SSH key on Mac..."
    install_ssh_key_interactive "$MAC_USER" "$MAC_IP" "${key_path}.pub"

    sleep 1
    if ! test_ssh_key_auth "$MAC_USER" "$MAC_IP" "$key_path"; then
        show_error "SSH key authentication failed"
        return 1
    fi

    show_result true "SSH key installed"
    return 0
}

step_setup_mac_software() {
    show_step 3 4 "Setup Mac (Remote)"

    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

    # Install Homebrew
    remote_install_homebrew "$MAC_USER" "$MAC_IP" "$key_path"

    # Install FFmpeg with VideoToolbox
    remote_install_ffmpeg "$MAC_USER" "$MAC_IP" "$key_path"
}

step_setup_mount_points() {
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

    # Setup synthetic links (may require reboot)
    local synth_result
    remote_setup_synthetic_links "$MAC_USER" "$MAC_IP" "$key_path"
    synth_result=$?

    if [[ $synth_result -eq 2 ]]; then
        # Mac needs to reboot
        if handle_mac_reboot "$MAC_USER" "$MAC_IP" "$key_path"; then
            if ! remote_check_synthetic_links "$MAC_USER" "$MAC_IP" "$key_path"; then
                show_error "Synthetic links not found after reboot"
                return 1
            fi
        else
            show_info "Re-run this script when Mac is back online"
            return 0
        fi
    fi

    return 0
}

step_configure_nfs() {
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"
    local nas_ip media_path cache_path

    nas_ip=$(get_config "nas_ip")
    media_path=$(get_config "media_path")
    cache_path=$(get_config "cache_path")

    # Use combined function - single sudo session for all NFS setup
    # This creates mount scripts, LaunchDaemons, configures energy, and verifies NFS
    remote_setup_nfs_complete "$MAC_USER" "$MAC_IP" "$key_path" "$nas_ip" "$media_path" "$cache_path"
}

step_register_rffmpeg() {
    show_step 4 4 "Register Mac"

    show_info "Adding Mac to rffmpeg configuration..."
    echo ""
    show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
    echo ""

    # Calculate weight based on existing nodes
    # First node = weight 2, second = weight 3, etc.
    local weight=2
    local node_count=0

    # Check if Jellyfin container is running
    if ! sudo docker ps 2>/dev/null | grep -q jellyfin; then
        show_warning "Jellyfin container not running"
        show_info "Start Jellyfin first, then add Mac manually:"
        echo -e "  ${GREEN}sudo docker exec jellyfin rffmpeg add $MAC_IP --weight $weight${NC}"
        return
    fi

    # Check if rffmpeg is available in container
    local rffmpeg_check
    rffmpeg_check=$(sudo docker exec jellyfin which rffmpeg 2>/dev/null || echo "")

    if [[ -z "$rffmpeg_check" ]]; then
        show_warning "rffmpeg not found in Jellyfin container"
        echo ""
        show_info "Make sure DOCKER_MODS is set in your docker-compose.yml:"
        echo -e "  ${CYAN}environment:${NC}"
        echo -e "    ${GREEN}- DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg${NC}"
        echo ""
        show_info "Then restart: sudo docker-compose up -d --force-recreate"
        echo ""
        show_info "After that, add Mac manually:"
        echo -e "  ${GREEN}sudo docker exec jellyfin rffmpeg add $MAC_IP --weight $weight${NC}"
        return
    fi

    # Count existing nodes from rffmpeg status
    local rffmpeg_output
    rffmpeg_output=$(sudo docker exec jellyfin rffmpeg status 2>/dev/null || echo "")

    if [[ -n "$rffmpeg_output" ]]; then
        # Count lines that look like host entries (IP addresses)
        node_count=$(echo "$rffmpeg_output" | grep -cE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" 2>/dev/null | tr -d '[:space:]' || true)
        [[ -z "$node_count" || ! "$node_count" =~ ^[0-9]+$ ]] && node_count=0
    fi

    show_info "Found $node_count existing node(s)"
    echo ""

    # Explain weight system
    echo -e "${CYAN}Weight determines how many transcoding jobs this Mac gets:${NC}"
    echo -e "  • Equal weight = equal share of jobs"
    echo -e "  • Higher weight = more jobs (e.g., weight 4 gets 2x more than weight 2)"
    echo -e "  • Use higher weight for faster Macs"
    echo ""

    # Let user choose weight
    local weight_choice
    weight_choice=$(gum choose \
        "2 - Equal share (recommended for similar Macs)" \
        "3 - Slightly more jobs" \
        "4 - Double the jobs (for faster Macs)" \
        "Custom - Enter your own value")

    case "$weight_choice" in
        "2 -"*) weight=2 ;;
        "3 -"*) weight=3 ;;
        "4 -"*) weight=4 ;;
        "Custom"*)
            weight=$(gum input --placeholder "Enter weight (1-10)" --value "2")
            # Validate input
            if [[ ! "$weight" =~ ^[0-9]+$ ]] || [[ "$weight" -lt 1 ]] || [[ "$weight" -gt 10 ]]; then
                show_warning "Invalid weight, using default (2)"
                weight=2
            fi
            ;;
        *) weight=2 ;;
    esac

    echo ""
    show_info "Using weight $weight for this Mac"

    if ask_confirm "Add Mac to rffmpeg now?"; then
        if sudo docker exec jellyfin rffmpeg add "$MAC_IP" --weight "$weight" 2>/dev/null; then
            show_result true "Mac added to rffmpeg with weight $weight"
            echo ""
            sudo docker exec jellyfin rffmpeg status 2>/dev/null || true
        else
            show_warning "Could not add Mac - try manually"
            echo ""
            show_info "Run: sudo docker exec jellyfin rffmpeg add $MAC_IP --weight $weight"
        fi
    else
        show_info "Add Mac manually with:"
        echo -e "  ${GREEN}sudo docker exec jellyfin rffmpeg add $MAC_IP --weight $weight${NC}"
    fi
}

# ============================================================================
# MAIN WIZARD
# ============================================================================

add_node_wizard() {
    # Step 1: Collect Mac info
    step_collect_mac_info

    # Step 2: Verify connectivity
    if ! step_verify_connectivity; then
        return 1
    fi

    # Step 2b: Install SSH key
    if ! step_install_ssh_key; then
        return 1
    fi

    # Step 3: Setup Mac software
    step_setup_mac_software

    # Step 3b: Setup mount points (may trigger reboot)
    if ! step_setup_mount_points; then
        return 1
    fi

    # Step 3c: Configure NFS
    step_configure_nfs

    # Step 4: Register with rffmpeg
    step_register_rffmpeg

    echo ""
    show_result true "New Mac added successfully!"
}

# ============================================================================
# ENTRY POINT
# ============================================================================

main() {
    # Check if running on Synology
    if ! is_synology; then
        show_error "This script must be run from Synology NAS"
        show_info "To add this Mac as a node, run install.sh on Synology"
        exit 1
    fi

    # Check prerequisites
    if ! check_prerequisites; then
        exit 1
    fi

    # Run the wizard
    add_node_wizard
}

main "$@"
