#!/bin/bash
#
# Transcodarr Installer
# Distributed Live Transcoding for Jellyfin using Apple Silicon Macs
#
# Unified wizard-style installer with auto-detection
#

set +e  # Don't exit on error, we handle errors ourselves

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="3.0.0"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Source library modules
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/detection.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/mac-setup.sh"
source "$SCRIPT_DIR/lib/jellyfin-setup.sh"
source "$SCRIPT_DIR/lib/remote-ssh.sh"

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
            echo -e "${RED}  Homebrew is not installed on your Synology!${NC}"
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "Install Homebrew first with these commands:"
            echo ""
            echo -e "${GREEN}git clone https://github.com/MrCee/Synology-Homebrew.git ~/Synology-Homebrew${NC}"
            echo -e "${GREEN}~/Synology-Homebrew/install-synology-homebrew.sh${NC}"
            echo ""
            echo "Choose option 1 (Minimal installation)."
            echo "Then: brew install gum"
            echo ""
            echo "Close your terminal, reconnect via SSH, and run ./install.sh again."
            exit 1
        fi

        # Mac: install Homebrew
        echo "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        setup_brew_path || {
            echo "Homebrew installation failed"
            exit 1
        }
    fi

    # Install gum if needed
    if ! command -v gum &> /dev/null; then
        echo "Installing gum (for interactive UI)..."
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
    local media_path=""
    local cache_path=""
    local jellyfin_config=""
    local key_path=""

    # Check for interrupted installation (waiting for Mac reboot)
    local resume_state
    resume_state=$(get_resume_state)

    if [[ "$resume_state" == "waiting_for_reboot" ]]; then
        show_info "Resuming after Mac reboot..."
        mac_ip=$(get_config "mac_ip")
        mac_user=$(get_config "mac_user")
        nas_ip=$(get_config "nas_ip")
        media_path=$(get_config "media_path")
        cache_path=$(get_config "cache_path")
        jellyfin_config=$(get_config "jellyfin_config")
        key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

        # Wait for Mac to come back
        if wait_for_mac_up "$mac_user" "$mac_ip" "$key_path" 300; then
            clear_state_value "reboot_in_progress"
            show_result true "Mac is back online!"

            # Verify synthetic links after reboot
            if ! remote_check_synthetic_links "$mac_user" "$mac_ip" "$key_path"; then
                show_error "Synthetic links not found after reboot"
                show_info "Try rebooting your Mac again"
                return 1
            fi
            show_result true "/data and /config are now available"

            # Jump to post-reboot steps
            show_step 7 8 "Configure NFS Mounts"
            # Use combined function - single sudo session for all NFS setup
            remote_setup_nfs_complete "$mac_user" "$mac_ip" "$key_path" "$nas_ip" "$media_path" "$cache_path"

            show_step 8 8 "Verify and Complete"

            mark_step_complete "nfs_verified"

            # Show completion and DOCKER_MODS instructions
            show_remote_install_complete "$mac_ip" "$mac_user"
            show_docker_mods_instructions "$mac_ip"
            return 0
        else
            show_error "Mac did not come back online"
            show_info "Check your Mac and re-run the installer"
            return 1
        fi
    fi

    # Step 1: NFS Setup (prerequisite check)
    show_step 1 8 "Verify NFS Prerequisites"

    if is_nfs_enabled; then
        show_result true "NFS service is active"
        show_info "Make sure your media and cache folders have NFS permissions."
        echo ""
        if ! ask_confirm "Are NFS permissions already configured?"; then
            show_nfs_instructions
            wait_for_user "Have you configured the NFS permissions?"
        fi
    else
        show_warning "NFS is not enabled on this Synology!"
        echo ""
        show_nfs_instructions
        wait_for_user "Have you enabled NFS and configured the permissions?"
    fi
    mark_step_complete "nfs_setup"

    # Step 2: Collect configuration
    show_step 2 8 "Collect Configuration"

    echo ""
    show_what_this_does "We need information about your Mac and your NAS to set up remote transcoding."
    echo ""

    # Get Mac IP
    mac_ip=$(ask_input "Mac IP address" "192.168.1.50")
    if [[ -z "$mac_ip" ]]; then
        show_error "Mac IP is required"
        return 1
    fi

    # Get Mac username
    mac_user=$(ask_input "Mac username" "$(whoami)")
    if [[ -z "$mac_user" ]]; then
        show_error "Mac username is required"
        return 1
    fi

    # Get NAS IP
    local detected_nas_ip
    detected_nas_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$detected_nas_ip" ]] && detected_nas_ip="192.168.1.100"
    nas_ip=$(ask_input "NAS IP address" "$detected_nas_ip")

    # Get media path (for NFS mount)
    media_path=$(ask_input "Media folder on NAS (NFS export)" "/volume1/data/media")

    # Get Jellyfin config path
    local detected_config
    detected_config=$(detect_jellyfin_config)
    jellyfin_config=$(ask_input "Jellyfin config folder" "$detected_config")

    # Get cache path
    cache_path=$(ask_input "Transcode cache folder (NFS export)" "${jellyfin_config}/cache")

    echo ""
    show_info "Configuration summary:"
    echo "  Mac:           $mac_user@$mac_ip"
    echo "  NAS:           $nas_ip"
    echo "  Media path:    $media_path"
    echo "  Jellyfin:      $jellyfin_config"
    echo "  Cache:         $cache_path"
    echo ""

    if ! ask_confirm "Is this correct?"; then
        show_info "Restart to enter different values."
        return 1
    fi

    # Save config to state for resume capability
    set_config "mac_ip" "$mac_ip"
    set_config "mac_user" "$mac_user"
    set_config "nas_ip" "$nas_ip"
    set_config "media_path" "$media_path"
    set_config "cache_path" "$cache_path"
    set_config "jellyfin_config" "$jellyfin_config"
    mark_step_complete "config_collected"

    # Step 3: Verify Mac is reachable (with retry)
    show_step 3 8 "Connect to Mac"

    local mac_reachable=false
    while [[ "$mac_reachable" == "false" ]]; do
        show_info "Checking if Mac is reachable at $mac_ip..."
        if test_mac_reachable "$mac_ip"; then
            show_result true "Mac reachable at $mac_ip"
            mac_reachable=true
        else
            show_error "Mac at $mac_ip is not reachable"
            echo ""
            if ask_confirm "Try a different IP address?"; then
                mac_ip=$(ask_input "Mac IP address" "$mac_ip")
                set_config "mac_ip" "$mac_ip"
            else
                show_info "Check that your Mac is turned on and connected to the network"
                return 1
            fi
        fi
    done

    # Check SSH port (with retry)
    local ssh_open=false
    while [[ "$ssh_open" == "false" ]]; do
        show_info "Checking if SSH is enabled on Mac..."
        if test_ssh_port "$mac_ip"; then
            show_result true "SSH port is open"
            ssh_open=true
        else
            show_warning "SSH port not open on Mac at $mac_ip"
            show_remote_login_instructions
            echo ""
            if ask_confirm "Try again after enabling Remote Login?"; then
                continue
            elif ask_confirm "Try a different IP address?"; then
                mac_ip=$(ask_input "Mac IP address" "$mac_ip")
                set_config "mac_ip" "$mac_ip"
                # Re-check reachability
                if ! test_mac_reachable "$mac_ip"; then
                    show_error "Mac at $mac_ip is not reachable"
                    continue
                fi
            else
                return 1
            fi
        fi
    done

    # Step 4: Generate and install SSH key
    show_step 4 8 "Setup SSH Key"

    # Generate SSH key if needed
    key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"
    if [[ ! -f "$key_path" ]]; then
        show_info "Generating SSH key..."
        generate_ssh_key
    else
        show_skip "SSH key already exists"
    fi

    # Test if key auth already works
    if test_ssh_key_auth "$mac_user" "$mac_ip" "$key_path"; then
        show_skip "SSH key authentication already working"
    else
        # Install SSH key (requires password)
        if ! install_ssh_key_interactive "$mac_user" "$mac_ip" "${key_path}.pub"; then
            show_error "Failed to install SSH key"
            show_info "Make sure you entered the correct Mac password"
            return 1
        fi

        # Verify key works now
        sleep 1
        if ! test_ssh_key_auth "$mac_user" "$mac_ip" "$key_path"; then
            show_error "SSH key authentication still not working"
            return 1
        fi
    fi
    show_result true "SSH key authentication working"
    mark_step_complete "ssh_key_installed"

    # Step 5: Remote Mac Setup (pre-reboot)
    show_step 5 8 "Setup Mac Software (Remote)"

    show_info "Installing software on Mac via SSH..."
    echo ""

    remote_install_homebrew "$mac_user" "$mac_ip" "$key_path"
    echo ""

    remote_install_ffmpeg "$mac_user" "$mac_ip" "$key_path"
    echo ""

    # Step 6: Synthetic links (may require reboot)
    show_step 6 8 "Create Mount Points"

    local synth_result
    remote_setup_synthetic_links "$mac_user" "$mac_ip" "$key_path"
    synth_result=$?

    if [[ $synth_result -eq 2 ]]; then
        # Needs reboot
        mark_step_complete "synthetic_links"

        if handle_mac_reboot "$mac_user" "$mac_ip" "$key_path"; then
            # Mac is back, verify synthetic links
            if ! remote_check_synthetic_links "$mac_user" "$mac_ip" "$key_path"; then
                show_error "Synthetic links not found after reboot"
                return 1
            fi
            show_result true "/data and /config are now available"
        else
            # User chose to handle manually or Mac didn't come back
            show_info "Re-run this installer when Mac is back online"
            return 0
        fi
    fi

    # Step 7: Remote Mac Setup (post-reboot)
    show_step 7 8 "Configure NFS Mounts"

    # Use combined function - single sudo session for all NFS setup
    remote_setup_nfs_complete "$mac_user" "$mac_ip" "$key_path" "$nas_ip" "$media_path" "$cache_path"

    # Step 8: Verify and finalize
    show_step 8 8 "Verify and Complete"

    mark_step_complete "nfs_verified"

    # Copy rffmpeg config to Jellyfin
    show_info "Setting up rffmpeg configuration..."
    create_rffmpeg_config "$mac_ip" "$mac_user"
    copy_rffmpeg_files "$jellyfin_config"

    # Show completion
    echo ""
    show_remote_install_complete "$mac_ip" "$mac_user"
    show_docker_mods_instructions "$mac_ip"

    # Step 8: Add Mac to rffmpeg
    show_step 8 8 "Register Mac with rffmpeg"

    echo ""
    show_warning "╔═══════════════════════════════════════════════════════════╗"
    show_warning "║  ACTION REQUIRED: Configure Jellyfin                      ║"
    show_warning "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    show_info "Add these environment variables to your Jellyfin container:"
    echo ""
    echo "  DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg"
    echo "  FFMPEG_PATH=/usr/local/bin/ffmpeg"
    echo ""
    show_info "Then restart the Jellyfin container."
    echo ""

    if ask_confirm "Have you restarted Jellyfin with DOCKER_MODS enabled?"; then
        echo ""
        show_info "Waiting 10 seconds for rffmpeg to initialize..."
        sleep 10

        echo ""
        # Explain weight system
        echo -e "${CYAN}Weight determines how many transcoding jobs this Mac gets:${NC}"
        echo -e "  • Equal weight = equal share of jobs"
        echo -e "  • Higher weight = more jobs (e.g., weight 4 gets 2x more than weight 2)"
        echo -e "  • Use higher weight for faster Macs"
        echo ""

        # Let user choose weight
        local weight_choice
        local weight=2
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
                if [[ ! "$weight" =~ ^[0-9]+$ ]] || [[ "$weight" -lt 1 ]] || [[ "$weight" -gt 10 ]]; then
                    show_warning "Invalid weight, using default (2)"
                    weight=2
                fi
                ;;
            *) weight=2 ;;
        esac

        echo ""
        show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
        echo ""
        show_info "Adding Mac to rffmpeg with weight $weight..."

        if sudo docker exec jellyfin rffmpeg add "$mac_ip" --weight "$weight" 2>/dev/null; then
            echo ""
            show_result true "Mac added to rffmpeg with weight $weight!"
            echo ""
            show_info "Current rffmpeg status:"
            sudo docker exec jellyfin rffmpeg status 2>/dev/null || true
        else
            echo ""
            show_error "Could not add Mac to rffmpeg"
            show_info "This can happen if:"
            echo "  - DOCKER_MODS is not configured"
            echo "  - Container was not restarted"
            echo "  - rffmpeg is still initializing"
            echo ""
            show_info "Try manually after container restart:"
            echo -e "  ${GREEN}sudo docker exec jellyfin rffmpeg add $mac_ip --weight $weight${NC}"
        fi
    else
        echo ""
        show_info "After restarting Jellyfin, run:"
        echo ""
        echo -e "  ${GREEN}sudo docker exec jellyfin rffmpeg add $mac_ip --weight 2${NC}"
        echo -e "  ${GREEN}sudo docker exec jellyfin rffmpeg status${NC}"
    fi

    echo ""
    show_result true "Installation complete!"
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
        show_info "Continuing after reboot..."
        clear_pending_reboot

        # Check if synthetic links now exist
        if check_synthetic_links; then
            show_result true "/data and /config directories found"
            # Continue with post-reboot setup
            run_mac_setup_after_reboot
            return $?
        else
            show_error "Synthetic links not found. Restart your Mac and try again."
            return 1
        fi
    fi

    # Step 1: Prerequisites
    show_step 1 4 "Install Prerequisites"

    install_homebrew
    install_ffmpeg
    enable_ssh

    # Step 2: Get NAS info
    show_step 2 4 "NAS Configuration"

    echo ""
    show_what_this_does "We need to know where your NAS is and where your media and cache are located."
    echo ""

    # Try to load from state first
    nas_ip=$(get_config "nas_ip")
    media_path=$(get_config "media_path")
    cache_path=$(get_config "cache_path")

    # If not in state, ask
    if [[ -z "$nas_ip" ]]; then
        nas_ip=$(ask_input "NAS/Synology IP address" "192.168.1.100")
    else
        show_info "NAS IP from saved configuration: $nas_ip"
        if ! ask_confirm "Is this correct?"; then
            nas_ip=$(ask_input "NAS/Synology IP address" "$nas_ip")
        fi
    fi

    # Validate NAS IP
    show_info "Checking if NAS is reachable..."
    if ! ping -c1 -W2 "$nas_ip" &>/dev/null; then
        show_warning "NAS at $nas_ip is not reachable."
        if ! ask_confirm "Continue anyway?"; then
            return 1
        fi
    else
        show_result true "NAS reachable at $nas_ip"
    fi

    if [[ -z "$media_path" ]]; then
        media_path=$(ask_input "Media folder on NAS (NFS export)" "/volume1/data/media")
    fi

    if [[ -z "$cache_path" ]]; then
        cache_path=$(ask_input "Cache folder on NAS (NFS export)" "/volume1/docker/jellyfin/cache")
    fi

    mark_step_complete "nas_config"

    # Step 3: Synthetic links (may require reboot)
    show_step 3 4 "Create Mount Points"

    local synth_result
    setup_synthetic_links
    synth_result=$?

    if [[ $synth_result -eq 2 ]]; then
        # Needs reboot
        show_reboot_instructions "$(pwd)"
        if ask_confirm "Reboot now?"; then
            show_info "Rebooting in 3 seconds..."
            sleep 3
            sudo reboot
        else
            show_warning "Don't forget to reboot!"
            show_info "After reboot: cd $(pwd) && ./install.sh"
        fi
        return 0  # Exit cleanly, will continue after reboot
    fi

    # Step 4: NFS mounts and LaunchDaemons
    show_step 4 4 "Configure NFS Mounts"

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
# NODE MANAGEMENT FUNCTIONS
# ============================================================================

