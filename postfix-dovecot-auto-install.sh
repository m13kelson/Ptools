#!/bin/bash
# Postfix + Dovecot 完全自动化部署脚本（通用版）
# 适用于 Ubuntu 22.04/24.04
# GitHub: https://github.com/your-repo/postfix-dovecot-auto-install
# 使用方法: ./install.sh yourdomain.com

set -e

# ==================== 颜色输出 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# ==================== 显示使用说明 ====================
show_usage() {
    cat << EOF
${GREEN}======================================${NC}
Postfix + Dovecot 自动部署脚本
${GREEN}======================================${NC}

使用方法:
  $0 <domain> [timezone]

参数说明:
  domain      必填 - 你的域名（如: example.com）
  timezone    可选 - 时区（默认: Asia/Shanghai）

示例:
  $0 example.com
  $0 example.com America/New_York
  $0 example.com Europe/London

${YELLOW}注意事项:${NC}
1. 必须使用 root 用户运行
2. 仅支持 Ubuntu 22.04/24.04
3. 建议至少 1GB 内存
4. 部署完成后需要配置 DNS

${GREEN}======================================${NC}
EOF
    exit 1
}

# ==================== 参数检查 ====================
if [ $# -lt 1 ]; then
    show_usage
fi

DOMAIN=$1
TIMEZONE=${2:-"Asia/Shanghai"}
HOSTNAME="mail.$DOMAIN"

# 验证域名格式
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*\.[a-zA-Z]{2,}$ ]]; then
    error "无效的域名格式: $DOMAIN"
fi

# ==================== 显示配置信息 ====================
clear
cat << EOF
${GREEN}======================================${NC}
${GREEN}部署配置信息${NC}
${GREEN}======================================${NC}
域名:     $DOMAIN
主机名:   $HOSTNAME
时区:     $TIMEZONE
${GREEN}======================================${NC}

EOF

read -p "确认配置无误？按 Enter 继续，Ctrl+C 取消..." 

# ==================== 检查系统 ====================
log "检查系统要求..."

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then 
    error "请使用 root 用户运行此脚本"
fi

# 检查系统版本
if ! grep -q "Ubuntu" /etc/os-release; then
    error "此脚本仅支持 Ubuntu 系统"
fi

UBUNTU_VERSION=$(lsb_release -rs)
if ! [[ "$UBUNTU_VERSION" =~ ^(22\.04|24\.04) ]]; then
    warning "此脚本仅在 Ubuntu 22.04/24.04 上测试过，你的版本是 $UBUNTU_VERSION"
fi

# 检查内存
TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM" -lt 1 ]; then
    warning "内存不足 1GB（当前 ${TOTAL_MEM}GB），可能影响性能"
fi

# 检查磁盘空间
DISK_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$DISK_SPACE" -lt 10 ]; then
    warning "磁盘空间不足 10GB（剩余 ${DISK_SPACE}GB）"
fi

log "系统检查通过"

# ==================== 获取 VPS IP ====================
log "获取服务器 IP 地址..."
VPS_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipinfo.io/ip)
if [ -z "$VPS_IP" ]; then
    error "无法获取服务器 IP 地址"
fi
info "服务器 IP: $VPS_IP"

# ==================== 设置主机名 ====================
log "设置主机名为: $HOSTNAME"
hostnamectl set-hostname $HOSTNAME

cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
$VPS_IP $HOSTNAME $DOMAIN

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOF

# ==================== 预配置 Postfix ====================
log "预配置 Postfix..."
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

# ==================== 安装软件包 ====================
log "更新软件包列表..."
apt-get update

log "安装 Postfix 和 Dovecot（这可能需要几分钟）..."
apt-get install -y postfix dovecot-core dovecot-imapd dovecot-pop3d mailutils

# ==================== 停止服务（先配置再启动）====================
systemctl stop postfix dovecot 2>/dev/null || true

# ==================== 备份原配置 ====================
log "备份原始配置文件..."
cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%Y%m%d%H%M%S)
cp -r /etc/dovecot /etc/dovecot.backup.$(date +%Y%m%d%H%M%S)

# ==================== 配置 Postfix ====================
log "配置 Postfix..."

