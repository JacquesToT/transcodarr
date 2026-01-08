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
# NAS IP CONFIRMATION
# ============================================================================

# Confirm NAS IP from config, with option to change
# Always shows current IP and asks for confirmation to prevent stale config issues
# Usage: nas_ip=$(confirm_nas_ip) || return 1
confirm_nas_ip() {
    local saved_ip
    saved_ip=$(get_config "nas_ip")

    if [[ -z "$saved_ip" ]]; then
        # No saved IP - ask for new one
        local detected_ip
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "$detected_ip" ]] && detected_ip="192.168."

        local new_ip
        new_ip=$(ask_input "NAS/Synology IP address" "$detected_ip")
        if [[ -z "$new_ip" ]]; then
            show_error "NAS IP is required"
            return 1
        fi
        set_config "nas_ip" "$new_ip"
        echo "$new_ip"
        return 0
    fi

    # Show saved IP and test connectivity
    echo ""
    show_info "Saved NAS configuration: $saved_ip"

    # Quick ping test
    if ping -c1 -W2 "$saved_ip" &>/dev/null; then
        show_result true "NAS reachable at $saved_ip"
    else
        show_warning "NAS at $saved_ip is NOT reachable!"
    fi

    # Always ask for confirmation
    echo ""
    if ask_confirm "Use this NAS IP ($saved_ip)?"; then
        echo "$saved_ip"
        return 0
    fi

    # User wants to change - ask for new IP
    local new_ip
    new_ip=$(ask_input "NAS/Synology IP address" "$saved_ip")
    if [[ -z "$new_ip" ]]; then
        show_error "NAS IP is required"
        return 1
    fi

    # Update config with new IP
    set_config "nas_ip" "$new_ip"
    show_result true "NAS IP updated to $new_ip"
    echo "$new_ip"
    return 0
}

# ============================================================================
# ADD NODE PREREQUISITES
# ============================================================================

# Check prerequisites for adding a node
# Returns 0 if OK, 1 if first-time setup needed
check_add_node_prerequisites() {
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

    # Check SSH key exists from previous installation
    if [[ ! -f "$key_path" ]]; then
        show_error "No SSH key found from previous installation"
        echo ""
        show_info "Run 'Install Transcodarr' first to set up your first Mac."
        echo ""
        return 1
    fi

    # Check for essential config
    local nas_ip
    nas_ip=$(get_config "nas_ip")
    if [[ -z "$nas_ip" ]]; then
        show_error "NAS configuration not found"
        echo ""
        show_info "Run 'Install Transcodarr' first to set up your first Mac."
        echo ""
        return 1
    fi

    return 0
}

# ============================================================================
# SYNOLOGY WIZARD
# ============================================================================