# Get list of registered nodes from rffmpeg
get_registered_nodes() {
    local status
    status=$(sudo docker exec jellyfin rffmpeg status 2>/dev/null || echo "")
    if [[ -z "$status" ]]; then
        return 1
    fi
    # Extract IP addresses from rffmpeg status output
    echo "$status" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort -u
}

# Shared weight selection menu (used by install, add-node, and change-weight)
select_weight() {
    echo ""
    echo -e "${CYAN}Weight determines how many transcoding jobs this Mac gets:${NC}"
    echo -e "  • Equal weight = equal share of jobs"
    echo -e "  • Higher weight = more jobs (e.g., weight 4 gets 2x more than weight 2)"
    echo -e "  • Use higher weight for faster Macs"
    echo ""

    local weight_choice
    local weight=2
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
            if [[ ! "$weight" =~ ^[0-9]+$ ]] || [[ "$weight" -lt 1 ]] || [[ "$weight" -gt 10 ]]; then
                show_warning "Invalid weight, using default (2)"
                weight=2
            fi
            ;;
        *) weight=2 ;;
    esac

    echo "$weight"
}

# Menu: Change node weight
menu_change_weight() {
    echo ""
    show_info "Change Node Weight"
    echo ""

    # Check if Jellyfin container is running
    if ! sudo docker ps 2>/dev/null | grep -q jellyfin; then
        show_error "Jellyfin container not running"
        show_info "Start the container first, then try again"
        wait_for_user "Press Enter to return to menu"
        return 1
    fi

    # Get registered nodes
    local nodes
    nodes=$(get_registered_nodes)

    if [[ -z "$nodes" ]]; then
        show_warning "No nodes registered with rffmpeg"
        show_info "Use 'Add a new Mac node' to register a Mac first"
        wait_for_user "Press Enter to return to menu"
        return 0
    fi

    # Let user select a node
    echo "Select node to update:"
    local selected_node
    selected_node=$(echo "$nodes" | gum choose)

    if [[ -z "$selected_node" ]]; then
        return 0
    fi

    echo ""
    show_info "Selected: $selected_node"

    # Select new weight
    local new_weight
    new_weight=$(select_weight)

    echo ""
    show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
    echo ""

    # Remove and re-add with new weight
    if sudo docker exec jellyfin rffmpeg remove "$selected_node" 2>/dev/null; then
        if sudo docker exec jellyfin rffmpeg add "$selected_node" --weight "$new_weight" 2>/dev/null; then
            show_result true "Weight updated to $new_weight for $selected_node"
            echo ""
            sudo docker exec jellyfin rffmpeg status 2>/dev/null || true
        else
            show_error "Failed to re-add node"
            show_info "Try manually: sudo docker exec jellyfin rffmpeg add $selected_node --weight $new_weight"
        fi
    else
        show_error "Failed to remove node for update"
    fi

    echo ""
    wait_for_user "Press Enter to return to menu"
}

