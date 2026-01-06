#!/bin/bash
#
# Jellyfin + rffmpeg Setup Module for Transcodarr
# Generates configuration files locally in output folder
#

# Use local variable to avoid overwriting parent SCRIPT_DIR
_JELLYFIN_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${_JELLYFIN_SETUP_DIR}/../output"

# Source dependencies
[[ -z "$STATE_DIR" ]] && source "$_JELLYFIN_SETUP_DIR/state.sh"
[[ -z "$RED" ]] && source "$_JELLYFIN_SETUP_DIR/ui.sh"

# ============================================================================
# SSH KEY GENERATION
# ============================================================================

generate_ssh_key() {
    local ssh_dir="${OUTPUT_DIR}/rffmpeg/.ssh"
    local key_file="${ssh_dir}/id_rsa"

    mkdir -p "$ssh_dir"

    if [[ -f "$key_file" ]]; then
        if ask_confirm "SSH key already exists. Regenerate?"; then
            rm -f "$key_file" "${key_file}.pub"
        else
            show_skip "Using existing SSH key"
            return 0
        fi
    fi

    show_info "Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$key_file" -N "" -C "transcodarr-rffmpeg"

    chmod 600 "$key_file"
    chmod 644 "${key_file}.pub"

    show_result true "SSH key pair generated"
    mark_step_complete "ssh_key_generated"
}

# Ensure SSH key exists in Jellyfin container with correct permissions
# This function checks the container and creates/copies keys if needed
# Also fixes permissions if key exists but has wrong ownership
ensure_container_ssh_key() {
    local jellyfin_config="${1:-$(get_config jellyfin_config)}"

    if [[ -z "$jellyfin_config" ]]; then
        jellyfin_config="/volume1/docker/jellyfin"
    fi

    local container_key_path="/config/rffmpeg/.ssh/id_rsa"
    local host_key_dir="${jellyfin_config}/rffmpeg/.ssh"
    local host_key_file="${host_key_dir}/id_rsa"
    local output_key="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa"

    # Get the actual abc user uid from the container
    local abc_uid abc_gid
    abc_uid=$(sudo docker exec jellyfin id -u abc 2>/dev/null || echo "1000")
    abc_gid=$(sudo docker exec jellyfin id -g abc 2>/dev/null || echo "1000")

    # Check if key exists in container
    if sudo docker exec jellyfin test -f "$container_key_path" 2>/dev/null; then
        # Key exists - verify abc user can read it
        if sudo docker exec -u abc jellyfin test -r "$container_key_path" 2>/dev/null; then
            show_skip "SSH key already exists with correct permissions"
            # Still run finalize to ensure persist dir and default key location
            finalize_rffmpeg_setup "$jellyfin_config"
            return 0
        else
            # Fix permissions
            show_info "Fixing SSH key permissions..."
            sudo chown -R "${abc_uid}:${abc_gid}" "${jellyfin_config}/rffmpeg"
            sudo chmod 600 "$host_key_file"
            sudo chmod 644 "${host_key_file}.pub" 2>/dev/null || true
            show_result true "SSH key permissions fixed"
            # Run finalize to ensure persist dir and default key location
            finalize_rffmpeg_setup "$jellyfin_config"
            return 0
        fi
    fi

    show_info "Setting up SSH key for rffmpeg..."

    # Step 1: Ensure key exists in output dir
    if [[ ! -f "$output_key" ]]; then
        show_info "Generating SSH key..."
        mkdir -p "${OUTPUT_DIR}/rffmpeg/.ssh"
        ssh-keygen -t ed25519 -f "$output_key" -N "" -C "transcodarr-rffmpeg" -q
        chmod 600 "$output_key"
        chmod 644 "${output_key}.pub"
    fi

    # Step 2: Copy to Jellyfin config directory
    show_info "Copying SSH key to Jellyfin..."
    sudo mkdir -p "$host_key_dir"
    sudo cp "$output_key" "$host_key_file"
    sudo cp "${output_key}.pub" "${host_key_file}.pub"

    # Set correct ownership (abc_uid/abc_gid fetched at top of function)
    sudo chown -R "${abc_uid}:${abc_gid}" "${jellyfin_config}/rffmpeg"
    sudo chmod 600 "$host_key_file"
    sudo chmod 644 "${host_key_file}.pub"

    # Step 3: Verify key is now visible in container
    if sudo docker exec jellyfin test -f "$container_key_path" 2>/dev/null; then
        show_result true "SSH key installed in Jellyfin container"
        # Run finalize to ensure persist dir and default key location
        finalize_rffmpeg_setup "$jellyfin_config"
        return 0
    else
        show_error "SSH key not visible in container"
        show_info "You may need to restart Jellyfin: sudo docker restart jellyfin"
        return 1
    fi
}