wizard_synology() {
    local mac_ip=""
    local mac_user=""
    local nas_ip=""
    local nas_user=""
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
        nas_user=$(get_config "nas_user")
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
    else
        show_warning "NFS is not enabled on this Synology!"
        echo ""
        show_nfs_instructions
        wait_for_user "Have you enabled NFS service?"
    fi
    mark_step_complete "nfs_setup"

    # Step 2: Collect configuration
    show_step 2 8 "Collect Configuration"

    echo ""
    show_what_this_does "We need information about your Mac and your NAS to set up remote transcoding."
    echo ""

    # Get Mac IP
    mac_ip=$(ask_input "Mac IP address" "192.168.")
    if [[ -z "$mac_ip" ]]; then
        show_error "Mac IP is required"
        return 1
    fi

    # Get Mac username
    mac_user=$(ask_input "Mac username" "")
    if [[ -z "$mac_user" ]]; then
        show_error "Mac username is required"
        return 1
    fi

    # Get NAS IP
    local detected_nas_ip
    detected_nas_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$detected_nas_ip" ]] && detected_nas_ip="192.168."
    nas_ip=$(ask_input "NAS IP address" "$detected_nas_ip")

    # Get NAS username (for monitor SSH access)
    nas_user=$(ask_input "NAS SSH username (for monitoring)" "$(whoami)")
    [[ -z "$nas_user" ]] && nas_user="$(whoami)"

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
    echo "  NAS:           $nas_user@$nas_ip"
    echo "  Media path:    $media_path"
    echo "  Jellyfin:      $jellyfin_config"
    echo "  Cache:         $cache_path"
    echo ""

    if ! ask_confirm "Is this correct?"; then
        show_info "Restart to enter different values."
        return 1
    fi

    # Check NFS exports for the specified paths
    echo ""
    show_info "Checking NFS exports..."
    show_warning ">>> Enter your SYNOLOGY password if prompted <<<"
    echo ""
    local nfs_ok=true
    if ! check_nfs_export "$media_path"; then
        nfs_ok=false
        show_warning "NFS not configured for media path: $media_path"
    fi
    if ! check_nfs_export "$cache_path"; then
        nfs_ok=false
        show_warning "NFS not configured for cache path: $cache_path"
    fi

    if [[ "$nfs_ok" == false ]]; then
        echo ""
        show_nfs_instructions
        wait_for_user "Have you configured NFS permissions for these folders?"

        # Re-check after user confirms
        echo ""
        show_info "Re-checking NFS exports..."
        local recheck_ok=true
        if ! check_nfs_export "$media_path"; then
            recheck_ok=false
            show_warning "Still no NFS export for: $media_path"
        else
            show_result true "NFS export found for media path"
        fi
        if ! check_nfs_export "$cache_path"; then
            recheck_ok=false
            show_warning "Still no NFS export for: $cache_path"
        else
            show_result true "NFS export found for cache path"
        fi

        if [[ "$recheck_ok" == false ]]; then
            echo ""
            show_warning "NFS exports still not detected. The installer will continue, but NFS mounts may fail."
            echo ""
            if ! ask_confirm "Continue anyway?"; then
                return 1
            fi
        fi
    else
        show_result true "NFS exports found for media and cache paths"
    fi

    # Save config to state for resume capability
    set_config "mac_ip" "$mac_ip"
    set_config "mac_user" "$mac_user"
    set_config "nas_ip" "$nas_ip"
    set_config "nas_user" "$nas_user"
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

    # Step 8: Add Mac to rffmpeg
    show_step 8 8 "Register Mac with rffmpeg"

    echo ""
    show_info "If you followed Step 2 of the README, DOCKER_MODS is already configured."
    show_info "Make sure your Jellyfin container has been restarted with the new settings."
    echo ""
    show_info "Note: Jellyfin can take a while to start up. Wait until it's accessible before continuing."
    echo ""

    if ask_confirm "Is Jellyfin running and accessible?"; then
        echo ""
        show_info "Waiting 10 seconds for rffmpeg to initialize..."
        sleep 10

        # Finalize rffmpeg setup (persist dir + default key location)
        finalize_rffmpeg_setup "$jellyfin_config"

        # Fix transcodes directory permissions for NFS write access from Mac
        # Mac user has different UID, so we need world-writable permissions
        if [[ -d "${cache_path}/transcodes" ]]; then
            sudo chmod 777 "${cache_path}/transcodes"
            show_result true "Transcodes directory permissions fixed"
        else
            sudo mkdir -p "${cache_path}/transcodes"
            sudo chmod 777 "${cache_path}/transcodes"
            show_result true "Transcodes directory created with correct permissions"
        fi

        # Use default weight 2 (weight only matters with multiple Macs)
        local weight=2

        echo ""
        show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
        echo ""

        # Check if Mac is already registered
        if sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null | grep -q "$mac_ip"; then
            show_skip "Mac is already registered in rffmpeg"
            echo ""
            show_info "Current rffmpeg status:"
            sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null || true
        else
            show_info "Adding Mac to rffmpeg..."
            local add_output
            if add_output=$(sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg add "$mac_ip" --weight "$weight" 2>&1); then
                echo "$add_output" | grep -v "DeprecationWarning" || true
                echo ""
                show_result true "Mac added to rffmpeg!"
                echo ""
                show_info "Current rffmpeg status:"
                sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null || true
            else
                echo "$add_output" | grep -v "DeprecationWarning" || true
                echo ""
                show_error "Could not add Mac to rffmpeg"
                show_info "This can happen if:"
                echo "  - DOCKER_MODS is not configured"
                echo "  - Container was not restarted"
                echo "  - rffmpeg is still initializing"
                echo ""
                show_info "Try manually after container restart:"
                echo -e "  ${GREEN}sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg add $mac_ip --weight $weight${NC}"
            fi
        fi
    else
        echo ""
        show_info "After restarting Jellyfin, run:"
        echo ""
        echo -e "  ${GREEN}sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg add $mac_ip --weight 2${NC}"
        echo -e "  ${GREEN}sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status${NC}"
    fi

    echo ""
    show_result true "Installation complete!"
}

# ============================================================================
# ADD NODE WIZARD
# ============================================================================