# Menu: Remove node
menu_remove_node() {
    echo ""
    show_info "Remove Node"
    echo ""

    # Check if Jellyfin container is running
    if ! sudo docker ps 2>/dev/null | grep -q jellyfin; then
        show_error "Jellyfin container not running"
        show_info "Start the container first, then try again"
        wait_for_user "Press Enter to return to menu"
        return 1
    fi

    # Get registered nodes
    local nodes
    nodes=$(get_registered_nodes)

    if [[ -z "$nodes" ]]; then
        show_warning "No nodes registered with rffmpeg"
        wait_for_user "Press Enter to return to menu"
        return 0
    fi

    # Let user select a node
    echo "Select node to remove:"
    local selected_node
    selected_node=$(echo "$nodes" | gum choose)

    if [[ -z "$selected_node" ]]; then
        return 0
    fi

    echo ""
    if ! ask_confirm "Remove $selected_node from rffmpeg?"; then
        return 0
    fi

    echo ""
    show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
    echo ""

    # Remove from rffmpeg
    if sudo docker exec jellyfin rffmpeg remove "$selected_node" 2>/dev/null; then
        show_result true "Node $selected_node removed from rffmpeg"
    else
        show_error "Failed to remove node from rffmpeg"
        wait_for_user "Press Enter to return to menu"
        return 1
    fi

    echo ""

    # Offer Mac cleanup
    if ask_confirm "Also uninstall Transcodarr from this Mac?"; then
        menu_remote_uninstall "$selected_node"
    fi

    echo ""
    wait_for_user "Press Enter to return to menu"
}

