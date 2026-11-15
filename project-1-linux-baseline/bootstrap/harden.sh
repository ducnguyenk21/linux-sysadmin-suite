#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Vui long chay script voi quyen root (sudo)." >&2
    exit 1
fi

ADMIN_USER="nguyen"
export DEBIAN_FRONTEND=noninteractive

echo "[1/7] Cap nhat ban va he thong (non-interactive) va cai dat goi kiem toan..."
apt-get update -qq
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade -y -qq
apt-get install -y -qq ufw fail2ban auditd libpam-tmpdir libpam-pwquality unattended-upgrades \
    acct sysstat debsums apt-listchanges apt-show-versions rkhunter

if [[ -f /etc/default/sysstat ]]; then
    sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
fi
systemctl enable --now auditd acct sysstat >/dev/null 2>&1

echo "[2/7] Kiem tra user, Sudo NOPASSWD va chinh sach mat khau CIS..."
if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${ADMIN_USER}"
fi
echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-admin-${ADMIN_USER}"
chmod 0440 "/etc/sudoers.d/99-admin-${ADMIN_USER}"
visudo -cf "/etc/sudoers.d/99-admin-${ADMIN_USER}" >/dev/null

sed -i 's/^UMASK.*/UMASK           027/' /etc/login.defs
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   7/' /etc/login.defs
grep -q '^SHA_CRYPT_MIN_ROUNDS' /etc/login.defs || echo 'SHA_CRYPT_MIN_ROUNDS 5000' >> /etc/login.defs
grep -q '^SHA_CRYPT_MAX_ROUNDS' /etc/login.defs || echo 'SHA_CRYPT_MAX_ROUNDS 10000' >> /etc/login.defs
grep -q '^\* hard core 0' /etc/security/limits.conf || echo '* hard core 0' >> /etc/security/limits.conf

echo "[3/7] Khoa an ninh SSH Daemon (00-hardening.conf)..."
cat << 'EOF' > /etc/ssh/sshd_config.d/00-hardening.conf
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 2
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
TCPKeepAlive no
Compression no
UseDNS no
LogLevel VERBOSE
Banner /etc/issue.net
EOF
chmod 0600 /etc/ssh/sshd_config
sshd -t
systemctl reload ssh

echo "[4/7] Tinh chinh bao mat nhan Linux (sysctl)..."
cat << 'EOF' > /etc/sysctl.d/99-hardening.conf
net.ipv4.ip_forward = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
dev.tty.ldisc_autoload = 0
EOF
sysctl --system >/dev/null

echo "[5/7] Vo hieu hoa Kernel Modules va giao thuc khong su dung..."
cat << 'EOF' > /etc/modprobe.d/99-hardening.conf
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install udf /bin/true
install usb-storage /bin/true
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
EOF

echo "[6/7] Thiet lap tuong lua UFW, IPS Fail2ban & Auditd Rules..."
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH Management' >/dev/null
ufw allow 80/tcp comment 'Nginx HTTP' >/dev/null
ufw allow 443/tcp comment 'Nginx HTTPS' >/dev/null
ufw --force enable >/dev/null

cp --update=none /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
cat << 'EOF' > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled = true
port = 22
filter = sshd
backend = systemd
journalmatch = _COMM=sshd
maxretry = 5
findtime = 600
bantime = 600
ignoreip = 127.0.0.1/8 ::1 192.168.56.1
EOF

cat << 'EOF' > /etc/fail2ban/filter.d/sshd.local
[Definition]
failregex = ^Connection closed by authenticating user \S+ <HOST> port \d+ \[preauth\]$
            ^Invalid user \S+ from <HOST> port \d+$
            ^Failed (?:password|publickey) for (?:invalid user )?\S+ from <HOST> port \d+.*$
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban

cat << 'EOF' > /etc/audit/rules.d/99-hardening.rules
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
EOF
augenrules --load >/dev/null 2>&1 || true

echo "[7/7] Thiet lap Legal Banner & siet quyen thu muc Cron..."
echo "Authorized access only. All activity may be monitored and reported." > /etc/issue
echo "Authorized access only. All activity may be monitored and reported." > /etc/issue.net
chmod 0600 /etc/crontab
for dir in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d; do
    if [[ -d "${dir}" ]]; then
        chmod 0700 "${dir}"
    fi
done

echo "[DONE] Hoan tat hardening he thong chuan Idempotent."
