#!/bin/bash
#
# Transcodarr Load Balancer
# Load-aware balancing for rffmpeg transcoding nodes
#
# This daemon continuously monitors the load on each Mac node and
# reorders rffmpeg hosts so the least-loaded node is always selected first.
#
# How it works:
# - Checks ffmpeg process count on each Mac via SSH
# - Calculates load score: (active_transcodes * 100) / weight
# - Lower score = better candidate (less load relative to capacity)
# - Reorders hosts so best candidate has lowest ID (selected first by rffmpeg)
#
# Usage:
#   ./load-balancer.sh start     - Start the load balancer daemon
#   ./load-balancer.sh stop      - Stop the daemon
#   ./load-balancer.sh status    - Show daemon status and current loads
#   ./load-balancer.sh balance   - Manually rebalance hosts once
#   ./load-balancer.sh show      - Show current host order with loads
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="/tmp/transcodarr-lb.pid"
LOG_FILE="/tmp/transcodarr-lb.log"
JELLYFIN_CONTAINER="${JELLYFIN_CONTAINER:-jellyfin}"

# Check interval in seconds (how often to check loads and rebalance)
CHECK_INTERVAL="${CHECK_INTERVAL:-3}"

# Source library functions
source "$SCRIPT_DIR/lib/state.sh" 2>/dev/null || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$LOG_FILE"
}

log_info() {
    log "INFO: $*"
}

