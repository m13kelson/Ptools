#!/bin/bash

################################################################################
# 邮件服务器自动部署脚本
# 功能：检测安装状态 -> 强制安装 -> 验证服务 -> 输出状态
################################################################################

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 获取参数
DOMAIN="${1:-$(hostname -d)}"
HOSTNAME="${2:-$(hostname -f)}"

# 如果域名为空，使用 example.com
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "localdomain" ]; then
    DOMAIN="example.com"
fi

# 如果主机名为空，使用 mail.example.com
if [ -z "$HOSTNAME" ] || [ "$HOSTNAME" = "localhost" ]; then
    HOSTNAME="mail.${DOMAIN}"
fi

################################################################################
# 函数：打印标题
################################################################################
print_header() {
    echo -e "${BLUE}=========================================="
    echo -e "$1"
    echo -e "==========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

################################################################################
# 步骤 1：检测是否已安装
################################################################################
check_installation() {
    print_header "步骤 1/7：检测邮件服务器安装状态"
    
    local postfix_installed=false
    local dovecot_installed=false
    local postfix_running=false
    local dovecot_running=false
    
    # 检查 Postfix 是否安装
    if dpkg -l | grep -q "^ii.*postfix"; then
        postfix_installed=true
        print_warning "检测到 Postfix 已安装"
    fi
    
    # 检查 Dovecot 是否安装
    if dpkg -l | grep -q "^ii.*dovecot-core"; then
        dovecot_installed=true
        print_warning "检测到 Dovecot 已安装"
    fi
    
    # 检查服务是否运行
    if systemctl is-active --quiet postfix 2>/dev/null; then
        postfix_running=true
        print_warning "Postfix 服务正在运行"
    fi
    
    if systemctl is-active --quiet dovecot 2>/dev/null; then
        dovecot_running=true
        print_warning "Dovecot 服务正在运行"
    fi
    
    # 如果已完整安装且运行正常
    if [ "$postfix_installed" = true ] && [ "$dovecot_installed" = true ] && \
       [ "$postfix_running" = true ] && [ "$dovecot_running" = true ]; then
        
        print_error "邮件服务器已安装并正在运行！"
        echo ""
        echo "当前服务状态："
        systemctl status postfix --no-pager -l | head -10
        echo ""
        systemctl status dovecot --no-pager -l | head -10
        echo ""
        echo "如需重新安装，请先执行："
        echo "  1. 停止服务：systemctl stop postfix dovecot"
        echo "  2. 卸载：apt-get purge -y postfix* dovecot*"
        echo "  3. 清理：rm -rf /etc/postfix /etc/dovecot"
        echo "  4. 然后重新运行此脚本"
        echo ""
        exit 1
    fi
    
    # 如果部分安装
    if [ "$postfix_installed" = true ] || [ "$dovecot_installed" = true ]; then
        print_warning "检测到不完整的安装，将执行完整重装"
        return 0
    fi
    
    print_success "未检测到已安装的邮件服务器，开始安装"
    return 0
}

################################################################################
# 步骤 2：完全清理旧安装
################################################################################
clean_old_installation() {
    print_header "步骤 2/7：清理旧安装"
    
    echo "停止邮件服务..."
    systemctl stop postfix 2>/dev/null || true
    systemctl stop dovecot 2>/dev/null || true
    
    echo "卸载旧软件包..."
    apt-get purge -y postfix postfix-* dovecot-* mailutils 2>/dev/null || true
    
    echo "清理配置文件和数据..."
    rm -rf /etc/postfix
    rm -rf /etc/dovecot
    rm -rf /var/vmail
    rm -rf /var/spool/postfix
    rm -f /var/log/mail.*
    rm -f /root/mail-server-info.txt
    
    echo "清理残留包..."
    apt-get autoremove -y
    apt-get autoclean
    
    print_success "清理完成"
}

################################################################################
# 步骤 3：安装软件包
################################################################################
install_packages() {
    print_header "步骤 3/7：安装邮件服务器软件包"
    
    # 设置非交互模式
    export DEBIAN_FRONTEND=noninteractive
    
    # 预配置 Postfix
    echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
    echo "postfix postfix/mailname string $HOSTNAME" | debconf-set-selections
    
    echo "更新软件包列表..."
    apt-get update -qq
    
    echo "安装 Postfix, Dovecot 和相关工具..."
    apt-get install -y --no-install-recommends \
        postfix \
        postfix-pcre \
        dovecot-core \
        dovecot-imapd \
        dovecot-pop3d \
        dovecot-lmtpd \
        mailutils \
        ssl-cert \
        ca-certificates
    
    print_success "软件包安装完成"
}

################################################################################
# 步骤 4：配置 Postfix
################################################################################
configure_postfix() {
    print_header "步骤 4/7：配置 Postfix"
    
    echo "备份默认配置..."
    cp /etc/postfix/main.cf /etc/postfix/main.cf.orig
    cp /etc/postfix/master.cf /etc/postfix/master.cf.orig
    
    echo "配置 main.cf..."
    
    # 使用 postconf 进行配置（关键改进）
    postconf -e "setgid_group = postdrop"
    postconf -e "myhostname = $HOSTNAME"
    postconf -e "mydomain = $DOMAIN"
    postconf -e "myorigin = \$mydomain"
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = all"
    postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
    postconf -e "mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128"
    postconf -e "relay_domains = "
    postconf -e "home_mailbox = Maildir/"
    
    # TLS 配置
    postconf -e "smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem"
    postconf -e "smtpd_tls_key_file = /etc/ssl/private/ssl-cert-snakeoil.key"
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtp_tls_security_level = may"
    postconf -e "smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache"
    postconf -e "smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache"
    
    # SASL 认证
    postconf -e "smtpd_sasl_type = dovecot"
    postconf -e "smtpd_sasl_path = private/auth"
    postconf -e "smtpd_sasl_auth_enable = yes"
    postconf -e "smtpd_sasl_security_options = noanonymous"
    postconf -e "smtpd_sasl_local_domain = \$myhostname"
    postconf -e "broken_sasl_auth_clients = yes"
    
    # 收件人限制
    postconf -e "smtpd_recipient_restrictions = permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination"
    
    echo "配置 master.cf (启用 submission 端口)..."
    
    # 添加 submission 配置
    cat >> /etc/postfix/master.cf <<'EOF'

# Submission port (587) with authentication
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
    
    print_success "Postfix 配置完成"
}

################################################################################
# 步骤 5：配置 Dovecot
################################################################################
configure_dovecot() {
    print_header "步骤 5/7：配置 Dovecot"
    
    echo "创建虚拟邮件用户..."
    groupadd -g 5000 vmail 2>/dev/null || true
    useradd -r -u 5000 -g vmail -s /sbin/nologin -d /var/vmail -m vmail 2>/dev/null || true
    
    echo "备份默认配置..."
    if [ -f /etc/dovecot/dovecot.conf ]; then
        cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.orig
    fi
    
    echo "配置 dovecot.conf..."
    cat > /etc/dovecot/dovecot.conf <<'EOF'
# Dovecot 主配置文件
protocols = imap pop3 lmtp
listen = *, ::

# 包含其他配置文件
!include_try /usr/share/dovecot/protocols.d/*.protocol
!include conf.d/*.conf
EOF
    
    echo "配置邮件存储位置..."
    cat > /etc/dovecot/conf.d/10-mail.conf <<'EOF'
mail_location = maildir:~/Maildir
mail_privileged_group = mail
first_valid_uid = 1000
EOF
    
    echo "配置认证..."
    cat > /etc/dovecot/conf.d/10-auth.conf <<'EOF'
disable_plaintext_auth = no
auth_mechanisms = plain login

!include auth-system.conf.ext
EOF
    
    echo "配置服务和 Postfix 集成..."
    cat > /etc/dovecot/conf.d/10-master.conf <<'EOF'
service imap-login {
  inet_listener imap {
    port = 143
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
  
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
  }
  
  user = dovecot
}

service auth-worker {
  user = root
}
EOF
    
    echo "配置 SSL..."
    cat > /etc/dovecot/conf.d/10-ssl.conf <<'EOF'
ssl = yes
ssl_cert = </etc/ssl/certs/ssl-cert-snakeoil.pem
ssl_key = </etc/ssl/private/ssl-cert-snakeoil.key
ssl_prefer_server_ciphers = yes
EOF
    
    print_success "Dovecot 配置完成"
}

################################################################################
# 步骤 6：验证配置
################################################################################
verify_configuration() {
    print_header "步骤 6/7：验证配置"
    
    local config_ok=true
    
    echo "验证 Postfix 配置..."
    if postfix check 2>&1; then
        print_success "Postfix 配置验证通过"
    else
        print_error "Postfix 配置验证失败"
        config_ok=false
    fi
    
    echo "验证 Dovecot 配置..."
    if doveconf > /dev/null 2>&1; then
        print_success "Dovecot 配置验证通过"
    else
        print_error "Dovecot 配置验证失败"
        config_ok=false
    fi
    
    echo "验证关键配置项..."
    SETGID=$(postconf -h setgid_group)
    if [ -z "$SETGID" ]; then
        print_error "setgid_group 配置为空！"
        config_ok=false
    else
        print_success "setgid_group = $SETGID"
    fi
    
    INET_INTERFACES=$(postconf -h inet_interfaces)
    print_success "inet_interfaces = $INET_INTERFACES"
    
    MYHOSTNAME=$(postconf -h myhostname)
    print_success "myhostname = $MYHOSTNAME"
    
    if [ "$config_ok" = false ]; then
        print_error "配置验证失败，请检查上述错误"
        exit 1
    fi
    
    print_success "所有配置验证通过"
}

################################################################################
# 步骤 7：启动服务并验证状态
################################################################################
start_and_verify_services() {
    print_header "步骤 7/7：启动服务并验证"
    
    echo "设置服务开机自启..."
    systemctl enable postfix
    systemctl enable dovecot
    
    echo "启动 Postfix..."
    systemctl start postfix
    
    echo "启动 Dovecot..."
    systemctl start dovecot
    
    echo "等待服务启动..."
    sleep 3
    
    echo ""
    print_header "服务状态验证"
    
    local all_ok=true
    
    # 验证 Postfix 状态
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "【Postfix 服务状态】"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if systemctl is-active --quiet postfix; then
        print_success "Postfix 服务运行正常"
        systemctl status postfix --no-pager -l | head -15
    else
        print_error "Postfix 服务未运行！"
        systemctl status postfix --no-pager -l || true
        all_ok=false
    fi
    
    # 验证 Dovecot 状态
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "【Dovecot 服务状态】"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if systemctl is-active --quiet dovecot; then
        print_success "Dovecot 服务运行正常"
        systemctl status dovecot --no-pager -l | head -15
    else
        print_error "Dovecot 服务未运行！"
        systemctl status dovecot --no-pager -l || true
        all_ok=false
    fi
    
    # 验证监听端口
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "【网络端口监听状态】"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    PORTS=$(ss -lntp 2>/dev/null | grep -E "\<(25|587|143|110|993|995)\>" || true)
    
    if [ -z "$PORTS" ]; then
        print_error "未检测到任何邮件服务端口监听！"
        all_ok=false
    else
        echo "$PORTS"
        
        # 逐个检查端口
        if echo "$PORTS" | grep -q ":25 "; then
            print_success "端口 25 (SMTP) 监听正常"
        else
            print_error "端口 25 (SMTP) 未监听"
            all_ok=false
        fi
        
        if echo "$PORTS" | grep -q ":587 "; then
            print_success "端口 587 (Submission) 监听正常"
        else
            print_warning "端口 587 (Submission) 未监听"
        fi
        
        if echo "$PORTS" | grep -q ":143 "; then
            print_success "端口 143 (IMAP) 监听正常"
        else
            print_error "端口 143 (IMAP) 未监听"
            all_ok=false
        fi
        
        if echo "$PORTS" | grep -q ":110 "; then
            print_success "端口 110 (POP3) 监听正常"
        else
            print_warning "端口 110 (POP3) 未监听"
        fi
    fi
    
    # 验证邮件队列
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "【邮件队列状态】"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if mailq 2>&1 | grep -q "Mail queue is empty"; then
        print_success "邮件队列正常（空）"
    elif mailq 2>&1 | grep -qi "fatal"; then
        print_error "邮件队列检查失败："
        mailq 2>&1 || true
        all_ok=false
    else
        print_success "邮件队列可访问"
        mailq | head -10
    fi
    
    # 保存配置信息
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "【保存配置信息】"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    cat > /root/mail-server-info.txt <<INFOEOF
邮件服务器配置信息
==========================================
部署时间: $(date)
主机名: $HOSTNAME
域名: $DOMAIN

服务状态:
- Postfix: $(systemctl is-active postfix)
- Dovecot: $(systemctl is-active dovecot)

网络端口:
- SMTP: 25
- Submission: 587 (需要认证)
- IMAP: 143
- POP3: 110

配置文件:
- Postfix: /etc/postfix/
- Dovecot: /etc/dovecot/
- 邮箱目录: ~/Maildir

管理命令:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
创建系统用户（可用于邮件登录）:
  adduser username

测试发送邮件:
  echo "Test email body" | mail -s "Test Subject" user@example.com

查看邮件队列:
  mailq

刷新邮件队列:
  postqueue -f

查看实时日志:
  tail -f /var/log/mail.log

重启服务:
  systemctl restart postfix dovecot

查看服务状态:
  systemctl status postfix dovecot

测试 SMTP 连接:
  telnet localhost 25

测试 IMAP 连接:
  telnet localhost 143
  
关键配置:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
setgid_group = $(postconf -h setgid_group)
myhostname = $(postconf -h myhostname)
mydomain = $(postconf -h mydomain)
inet_interfaces = $(postconf -h inet_interfaces)
INFOEOF
    
    print_success "配置信息已保存到 /root/mail-server-info.txt"
    
    # 最终结果
    echo ""
    if [ "$all_ok" = true ]; then
        print_header "部署成功！"
        echo -e "${GREEN}"
        echo "  ███████╗██╗   ██╗ ██████╗ ██████╗███████╗███████╗███████╗"
        echo "  ██╔════╝██║   ██║██╔════╝██╔════╝██╔════╝██╔════╝██╔════╝"
        echo "  ███████╗██║   ██║██║     ██║     █████╗  ███████╗███████╗"
        echo "  ╚════██║██║   ██║██║     ██║     ██╔══╝  ╚════██║╚════██║"
        echo "  ███████║╚██████╔╝╚██████╗╚██████╗███████╗███████║███████║"
        echo "  ╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝╚══════╝╚══════╝╚══════╝"
        echo -e "${NC}"
        echo ""
        echo "✓ 所有服务运行正常"
        echo "✓ 所有端口监听正常"
        echo "✓ 配置验证通过"
        echo ""
        echo "下一步操作："
        echo "  1. 创建用户: adduser <username>"
        echo "  2. 测试邮件: echo 'test' | mail -s 'test' user@$DOMAIN"
        echo "  3. 查看信息: cat /root/mail-server-info.txt"
        echo ""
    else
        print_header "部署完成但存在问题"
        echo -e "${YELLOW}"
        echo "  ⚠️  部分服务或功能可能不正常"
        echo ""
        echo "请检查上述错误输出，常见问题："
        echo "  1. 防火墙未开放端口"
        echo "  2. 服务启动失败（查看日志）"
        echo "  3. 配置文件语法错误"
        echo ""
        echo "查看详细日志："
        echo "  journalctl -u postfix -n 50"
        echo "  journalctl -u dovecot -n 50"
        echo "  tail -f /var/log/mail.log"
        echo -e "${NC}"
    fi
}

################################################################################
# 主函数
################################################################################
main() {
    # 检查是否为 root
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    clear
    echo ""
    echo -e "${BLUE}"
    echo "  ███╗   ███╗ █████╗ ██╗██╗         ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ "
    echo "  ████╗ ████║██╔══██╗██║██║         ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗"
    echo "  ██╔████╔██║███████║██║██║         ███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝"
    echo "  ██║╚██╔╝██║██╔══██║██║██║         ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗"
    echo "  ██║ ╚═╝ ██║██║  ██║██║███████╗    ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║"
    echo "  ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝╚══════╝    ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo "  邮件服务器自动部署脚本 v1.0"
    echo "  域名: $DOMAIN"
    echo "  主机名: $HOSTNAME"
    echo ""
    
    # 执行部署流程
    check_installation
    clean_old_installation
    install_packages
    configure_postfix
    configure_dovecot
    verify_configuration
    start_and_verify_services
}

# 运行主函数
main "$@"