postconf -e "myhostname = $HOSTNAME"
postconf -e "mydomain = $DOMAIN"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
postconf -e "home_mailbox = Maildir/"

# SASL 认证配置
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_sasl_local_domain = \$myhostname"
postconf -e "broken_sasl_auth_clients = yes"

# 限制配置
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"
postconf -e "smtpd_relay_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"

# ==================== 配置 Dovecot ====================
log "配置 Dovecot..."

# 邮件位置配置
cat > /etc/dovecot/conf.d/10-mail.conf << 'EOF'
mail_location = maildir:~/Maildir
mail_privileged_group = mail

namespace inbox {
  inbox = yes
}

first_valid_uid = 1000
EOF

# 认证配置
cat > /etc/dovecot/conf.d/10-auth.conf << 'EOF'
disable_plaintext_auth = no
auth_mechanisms = plain login

passdb {
  driver = pam
}

userdb {
  driver = passwd
}
EOF

# 主服务配置
cat > /etc/dovecot/conf.d/10-master.conf << 'EOF'
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}

service lmtp {
  unix_listener lmtp {
  }
}

service imap {
}

service pop3 {
}

service submission-login {
  inet_listener submission {
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }

  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
  
  user = dovecot
}

service auth-worker {
  user = root
}

service dict {
  unix_listener dict {
  }
}
EOF

# SSL 配置
cat > /etc/dovecot/conf.d/10-ssl.conf << 'EOF'
ssl = yes
ssl_cert = </etc/dovecot/private/dovecot.pem
ssl_key = </etc/dovecot/private/dovecot.key
ssl_dh = </usr/share/dovecot/dh.pem
EOF

# 日志配置
cat > /etc/dovecot/conf.d/10-logging.conf << 'EOF'
log_path = /var/log/dovecot.log
info_log_path = /var/log/dovecot-info.log
debug_log_path = /var/log/dovecot-debug.log
EOF

# 协议配置
cat > /etc/dovecot/conf.d/20-imap.conf << 'EOF'
protocol imap {
  mail_plugins = $mail_plugins
  mail_max_userip_connections = 20
}
EOF

cat > /etc/dovecot/conf.d/20-pop3.conf << 'EOF'
protocol pop3 {
  mail_plugins = $mail_plugins
  pop3_uidl_format = %08Xu%08Xv
  pop3_client_workarounds = outlook-no-nuls oe-ns-eoh
}
EOF

# 创建 vmail 用户
if ! id -u vmail > /dev/null 2>&1; then
    log "创建 vmail 用户..."
    groupadd -g 5000 vmail
    useradd -g vmail -u 5000 vmail -d /var/vmail -m -s /bin/false
fi

# 设置权限
chown -R vmail:dovecot /etc/dovecot
chmod -R o-rwx /etc/dovecot

# ==================== 配置时区 ====================
log "设置时区为: $TIMEZONE"
timedatectl set-timezone $TIMEZONE

# ==================== 启动服务 ====================
log "启动服务..."
systemctl restart postfix
systemctl enable postfix

systemctl restart dovecot
systemctl enable dovecot

sleep 3

# 检查服务状态
if ! systemctl is-active --quiet postfix; then
    error "Postfix 启动失败，查看日志: journalctl -xeu postfix"
fi

if ! systemctl is-active --quiet dovecot; then
    error "Dovecot 启动失败，查看日志: journalctl -xeu dovecot"
fi

log "服务启动成功"

# ==================== 创建管理脚本 ====================
log "创建管理脚本..."

# mail-adduser 脚本
cat > /usr/local/bin/mail-adduser << ADDUSER_SCRIPT
#!/bin/bash
DOMAIN="$DOMAIN"

if [ -z "\$1" ] || [ -z "\$2" ]; then
    echo "用法: mail-adduser <用户名> <密码>"
    echo "示例: mail-adduser user1 password123"
    echo "完整邮箱: user1@\$DOMAIN"
    exit 1
fi

USERNAME=\$1
PASSWORD=\$2

# 创建系统用户
if id "\$USERNAME" &>/dev/null; then
    echo "用户 \$USERNAME 已存在"