wizard_add_node() {
    local mac_ip=""
    local mac_user=""
    local nas_ip=""
    local media_path=""
    local cache_path=""
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

    # Check prerequisites first
    if ! check_add_node_prerequisites; then
        wait_for_user "Press Enter to return to menu"
        return 1
    fi

    # Load existing configuration from state
    mac_user=$(get_config "mac_user")
    media_path=$(get_config "media_path")
    cache_path=$(get_config "cache_path")

    # Confirm NAS IP (always ask, prevents stale config issues)
    nas_ip=$(confirm_nas_ip) || return 1

    # Step 1: Collect new Mac info
    show_step 1 4 "Add New Mac"

    echo ""
    show_what_this_does "Add another Mac to your transcoding cluster."
    echo ""

    mac_ip=$(ask_input "New Mac IP address" "192.168.")
    if [[ -z "$mac_ip" ]]; then
        show_error "Mac IP is required"
        return 1
    fi

    # Enforce same username
    if [[ -n "$mac_user" ]]; then
        echo ""
        show_warning "All Macs must use the same SSH username!"
        show_info "First Mac was configured with user: $mac_user"
        echo ""

        local entered_user
        entered_user=$(ask_input "Mac username (must be: $mac_user)" "$mac_user")

        if [[ "$entered_user" != "$mac_user" ]]; then
            echo ""
            show_error "Username must be '$mac_user' to match rffmpeg configuration"
            show_info "Either:"
            echo "  1. Use username '$mac_user' on this Mac"
            echo "  2. Create user '$mac_user' on this Mac"
            echo ""
            wait_for_user "Press Enter to return to menu"
            return 1
        fi
    else
        mac_user=$(ask_input "Mac username" "$(whoami)")
        set_config "mac_user" "$mac_user"
    fi

    # Step 2: Verify connectivity
    show_step 2 4 "Connect to Mac"

    # Test reachability (with retry loop)
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
            else
                return 1
            fi
        fi
    done

    # Install SSH key (reuse existing key)
    if test_ssh_key_auth "$mac_user" "$mac_ip" "$key_path"; then
        show_skip "SSH key authentication already working"
    else
        if ! install_ssh_key_interactive "$mac_user" "$mac_ip" "${key_path}.pub"; then
            show_error "Failed to install SSH key"
            show_info "Make sure you entered the correct Mac password"
            return 1
        fi

        sleep 1
        if ! test_ssh_key_auth "$mac_user" "$mac_ip" "$key_path"; then
            show_error "SSH key authentication still not working"
            return 1
        fi
    fi
    show_result true "SSH key authentication working"

    # Step 3: Setup Mac (Software + Mounts + NFS)
    show_step 3 4 "Setup Mac (Remote)"

    show_info "Installing software on Mac via SSH..."
    echo ""

    remote_install_homebrew "$mac_user" "$mac_ip" "$key_path"
    echo ""

    remote_install_ffmpeg "$mac_user" "$mac_ip" "$key_path"
    echo ""

    # Setup synthetic links (may require reboot)
    local synth_result
    remote_setup_synthetic_links "$mac_user" "$mac_ip" "$key_path"
    synth_result=$?

    if [[ $synth_result -eq 2 ]]; then
        # Needs reboot
        if handle_mac_reboot "$mac_user" "$mac_ip" "$key_path"; then
            if ! remote_check_synthetic_links "$mac_user" "$mac_ip" "$key_path"; then
                show_error "Synthetic links not found after reboot"
                return 1
            fi
            show_result true "/data and /config are now available"
        else
            show_info "Re-run 'Add a new Mac node' when Mac is back online"
            return 0
        fi
    fi

    # Configure NFS mounts
    remote_setup_nfs_complete "$mac_user" "$mac_ip" "$key_path" "$nas_ip" "$media_path" "$cache_path"

    # Step 4: Register with rffmpeg
    show_step 4 4 "Register Mac"

    # Setup SSH from container to Mac (for rffmpeg)
    show_info "Setting up rffmpeg SSH access..."
    ensure_container_ssh_key

    if test_container_ssh_to_mac "$mac_user" "$mac_ip"; then
        show_skip "SSH from Jellyfin to Mac already working"
    else
        copy_ssh_key_to_mac "$mac_user" "$mac_ip"
        sleep 1
        if test_container_ssh_to_mac "$mac_user" "$mac_ip"; then
            show_result true "rffmpeg can now SSH to Mac"
        else
            show_warning "SSH from container may still need password"
            show_info "Run 'Fix SSH Keys' from the menu if transcoding fails"
        fi
    fi

    echo ""
    show_info "Adding Mac to rffmpeg configuration..."
    echo ""
    show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
    echo ""

    # Check if Jellyfin container is running
    if ! sudo docker ps 2>/dev/null | grep -q "$JELLYFIN_CONTAINER"; then
        show_warning "Jellyfin container not running"
        show_info "Start Jellyfin first, then add Mac manually:"
        echo -e "  ${GREEN}sudo docker exec $JELLYFIN_CONTAINER rffmpeg add $mac_ip --weight 2${NC}"
        echo ""
        wait_for_user "Press Enter to return to menu"
        return 0
    fi

    # Check if rffmpeg is available
    if ! sudo docker exec "$JELLYFIN_CONTAINER" which rffmpeg &>/dev/null; then
        show_warning "rffmpeg not found in Jellyfin container"
        show_docker_mods_instructions "$mac_ip"
        echo ""
        wait_for_user "Press Enter to return to menu"
        return 0
    fi

    # Check if already registered
    if sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null | grep -q "$mac_ip"; then
        show_skip "Mac is already registered in rffmpeg"
        echo ""
        show_info "Current rffmpeg status:"
        sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null || true
    else
        # Select weight using shared function
        local weight
        weight=$(select_weight)

        echo ""
        local add_output
        if add_output=$(sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg add "$mac_ip" --weight "$weight" 2>&1); then
            echo "$add_output" | grep -v "DeprecationWarning" || true
            show_result true "Mac added to rffmpeg with weight $weight!"
            echo ""
            sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null || true
        else
            echo "$add_output" | grep -v "DeprecationWarning" || true
            show_warning "Could not add Mac - try manually"
            echo -e "  ${GREEN}sudo docker exec $JELLYFIN_CONTAINER rffmpeg add $mac_ip --weight $weight${NC}"
        fi
    fi

    echo ""
    show_result true "New Mac added successfully!"
    echo ""
    wait_for_user "Press Enter to return to menu"
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
        nas_ip=$(ask_input "NAS/Synology IP address" "192.168.")
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
# CONFIGURE MONITOR SETTINGS
# ============================================================================

configure_monitor_settings() {
    echo ""
    show_info "Configure Monitor Settings"
    echo ""

    local current_nas_ip current_nas_user
    current_nas_ip=$(get_config "nas_ip")
    current_nas_user=$(get_config "nas_user")

    echo "Current configuration:"
    echo "  NAS IP:   ${current_nas_ip:-Not set}"
    echo "  NAS User: ${current_nas_user:-Not set}"
    echo ""

    if ask_confirm "Update NAS SSH settings?"; then
        local new_nas_ip new_nas_user

        new_nas_ip=$(ask_input "NAS IP address" "$current_nas_ip")
        new_nas_user=$(ask_input "NAS SSH username" "${current_nas_user:-$(whoami)}")

        set_config "nas_ip" "$new_nas_ip"
        set_config "nas_user" "$new_nas_user"

        echo ""
        show_result true "Monitor settings updated"
        echo ""
        echo "New configuration:"
        echo "  NAS IP:   $new_nas_ip"
        echo "  NAS User: $new_nas_user"
    fi

    echo ""
    wait_for_user "Press Enter to return to menu"
}

# Check and install monitor dependencies
ensure_monitor_dependencies() {
    local venv_dir="$SCRIPT_DIR/.venv"
    local python_cmd=""

    # Find Python 3
    if command -v python3 &> /dev/null; then
        python_cmd="python3"
    elif command -v python &> /dev/null && python --version 2>&1 | grep -q "Python 3"; then
        python_cmd="python"
    else
        show_error "Python 3 is required for the monitor"
        echo ""
        echo "Install Python with:"
        echo "  brew install python3   (macOS)"
        echo "  apt install python3    (Linux/Synology)"
        return 1
    fi

    # Check if textual is already installed in venv
    if [[ -d "$venv_dir" ]] && "$venv_dir/bin/python" -c "import textual" 2>/dev/null; then
        return 0  # Already installed
    fi

    # Dependencies not installed - ask user
    echo ""
    show_info "Monitor Dependencies Required"
    echo ""
    echo "The Transcodarr Monitor requires Python packages:"
    echo "  • textual (TUI framework)"
    echo "  • rich (terminal formatting)"
    echo ""

    if ! ask_confirm "Install monitor dependencies now?"; then
        show_warning "Monitor dependencies not installed"
        return 1
    fi

    echo ""
    show_info "Installing monitor dependencies..."

    # Create virtual environment if needed
    if [[ ! -d "$venv_dir" ]]; then
        echo "Creating virtual environment..."
        "$python_cmd" -m venv "$venv_dir"
    fi

    # Install dependencies
    echo "Installing packages..."
    "$venv_dir/bin/pip" install -q --upgrade pip
    "$venv_dir/bin/pip" install -q -r "$SCRIPT_DIR/monitor/requirements.txt"

    echo ""
    show_result true "Monitor dependencies installed successfully"
    return 0
}

# Start the monitor (with dependency check)
start_monitor() {
    if ensure_monitor_dependencies; then
        echo ""
        show_info "Starting Transcodarr Monitor..."
        exec "$SCRIPT_DIR/monitor.sh"
    else
        echo ""
        wait_for_user "Press Enter to return to menu"
    fi
}

# ============================================================================
# NODE MANAGEMENT FUNCTIONS
# ============================================================================

# Get list of registered nodes from rffmpeg
get_registered_nodes() {
    local status
    status=$(sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null || echo "")
    if [[ -z "$status" ]]; then
        return 1
    fi
    # Extract IP addresses from rffmpeg status output
    echo "$status" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort -u
}

# Shared weight selection menu (used by install, add-node, and change-weight)
# Returns weight value via stdout - all display text goes to stderr
select_weight() {
    echo "" >&2
    echo -e "${CYAN}Weight determines how many transcoding jobs this Mac gets:${NC}" >&2
    echo -e "  • Equal weight = equal share of jobs" >&2
    echo -e "  • Higher weight = more jobs (e.g., weight 4 gets 2x more than weight 2)" >&2
    echo -e "  • Use higher weight for faster Macs" >&2
    echo "" >&2

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
                echo -e "${YELLOW}  [!] Invalid weight, using default (2)${NC}" >&2
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
    show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
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

    # Remove and re-add with new weight
    if sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg remove "$selected_node" 2>/dev/null; then
        if sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg add "$selected_node" --weight "$new_weight" 2>/dev/null; then
            show_result true "Weight updated to $new_weight for $selected_node"
            echo ""
            sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null || true
        else
            show_error "Failed to re-add node"
            show_info "Try manually: sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg add $selected_node --weight $new_weight"
        fi
    else
        show_error "Failed to remove node for update"
    fi

    echo ""
    wait_for_user "Press Enter to return to menu"
}

# ============================================================================
# UNINSTALL MENU
# ============================================================================

# Show Uninstall submenu
menu_uninstall() {
    while true; do
        echo ""
        if command -v gum &> /dev/null; then
            gum style \
                --foreground 196 \
                --border-foreground 196 \
                --border double \
                --padding "0 2" \
                --width 60 \
                "Uninstall Transcodarr"
        else
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo -e "${RED}  Uninstall Transcodarr${NC}"
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
        fi
        echo ""

        local choice
        choice=$(gum choose \
            "1. Uninstall from a Node" \
            "2. Uninstall from Synology" \
            "3. Uninstall from Both" \
            "4. Back to Main Menu")

        case "$choice" in
            "1. Uninstall from a Node")
                menu_uninstall_node
                ;;
            "2. Uninstall from Synology")
                menu_uninstall_synology
                ;;
            "3. Uninstall from Both")
                menu_uninstall_both
                ;;
            "4. Back to Main Menu"|"")
                return 0
                ;;
        esac
    done
}