# Menu: Remote uninstall components from Mac
menu_remote_uninstall() {
    local mac_ip="$1"

    echo ""
    show_info "Select components to remove from Mac $mac_ip"
    echo ""
    show_info "Use Space to select, Enter to confirm"
    echo ""

    # Multi-select components
    local selected
    selected=$(gum choose --no-limit \
        "LaunchDaemons (NFS auto-mounts)" \
        "Mount scripts (/usr/local/bin/mount-*.sh)" \
        "Synthetic links (/data, /config) - requires reboot" \
        "FFmpeg" \
        "Energy settings (re-enable sleep)" \
        "SSH key (revoke Transcodarr access)")

    if [[ -z "$selected" ]]; then
        show_info "No components selected"
        return 0
    fi

    # Convert selections to component names
    local components=""
    echo "$selected" | while read -r line; do
        case "$line" in
            "LaunchDaemons"*) components+="launchdaemons " ;;
            "Mount scripts"*) components+="mount_scripts " ;;
            "Synthetic links"*) components+="synthetic " ;;
            "FFmpeg"*) components+="ffmpeg " ;;
            "Energy settings"*) components+="energy " ;;
            "SSH key"*) components+="ssh_key " ;;
        esac
    done

    # Build components string properly
    components=""
    while IFS= read -r line; do
        case "$line" in
            "LaunchDaemons"*) components+="launchdaemons " ;;
            "Mount scripts"*) components+="mount_scripts " ;;
            "Synthetic links"*) components+="synthetic " ;;
            "FFmpeg"*) components+="ffmpeg " ;;
            "Energy settings"*) components+="energy " ;;
            "SSH key"*) components+="ssh_key " ;;
        esac
    done <<< "$selected"

    if [[ -z "$components" ]]; then
        show_info "No components selected"
        return 0
    fi

    # Get SSH key path and username
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"
    local mac_user
    mac_user=$(get_config "mac_user")

    if [[ -z "$mac_user" ]]; then
        show_warning "Mac username not found in configuration"
        mac_user=$(ask_input "Mac username" "$(whoami)")
    fi

    if [[ ! -f "$key_path" ]]; then
        show_error "SSH key not found"
        show_info "Cannot connect to Mac without SSH key"
        return 1
    fi

    # Check Mac is reachable
    if ! test_mac_reachable "$mac_ip"; then
        show_error "Mac at $mac_ip is not reachable"
        return 1
    fi

    # Run uninstall
    local result
    remote_uninstall_components "$mac_user" "$mac_ip" "$key_path" $components
    result=$?

    if [[ $result -eq 2 ]]; then
        echo ""
        if ask_confirm "Reboot Mac now to complete removal?"; then
            show_info "Sending reboot command..."
            ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" "reboot" 2>/dev/null || true
            show_info "Mac is rebooting"
        fi
    fi

    return 0
}

