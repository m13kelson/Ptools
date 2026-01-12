#!/bin/bash

# Mailcow Management Script
# Usage: ./mailcow.sh [check|install|uninstall]

# Disable errexit to prevent early exit on command failures
set +e
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
        set +u
        . /etc/os-release
        set -u
        OS_NAME="${NAME:-Unknown}"
        OS_VERSION="${VERSION_ID:-Unknown}"
        
        SUPPORTED=false
        case "${ID:-unknown}" in
            debian)
                VERSION_MAJOR="${VERSION_ID%%.*}"
                if [ -n "$VERSION_MAJOR" ] && [ "$VERSION_MAJOR" -ge 11 ] 2>/dev/null; then
                    SUPPORTED=true
                fi
                ;;
            ubuntu)
                VERSION_MAJOR="${VERSION_ID%%.*}"
                if [ -n "$VERSION_MAJOR" ] && [ "$VERSION_MAJOR" -ge 22 ] 2>/dev/null; then
                    SUPPORTED=true
                fi
                ;;
            almalinux|rocky)
                VERSION_MAJOR="${VERSION_ID%%.*}"
                if [ -n "$VERSION_MAJOR" ] && [ "$VERSION_MAJOR" -ge 8 ] 2>/dev/null; then
                    SUPPORTED=true
                fi
                ;;
            alpine)
                VERSION_MAJOR="${VERSION_ID%%.*}"
                if [ -n "$VERSION_MAJOR" ] && [ "$VERSION_MAJOR" -ge 3 ] 2>/dev/null; then
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
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "Unknown")
    elif [ -f /proc/cpuinfo ]; then
        if grep -q "hypervisor" /proc/cpuinfo 2>/dev/null; then
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
    CPU_COUNT=$(nproc 2>/dev/null || echo "1")
    CPU_MHZ=$(lscpu 2>/dev/null | grep "CPU MHz" | awk '{print $3}' | cut -d'.' -f1 || echo "")
    if [ -z "$CPU_MHZ" ]; then
        CPU_MHZ=$(lscpu 2>/dev/null | grep "CPU max MHz" | awk '{print $4}' | cut -d'.' -f1 || echo "")
    fi

    if [ -n "$CPU_MHZ" ] && [ "$CPU_MHZ" -ge 1000 ] 2>/dev/null; then
        check_result "PASS" "CPU: ${CPU_COUNT} cores @ ${CPU_MHZ}MHz"
    else
        check_result "PASS" "CPU: ${CPU_COUNT} cores"
    fi
    echo ""

    # 5. RAM Check
    echo "[Memory]"
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
    SWAP_KB=$(grep SwapTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    SWAP_GB=$((SWAP_KB / 1024 / 1024))

    if [ "$TOTAL_RAM_GB" -ge 6 ] 2>/dev/null; then
        check_result "PASS" "RAM: ${TOTAL_RAM_GB}GB (Minimum: 6GB)"
    else
        check_result "FAIL" "RAM: ${TOTAL_RAM_GB}GB (Minimum: 6GB required)"
    fi

    if [ "$SWAP_GB" -ge 1 ] 2>/dev/null; then
        check_result "PASS" "SWAP: ${SWAP_GB}GB"
    else
        check_result "WARN" "SWAP: ${SWAP_GB}GB (Recommended: 1GB+)"
    fi
    echo ""

    # 6. Disk Space Check
    echo "[Disk Space]"
    DISK_AVAIL=$(df / 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    DISK_AVAIL_GB=$((DISK_AVAIL / 1024 / 1024))

    if [ "$DISK_AVAIL_GB" -ge 20 ] 2>/dev/null; then
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
        NTP_STATUS=$(timedatectl status 2>/dev/null | grep "NTP" | tail -1 || echo "")
        if echo "$NTP_STATUS" | grep -q "yes" 2>/dev/null; then
            check_result "PASS" "NTP synchronized"
        else
            check_result "FAIL" "NTP not synchronized"
        fi
        
        TIMEZONE=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' || echo "Unknown")
        check_result "PASS" "Timezone: $TIMEZONE"
    else
        check_result "WARN" "Cannot check NTP status (timedatectl not found)"
    fi
    echo ""

    # 10. Docker Check
    echo "[Docker]"
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//' || echo "Unknown")
        check_result "PASS" "Docker installed: $DOCKER_VERSION"
        
        if docker compose version &> /dev/null; then
            COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "Unknown")
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
    if command -v ip &> /dev/null; then
        DEFAULT_IFACE=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1 || echo "")
        if [ -n "$DEFAULT_IFACE" ]; then
            MTU=$(ip link show "$DEFAULT_IFACE" 2>/dev/null | grep mtu | awk '{print $5}' || echo "")
            if [ -n "$MTU" ] && [ "$MTU" != "1500" ] 2>/dev/null; then
                check_result "WARN" "MTU: $MTU on $DEFAULT_IFACE (Standard: 1500, may need adjustment)"
            elif [ -n "$MTU" ]; then
                check_result "PASS" "MTU: $MTU on $DEFAULT_IFACE"
            fi
        fi
    else
        check_result "WARN" "Cannot check MTU (ip command not found)"
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
        
        # Check for warnings and provide suggestions
        if [ "$WARN" -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}Optional Improvements:${NC}"
            echo "======================================"
            
            # Check for SWAP warning
            SWAP_KB=$(grep SwapTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
            SWAP_GB=$((SWAP_KB / 1024 / 1024))
            if [ "$SWAP_GB" -lt 1 ] 2>/dev/null; then
                echo -e "- Add SWAP space (Recommended: 2GB+):\n"
                echo -e "${BLUE}fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab${NC}"
                echo ""
            fi
            
            echo "======================================"
        fi
        return 0
    else
        echo -e "${RED}✗ System does not meet all requirements${NC}"
        echo ""
        
        # Build fix command
        FIX_CMD=""
        FIX_DESC=""
        
        # Check for NTP issue
        if command -v timedatectl &> /dev/null; then
            NTP_STATUS=$(timedatectl status 2>/dev/null | grep "NTP" | tail -1 || echo "")
            if ! echo "$NTP_STATUS" | grep -q "yes" 2>/dev/null; then
                FIX_CMD="${FIX_CMD}timedatectl set-ntp true && systemctl restart systemd-timesyncd && "
                FIX_DESC="${FIX_DESC}- Enable NTP time sync\n"
            fi
        fi
        
        # Check for Docker Compose
        if command -v docker &> /dev/null; then
            if ! docker compose version &> /dev/null; then
                FIX_CMD="${FIX_CMD}apt-get update && apt-get install -y docker-compose-plugin && "
                FIX_DESC="${FIX_DESC}- Install Docker Compose Plugin\n"
            fi
        else
            # Docker not installed
            FIX_CMD="${FIX_CMD}curl -fsSL https://get.docker.com | bash && "
            FIX_DESC="${FIX_DESC}- Install Docker & Docker Compose\n"
        fi
        
        # Remove trailing " && "
        FIX_CMD="${FIX_CMD% && }"
        
        if [ -n "$FIX_CMD" ]; then
            echo -e "${YELLOW}Quick Fix:${NC}"
            echo "======================================"
            echo -e "$FIX_DESC"
            echo -e "${BLUE}${FIX_CMD}${NC}"
            echo "======================================"
        else
            echo "No automatic fix available"
        fi
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