# Uninstall from a specific Mac node
menu_uninstall_node() {
    echo ""
    show_step 1 3 "Select Node"
    echo ""

    # Get Mac IP - either from user input or registered nodes
    local mac_ip=""
    local mac_user=""

    # Check if Jellyfin is running and get registered nodes
    local nodes=""
    if sudo docker ps 2>/dev/null | grep -q jellyfin; then
        nodes=$(get_registered_nodes 2>/dev/null || true)
    fi

    if [[ -n "$nodes" ]]; then
        echo "  Select a registered node or enter a new IP:"
        echo ""
        local node_options
        node_options=$(echo "$nodes"; echo "Enter IP manually")
        local selected
        selected=$(echo "$node_options" | gum choose)

        if [[ -z "$selected" ]]; then
            return 0
        fi

        if [[ "$selected" == "Enter IP manually" ]]; then
            mac_ip=$(ask_input "Mac IP address" "")
        else
            mac_ip="$selected"
        fi
    else
        mac_ip=$(ask_input "Mac IP address to uninstall from" "")
    fi

    if [[ -z "$mac_ip" ]]; then
        show_error "No IP address provided"
        wait_for_user "Press Enter to continue"
        return 1
    fi

    # Get Mac username
    mac_user=$(get_config "mac_user" 2>/dev/null || true)
    if [[ -z "$mac_user" ]]; then
        mac_user=$(ask_input "Mac username" "")
    fi

    if [[ -z "$mac_user" ]]; then
        show_error "No username provided"
        wait_for_user "Press Enter to continue"
        return 1
    fi

    echo ""
    show_step 2 3 "Components to Remove"
    echo ""

    echo "  The following will be removed from $mac_ip:"
    echo ""
    echo "  Use Space to select/deselect, Enter to confirm"
    echo ""

    # Multi-select components with defaults
    local selected
    selected=$(gum choose --no-limit --selected="NFS mounts & scripts,LaunchDaemons,Log files,jellyfin-ffmpeg,SSH key" \
        "NFS mounts & scripts" \
        "LaunchDaemons" \
        "Log files" \
        "jellyfin-ffmpeg" \
        "SSH key" \
        "Reset energy settings" \
        "Remove synthetic links (reboot required)")

    if [[ -z "$selected" ]]; then
        show_info "No components selected"
        wait_for_user "Press Enter to continue"
        return 0
    fi

    # Convert selections to component names
    local components=""
    while IFS= read -r line; do
        case "$line" in
            "NFS mounts & scripts") components+="mount_scripts " ;;
            "LaunchDaemons") components+="launchdaemons " ;;
            "Log files") components+="mount_scripts " ;;  # logs included with mount_scripts
            "jellyfin-ffmpeg") components+="ffmpeg " ;;
            "SSH key") components+="ssh_key " ;;
            "Reset energy settings") components+="energy " ;;
            "Remove synthetic links"*) components+="synthetic " ;;
        esac
    done <<< "$selected"

    echo ""
    show_step 3 3 "Confirm"
    echo ""

    gum style --foreground 226 --border double --padding "1 2" \
        "⚠ WARNING" \
        "" \
        "This will remove Transcodarr from:" \
        "$mac_ip" \
        "" \
        "Components: $components"
    echo ""

    if ! ask_confirm "Continue with uninstall?"; then
        return 0
    fi

    # Get SSH key path
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

    if [[ ! -f "$key_path" ]]; then
        show_error "SSH key not found at $key_path"
        show_info "Cannot connect to Mac without SSH key"
        wait_for_user "Press Enter to continue"
        return 1
    fi

    # Check Mac is reachable
    if ! test_mac_reachable "$mac_ip"; then
        show_error "Mac at $mac_ip is not reachable"
        wait_for_user "Press Enter to continue"
        return 1
    fi

    echo ""
    show_info "Uninstalling from Mac..."
    echo ""
    show_warning ">>> Enter your MAC password when prompted <<<"
    echo ""

    # Run uninstall
    local result
    remote_uninstall_components "$mac_user" "$mac_ip" "$key_path" $components
    result=$?

    # Also remove from rffmpeg if container is running
    if sudo docker ps 2>/dev/null | grep -q jellyfin; then
        echo ""
        if ask_confirm "Also remove $mac_ip from rffmpeg?"; then
            if sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg remove "$mac_ip" 2>/dev/null; then
                show_result true "Node removed from rffmpeg"
            else
                show_warning "Could not remove from rffmpeg (may not be registered)"
            fi
        fi
    fi

    if [[ $result -eq 2 ]]; then
        echo ""
        if ask_confirm "Reboot Mac now to complete removal?"; then
            show_info "Sending reboot command..."
            ssh_exec_sudo "$mac_user" "$mac_ip" "$key_path" "reboot" 2>/dev/null || true
            show_info "Mac is rebooting"
        fi
    fi

    echo ""
    show_result true "Uninstall from node complete"
    wait_for_user "Press Enter to continue"
}

