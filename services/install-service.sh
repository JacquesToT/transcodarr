#!/bin/bash
#
# Install/Uninstall Transcodarr Load Balancer as a systemd service
# For Synology NAS and other Linux systems
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SERVICE_NAME="transcodarr-lb"
SERVICE_FILE="$SCRIPT_DIR/${SERVICE_NAME}.service"
INSTALL_PATH="/opt/transcodarr"
SYSTEMD_PATH="/etc/systemd/system"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        echo "Use: sudo $0 $*"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl &>/dev/null; then
        echo -e "${RED}Error: systemd not found${NC}"
        echo "This service installer requires systemd."
        echo ""
        echo "For manual startup, use: ./load-balancer.sh start"
        exit 1
    fi
}

install_service() {
    check_root
    check_systemd

    echo -e "${CYAN}Installing Transcodarr Load Balancer service...${NC}"

    # Create install directory
    echo -e "  Creating ${INSTALL_PATH}..."
    mkdir -p "$INSTALL_PATH"

    # Copy necessary files
    echo -e "  Copying files..."
    cp "$PROJECT_DIR/load-balancer.sh" "$INSTALL_PATH/"
    cp -r "$PROJECT_DIR/lib" "$INSTALL_PATH/"
    chmod +x "$INSTALL_PATH/load-balancer.sh"

    # Install systemd service
    echo -e "  Installing systemd service..."
    cp "$SERVICE_FILE" "$SYSTEMD_PATH/${SERVICE_NAME}.service"

    # Reload systemd
    systemctl daemon-reload

    # Enable service
    echo -e "  Enabling service..."
    systemctl enable "$SERVICE_NAME"

    echo ""
    echo -e "${GREEN}Service installed successfully!${NC}"
    echo ""
    echo "Commands:"
    echo "  systemctl start $SERVICE_NAME    - Start the service"
    echo "  systemctl stop $SERVICE_NAME     - Stop the service"
    echo "  systemctl status $SERVICE_NAME   - Check status"
    echo "  journalctl -u $SERVICE_NAME -f   - Follow logs"
    echo ""
    echo -e "${YELLOW}Start the service now? [y/N]${NC}"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        systemctl start "$SERVICE_NAME"
        echo -e "${GREEN}Service started!${NC}"
        systemctl status "$SERVICE_NAME" --no-pager
    fi
}

uninstall_service() {
    check_root
    check_systemd

    echo -e "${CYAN}Uninstalling Transcodarr Load Balancer service...${NC}"

    # Stop and disable service
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  Stopping service..."
        systemctl stop "$SERVICE_NAME"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  Disabling service..."
        systemctl disable "$SERVICE_NAME"
    fi

    # Remove service file
    if [[ -f "$SYSTEMD_PATH/${SERVICE_NAME}.service" ]]; then
        echo -e "  Removing service file..."
        rm -f "$SYSTEMD_PATH/${SERVICE_NAME}.service"
    fi

    # Reload systemd
    systemctl daemon-reload

    # Optionally remove install directory
    if [[ -d "$INSTALL_PATH" ]]; then
        echo ""
        echo -e "${YELLOW}Remove installation directory $INSTALL_PATH? [y/N]${NC}"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_PATH"
            echo -e "  Installation directory removed"
        fi
    fi

    echo ""
    echo -e "${GREEN}Service uninstalled successfully!${NC}"
}

status_service() {
    check_systemd

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "Service: ${GREEN}Running${NC}"
    else
        echo -e "Service: ${RED}Stopped${NC}"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "Enabled: ${GREEN}Yes${NC}"
    else
        echo -e "Enabled: ${YELLOW}No${NC}"
    fi

    echo ""
    systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true
}

usage() {
    echo "Transcodarr Load Balancer Service Installer"
    echo ""
    echo "Usage: sudo $0 <command>"
    echo ""
    echo "Commands:"
    echo "  install    Install and enable the systemd service"
    echo "  uninstall  Remove the systemd service"
    echo "  status     Show service status"
    echo ""
}

main() {
    local cmd="${1:-help}"

    case "$cmd" in
        install)
            install_service
            ;;
        uninstall)
            uninstall_service
            ;;
        status)
            status_service
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $cmd${NC}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