else
    useradd -m -s /bin/bash \$USERNAME
    echo "\$USERNAME:\$PASSWORD" | chpasswd
    echo "系统用户 \$USERNAME 创建成功"
fi

# 创建 Maildir
su - \$USERNAME -c "mkdir -p ~/Maildir/{cur,new,tmp}" 2>/dev/null || true
chown -R \$USERNAME:\$USERNAME /home/\$USERNAME/Maildir

echo "================================"
echo "邮箱用户创建成功！"
echo "邮箱地址: \$USERNAME@\$DOMAIN"
echo "密码: \$PASSWORD"
echo "================================"
ADDUSER_SCRIPT

chmod +x /usr/local/bin/mail-adduser

# mail-listusers 脚本
cat > /usr/local/bin/mail-listusers << LISTUSERS_SCRIPT
#!/bin/bash
DOMAIN="$DOMAIN"

echo "================================"
echo "邮箱用户列表"
echo "================================"
for user in \$(ls /home 2>/dev/null); do
    if [ -d "/home/\$user/Maildir" ]; then
        echo "\$user@\$DOMAIN"
    fi
done
echo "================================"
LISTUSERS_SCRIPT

chmod +x /usr/local/bin/mail-listusers

# mail-deluser 脚本
cat > /usr/local/bin/mail-deluser << 'DELUSER_SCRIPT'
#!/bin/bash
if [ -z "$1" ]; then
    echo "用法: mail-deluser <用户名>"
    exit 1
fi

USERNAME=$1
userdel -r $USERNAME 2>/dev/null
echo "用户 $USERNAME 已删除"
DELUSER_SCRIPT

chmod +x /usr/local/bin/mail-deluser

# mail-status 脚本
cat > /usr/local/bin/mail-status << 'STATUS_SCRIPT'
#!/bin/bash
echo "================================"
echo "邮件服务器状态"
echo "================================"
echo ""
echo "Postfix 状态:"
systemctl status postfix --no-pager -l | head -20
echo ""
echo "Dovecot 状态:"
systemctl status dovecot --no-pager -l | head -20
echo ""
echo "邮件队列:"
mailq
echo ""
echo "监听端口:"
ss -tlnp | grep -E ':(25|587|143|993|110|995)'
echo ""
STATUS_SCRIPT

chmod +x /usr/local/bin/mail-status

# ==================== 创建测试用户 ====================
log "创建测试用户..."
mail-adduser testuser TestPass123!

# ==================== 保存部署信息 ====================
cat > /root/mail-server-info.txt << EOF
================================
邮件服务器部署信息
================================
部署时间: $(date)
域名: $DOMAIN
主机名: $HOSTNAME
VPS IP: $VPS_IP
时区: $TIMEZONE

================================
服务端口
================================
SMTP: $VPS_IP:25
SMTP Submission: $VPS_IP:587
IMAP: $VPS_IP:143
IMAPS: $VPS_IP:993
POP3: $VPS_IP:110
POP3S: $VPS_IP:995

================================
测试账号
================================
testuser@$DOMAIN / TestPass123!

================================
管理命令
================================
创建用户: mail-adduser <用户名> <密码>
列出用户: mail-listusers
删除用户: mail-deluser <用户名>
查看状态: mail-status

示例:
  mail-adduser john password123
  mail-listusers
  mail-deluser john
  mail-status

================================
DNS 配置（必须！）
================================
请在域名 $DOMAIN 的管理后台添加以下 DNS 记录：

1. A 记录:
   类型: A
   名称: mail
   值: $VPS_IP
   TTL: 3600

2. MX 记录:
   类型: MX
   名称: @
   值: mail.$DOMAIN
   优先级: 10
   TTL: 3600

3. TXT 记录（SPF - 防止邮件伪造）:
   类型: TXT
   名称: @
   值: v=spf1 mx a ip4:$VPS_IP ~all
   TTL: 3600

4. TXT 记录（DMARC - 反钓鱼）:
   类型: TXT
   名称: _dmarc
   值: v=DMARC1; p=quarantine; rua=mailto:postmaster@$DOMAIN
   TTL: 3600

5. 反向 DNS（PTR 记录）:
   在 VPS 提供商控制面板设置：
   $VPS_IP → $HOSTNAME

