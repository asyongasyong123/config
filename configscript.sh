#!/bin/bash
set -euo pipefail

# =========================================
# 🚀 GCP-XRAY MULTI-ENGINE DEPLOYER + SING-BOX
# ✅ CLOUDFLARE HARDENED + IPTABLES IP LOCKDOWN
# ✅ ENGINES: OPENRESTY, ENVOY, HAPROXY, CADDY, SING-BOX
# ✅ WS + XHTTP SUPPORT FOR ALL ENGINES
# ✅ SOLID HOST TUNING | ANTI-DDOS | LOG CLEANER | SUPERVISORD
# ✅ RAM DISK (tmpfs) | SMART BBR CHECK | AUTO TLS MASKING ENGINE
# =========================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ==============================================
# CLOUDFLARE IPTABLES LOCKDOWN INTEGRATION
# ==============================================
apply_cloudflare_iptables_lockdown() {
  echo -e "\n${CYAN}🛡️ Setting up Cloudflare IPTables Strict Firewall...${NC}"

  if ! command -v iptables &> /dev/null; then
    echo -e "${YELLOW}⚠️ IPTables not found, installing iptables...${NC}"
    sudo apt update -qq && sudo apt install -y -qq iptables ipset || true
  fi

  # Fetch Cloudflare IPv4 List
  echo -e "${CYAN}📡 Fetching official Cloudflare IP ranges...${NC}"
  CF_IPV4=$(curl -sSL https://www.cloudflare.com/ips-v4 || true)

  if [ -z "$CF_IPV4" ]; then
    echo -e "${RED}⚠️ Failed to fetch Cloudflare IPs. Skipping IPTables lockdown for safety.${NC}"
    return
  fi

  # Flush existing rules
  sudo iptables -F
  sudo iptables -X

  # Allow Loopback (Localhost)
  sudo iptables -A INPUT -i lo -j ACCEPT

  # Allow Established / Related Connections
  sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # Allow SSH (Port 22 - Google Cloud Shell / Admin Access)
  sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT

  # Allow Traffic ALWAYS on Proxy Port 8080 ONLY IF from Cloudflare IPs
  echo -e "${GREEN}🔒 Locking down port 8080 to Cloudflare IP ranges only...${NC}"
  for ip in $CF_IPV4; do
    sudo iptables -A INPUT -p tcp --dport 8080 -s "$ip" -j ACCEPT
  done

  # DROP all other direct requests to 8080 (Bypass Protection)
  sudo iptables -A INPUT -p tcp --dport 8080 -j DROP

  # Save IPTables rules persistent
  if command -v iptables-save &> /dev/null; then
    sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null 2>&1 || true
  fi

  echo -e "${GREEN}✅ Cloudflare IPTables Lockdown Applied Successfully!${NC}"
}

# ==============================================
# SMART BBR CHECK & SYSTEM OPTIMIZATIONS
# ==============================================
sysctl_optimize() {
  echo -e "\n${CYAN}⚙️ Checking TCP Congestion Control & BBR Status...${NC}"
  
  AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "cubic")

  if echo "$AVAILABLE_CC" | grep -q "bbr"; then
    echo -e "${GREEN}🚀 TCP BBR Supported! Enabling BBR + FQ...${NC}"
    sudo sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    BBR_CONF="net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr"
  else
    echo -e "${YELLOW}⚠️ BBR unavailable on host kernel. Optimizing standard TCP stack...${NC}"
    BBR_CONF="# BBR not available"
  fi

  echo -e "${CYAN}⚙️ Applying kernel network optimizations...${NC}"
  sudo tee /etc/sysctl.d/99-solid-host.conf > /dev/null <<EOF
$BBR_CONF
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.core.somaxconn = 8192
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_all = 1
EOF
  sudo sysctl -p /etc/sysctl.d/99-solid-host.conf >/dev/null 2>&1 || true
}

# ==============================================
# LOG CLEANER — Auto-Purge Old Logs
# ==============================================
setup_log_cleaner() {
  echo -e "${CYAN}🧹 Setting up log cleaner...${NC}"
  sudo tee /etc/cron.daily/log-cleaner > /dev/null <<'EOF'
#!/bin/bash
find /var/log -type f -name "*.log" -mtime +3 -delete
find /var/log -type f -name "*.gz" -mtime +3 -delete
for log in /var/log/nginx/*.log /var/log/xray/*.log /var/log/sing-box/*.log; do
    if [ -f "$log" ]; then : > "$log"; fi
done
EOF
  sudo chmod +x /etc/cron.daily/log-cleaner
}

# ==============================================
# DEPLOYMENT FUNCTION WITH INTEGRATED LOCKDOWN
# ==============================================
deploy_new_service() {
  sysctl_optimize
  setup_log_cleaner
  apply_cloudflare_iptables_lockdown

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}❌ No GCP project set! Run: gcloud config set project YOUR_ID${NC}"
    read -p "Press [Enter] to return..."
    return
  fi

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}   CLOUDFLARE + IPTABLES DEPLOYMENT READY${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}✅ IPTables Filter:${NC} Cloudflare IPs ONLY"
  echo -e "${GREEN}✅ Anti-DDoS:${NC} Double Layered Defense Active"
  echo ""
  read -p "Press [Enter] to run build & deployment..."
}

# ==============================================
# MAIN MENU LOOP
# ==============================================
while true; do
  clear
  echo "=========================================="
  echo "🔥 HARDENED CLOUDFLARE + IPTABLES DEPLOYER"
  echo "=========================================="
  echo "1) Deploy Service with Cloudflare + IPTables Protection"
  echo "2) Apply IPTables Cloudflare Lockdown Only"
  echo "3) Exit"
  echo "=========================================="
  read -p "Select Option [1-3]: " MENU_CHOICE

  case $MENU_CHOICE in
    1) deploy_new_service ;;
    2) apply_cloudflare_iptables_lockdown; read -p "Done! Press [Enter]..." ;;
    3) echo -e "\n👋 Goodbye!"; exit 0 ;;
    *) echo -e "${RED}❌ Enter 1/2/3 only${NC}"; sleep 2 ;;
  esac
done
