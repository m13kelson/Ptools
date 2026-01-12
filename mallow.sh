#!/bin/bash

# Mailcow Management Script
# Usage: ./mailcow.sh [check|install|uninstall]

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Result counters
PASS=0
FAIL=0
WARN=0

# Show usage
show_usage() {
    echo -e "${BLUE}Mailcow Management Script${NC}"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  check      - Check system environment"
    echo "  install    - Install mailcow (Coming soon)"
    echo "  uninstall  - Uninstall mailcow (Coming soon)"
    echo ""
    echo "Example:"
    echo "  $0 check"
    exit 0
}

# Check functions
check_result() {
    local status=$1
    local message=$2
    if [ "$status" = "PASS" ]; then
        echo -e "${GREEN}✓${NC} $message"
        ((PASS++))
    elif [ "$status" = "FAIL" ]; then
        echo -e "${RED}✗${NC} $message"
        ((FAIL++))
    else
        echo -e "${YELLOW}⚠${NC} $message"
        ((WARN++))
    fi
}

# Environment check function
check_environment() {
    echo "======================================"
    echo "Mailcow Environment Check"
    echo "======================================"
    echo ""

    # 1. Architecture Check
    echo "[System Architecture]"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" || "$ARCH" == "aarch64" ]]; then
        check_result "PASS" "Architecture: $ARCH"
    else
        check_result "FAIL" "Architecture: $ARCH (Required: x86_64 or aarch64)"
    fi
    echo ""
    
    # 2. OS Check
    echo "[Operating System]"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="$VERSION_ID"
        
        SUPPORTED=false
        case "$ID" in
            debian)
                if [[ "${VERSION_ID%%.*}" -ge 11 ]]; then
                    SUPPORTED=true
                fi
                ;;
            ubuntu)
                if [[ "${VERSION_ID%%.*}" -ge 22 ]]; then
                    SUPPORTED=true
                fi
                ;;
            almalinux|rocky)
                if [[ "${VERSION_ID%%.*}" -ge 8 ]]; then
                    SUPPORTED=true
                fi
                ;;
            alpine)
                if [[ "${VERSION_ID%%.*}" -ge 3 ]]; then
                    SUPPORTED=true
                fi
                ;;
        esac
        
        if $SUPPORTED; then
            check_result "PASS" "OS: $OS_NAME $OS_VERSION"
        else
            check_result "WARN" "OS: $OS_NAME $OS_VERSION (Not officially supported)"
        fi
    else
        check_result "WARN" "Cannot detect OS version"
    fi
    echo ""
    
    # 3. Virtualization Check
    echo "[Virtualization]"
    VIRT_TYPE="Unknown"
    if command -v systemd-detect-virt &> /dev/null; then
        VIRT_TYPE=$(systemd-detect-virt)
    elif [ -f /proc/cpuinfo ]; then
        if grep -q "hypervisor" /proc/cpuinfo; then
            VIRT_TYPE="VM"
        fi
    fi

    case "$VIRT_TYPE" in
        kvm|vmware|hyperv|microsoft)
            check_result "PASS" "Virtualization: $VIRT_TYPE"
            ;;
        openvz|lxc)
            check_result "FAIL" "Virtualization: $VIRT_TYPE (Not supported)"
            ;;
        none)
            check_result "PASS" "Running on bare metal"
            ;;
        *)
            check_result "WARN" "Virtualization: $VIRT_TYPE"
            ;;
    esac
    echo ""

    # 4. CPU Check
    echo "[CPU]"
    CPU_COUNT=$(nproc)
    CPU_MHZ=$(lscpu | grep "CPU MHz" | awk '{print $3}' | cut -d'.' -f1)
    if [ -z "$CPU_MHZ" ]; then
        CPU_MHZ=$(lscpu | grep "CPU max MHz" | awk '{print $4}' | cut -d'.' -f1)
    fi

    if [ -n "$CPU_MHZ" ] && [ "$CPU_MHZ" -ge 1000 ]; then
        check_result "PASS" "CPU: ${CPU_COUNT} cores @ ${CPU_MHZ}MHz"
    else
        check_result "PASS" "CPU: ${CPU_COUNT} cores"
    fi
    echo ""

    # 5. RAM Check
    echo "[Memory]"
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
    SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    SWAP_GB=$((SWAP_KB / 1024 / 1024))

    if [ "$TOTAL_RAM_GB" -ge 6 ]; then
        check_result "PASS" "RAM: ${TOTAL_RAM_GB}GB (Minimum: 6GB)"
    else
        check_result "FAIL" "RAM: ${TOTAL_RAM_GB}GB (Minimum: 6GB required)"
    fi

    if [ "$SWAP_GB" -ge 1 ]; then
        check_result "PASS" "SWAP: ${SWAP_GB}GB"
    else
        check_result "WARN" "SWAP: ${SWAP_GB}GB (Recommended: 1GB+)"
    fi
    echo ""

    # 6. Disk Space Check
    echo "[Disk Space]"
    DISK_AVAIL=$(df / | tail -1 | awk '{print $4}')
    DISK_AVAIL_GB=$((DISK_AVAIL / 1024 / 1024))

    if [ "$DISK_AVAIL_GB" -ge 20 ]; then
        check_result "PASS" "Available: ${DISK_AVAIL_GB}GB (Minimum: 20GB)"
    else
        check_result "FAIL" "Available: ${DISK_AVAIL_GB}GB (Minimum: 20GB required)"
    fi
    echo ""

    # 7. Port Check
    echo "[Port Availability]"
    REQUIRED_PORTS=(25 80 110 143 443 465 587 993 995 4190)
    for PORT in "${REQUIRED_PORTS[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":$PORT " || netstat -tlnp 2>/dev/null | grep -q ":$PORT "; then
            check_result "FAIL" "Port $PORT is already in use"
        else
            check_result "PASS" "Port $PORT is available"
        fi
    done
    echo ""

    # 8. Firewall Check
    echo "[Firewall]"
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        check_result "WARN" "firewalld is active (May cause issues with Docker)"
    elif systemctl is-active --quiet ufw 2>/dev/null; then
        check_result "WARN" "ufw is active (May cause issues with Docker)"
    else
        check_result "PASS" "No conflicting firewall detected"
    fi
    echo ""

    # 9. Time Sync Check
    echo "[Date and Time]"
    if command -v timedatectl &> /dev/null; then
        NTP_STATUS=$(timedatectl status | grep "NTP" | tail -1)
        if echo "$NTP_STATUS" | grep -q "yes"; then
            check_result "PASS" "NTP synchronized"
        else
            check_result "FAIL" "NTP not synchronized"
        fi
        
        TIMEZONE=$(timedatectl | grep "Time zone" | awk '{print $3}')
        check_result "PASS" "Timezone: $TIMEZONE"
    else
        check_result "WARN" "Cannot check NTP status (timedatectl not found)"
    fi
    echo ""

    # 10. Docker Check
    echo "[Docker]"
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
        check_result "PASS" "Docker installed: $DOCKER_VERSION"
        
        if docker compose version &> /dev/null; then
            COMPOSE_VERSION=$(docker compose version --short)
            check_result "PASS" "Docker Compose installed: $COMPOSE_VERSION"
        else
            check_result "FAIL" "Docker Compose not found"
        fi
    else
        check_result "FAIL" "Docker not installed"
    fi
    echo ""

    # 11. MTU Check
    echo "[Network MTU]"
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$DEFAULT_IFACE" ]; then
        MTU=$(ip link show "$DEFAULT_IFACE" | grep mtu | awk '{print $5}')
        if [ "$MTU" != "1500" ]; then
            check_result "WARN" "MTU: $MTU on $DEFAULT_IFACE (Standard: 1500, may need adjustment)"
        else
            check_result "PASS" "MTU: $MTU on $DEFAULT_IFACE"
        fi
    fi
    echo ""

    # Summary
    echo "======================================"
    echo "Summary"
    echo "======================================"
    echo -e "${GREEN}Passed:${NC}  $PASS"
    echo -e "${YELLOW}Warnings:${NC} $WARN"
    echo -e "${RED}Failed:${NC}  $FAIL"
    echo ""

    if [ "$FAIL" -eq 0 ]; then
        echo -e "${GREEN}✓ System meets mailcow requirements${NC}"
        return 0
    else
        echo -e "${RED}✗ System does not meet all requirements${NC}"
        echo "Please fix the failed checks before installing mailcow"
        return 1
    fi
}

# Install function
install_mailcow() {
    echo -e "${YELLOW}Install feature coming soon...${NC}"
    exit 0
}

# Uninstall function
uninstall_mailcow() {
    echo -e "${YELLOW}Uninstall feature coming soon...${NC}"
    exit 0
}

# Main script
if [ $# -eq 0 ]; then
    show_usage
fi

case "$1" in
    check)
        check_environment
        ;;
    install)
        install_mailcow
        ;;
    uninstall)
        uninstall_mailcow
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$1'${NC}"
        echo ""
        show_usage
        ;;
esac