log_debug() {
    [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG: $*"
}

log_error() {
    log "ERROR: $*"
}

is_synology() {
    [[ -f /etc/synoinfo.conf ]] || [[ -d /volume1 ]]
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        if is_synology && [[ -x /usr/local/bin/docker ]]; then
            return 0
        fi
        echo -e "${RED}Error: Docker not found${NC}"
        return 1
    fi
    return 0
}

check_container() {
    if ! sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${JELLYFIN_CONTAINER}$"; then
        echo -e "${RED}Error: Container '$JELLYFIN_CONTAINER' not running${NC}"
        return 1
    fi
    return 0
}

# Get Mac username from config
get_mac_user() {
    local state_file="$HOME/.transcodarr/state.json"
    if [[ -f "$state_file" ]]; then
        grep -o '"mac_user": *"[^"]*"' "$state_file" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/'
    fi
}

# ============================================================================
# LOAD MONITORING FUNCTIONS
# ============================================================================

# Global cache for rffmpeg status (to avoid multiple calls)
RFFMPEG_STATUS_CACHE=""

# Refresh the rffmpeg status cache
refresh_rffmpeg_cache() {
    local container="${1:-$JELLYFIN_CONTAINER}"
    RFFMPEG_STATUS_CACHE=$(sudo docker exec "$container" rffmpeg status 2>/dev/null)
}

# Get active process count for a node from cached rffmpeg status
# Counts "PID XXXXX:" lines belonging to each host
get_node_load() {
    local ip="$1"
    local mac_user="$2"  # unused but kept for compatibility
    local container="${3:-$JELLYFIN_CONTAINER}"

    # Refresh cache if empty
    if [[ -z "$RFFMPEG_STATUS_CACHE" ]]; then
        refresh_rffmpeg_cache "$container"
    fi

    # Parse rffmpeg status to count PIDs for this host
    # Format: IP starts a new host block, subsequent lines with "PID XXXXX:" belong to it
    local in_host=false
    local pid_count=0

    while IFS= read -r line; do
        # Check if line starts with an IP (new host block)
        if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            if [[ "$line" =~ ^${ip}[[:space:]] ]]; then
                in_host=true
                # Check if first line has a PID
                if [[ "$line" =~ PID\ [0-9]+: ]]; then
                    ((pid_count++))
                fi
            else
                in_host=false
            fi
        elif [[ "$in_host" == true ]] && [[ "$line" =~ PID\ [0-9]+: ]]; then
            ((pid_count++))
        fi
    done <<< "$RFFMPEG_STATUS_CACHE"

    echo "$pid_count"
}

# Get state (active/idle) from cached rffmpeg status
get_node_state() {
    local ip="$1"
    local container="${2:-$JELLYFIN_CONTAINER}"

    # Refresh cache if empty
    if [[ -z "$RFFMPEG_STATUS_CACHE" ]]; then
        refresh_rffmpeg_cache "$container"
    fi

    local state
    state=$(echo "$RFFMPEG_STATUS_CACHE" | grep -E "^${ip}[[:space:]]" | awk '{print $5}')

    if [[ "$state" == "active" ]]; then
        echo "active"
    else
        echo "idle"
    fi
}

# Calculate load score for a node
# Lower score = better candidate
# Formula: (active_transcodes * 100) / weight
# This means a node with weight 4 can handle 4x the load of weight 1
calculate_load_score() {
    local load="$1"
    local weight="$2"

    # Avoid division by zero
    [[ "$weight" -lt 1 ]] && weight=1

    # Multiply by 100 for integer math precision
    # Add weight as tiebreaker (higher weight = lower score when equal load)
    local score=$(( (load * 1000) / weight ))

    # Subtract weight bonus for tiebreaking (higher weight preferred)
    score=$((score - weight))

    echo "$score"
}

# Get all hosts with their current loads
# Output: "IP WEIGHT LOAD SCORE" per line, sorted by score (best first)
get_hosts_with_load() {
    local container="${1:-$JELLYFIN_CONTAINER}"
    local mac_user
    mac_user=$(get_mac_user)

    if [[ -z "$mac_user" ]]; then
        mac_user=$(whoami)
    fi

    # Refresh the cache first
    refresh_rffmpeg_cache "$container"

    # Get hosts from cached status (filter to only lines starting with IP addresses)
    local hosts
    hosts=$(echo "$RFFMPEG_STATUS_CACHE" | tail -n +2 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')

    if [[ -z "$hosts" ]]; then
        return 1
    fi

    # For each host, get load and calculate score
    local result=""
    while read -r line; do
        local ip weight
        ip=$(echo "$line" | awk '{print $1}')
        weight=$(echo "$line" | awk '{print $4}')

        [[ -z "$ip" ]] && continue
        [[ -z "$weight" ]] && weight=1

        # Get current load
        local load
        load=$(get_node_load "$ip" "$mac_user" "$container")

        # Calculate score
        local score
        score=$(calculate_load_score "$load" "$weight")

        result+="$ip $weight $load $score"$'\n'
    done <<< "$hosts"

    # Sort by score (ascending - lowest score first)
    echo "$result" | grep -v '^$' | sort -t' ' -k4 -n
}

# ============================================================================
# HOST REORDERING FUNCTIONS
# ============================================================================

# Reorder hosts based on current load
# Puts the least-loaded node first (lowest ID)
reorder_by_load() {
    local container="${1:-$JELLYFIN_CONTAINER}"
    local quiet="${2:-false}"

    # Get hosts sorted by load score
    local sorted_hosts
    sorted_hosts=$(get_hosts_with_load "$container")

    if [[ -z "$sorted_hosts" ]]; then
        [[ "$quiet" != "true" ]] && echo "No hosts configured"
        return 1
    fi

    # Count hosts
    local host_count
    host_count=$(echo "$sorted_hosts" | wc -l | tr -d ' ')
    if [[ "$host_count" -lt 2 ]]; then
        [[ "$quiet" != "true" ]] && echo "Only one host, nothing to reorder"
        return 2
    fi

    # Check if reordering is needed
    # Get current first host (lowest ID) - filter to only IP addresses
    local current_first
    current_first=$(echo "$RFFMPEG_STATUS_CACHE" | \
        tail -n +2 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -t' ' -k3 -n | head -1 | awk '{print $1}')

    # Get best host (lowest score)
    local best_host
    best_host=$(echo "$sorted_hosts" | head -1 | awk '{print $1}')

    # If already optimal, skip
    if [[ "$current_first" == "$best_host" ]]; then
        log_debug "Host order already optimal ($best_host is first)"
        return 0
    fi

    log_info "Reordering: moving $best_host to front (was: $current_first)"

    # Remove all hosts
    local hosts_to_add=""
    while read -r line; do
        local ip weight
        ip=$(echo "$line" | awk '{print $1}')
        weight=$(echo "$line" | awk '{print $2}')

        [[ -z "$ip" ]] && continue

        sudo docker exec "$container" rffmpeg remove "$ip" 2>/dev/null || true
        hosts_to_add+="$ip $weight"$'\n'
    done <<< "$sorted_hosts"

    # Re-add in order (best first = lowest ID)
    while read -r line; do
        local ip weight
        ip=$(echo "$line" | awk '{print $1}')
        weight=$(echo "$line" | awk '{print $2}')

        [[ -z "$ip" ]] && continue

        sudo docker exec "$container" rffmpeg add "$ip" --weight "$weight" 2>/dev/null || true
    done <<< "$hosts_to_add"

    [[ "$quiet" != "true" ]] && echo "Reordered: $best_host is now first"
    return 0
}

# Show current host order with loads
show_hosts() {
    local container="${1:-$JELLYFIN_CONTAINER}"

    echo -e "${CYAN}${BOLD}Current Node Status:${NC}"
    echo ""

    # Get hosts with load info
    local hosts_with_load
    hosts_with_load=$(get_hosts_with_load "$container" 2>/dev/null)

    if [[ -z "$hosts_with_load" ]]; then
        echo -e "${YELLOW}No hosts configured${NC}"
        return 1
    fi

    # Get current rffmpeg order (by ID) from cache - filter to only IP addresses
    local current_order
    current_order=$(echo "$RFFMPEG_STATUS_CACHE" | \
        tail -n +2 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -t' ' -k3 -n | awk '{print $1}')

    # Display each host
    local rank=1
    while read -r ip; do
        [[ -z "$ip" ]] && continue

        # Find this host's info
        local host_info
        host_info=$(echo "$hosts_with_load" | grep "^$ip ")

        local weight load score
        weight=$(echo "$host_info" | awk '{print $2}')
        load=$(echo "$host_info" | awk '{print $3}')
        score=$(echo "$host_info" | awk '{print $4}')

        # Get rffmpeg state as fallback (for burst transcoding where pgrep may miss)
        local rffmpeg_state
        rffmpeg_state=$(get_node_state "$ip" "$container")

        # Format load display
        local load_display
        if [[ "$load" -eq 0 ]]; then
            # If pgrep shows 0 but rffmpeg says active, show "active" instead of "idle"
            if [[ "$rffmpeg_state" == "active" ]]; then
                load_display="${YELLOW}active${NC}"
            else
                load_display="${GREEN}idle${NC}"
            fi
        elif [[ "$load" -eq 1 ]]; then
            load_display="${YELLOW}1 transcode${NC}"
        else
            load_display="${RED}${load} transcodes${NC}"
        fi

        if [[ $rank -eq 1 ]]; then
            echo -e "  ${GREEN}${BOLD}#$rank${NC} $ip  W:$weight  $load_display  ${GREEN}<-- NEXT${NC}"
        else
            echo -e "  ${DIM}#$rank${NC} $ip  W:$weight  $load_display"
        fi
        ((rank++))
    done <<< "$current_order"

    echo ""

    # Show best candidate
    local best
    best=$(echo "$hosts_with_load" | head -1 | awk '{print $1}')
    local first
    first=$(echo "$current_order" | head -1)

    if [[ "$best" != "$first" ]]; then
        echo -e "${YELLOW}Note: $best has lower load and should be first${NC}"
        echo -e "${DIM}Run './load-balancer.sh balance' to reorder${NC}"
    fi
}

# ============================================================================
# DAEMON FUNCTIONS
# ============================================================================

daemon_loop() {
    log_info "Load balancer daemon started (PID: $$)"
    log_info "Mode: Load-aware balancing"
    log_info "Check interval: ${CHECK_INTERVAL}s"

    local last_order=""

    while true; do
        sleep "$CHECK_INTERVAL"

        # Clear cache before each cycle
        RFFMPEG_STATUS_CACHE=""

        # Reorder hosts based on current load
        if reorder_by_load "$JELLYFIN_CONTAINER" "true"; then
            # Log if order changed (cache is now populated by reorder_by_load)
            local current_order
            current_order=$(echo "$RFFMPEG_STATUS_CACHE" | \
                tail -n +2 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -t' ' -k3 -n | awk '{print $1}' | tr '\n' ' ')

            if [[ "$current_order" != "$last_order" ]] && [[ -n "$last_order" ]]; then
                log_info "Host order changed: $current_order"
            fi
            last_order="$current_order"
        fi
    done
}

start_daemon() {
    # Check prerequisites
    check_docker || exit 1
    check_container || exit 1

    # Check if already running
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo -e "${YELLOW}Load balancer already running (PID: $old_pid)${NC}"
            return 1
        else
            rm -f "$PID_FILE"
        fi
    fi

    # Refresh cache and check host count (filter to only IP addresses)
    refresh_rffmpeg_cache "$JELLYFIN_CONTAINER"
    local host_count
    host_count=$(echo "$RFFMPEG_STATUS_CACHE" | tail -n +2 | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "0")
    if [[ "$host_count" -lt 2 ]]; then
        echo -e "${YELLOW}Warning: Only $host_count host(s) configured. Load balancing requires at least 2 hosts.${NC}"
        echo -e "${DIM}Add more nodes with: ./add-node.sh${NC}"
        return 1
    fi

    # Get mac_user for SSH
    local mac_user
    mac_user=$(get_mac_user)
    if [[ -z "$mac_user" ]]; then
        echo -e "${YELLOW}Warning: mac_user not found in config, using current user${NC}"
        mac_user=$(whoami)
    fi

    echo -e "${CYAN}Starting Transcodarr Load Balancer...${NC}"
    echo -e "  Mode: ${GREEN}Load-aware${NC} (monitors active transcodes per node)"
    echo -e "  Interval: ${CHECK_INTERVAL}s"
    echo -e "  Hosts: $host_count"
    echo ""

    # Start daemon in background
    nohup bash -c "
        source '$SCRIPT_DIR/lib/state.sh' 2>/dev/null || true

        $(declare -f log log_info log_debug log_error)
        $(declare -f get_mac_user get_node_load calculate_load_score)
        $(declare -f get_hosts_with_load reorder_by_load daemon_loop)

        JELLYFIN_CONTAINER='$JELLYFIN_CONTAINER'
        CHECK_INTERVAL='$CHECK_INTERVAL'
        LOG_FILE='$LOG_FILE'
        HOME='$HOME'

        daemon_loop
    " >> "$LOG_FILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$PID_FILE"

    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${GREEN}Load balancer started successfully${NC}"
        echo -e "  PID: $pid"
        echo -e "  Log: $LOG_FILE"
        echo ""
        show_hosts
    else
        echo -e "${RED}Failed to start load balancer${NC}"
        echo -e "${DIM}Check $LOG_FILE for errors${NC}"
        rm -f "$PID_FILE"
        return 1
    fi
}

stop_daemon() {
    if [[ ! -f "$PID_FILE" ]]; then
        echo -e "${YELLOW}Load balancer is not running${NC}"
        return 1
    fi

    local pid
    pid=$(cat "$PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${CYAN}Stopping load balancer (PID: $pid)...${NC}"
        kill "$pid"
        sleep 1

        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${YELLOW}Process still running, sending SIGKILL...${NC}"
            kill -9 "$pid" 2>/dev/null
        fi

        rm -f "$PID_FILE"
        echo -e "${GREEN}Load balancer stopped${NC}"
    else
        echo -e "${YELLOW}Load balancer process not found (stale PID file)${NC}"
        rm -f "$PID_FILE"
    fi
}

show_status() {
    echo -e "${CYAN}${BOLD}Transcodarr Load Balancer Status${NC}"
    echo ""

    # Daemon status
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  Daemon: ${GREEN}Running${NC} (PID: $pid)"
            echo -e "  Mode: ${GREEN}Load-aware${NC}"
        else
            echo -e "  Daemon: ${RED}Stopped${NC} (stale PID file)"
        fi
    else
        echo -e "  Daemon: ${DIM}Not running${NC}"
    fi

    # Container status
    if check_container 2>/dev/null; then
        echo -e "  Container: ${GREEN}$JELLYFIN_CONTAINER${NC}"
    else
        echo -e "  Container: ${RED}Not found${NC}"
        return 1
    fi

    echo ""

    # Show hosts with load
    show_hosts 2>/dev/null || true

    # Show recent log entries
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${CYAN}Recent log entries:${NC}"
        tail -5 "$LOG_FILE" 2>/dev/null | while read -r line; do
            echo -e "  ${DIM}$line${NC}"
        done
        echo ""
    fi
}

# ============================================================================
# MAIN
# ============================================================================

usage() {
    echo "Transcodarr Load Balancer (Load-Aware)"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  start    Start the load balancer daemon"
    echo "  stop     Stop the daemon"
    echo "  status   Show daemon and host status with current loads"
    echo "  balance  Manually rebalance hosts based on current load"
    echo "  show     Show current host order with loads"
    echo "  logs     Show daemon logs"
    echo ""
    echo "How it works:"
    echo "  - Monitors ffmpeg process count on each Mac node"
    echo "  - Calculates load score: transcodes / weight"
    echo "  - Reorders hosts so least-loaded node is selected first"
    echo "  - Higher weight = can handle more concurrent transcodes"
    echo ""
    echo "Environment:"
    echo "  JELLYFIN_CONTAINER  Container name (default: jellyfin)"
    echo "  CHECK_INTERVAL      Check interval in seconds (default: 3)"
    echo ""
}

main() {
    local cmd="${1:-status}"

    case "$cmd" in
        start)
            start_daemon
            ;;
        stop)
            stop_daemon
            ;;
        status)
            show_status
            ;;
        balance)
            check_docker || exit 1
            check_container || exit 1
            reorder_by_load "$JELLYFIN_CONTAINER" "false"
            echo ""
            show_hosts
            ;;
        show)
            check_docker || exit 1
            check_container || exit 1
            show_hosts "$JELLYFIN_CONTAINER"
            ;;
        logs)
            if [[ -f "$LOG_FILE" ]]; then
                tail -50 "$LOG_FILE"
            else
                echo "No log file found"
            fi
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $cmd${NC}"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