# Copy SSH public key to a Mac for passwordless access
copy_ssh_key_to_mac() {
    local mac_user="$1"
    local mac_ip="$2"
    local jellyfin_config="${3:-$(get_config jellyfin_config)}"

    if [[ -z "$jellyfin_config" ]]; then
        jellyfin_config="/volume1/docker/jellyfin"
    fi

    local pub_key_file="${jellyfin_config}/rffmpeg/.ssh/id_rsa.pub"
    local output_pub_key="${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa.pub"

    # Get the public key content
    local pub_key=""
    if [[ -f "$pub_key_file" ]]; then
        pub_key=$(sudo cat "$pub_key_file")
    elif [[ -f "$output_pub_key" ]]; then
        pub_key=$(cat "$output_pub_key")
    else
        show_error "No SSH public key found"
        return 1
    fi

    show_info "Installing SSH key on Mac ($mac_ip)..."
    echo ""
    show_warning ">>> Enter your MAC password when prompted <<<"
    echo ""

    # Use ssh-copy-id style approach
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${mac_user}@${mac_ip}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"

    if [[ $? -eq 0 ]]; then
        show_result true "SSH key installed on Mac"
        return 0
    else
        show_error "Failed to install SSH key on Mac"
        return 1
    fi
}

# Test if SSH from container to Mac works without password
test_container_ssh_to_mac() {
    local mac_user="$1"
    local mac_ip="$2"

    # IMPORTANT: Run as abc user (not root) because that's how rffmpeg runs
    # This catches permission issues with the SSH key
    if sudo docker exec -u abc jellyfin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=5 \
        -i /config/rffmpeg/.ssh/id_rsa \
        "${mac_user}@${mac_ip}" "echo ok" 2>/dev/null | grep -q "ok"; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# RFFMPEG CONFIGURATION
# ============================================================================

create_rffmpeg_config() {
    local mac_ip="$1"
    local mac_user="$2"
    local config_file="${OUTPUT_DIR}/rffmpeg/rffmpeg.yml"

    # Determine FFmpeg paths based on variant
    local ffmpeg_path ffprobe_path variant
    variant=$(get_config "ffmpeg_variant")

    # Default to jellyfin if not specified (recommended for HDR)
    if [[ -z "$variant" ]]; then
        variant="jellyfin"
    fi

    case "$variant" in
        jellyfin)
            ffmpeg_path="/opt/jellyfin-ffmpeg/ffmpeg"
            ffprobe_path="/opt/jellyfin-ffmpeg/ffprobe"
            ;;
        homebrew|*)
            ffmpeg_path="/opt/homebrew/bin/ffmpeg"
            ffprobe_path="/opt/homebrew/bin/ffprobe"
            ;;
    esac

    mkdir -p "$(dirname "$config_file")"

    cat > "$config_file" << EOF
# Transcodarr - rffmpeg Configuration
# FFmpeg variant: ${variant}
# Generated by Transcodarr Installer

rffmpeg:
    logging:
        log_to_file: true
        logfile: "/config/log/rffmpeg.log"
        debug: false

    directories:
        state: "/config/rffmpeg"
        persist: "/config/rffmpeg/persist"
        owner: abc
        group: abc

    remote:
        user: "${mac_user}"
        persist: 300
        args:
            - "-o"
            - "StrictHostKeyChecking=no"
            - "-o"
            - "UserKnownHostsFile=/dev/null"
            - "-i"
            - "/config/rffmpeg/.ssh/id_rsa"

    commands:
        ssh: "/usr/bin/ssh"
        ffmpeg: "${ffmpeg_path}"
        ffprobe: "${ffprobe_path}"
        fallback_ffmpeg: "/usr/lib/jellyfin-ffmpeg/ffmpeg"
        fallback_ffprobe: "/usr/lib/jellyfin-ffmpeg/ffprobe"
EOF

    show_result true "rffmpeg.yml created (using ${variant} FFmpeg)"
}

# ============================================================================
# DOCKER COMPOSE
# ============================================================================