================================
验证 DNS 配置
================================
等待 DNS 生效后（5-30 分钟），使用以下命令验证：

dig $DOMAIN MX
dig $DOMAIN TXT
dig mail.$DOMAIN A
host $VPS_IP

或访问在线工具：
https://mxtoolbox.com/SuperTool.aspx

================================
测试发送邮件
================================
1. 命令行测试（本地用户之间）:
   echo "Test email content" | mail -s "Test Subject" testuser@$DOMAIN

2. 使用邮件客户端测试:
   SMTP: $VPS_IP:587
   用户名: testuser@$DOMAIN
   密码: TestPass123!
   安全: STARTTLS

3. 发送到外部邮箱（需先配置 DNS）:
   echo "Test" | mail -s "Test" your-email@gmail.com

================================
配置文件位置
================================
Postfix 主配置: /etc/postfix/main.cf
Dovecot 配置: /etc/dovecot/dovecot.conf
日志文件: /var/log/mail.log

================================
常见问题
================================
1. 邮件被拒收或进垃圾箱？
   - 检查 DNS 配置是否正确
   - 确保设置了 SPF、DKIM、DMARC
   - 检查 IP 是否在黑名单：https://mxtoolbox.com/blacklists.aspx

2. 无法连接到 SMTP？
   - 检查防火墙：ufw allow 25,587,143,993,110,995/tcp
   - 检查服务状态：mail-status

3. 用户无法登录？
   - 确认用户已创建：mail-listusers
   - 检查密码是否正确
   - 查看日志：tail -f /var/log/mail.log

================================
安全建议
================================
1. 启用防火墙:
   ufw allow 22/tcp
   ufw allow 25,587,143,993,110,995/tcp
   ufw enable

2. 安装 Fail2ban 防止暴力破解:
   apt-get install fail2ban
   systemctl enable fail2ban

3. 定期更新系统:
   apt-get update && apt-get upgrade

4. 配置 SSL 证书（Let's Encrypt）:
   apt-get install certbot
   certbot certonly --standalone -d $HOSTNAME

================================
更多信息
================================
GitHub: https://github.com/your-repo/postfix-dovecot-auto-install
文档: https://your-docs-url.com

需要帮助？提交 Issue 或发送邮件到：
support@$DOMAIN

================================
EOF

chmod 600 /root/mail-server-info.txt

# ==================== 显示部署完成信息 ====================
clear
cat << EOF

${GREEN}================================${NC}
${GREEN}邮件服务器部署成功！${NC}
${GREEN}================================${NC}

${BLUE}服务器信息:${NC}
  域名: $DOMAIN
  主机名: $HOSTNAME
  IP 地址: $VPS_IP
  时区: $TIMEZONE

${BLUE}服务端口:${NC}
  SMTP: $VPS_IP:25 或 587
  IMAP: $VPS_IP:143 或 993 (SSL)
  POP3: $VPS_IP:110 或 995 (SSL)

${BLUE}测试账号:${NC}
  邮箱: testuser@$DOMAIN
  密码: TestPass123!

${BLUE}管理命令:${NC}
  ${GREEN}mail-adduser${NC} user1 pass123    # 创建用户
  ${GREEN}mail-listusers${NC}                # 列出用户
  ${GREEN}mail-deluser${NC} user1            # 删除用户
  ${GREEN}mail-status${NC}                   # 查看状态

${YELLOW}重要：配置 DNS（必须完成！）${NC}
在域名 $DOMAIN 的管理后台添加：

  1. ${GREEN}A 记录${NC}:    mail.$DOMAIN → $VPS_IP
  2. ${GREEN}MX 记录${NC}:   @ → 10 mail.$DOMAIN
  3. ${GREEN}TXT 记录${NC}:  @ → v=spf1 mx a ip4:$VPS_IP ~all

${BLUE}详细信息:${NC}
  查看完整配置: ${GREEN}cat /root/mail-server-info.txt${NC}
  查看服务状态: ${GREEN}mail-status${NC}

${GREEN}================================${NC}
${GREEN}部署完成！${NC}
${GREEN}================================${NC}

EOF

log "所有信息已保存到: /root/mail-server-info.txt"
log "部署完成！请配置 DNS 后即可开始使用。"
