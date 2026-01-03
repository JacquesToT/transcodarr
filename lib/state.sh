#!/bin/bash
#
# Transcodarr State Persistence
# Manages installation state across reboots and sessions
#

STATE_DIR="$HOME/.transcodarr"
STATE_FILE="$STATE_DIR/state.json"
STATE_VERSION="2.0"

# Initialize state directory
init_state_dir() {
    mkdir -p "$STATE_DIR"
}

# Check if state file exists
state_exists() {
    [[ -f "$STATE_FILE" ]]
}

# Create new state file with defaults
create_state() {
    local machine_type="${1:-unknown}"
    init_state_dir
    cat > "$STATE_FILE" << EOF
{
  "version": "$STATE_VERSION",
  "machine_type": "$machine_type",
  "install_started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pending_reboot": false,
  "completed_steps": [],
  "config": {}
}
EOF
}

# Read entire state file
read_state() {
    if state_exists; then
        cat "$STATE_FILE"
    else
        echo '{}'
    fi
}

# Get a simple value from state (works without jq)
# Usage: get_state_value "pending_reboot"
get_state_value() {
    local key="$1"
    if state_exists; then
        grep -o "\"$key\": *\"[^\"]*\"" "$STATE_FILE" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/'
    fi
}

# Get boolean value from state
# Usage: get_state_bool "pending_reboot"
get_state_bool() {
    local key="$1"
    if state_exists; then
        local value
        value=$(grep -o "\"$key\": *[a-z]*" "$STATE_FILE" 2>/dev/null | head -1 | sed 's/.*: *//')
        [[ "$value" == "true" ]]
    else
        return 1
    fi
}

# Set a simple string value in state
# Usage: set_state_value "machine_type" "mac"
set_state_value() {
    local key="$1"
    local value="$2"

    if ! state_exists; then
        create_state
    fi

    if grep -q "\"$key\":" "$STATE_FILE"; then
        # Key exists, update it
        sed -i.bak "s/\"$key\": *\"[^\"]*\"/\"$key\": \"$value\"/" "$STATE_FILE"
        rm -f "${STATE_FILE}.bak"
    else
        # Key doesn't exist, add it before the last }
        sed -i.bak "s/}$/,\n  \"$key\": \"$value\"\n}/" "$STATE_FILE"
        rm -f "${STATE_FILE}.bak"
    fi
}

# Set a boolean value in state
# Usage: set_state_bool "pending_reboot" true
set_state_bool() {
    local key="$1"
    local value="$2"

    if ! state_exists; then
        create_state
    fi

    if grep -q "\"$key\":" "$STATE_FILE"; then
        # Key exists, update it
        sed -i.bak "s/\"$key\": *[a-z]*/\"$key\": $value/" "$STATE_FILE"
        rm -f "${STATE_FILE}.bak"
    else
        # Key doesn't exist, add it before the last }
        sed -i.bak "s/}$/,\n  \"$key\": $value\n}/" "$STATE_FILE"
        rm -f "${STATE_FILE}.bak"
    fi
}

# Set a config value
# Usage: set_config "mac_ip" "192.168.1.50"
set_config() {
    local key="$1"
    local value="$2"

    if ! state_exists; then
        create_state
    fi

    # Read current config section
    local temp_file="${STATE_FILE}.tmp"

    if grep -q "\"config\": *{" "$STATE_FILE"; then
        # Config section exists, add/update key
        # This is simplified - for complex JSON, use jq
        if grep -q "\"$key\":" "$STATE_FILE"; then
            sed -i.bak "s/\"$key\": *\"[^\"]*\"/\"$key\": \"$value\"/" "$STATE_FILE"
        else
            # Add key to config object
            sed -i.bak "s/\"config\": *{/\"config\": {\n    \"$key\": \"$value\",/" "$STATE_FILE"
        fi
        rm -f "${STATE_FILE}.bak"
    fi
}

# Get a config value
# Usage: get_config "mac_ip"
get_config() {
    local key="$1"
    if state_exists; then
        grep -o "\"$key\": *\"[^\"]*\"" "$STATE_FILE" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/'
    fi
}

# Check if a step is completed
# Usage: is_step_complete "homebrew"
is_step_complete() {
    local step="$1"
    if state_exists; then
        grep -q "\"$step\"" "$STATE_FILE" && grep -A 20 "completed_steps" "$STATE_FILE" | grep -q "\"$step\""
    else
        return 1
    fi
}

# Mark a step as complete
# Usage: mark_step_complete "homebrew"
mark_step_complete() {
    local step="$1"

    if ! state_exists; then
        create_state
    fi

    # Check if already marked
    if is_step_complete "$step"; then
        return 0
    fi

    # Add to completed_steps array
    if grep -q '"completed_steps": \[\]' "$STATE_FILE"; then
        # Empty array, add first item
        sed -i.bak "s/\"completed_steps\": \[\]/\"completed_steps\": [\"$step\"]/" "$STATE_FILE"
    else
        # Array has items, append
        sed -i.bak "s/\"completed_steps\": \[/\"completed_steps\": [\"$step\", /" "$STATE_FILE"
    fi
    rm -f "${STATE_FILE}.bak"
}

# Set pending reboot flag
set_pending_reboot() {
    set_state_bool "pending_reboot" "true"
}

# Clear pending reboot flag
clear_pending_reboot() {
    set_state_bool "pending_reboot" "false"
}

# Check if reboot is pending
is_reboot_pending() {
    get_state_bool "pending_reboot"
}

# Get machine type from state
get_machine_type() {
    get_state_value "machine_type"
}

# Set machine type in state
set_machine_type() {
    set_state_value "machine_type" "$1"
}

# Get all completed steps as space-separated list
get_completed_steps() {
    if state_exists; then
        grep -o '"completed_steps": \[[^]]*\]' "$STATE_FILE" 2>/dev/null | \
            sed 's/"completed_steps": \[//;s/\]//;s/"//g;s/,/ /g'
    fi
}

# Reset state (for testing or starting over)
reset_state() {
    rm -f "$STATE_FILE"
}

# Show state file contents (for debugging)
show_state() {
    if state_exists; then
        echo "=== Transcodarr State ==="
        cat "$STATE_FILE"
        echo ""
    else
        echo "No state file found at $STATE_FILE"
    fi
}