# Uninstall Transcodarr from Synology
menu_uninstall_synology() {
    echo ""
    show_step 1 2 "Components to Remove"
    echo ""

    echo "  The following will be removed from this Synology:"
    echo ""

    gum style --foreground 252 --padding "0 2" \
        "[✓] State file (~/.transcodarr)" \
        "[✓] Output files (SSH keys, configs)" \
        "[✓] rffmpeg config from Jellyfin" \
        "[✓] Remove all nodes from rffmpeg"
    echo ""

    echo ""
    show_step 2 2 "Confirm"
    echo ""

    gum style --foreground 226 --border double --padding "1 2" \
        "⚠ WARNING" \
        "" \
        "This will remove Transcodarr config" \
        "from this Synology." \
        "" \
        "You will need to reinstall to use" \
        "distributed transcoding again."
    echo ""

    if ! ask_confirm "Continue with uninstall?"; then
        return 0
    fi

    echo ""
    show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
    echo ""

    # Remove all nodes from rffmpeg first
    if sudo docker ps 2>/dev/null | grep -q jellyfin; then
        show_info "Removing all nodes from rffmpeg..."
        local nodes
        nodes=$(get_registered_nodes 2>/dev/null || true)

        if [[ -n "$nodes" ]]; then
            while IFS= read -r node_ip; do
                if [[ -n "$node_ip" ]]; then
                    sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg remove "$node_ip" 2>/dev/null || true
                    show_result true "Removed $node_ip from rffmpeg"
                fi
            done <<< "$nodes"
        fi

        # Remove rffmpeg config from Jellyfin
        show_info "Removing rffmpeg config from Jellyfin..."
        local jellyfin_config
        jellyfin_config=$(get_config "jellyfin_config" 2>/dev/null || echo "/volume1/docker/jellyfin")
        if [[ -d "${jellyfin_config}/rffmpeg" ]]; then
            sudo rm -rf "${jellyfin_config}/rffmpeg"
            show_result true "Removed rffmpeg config"
        else
            show_skip "rffmpeg config not found"
        fi
    else
        show_warning "Jellyfin container not running - skipping rffmpeg cleanup"
    fi

    # Remove output directory
    show_info "Removing output directory..."
    if [[ -d "$OUTPUT_DIR" ]]; then
        rm -rf "$OUTPUT_DIR"
        show_result true "Removed $OUTPUT_DIR"
    else
        show_skip "Output directory not found"
    fi

    # Remove state file
    show_info "Removing state file..."
    if [[ -d "$STATE_DIR" ]]; then
        rm -rf "$STATE_DIR"
        show_result true "Removed ~/.transcodarr"
    else
        show_skip "State directory not found"
    fi

    echo ""
    show_result true "Synology uninstall complete"
    echo ""

    # Show instructions for restoring Jellyfin to normal operation
    gum style --foreground 226 --border double --padding "1 2" \
        "⚠ IMPORTANT: Restore Jellyfin to normal operation" \
        "" \
        "Remove these environment variables from Jellyfin:" \
        "" \
        "  DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg" \
        "  FFMPEG_PATH=/usr/local/bin/ffmpeg" \
        "" \
        "Then restart the Jellyfin container." \
        "" \
        "Without this, Jellyfin will fail to transcode!"
    echo ""
    show_info "To reinstall: git clone the repository and run ./install.sh"
    wait_for_user "Press Enter to continue"
}

