#!/bin/bash

# Mailcow Management Script
# Usage: ./mailcow.sh [check|config|install|uninstall]

set +e
set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Result counters
PASS=0
FAIL=0
WARN=0

# Show usage
show_usage() {
    echo -e "${BLUE}Mailcow Management Script${NC}"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  check                          - Check system environment"
    echo "  config <hostname> <timezone>   - Generate mailcow configuration"
    echo "  install                        - Install mailcow"
    echo "  uninstall                      - Uninstall mailcow"
    echo ""
    echo "Examples:"
    echo "  $0 check"
    echo "  $0 config mail.example.com Asia/Shanghai"
    echo "  $0 install"
    echo "  $0 uninstall"
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
    DISK_AVAIL=$(df / 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    DISK_AVAIL_GB=$((DISK_AVAIL / 1024 / 1024))

    if [ "$DISK_AVAIL_GB" -ge 20 ] 2>/dev/null; then
        check_result "PASS" "Available: ${DISK_AVAIL_GB}GB (Minimum: 20GB)"
    else
        check_result "FAIL" "Available: ${DISK_AVAIL_GB}GB (Minimum: 20GB required)"
    fi
    echo ""

    # 7. Port Check
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
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        check_result "WARN" "firewalld is active (May cause issues with Docker)"
    elif systemctl is-active --quiet ufw 2>/dev/null; then
        check_result "WARN" "ufw is active (May cause issues with Docker)"
    else
        check_result "PASS" "No conflicting firewall detected"
    fi
    echo ""

    # 9. Time Sync Check
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
            
            # Check for SWAP warning
            SWAP_KB=$(grep SwapTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
            SWAP_GB=$((SWAP_KB / 1024 / 1024))
            if [ "$SWAP_GB" -lt 1 ] 2>/dev/null; then
                echo -e "- Add SWAP space: ${BLUE}fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile${NC}"
            fi
        fi
        return 0
    else
        echo -e "${RED}✗ System does not meet all requirements${NC}"
        echo ""
        
        # Build fix command
        FIX_CMD=""
        
        # Check for NTP issue
        if command -v timedatectl &> /dev/null; then
            NTP_STATUS=$(timedatectl status 2>/dev/null | grep "NTP" | tail -1 || echo "")
            if ! echo "$NTP_STATUS" | grep -q "yes" 2>/dev/null; then
                FIX_CMD="${FIX_CMD}timedatectl set-ntp true && "
            fi
        fi
        
        # Check for Docker Compose
        if command -v docker &> /dev/null; then
            if ! docker compose version &> /dev/null; then
                FIX_CMD="${FIX_CMD}apt-get update && apt-get install -y docker-compose-plugin && "
            fi
        else
            FIX_CMD="${FIX_CMD}curl -fsSL https://get.docker.com | bash && "
        fi
        
        # Remove trailing " && "
        FIX_CMD="${FIX_CMD% && }"
        
        if [ -n "$FIX_CMD" ]; then
            echo -e "${YELLOW}Quick Fix:${NC}"
            echo -e "${BLUE}${FIX_CMD}${NC}"
        fi
        return 1
    fi
}

# Config function - Generate mailcow.conf without interaction
generate_config() {
    local MAILCOW_HOSTNAME=$1
    local MAILCOW_TZ=$2
    local INSTALL_DIR="/opt/mailcow-dockerized"
    
    # Validate hostname
    if [ -z "$MAILCOW_HOSTNAME" ]; then
        echo -e "${RED}Error: Hostname is required${NC}"
        exit 1
    fi
    
    DOTS=${MAILCOW_HOSTNAME//[^.]};
    if [ ${#DOTS} -lt 1 ]; then
        echo -e "${RED}Error: MAILCOW_HOSTNAME ($MAILCOW_HOSTNAME) is not a FQDN!${NC}"
        exit 1
    elif [[ "${MAILCOW_HOSTNAME: -1}" == "." ]]; then
        echo -e "${RED}Error: MAILCOW_HOSTNAME ($MAILCOW_HOSTNAME) is ending with a dot!${NC}"
        exit 1
    fi
    
    # Validate timezone
    if [ -z "$MAILCOW_TZ" ]; then
        echo -e "${RED}Error: Timezone is required${NC}"
        exit 1
    fi
    
    # Check if we're in mailcow directory
    if [ -f "docker-compose.yml" ] && grep -q "mailcow" "docker-compose.yml" 2>/dev/null; then
        INSTALL_DIR="$PWD"
    elif [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}Error: Mailcow directory not found at $INSTALL_DIR${NC}"
        exit 1
    fi
    
    cd "$INSTALL_DIR" || exit 1
    
    # Backup existing config
    if [ -f mailcow.conf ]; then
        mv mailcow.conf "mailcow.conf.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
    fi
    
    # Detect memory for ClamAV decision
    MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [ "${MEM_TOTAL}" -le "2621440" ]; then
        SKIP_CLAMD=y
    else
        SKIP_CLAMD=n
    fi
    
    # Generate passwords
    DBPASS=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 2> /dev/null | head -c 28)
    DBROOT=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 2> /dev/null | head -c 28)
    REDISPASS=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 2> /dev/null | head -c 28)
    SOGO_KEY=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 2>/dev/null | head -c 16)
    
    # Detect Docker Compose version
    if docker compose version &> /dev/null; then
        COMPOSE_VERSION="native"
    else
        COMPOSE_VERSION="standalone"
    fi
    
    # Detect IPv6
    if ip -6 addr show | grep -q "inet6" && ! ip -6 addr show | grep -qE "inet6 ::1|inet6 fe80:"; then
        IPV6_BOOL="true"
    else
        IPV6_BOOL="false"
    fi
    
    cat << EOF > mailcow.conf
# ------------------------------
# mailcow web ui configuration
# ------------------------------
MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}
MAILCOW_PASS_SCHEME=BLF-CRYPT

# ------------------------------
# SQL database configuration
# ------------------------------
DBNAME=mailcow
DBUSER=mailcow
DBPASS=${DBPASS}
DBROOT=${DBROOT}

# ------------------------------
# REDIS configuration
# ------------------------------
REDISPASS=${REDISPASS}

# ------------------------------
# HTTP/S Bindings
# ------------------------------
HTTP_PORT=80
HTTP_BIND=
HTTPS_PORT=443
HTTPS_BIND=
HTTP_REDIRECT=y

# ------------------------------
# Other bindings
# ------------------------------
SMTP_PORT=25
SMTPS_PORT=465
SUBMISSION_PORT=587
IMAP_PORT=143
IMAPS_PORT=993
POP_PORT=110
POPS_PORT=995
SIEVE_PORT=4190
DOVEADM_PORT=127.0.0.1:19991
SQL_PORT=127.0.0.1:13306
REDIS_PORT=127.0.0.1:7654

# ------------------------------
# Timezone
# ------------------------------
TZ=${MAILCOW_TZ}

# ------------------------------
# Project name
# ------------------------------
COMPOSE_PROJECT_NAME=mailcowdockerized
DOCKER_COMPOSE_VERSION=${COMPOSE_VERSION}

# ------------------------------
# Additional settings
# ------------------------------
ACL_ANYONE=disallow
MAILDIR_GC_TIME=7200
ADDITIONAL_SAN=
AUTODISCOVER_SAN=y
ADDITIONAL_SERVER_NAMES=
SKIP_LETS_ENCRYPT=n
ENABLE_SSL_SNI=n
SKIP_IP_CHECK=n
SKIP_HTTP_VERIFICATION=n
SKIP_UNBOUND_HEALTHCHECK=n
SKIP_CLAMD=${SKIP_CLAMD}
SKIP_OLEFY=n
SKIP_SOGO=n
SKIP_FTS=n
FTS_HEAP=128
FTS_PROCS=1
ALLOW_ADMIN_EMAIL_LOGIN=n
USE_WATCHDOG=y
WATCHDOG_NOTIFY_BAN=n
WATCHDOG_NOTIFY_START=y
WATCHDOG_EXTERNAL_CHECKS=n
WATCHDOG_VERBOSE=n
LOG_LINES=9999
IPV4_NETWORK=172.22.1
IPV6_NETWORK=fd4d:6169:6c63:6f77::/64
MAILDIR_SUB=Maildir
SOGO_EXPIRE_SESSION=480
SOGO_URL_ENCRYPTION_KEY=${SOGO_KEY}
DOVECOT_MASTER_USER=
DOVECOT_MASTER_PASS=
WEBAUTHN_ONLY_TRUSTED_VENDORS=n
SPAMHAUS_DQS_KEY=
ENABLE_IPV6=${IPV6_BOOL}
DISABLE_NETFILTER_ISOLATION_RULE=n
EOF

    chmod 600 mailcow.conf
    ln -sf mailcow.conf .env
    
    mkdir -p data/assets/ssl data/assets/ssl-example
    
    openssl req -x509 -newkey rsa:4096 -keyout data/assets/ssl-example/key.pem \
        -out data/assets/ssl-example/cert.pem -days 365 \
        -subj "/C=US/ST=State/L=City/O=mailcow/OU=mailcow/CN=${MAILCOW_HOSTNAME}" \
        -sha256 -nodes 2>/dev/null
    
    cp -n data/assets/ssl-example/*.pem data/assets/ssl/ 2>/dev/null || true
    
    echo -e "${GREEN}✓ Configuration generated${NC}"
    echo "Hostname: $MAILCOW_HOSTNAME"
    echo "Timezone: $MAILCOW_TZ"
    echo "ClamAV: $([ "$SKIP_CLAMD" = "y" ] && echo "Disabled" || echo "Enabled")"
}

# Install function
install_mailcow() {
    local INSTALL_DIR="/opt/mailcow-dockerized"
    
    # Check if we're in mailcow directory
    if [ -f "docker-compose.yml" ] && grep -q "mailcow" "docker-compose.yml" 2>/dev/null; then
        INSTALL_DIR="$PWD"
    elif [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}Error: Mailcow directory not found at $INSTALL_DIR${NC}"
        exit 1
    fi
    
    cd "$INSTALL_DIR" || exit 1
    
    # Check if config exists
    if [ ! -f mailcow.conf ]; then
        echo -e "${RED}Error: mailcow.conf not found${NC}"
        exit 1
    fi
    
    # Check if mailcow is already running
    if docker ps --format '{{.Names}}' | grep -q "mailcow"; then
        echo -e "${YELLOW}Mailcow is already running, stopping...${NC}"
        docker compose down 2>/dev/null || docker-compose down 2>/dev/null
    fi
    
    # Pull images quietly
    echo "Pulling Docker images..."
    if docker compose version &> /dev/null; then
        docker compose pull -q
    else
        docker-compose pull -q
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to pull Docker images${NC}"
        exit 1
    fi
    
    # Start containers
    echo "Starting mailcow containers..."
    if docker compose version &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    if [ $? -eq 0 ]; then
        HOSTNAME=$(grep MAILCOW_HOSTNAME mailcow.conf | cut -d'=' -f2)
        echo -e "${GREEN}✓ Mailcow installed successfully${NC}"
        echo "Access: https://${HOSTNAME}"
        echo "Login: admin / moohoo"
        echo -e "${YELLOW}Please change the default password immediately!${NC}"
    else
        echo -e "${RED}Failed to start mailcow containers${NC}"
        exit 1
    fi
}

# Uninstall function
uninstall_mailcow() {
    local INSTALL_DIR="/opt/mailcow-dockerized"
    local FORCE=false
    
    if [[ "$1" == "-y" ]] || [[ "$1" == "--yes" ]]; then
        FORCE=true
    fi
    
    if [ -f "docker-compose.yml" ] && grep -q "mailcow" "docker-compose.yml" 2>/dev/null; then
        INSTALL_DIR="$PWD"
    elif [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}Mailcow directory not found${NC}"
        exit 0
    fi
    
    cd "$INSTALL_DIR" || exit 1
    
    if ! docker ps -a --format '{{.Names}}' | grep -q "mailcow"; then
        echo -e "${YELLOW}No mailcow containers found${NC}"
        exit 0
    fi
    
    if [ "$FORCE" != true ]; then
        echo -e "${RED}WARNING: This will remove all mailcow containers, volumes, and images!${NC}"
        echo -e "${RED}All emails and data will be permanently deleted!${NC}"
        read -p "Continue? [y/N] " -n 1 -r
        echo
        
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Uninstall cancelled"
            exit 0
        fi
    fi
    
    echo "Removing mailcow..."
    
    if docker compose version &> /dev/null; then
        docker compose down -v --rmi all --remove-orphans
    else
        docker-compose down -v --rmi all --remove-orphans
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Mailcow removed successfully${NC}"
    else
        echo -e "${RED}Failed to remove mailcow${NC}"
        exit 1
    fi
}

# Main script
if [ $# -eq 0 ]; then
    show_usage
fi

case "$1" in
    check)
        check_environment
        ;;
    config)
        if [ $# -lt 3 ]; then
            echo -e "${RED}Error: Missing arguments${NC}"
            echo "Usage: $0 config <hostname> <timezone>"
            exit 1
        fi
        generate_config "$2" "$3"
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
        show_usage
        ;;
esac