# Menu: Show documentation
menu_documentation() {
    local url="https://github.com/JacquesToT/Transcodarr"

    echo ""
    gum style --border double --padding "1 2" --border-foreground 39 \
        "📖 Transcodarr Documentation" \
        "" \
        "$url" \
        "" \
        "Topics:" \
        "• Prerequisites & Setup" \
        "• NFS Configuration" \
        "• Troubleshooting" \
        "• rffmpeg Commands"
    echo ""

    wait_for_user "Press Enter to return to menu"
}

# ============================================================================
# MAIN MENU
# ============================================================================

show_main_menu() {
    local install_status="$1"
    local menu_options=()

    # Build menu based on install status
    if [[ "$install_status" == "first_time" ]]; then
        menu_options+=("🚀 Install Transcodarr")
    else
        menu_options+=("🚀 Install Transcodarr (reinstall)")
    fi

    menu_options+=("➕ Add a new Mac node")

    # Node management options (only if configured)
    if [[ "$install_status" != "first_time" ]]; then
        menu_options+=("⚖️  Change Node Weight")
        menu_options+=("➖ Remove Node")
    fi

    # Documentation always available
    menu_options+=("📖 Documentation")

    # Only show Monitor if configured
    if [[ "$install_status" == "configured" ]] && [[ -f "$SCRIPT_DIR/monitor.sh" ]]; then
        menu_options+=("📊 Monitor")
    fi

    menu_options+=("❌ Exit")

    # Show menu with gum
    local choice
    choice=$(gum choose --header "What would you like to do?" "${menu_options[@]}")

    echo "$choice"
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    # Check if running on Mac - redirect to Synology
    if is_mac; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  This installer now runs from your Synology NAS!             ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  The installer will set up your Mac automatically via SSH."
        echo ""
        echo "  To install Transcodarr:"
        echo ""
        echo "    1. SSH into your Synology:"
        echo -e "       ${GREEN}ssh your-username@your-synology-ip${NC}"
        echo ""
        echo "    2. Run the installer:"
        echo -e "       ${GREEN}git clone https://github.com/JacquesToT/Transcodarr.git ~/Transcodarr${NC}"
        echo -e "       ${GREEN}cd ~/Transcodarr && ./install.sh${NC}"
        echo ""
        echo "  The installer will connect to your Mac and set everything up."
        echo ""
        exit 0
    fi

    # Must be Synology from here
    if ! is_synology; then
        show_error "This installer only works on Synology NAS."
        show_info "Run this on your Synology, not your computer."
        exit 1
    fi

    # Ensure gum is available
    check_and_install_gum

    # Show banner
    show_banner "$VERSION"

    echo ""
    show_info "Detected system: Synology NAS"

    # Check for resume state first
    local resume_state
    resume_state=$(get_resume_state)

    if [[ "$resume_state" == "waiting_for_reboot" ]]; then
        show_info "Resuming installation (waiting for Mac reboot)..."
        echo ""
        wizard_synology
        # After install, show menu
        main_menu_loop
        return
    fi

    # Start menu loop
    main_menu_loop
}

main_menu_loop() {
    while true; do
        # Detect install status
        local install_status
        install_status=$(get_install_status)

        echo ""

        # Show menu and get choice
        local choice
        choice=$(show_main_menu "$install_status")

        case "$choice" in
            "🚀 Install Transcodarr"*)
                echo ""
                wizard_synology
                ;;
            "➕ Add a new Mac node")
                echo ""
                "$SCRIPT_DIR/add-node.sh"
                ;;
            "⚖️  Change Node Weight")
                menu_change_weight
                ;;
            "➖ Remove Node")
                menu_remove_node
                ;;
            "📖 Documentation")
                menu_documentation
                ;;
            "📊 Monitor")
                echo ""
                show_info "Starting Transcodarr Monitor..."
                exec "$SCRIPT_DIR/monitor.sh"
                ;;
            "❌ Exit"|"")
                echo ""
                show_info "Goodbye!"
                exit 0
                ;;
        esac
    done
}

# Run main
main "$@"