# Uninstall from both Mac nodes and Synology
menu_uninstall_both() {
    echo ""
    show_step 1 3 "Nodes to Remove"
    echo ""

    # Get registered nodes
    local nodes=""
    local node_count=0

    if sudo docker ps 2>/dev/null | grep -q jellyfin; then
        nodes=$(get_registered_nodes 2>/dev/null || true)
        if [[ -n "$nodes" ]]; then
            node_count=$(echo "$nodes" | wc -l | tr -d ' ')
        fi
    fi

    if [[ -n "$nodes" ]]; then
        echo "  Found nodes in rffmpeg:"
        echo ""
        while IFS= read -r node_ip; do
            if [[ -n "$node_ip" ]]; then
                local weight
                weight=$(sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg status 2>/dev/null | grep "$node_ip" | awk '{print $NF}' || echo "?")
                echo "  • $node_ip (weight: $weight)"
            fi
        done <<< "$nodes"
        echo ""
        echo "  All nodes will be uninstalled."
    else
        show_warning "No nodes found in rffmpeg"
        echo ""
        echo "  Would you like to enter Mac IPs manually?"
        echo ""
        if ask_confirm "Enter IPs manually?"; then
            nodes=$(ask_input "Mac IP addresses (comma-separated)" "")
            nodes=$(echo "$nodes" | tr ',' '\n')
            node_count=$(echo "$nodes" | wc -l | tr -d ' ')
        fi
    fi

    echo ""
    show_step 2 3 "Components"
    echo ""

    echo "  Mac cleanup (per node):"
    gum style --foreground 252 --padding "0 2" \
        "[✓] NFS, scripts, daemons, logs" \
        "[✓] jellyfin-ffmpeg" \
        "[ ] Reset energy + synthetic"
    echo ""
    echo "  Synology cleanup:"
    gum style --foreground 252 --padding "0 2" \
        "[✓] State + output files" \
        "[✓] rffmpeg config"
    echo ""

    local include_energy_synthetic=false
    if ask_confirm "Also reset energy settings and remove synthetic links?"; then
        include_energy_synthetic=true
    fi

    echo ""
    show_step 3 3 "Final Confirm"
    echo ""

    gum style --foreground 196 --border double --padding "1 2" \
        "⚠ FINAL WARNING" \
        "" \
        "This will COMPLETELY remove" \
        "Transcodarr from:" \
        "" \
        "• $node_count Mac node(s)" \
        "• This Synology"
    echo ""

    if ! ask_confirm "Are you absolutely sure?"; then
        return 0
    fi

    echo ""
    show_warning ">>> Enter passwords when prompted (Mac & Synology) <<<"
    echo ""

    # Get SSH key and username
    local key_path="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"
    local mac_user
    mac_user=$(get_config "mac_user" 2>/dev/null || true)

    if [[ -z "$mac_user" ]]; then
        mac_user=$(ask_input "Mac username" "")
    fi

    # Uninstall from each Mac node
    if [[ -n "$nodes" ]] && [[ -f "$key_path" ]]; then
        while IFS= read -r mac_ip; do
            if [[ -n "$mac_ip" ]]; then
                show_info "Uninstalling from $mac_ip..."

                # Check if Mac is reachable
                if test_mac_reachable "$mac_ip"; then
                    # Build component list
                    local components="launchdaemons mount_scripts ffmpeg ssh_key"
                    if [[ "$include_energy_synthetic" == true ]]; then
                        components+=" energy synthetic"
                    fi

                    # Run uninstall
                    remote_uninstall_components "$mac_user" "$mac_ip" "$key_path" $components || true
                    show_result true "Uninstalled from $mac_ip"
                else
                    show_warning "Mac $mac_ip not reachable - skipping"
                fi
            fi
        done <<< "$nodes"
    else
        show_warning "Cannot uninstall from Macs (no SSH key or no nodes)"
    fi

    # Now uninstall from Synology
    echo ""
    show_info "Cleaning up Synology..."
    echo ""

    # Remove all nodes from rffmpeg
    if sudo docker ps 2>/dev/null | grep -q jellyfin; then
        local registered_nodes
        registered_nodes=$(get_registered_nodes 2>/dev/null || true)
        if [[ -n "$registered_nodes" ]]; then
            while IFS= read -r node_ip; do
                if [[ -n "$node_ip" ]]; then
                    sudo docker exec "$JELLYFIN_CONTAINER" rffmpeg remove "$node_ip" 2>/dev/null || true
                fi
            done <<< "$registered_nodes"
            show_result true "Removed all nodes from rffmpeg"
        fi

        # Remove rffmpeg config
        local jellyfin_config
        jellyfin_config=$(get_config "jellyfin_config" 2>/dev/null || echo "/volume1/docker/jellyfin")
        if [[ -d "${jellyfin_config}/rffmpeg" ]]; then
            sudo rm -rf "${jellyfin_config}/rffmpeg"
            show_result true "Removed rffmpeg config"
        fi
    fi

    # Remove output and state directories
    [[ -d "$OUTPUT_DIR" ]] && rm -rf "$OUTPUT_DIR" && show_result true "Removed output directory"
    [[ -d "$STATE_DIR" ]] && rm -rf "$STATE_DIR" && show_result true "Removed state directory"

    echo ""
    gum style --foreground 46 --border double --padding "1 2" \
        "✓ COMPLETE UNINSTALL FINISHED" \
        "" \
        "Transcodarr has been removed from" \
        "all nodes and this Synology."
    echo ""

    # Show instructions for restoring Jellyfin to normal operation
    gum style --foreground 226 --border double --padding "1 2" \
        "⚠ IMPORTANT: Restore Jellyfin to normal operation" \
        "" \
        "Remove these environment variables from Jellyfin:" \
        "" \
        "  DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg" \
        "  FFMPEG_PATH=/usr/local/bin/ffmpeg" \
        "" \
        "Then restart the Jellyfin container." \
        "" \
        "Without this, Jellyfin will fail to transcode!"
    echo ""
    show_info "To reinstall: git clone the repository and run ./install.sh"

    wait_for_user "Press Enter to exit"
    exit 0
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

menu_fix_ssh_keys() {
    echo ""
    show_info "Fix rffmpeg SSH Keys"
    echo ""

    # Get registered nodes
    local nodes
    nodes=$(get_registered_nodes)

    if [[ -z "$nodes" ]]; then
        show_warning "No nodes registered with rffmpeg"
        wait_for_user "Press Enter to return to menu"
        return
    fi

    local mac_user
    mac_user=$(get_config "mac_user")

    if [[ -z "$mac_user" ]]; then
        mac_user=$(ask_input "Mac username (same for all Macs)" "")
    fi

    # Step 1: Ensure SSH key exists in container
    show_info "Step 1: Checking SSH key in Jellyfin container..."
    ensure_container_ssh_key

    # Step 2: For each registered node, copy public key
    echo ""
    show_info "Step 2: Installing SSH key on registered Macs..."
    echo ""

    local success_count=0
    local fail_count=0

    while IFS= read -r node_ip; do
        [[ -z "$node_ip" ]] && continue

        echo -n "  $node_ip: "

        # Check if already working
        if test_container_ssh_to_mac "$mac_user" "$node_ip"; then
            echo -e "${GREEN}✓ Already working${NC}"
            ((success_count++))
            continue
        fi

        # Try to copy key
        if copy_ssh_key_to_mac "$mac_user" "$node_ip" 2>/dev/null; then
            sleep 1
            if test_container_ssh_to_mac "$mac_user" "$node_ip"; then
                echo -e "${GREEN}✓ Fixed${NC}"
                ((success_count++))
            else
                echo -e "${YELLOW}⚠ Key copied but still not working${NC}"
                ((fail_count++))
            fi
        else
            echo -e "${RED}✗ Failed${NC}"
            ((fail_count++))
        fi
    done <<< "$nodes"

    echo ""
    if [[ $fail_count -eq 0 ]]; then
        show_result true "All $success_count nodes have working SSH"
    else
        show_warning "$success_count working, $fail_count failed"
        echo ""
        show_info "For failed nodes, ensure:"
        echo "  • Remote Login is enabled on the Mac"
        echo "  • Firewall allows SSH (port 22)"
        echo "  • Correct password was entered"
    fi

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

    # Node management options (only if configured)
    if [[ "$install_status" != "first_time" ]]; then
        menu_options+=("➕ Add a new Mac node")
        menu_options+=("⚖️  Change Node Weight")
        menu_options+=("🗑️  Uninstall Transcodarr")
        menu_options+=("🔑 Fix SSH Keys")
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

    # Detect Jellyfin container name (supports custom names)
    detect_jellyfin_container

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
                wizard_add_node
                ;;
            "⚖️  Change Node Weight")
                menu_change_weight
                ;;
            "🗑️  Uninstall Transcodarr")
                menu_uninstall
                ;;
            "📖 Documentation")
                menu_documentation
                ;;
            "🔑 Fix SSH Keys")
                menu_fix_ssh_keys
                ;;
            "📊 Monitor")
                start_monitor
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