create_docker_compose() {
    local mac_ip="$1"
    local nas_ip="$2"
    local cache_path="${3:-/volume1/docker/jellyfin/cache}"
    local jellyfin_config="${4:-/volume1/docker/jellyfin}"
    local compose_file="${OUTPUT_DIR}/docker-compose.yml"

    cat > "$compose_file" << EOF
# Transcodarr - Jellyfin with rffmpeg
# For NEW installations

services:
  jellyfin:
    image: linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Amsterdam
      - JELLYFIN_PublishedServerUrl=${nas_ip}
      - UMASK=022
      - DOCKER_MODS=linuxserver/mods:jellyfin-rffmpeg
      - FFMPEG_PATH=/usr/local/bin/ffmpeg
    volumes:
      - ${jellyfin_config}:/config
      - /volume1/data/media:/data/media
      - ${cache_path}:/config/cache
    ports:
      - 8096:8096/tcp
      - 8920:8920/tcp
      - 7359:7359/udp
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
EOF

    show_result true "docker-compose.yml created"
}

# ============================================================================
# SETUP INSTRUCTIONS
# ============================================================================

create_setup_instructions() {
    local mac_ip="$1"
    local mac_user="$2"
    local nas_ip="$3"
    local jellyfin_config="$4"
    local readme_file="${OUTPUT_DIR}/SETUP_INSTRUCTIONS.md"
    local public_key=""

    if [[ -f "${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa.pub" ]]; then
        public_key=$(cat "${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa.pub")
    fi

    cat > "$readme_file" << EOF
# Transcodarr Setup Instructions

**Mac:** ${mac_user}@${mac_ip}
**NAS:** ${nas_ip}

---

## Add SSH Key to Mac

Run this on your Mac:

\`\`\`bash
mkdir -p ~/.ssh
echo "${public_key}" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
\`\`\`

---

## Copy Files to Synology

\`\`\`bash
sudo mkdir -p ${jellyfin_config}/rffmpeg/.ssh
sudo cp -a output/rffmpeg/. ${jellyfin_config}/rffmpeg/

# Get abc user UID from container (matches your PUID setting)
ABC_UID=\$(sudo docker exec jellyfin id -u abc)
ABC_GID=\$(sudo docker exec jellyfin id -g abc)
sudo chown -R \${ABC_UID}:\${ABC_GID} ${jellyfin_config}/rffmpeg
\`\`\`

---

## Add Mac to rffmpeg

\`\`\`bash
docker exec jellyfin rffmpeg add ${mac_ip} --weight 2
docker exec jellyfin rffmpeg status
\`\`\`
EOF

    show_result true "SETUP_INSTRUCTIONS.md created"
}

# ============================================================================
# SSH KEY INSTALLATION ON MAC
# ============================================================================

install_ssh_key_on_mac() {
    local mac_ip="$1"
    local mac_user="$2"
    local public_key=""

    if [[ -f "${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa.pub" ]]; then
        public_key=$(cat "${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa.pub")
    else
        show_error "No SSH key found. Generate a key first."
        return 1
    fi

    echo ""
    show_ssh_key_instructions "$mac_user" "$mac_ip"

    if ask_confirm "Install SSH key on Mac now?"; then
        echo ""
        show_info "Connecting to Mac at ${mac_ip}..."
        show_warning "Enter your MAC password (not Synology!)"
        echo ""

        if ssh -o StrictHostKeyChecking=accept-new "${mac_user}@${mac_ip}" \
            "mkdir -p ~/.ssh && echo '${public_key}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"; then
            echo ""
            show_result true "SSH key installed on Mac"
            mark_step_complete "ssh_key_installed"
            return 0
        else
            echo ""
            show_result false "SSH key installation failed"
            show_info "Try manually on your Mac:"
            echo ""
            echo "mkdir -p ~/.ssh && echo '${public_key}' >> ~/.ssh/authorized_keys"
            return 1
        fi
    else
        show_info "You can install the key manually later."
        show_info "See: output/SETUP_INSTRUCTIONS.md"
        return 0
    fi
}

# ============================================================================
# COPY FILES TO JELLYFIN
# ============================================================================

copy_rffmpeg_files() {
    local jellyfin_config="$1"
    local success=true

    echo ""
    show_warning ">>> Enter your SYNOLOGY password when prompted <<<"
    echo ""

    # Dynamically get abc user UID/GID from running container
    local abc_uid abc_gid
    abc_uid=$(sudo docker exec jellyfin id -u abc 2>/dev/null || echo "1000")
    abc_gid=$(sudo docker exec jellyfin id -g abc 2>/dev/null || echo "1000")

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 212 \
            --border-foreground 212 \
            --border double \
            --padding "1 2" \
            --width 65 \
            "Copy Files to Jellyfin"
    else
        echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
        echo -e "${MAGENTA}  Copy Files to Jellyfin${NC}"
        echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
    fi
    echo ""

    echo "  The following commands will be executed:"
    echo ""
    echo -e "  ${CYAN}1.${NC} sudo mkdir -p ${jellyfin_config}/rffmpeg/.ssh"
    echo -e "  ${CYAN}2.${NC} sudo cp -a ${OUTPUT_DIR}/rffmpeg/. ${jellyfin_config}/rffmpeg/"
    echo -e "  ${CYAN}3.${NC} sudo chown -R ${abc_uid}:${abc_gid} ${jellyfin_config}/rffmpeg"
    echo ""

    if ask_confirm "Execute these commands now?"; then
        echo ""
        show_warning ">>> Enter your SYNOLOGY password (not Mac!) <<<"
        echo ""

        # Step 1: Create directory
        echo -n "  1. Creating directory... "
        if sudo mkdir -p "${jellyfin_config}/rffmpeg/.ssh" 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
            success=false
        fi

        # Step 2: Copy files
        echo -n "  2. Copying files... "
        if sudo cp -a "${OUTPUT_DIR}/rffmpeg/." "${jellyfin_config}/rffmpeg/" 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
            success=false
        fi

        # Step 3: Set permissions (use dynamic abc uid/gid)
        echo -n "  3. Setting permissions... "
        if sudo chown -R "${abc_uid}:${abc_gid}" "${jellyfin_config}/rffmpeg" 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
            success=false
        fi

        echo ""
        if [[ "$success" == true ]]; then
            show_result true "All files copied to Jellyfin config"
            mark_step_complete "files_copied"
            return 0
        else
            show_result false "Some commands failed"
            show_manual_copy_instructions "$jellyfin_config"
            return 1
        fi
    else
        show_manual_copy_instructions "$jellyfin_config"
        return 0
    fi
}

show_manual_copy_instructions() {
    local jellyfin_config="$1"

    # Get abc uid/gid for instructions
    local abc_uid abc_gid
    abc_uid=$(sudo docker exec jellyfin id -u abc 2>/dev/null || echo "<PUID>")
    abc_gid=$(sudo docker exec jellyfin id -g abc 2>/dev/null || echo "<PGID>")

    echo ""
    show_info "Run these commands manually:"
    echo ""
    echo -e "  ${GREEN}sudo mkdir -p ${jellyfin_config}/rffmpeg/.ssh${NC}"
    echo -e "  ${GREEN}sudo cp -a ${OUTPUT_DIR}/rffmpeg/. ${jellyfin_config}/rffmpeg/${NC}"
    echo -e "  ${GREEN}sudo chown -R ${abc_uid}:${abc_gid} ${jellyfin_config}/rffmpeg${NC}"
    echo ""
}

# ============================================================================
# FINALIZE RFFMPEG SETUP
# ============================================================================

# Finalize rffmpeg setup inside container
# Creates persist directory and copies keys to default rffmpeg location
# This fixes "remote 255" errors by ensuring rffmpeg can find SSH keys
finalize_rffmpeg_setup() {
    local jellyfin_config="${1:-$(get_config jellyfin_config)}"

    show_info "Finalizing rffmpeg setup..."

    # Check if container is running
    if ! sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^jellyfin$"; then
        show_warning "Jellyfin container not running - skipping finalize"
        show_info "Run this after starting Jellyfin: sudo docker exec jellyfin bash -c 'mkdir -p /config/rffmpeg/persist /var/lib/jellyfin/.ssh'"
        return 0
    fi

    # Execute all setup inside container in single command for efficiency
    if sudo docker exec jellyfin bash -c '
        # 1. Create persist directory for SSH ControlMaster sockets
        mkdir -p /config/rffmpeg/persist
        chown abc:abc /config/rffmpeg/persist
        chmod 755 /config/rffmpeg/persist

        # 2. Copy keys to rffmpeg default location (/var/lib/jellyfin/.ssh/)
        # rffmpeg looks here by default even when custom path is configured
        mkdir -p /var/lib/jellyfin/.ssh
        # Fix parent dir permissions so abc user can access .ssh
        chmod 755 /var/lib/jellyfin
        if [ -f /config/rffmpeg/.ssh/id_rsa ]; then
            cp /config/rffmpeg/.ssh/id_rsa /var/lib/jellyfin/.ssh/id_rsa
            cp /config/rffmpeg/.ssh/id_rsa.pub /var/lib/jellyfin/.ssh/id_rsa.pub 2>/dev/null || true
            chown -R abc:abc /var/lib/jellyfin/.ssh
            chmod 700 /var/lib/jellyfin/.ssh
            chmod 600 /var/lib/jellyfin/.ssh/id_rsa
            chmod 644 /var/lib/jellyfin/.ssh/id_rsa.pub 2>/dev/null || true
        fi
    ' 2>/dev/null; then
        # Verify abc user can read the key
        if sudo docker exec -u abc jellyfin test -r /var/lib/jellyfin/.ssh/id_rsa 2>/dev/null; then
            show_result true "rffmpeg setup finalized"
            return 0
        else
            show_warning "Key copied but abc user cannot read it"
            return 1
        fi
    else
        show_error "Failed to finalize rffmpeg setup"
        return 1
    fi
}

# ============================================================================
# SUMMARY
# ============================================================================

show_setup_summary() {
    local mac_ip="$1"
    local mac_user="$2"
    local nas_ip="$3"
    local jellyfin_config="$4"

    echo ""
    if command -v gum &> /dev/null; then
        gum style \
            --foreground 46 \
            --border-foreground 46 \
            --border double \
            --padding "1 2" \
            --width 60 \
            "Configuration Generated!"
    else
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  Configuration Generated!                                    ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""

    echo "  Generated files in: ${OUTPUT_DIR}/"
    echo ""
    echo "    output/"
    echo "    ├── docker-compose.yml"
    echo "    ├── SETUP_INSTRUCTIONS.md"
    echo "    └── rffmpeg/"
    echo "        ├── rffmpeg.yml"
    echo "        └── .ssh/"
    echo "            ├── id_rsa"
    echo "            └── id_rsa.pub"
    echo ""
}

# ============================================================================
# MAIN SETUP FUNCTION
# ============================================================================

run_jellyfin_setup() {
    local mac_ip="$1"
    local mac_user="$2"
    local nas_ip="$3"
    local cache_path="${4:-/volume1/docker/jellyfin/cache}"
    local jellyfin_config="${5:-/volume1/docker/jellyfin}"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Initialize state if needed
    if ! state_exists; then
        create_state "synology"
    fi

    # Save config to state
    set_config "mac_ip" "$mac_ip"
    set_config "mac_user" "$mac_user"
    set_config "nas_ip" "$nas_ip"
    set_config "cache_path" "$cache_path"
    set_config "jellyfin_config" "$jellyfin_config"

    show_info "Generating configuration files..."
    echo ""

    # Generate files
    generate_ssh_key
    create_rffmpeg_config "$mac_ip" "$mac_user"
    create_docker_compose "$mac_ip" "$nas_ip" "$cache_path" "$jellyfin_config"
    create_setup_instructions "$mac_ip" "$mac_user" "$nas_ip" "$jellyfin_config"

    # Show summary
    show_setup_summary "$mac_ip" "$mac_user" "$nas_ip" "$jellyfin_config"

    # Install SSH key on Mac
    install_ssh_key_on_mac "$mac_ip" "$mac_user"

    # Copy rffmpeg files to Jellyfin config (with sudo)
    copy_rffmpeg_files "$jellyfin_config"

    # Show DOCKER_MODS instructions
    echo ""
    show_docker_mods_instructions "$mac_ip"

    echo ""
    show_synology_summary "$mac_ip" "$mac_user" "$jellyfin_config"
}

# Quick setup for adding additional node (SSH key already exists)
run_add_node_setup() {
    local mac_ip="$1"
    local mac_user="$2"

    # Get existing config from state
    local jellyfin_config
    jellyfin_config=$(get_config "jellyfin_config")

    if [[ -z "$jellyfin_config" ]]; then
        jellyfin_config="/volume1/docker/jellyfin"
    fi

    # Check if SSH key exists
    if [[ ! -f "${OUTPUT_DIR}/rffmpeg/.ssh/id_rsa.pub" ]]; then
        # Try to find key in Jellyfin config
        if [[ -f "${jellyfin_config}/rffmpeg/.ssh/id_rsa.pub" ]]; then
            mkdir -p "${OUTPUT_DIR}/rffmpeg/.ssh"
            cp "${jellyfin_config}/rffmpeg/.ssh/id_rsa.pub" "${OUTPUT_DIR}/rffmpeg/.ssh/"
        else
            show_error "No existing SSH key found"
            show_info "Run full setup first"
            return 1
        fi
    fi

    show_info "Adding node: ${mac_user}@${mac_ip}"
    echo ""

    # Install SSH key on new Mac
    install_ssh_key_on_mac "$mac_ip" "$mac_user"

    # Show rffmpeg add command
    echo ""
    show_info "Add the Mac to rffmpeg:"
    echo ""
    echo -e "  ${GREEN}docker exec jellyfin rffmpeg add ${mac_ip} --weight 2${NC}"
    echo ""
    echo -e "  ${GREEN}docker exec jellyfin rffmpeg status${NC}"
    echo ""
}
