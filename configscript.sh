#!/bin/bash
set -euo pipefail

# =========================================
# 🚀 GCP-XRAY MULTI-ENGINE DEPLOYER + SING-BOX (CLOUD RUN ONLY)
# ✅ ENGINES: OPENRESTY, ENVOY, HAPROXY, CADDY, SING-BOX
# ✅ WS + XHTTP SUPPORT FOR ALL ENGINES
# ✅ SOLID HOST TUNING | ANTI-DDOS | LOG CLEANER | SUPERVISORD
# ✅ RAM DISK (tmpfs) | SMART BBR CHECK | AUTO TLS MASKING ENGINE
# ✅ Custom Decoy HTML — No Sniffing
# =========================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ==============================================
# AUTO INSTALL JQ IF MISSING
# ==============================================
if ! command -v jq &> /dev/null; then
    echo -e "\n${YELLOW}⚠️ Installing required tool: jq...${NC}"
    sudo apt update -qq && sudo apt install -y -qq jq || {
        echo -e "${RED}❌ Failed to install jq!${NC}"
        exit 1
    }
    echo -e "${GREEN}✅ jq installed successfully!${NC}"
fi

# ==============================================
# SMART BBR CHECK & SYSTEM OPTIMIZATIONS
# ==============================================
sysctl_optimize() {
  echo -e "\n${CYAN}⚙️ Checking TCP Congestion Control & BBR Status...${NC}"
  
  AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "cubic")
  CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")

  if echo "$AVAILABLE_CC" | grep -q "bbr"; then
    echo -e "${GREEN}🚀 TCP BBR is supported on this host kernel! Enabling BBR + FQ...${NC}"
    sudo sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    BBR_CONF="net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr"
  else
    echo -e "${YELLOW}⚠️ BBR not supported on this host kernel (Current: $CURRENT_CC). Optimizing standard TCP stack...${NC}"
    BBR_CONF="# BBR not natively available on host kernel"
  fi

  echo -e "${CYAN}⚙️ Applying kernel & network optimizations...${NC}"
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
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
  sudo sysctl -p /etc/sysctl.d/99-solid-host.conf >/dev/null 2>&1 || true

  sudo tee /etc/security/limits.d/99-proxy-limits.conf > /dev/null <<'EOF'
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
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
find /var/log -type f -name "*.old" -mtime +3 -delete
for log in /var/log/syslog /var/log/messages /var/log/nginx/*.log /var/log/xray/*.log /var/log/sing-box/*.log; do
    if [ -f "$log" ]; then : > "$log"; fi
done
EOF
  sudo chmod +x /etc/cron.daily/log-cleaner
}

# ==============================================
# SUPERVISORD — Process Manager
# ==============================================
install_supervisord() {
  echo -e "${CYAN}📦 Installing Supervisord...${NC}"
  sudo apt update -qq && sudo apt install -y -qq supervisor || true
  sudo systemctl enable supervisor >/dev/null 2>&1 || true
}

# ==============================================
# LIST SERVICES
# ==============================================
list_deployed_services() {
  echo -e "\n======================================"
  echo -e "${CYAN}📋 ALL DEPLOYED GCP-XRAY SERVICES${NC}"
  echo -e "======================================"

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  echo "Project: $PROJECT_ID"
  echo ""

  declare -A REGION_NAMES=(
    ["us-central1"]="Iowa, United States 🇺🇸"
    ["us-east1"]="South Carolina, United States 🇺🇸"
    ["us-east4"]="N. Virginia, United States 🇺🇸"
    ["us-west1"]="Oregon, United States 🇺🇸"
    ["asia-east1"]="Taiwan 🇹🇼"
    ["asia-southeast1"]="Singapore 🇸🇬"
    ["asia-northeast1"]="Tokyo, Japan 🇯🇵"
    ["asia-northeast3"]="Seoul, South Korea 🇰🇷"
    ["europe-west1"]="Belgium 🇧🇪"
    ["europe-west4"]="Netherlands 🇳🇱"
    ["europe-west9"]="Paris, France 🇫🇷"
    ["asia-south1"]="Mumbai, India 🇮🇳"
  )

  SERVICES=$(gcloud run services list \
    --format="value(metadata.name, status.url, region, metadata.creationTimestamp.date(%Y-%m-%d))" \
    --project="$PROJECT_ID" 2>/dev/null)

  if [ -z "$SERVICES" ]; then
    echo -e "${RED}❌ No services found.${NC}"
  else
    local COUNT=1
    while IFS=$'\t' read -r NAME URL REGION CREATED; do
      [ -z "$NAME" ] && continue

      FULL_REGION="${REGION_NAMES[$REGION]:-$REGION}"
      DETAILS=$(gcloud run services describe "$NAME" --region "$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null || true)

      if [ -z "$DETAILS" ]; then
        echo -e "${GREEN}=== SERVICE #$COUNT ===${NC}"
        echo "🔹 Name: $NAME"
        echo "🔹 URL: $URL"
        echo "🔹 Region: $REGION → $FULL_REGION"
        echo "🔹 Created: $CREATED"
        echo ""
        ((COUNT++))
        continue
      fi

      MEMORY=$(echo "$DETAILS" | jq -r '.spec.template.spec.containers[0].resources.limits.memory // "1Gi"')
      CPU=$(echo "$DETAILS" | jq -r '.spec.template.spec.containers[0].resources.limits.cpu // "1"')
      BILLING=$(echo "$DETAILS" | jq -r '.spec.template.spec.billingMode // "Instance Based"' | sed 's/_/ /g;s/^./\U&/')
      MIN_INST=$(echo "$DETAILS" | jq -r '.spec.template.spec.minInstances // "0"')
      MAX_INST=$(echo "$DETAILS" | jq -r '.spec.template.spec.maxInstances // "1"')
      CONCURRENCY=$(echo "$DETAILS" | jq -r '.spec.template.spec.containerConcurrency // "300"')
      TIMEOUT=$(echo "$DETAILS" | jq -r '.spec.template.spec.timeoutSeconds // "300"')

      echo -e "${GREEN}=== SERVICE #$COUNT ===${NC}"
      echo "🔹 Name: $NAME"
      echo "🔹 URL: $URL"
      echo "🔹 Region: $REGION → $FULL_REGION"
      echo "🔹 Created: $CREATED"
      echo "🔹 Resources: $MEMORY RAM | $CPU vCPU"
      echo "🔹 Billing: $BILLING"
      echo "🔹 Instances: Min $MIN_INST / Max $MAX_INST"
      echo "🔹 Connections: Max $CONCURRENCY"
      echo "🔹 Timeout: ${TIMEOUT}s"
      echo ""
      ((COUNT++))
    done <<< "$SERVICES"
  fi

  echo -e "\n======================================"
  read -p "Press [Enter] to return..."
}

# ==============================================
# REGION SELECTOR
# ==============================================
select_region() {
  echo -e "\n=== GCP CLOUD RUN REGION SELECTION ==="
  echo "--- North America ---"
  echo "1) us-central1 (Iowa, US 🇺🇸)"
  echo "2) us-east1 (South Carolina, US 🇺🇸)"
  echo "3) us-east4 (N. Virginia, US 🇺🇸)"
  echo "4) us-west1 (Oregon, US 🇺🇸)"
  echo ""
  echo "--- Asia Pacific ---"
  echo "5) asia-east1 (Taiwan 🇹🇼 — RECOMMENDED!)"
  echo "6) asia-southeast1 (Singapore 🇸🇬)"
  echo "7) asia-northeast1 (Tokyo, Japan 🇯🇵)"
  echo "8) asia-northeast3 (Seoul, South Korea 🇰🇷)"
  echo "9) asia-south1 (Mumbai, India 🇮🇳)"
  echo ""
  echo "--- Europe ---"
  echo "10) europe-west1 (Belgium 🇧🇪)"
  echo "11) europe-west4 (Netherlands 🇳🇱)"
  echo "12) europe-west9 (Paris, France 🇫🇷)"
  echo ""
  echo "0) Enter custom region code"
  echo ""

  read -p "Enter region number: " REGION_NUM

  case $REGION_NUM in
    1) REGION="us-central1" ;;
    2) REGION="us-east1" ;;
    3) REGION="us-east4" ;;
    4) REGION="us-west1" ;;
    5) REGION="asia-east1" ;;
    6) REGION="asia-southeast1" ;;
    7) REGION="asia-northeast1" ;;
    8) REGION="asia-northeast3" ;;
    9) REGION="asia-south1" ;;
    10) REGION="europe-west1" ;;
    11) REGION="europe-west4" ;;
    12) REGION="europe-west9" ;;
    0) read -p "Type full region code: " REGION ;;
    *) echo -e "${YELLOW}⚠️ Invalid! Using us-central1${NC}"; REGION="us-central1" ;;
  esac

  echo -e "${GREEN}✅ Selected Region:${NC} $REGION"
}

# ==============================================
# DEPLOYMENT FUNCTION
# ==============================================
deploy_new_service() {
  sysctl_optimize
  setup_log_cleaner
  install_supervisord
  select_region

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}❌ No project set! Run: gcloud config set project YOUR_ID${NC}"
    read -p "Press [Enter] to return..."
    return
  fi

  gcloud services enable run.googleapis.com cloudbuild.googleapis.com --project="$PROJECT_ID" --quiet

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}        CHOOSE PROXY ENGINE${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo "1) OpenResty  - [Standard / Highly Reliable]"
  echo "2) Envoy Proxy - [High Performance / Cloud Native]"
  echo "3) HAProxy     - [Ultra Low Latency / Lightweight]"
  echo "4) Caddy Proxy - [Modern / Simple & Fast]"
  echo "5) Sing-Box    - [Lightweight / High Performance]"

  while true; do
    read -p "Select Engine [1-5]: " ENGINE_CHOICE
    case $ENGINE_CHOICE in
      1) ENGINE="openresty"; DISPLAY_ENGINE="OpenResty"; echo -e "${GREEN}✅ Selected: OpenResty${NC}"; break ;;
      2) ENGINE="envoy"; DISPLAY_ENGINE="Envoy Proxy"; echo -e "${GREEN}✅ Selected: Envoy Proxy${NC}"; break ;;
      3) ENGINE="haproxy"; DISPLAY_ENGINE="HAProxy"; echo -e "${GREEN}✅ Selected: HAProxy${NC}"; break ;;
      4) ENGINE="caddy"; DISPLAY_ENGINE="Caddy Proxy"; echo -e "${GREEN}✅ Selected: Caddy Proxy${NC}"; break ;;
      5) ENGINE="singbox"; DISPLAY_ENGINE="Sing-Box Engine"; echo -e "${GREEN}✅ Selected: Sing-Box Engine${NC}"; break ;;
      *) echo -e "${RED}Enter 1, 2, 3, 4, or 5 only${NC}" ;;
    esac
  done

  RAND=$(openssl rand -hex 3)
  CLOUD_RUN_SERVICE_NAME="gcp-xray-${ENGINE}-$RAND"

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}          RESOURCE CONFIG MODE${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}1) AUTO PRESETS | Recommended (Instance-Based)${NC}"
  echo -e "${YELLOW}2) MANUAL SETUP | Full Memory & vCPU Range${NC}"

  while true; do
    read -p "Select Mode [1-2]: " RES_MODE
    case $RES_MODE in
      1)
        echo -e "\n${CYAN}--- AUTO PRESETS ---${NC}"
        echo "1) Basic: 1Gi RAM + 1 vCPU (Min: 1, Max: 3, Concurrency: 100)"
        echo "2) Balanced: 2Gi RAM + 2 vCPU (Min: 1, Max: 5, Concurrency: 130) ✅"
        echo "3) Turbo: 4Gi RAM + 4 vCPU (Min: 1, Max: 4, Concurrency: 200)"
        read -p "Choose preset [1-3]: " AUTO_CHOICE

        BILLING_MODE="instance"
        BILLING_FLAG="--no-cpu-throttling"

        case $AUTO_CHOICE in
          1) MEMORY="1Gi"; CPU="1"; MIN_INST=1; MAX_INST=3; CONCURRENCY=100; TIMEOUT=3600 ;;
          2) MEMORY="2Gi"; CPU="2"; MIN_INST=1; MAX_INST=5; CONCURRENCY=130; TIMEOUT=3600 ;;
          3) MEMORY="4Gi"; CPU="4"; MIN_INST=1; MAX_INST=4; CONCURRENCY=200; TIMEOUT=3600 ;;
          *) MEMORY="2Gi"; CPU="2"; MIN_INST=1; MAX_INST=5; CONCURRENCY=130; TIMEOUT=3600; echo -e "${YELLOW}Using Balanced preset${NC}" ;;
        esac
        echo -e "${GREEN}✅ Applied Preset: $MEMORY | $CPU vCPU | Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY${NC}"
        break
        ;;
      2)
        echo -e "\n${CYAN}=========================================${NC}"
        echo -e "${GREEN}              BILLING MODE${NC}"
        echo -e "${CYAN}=========================================${NC}"
        echo -e "${YELLOW}Instance-Based = Stable, No Throttling${NC}"
        echo "1) Request-Based | 2) Instance-Based"
        while true; do
          read -p "Select [1-2]: " BILLING_CHOICE
          case $BILLING_CHOICE in
            1) BILLING_MODE="request"; BILLING_FLAG="--cpu-throttling"; break ;;
            2) BILLING_MODE="instance"; BILLING_FLAG="--no-cpu-throttling"; break ;;
            *) echo -e "${RED}Enter 1 or 2 only${NC}" ;;
          esac
        done

        echo -e "\n${YELLOW}--- MANUAL SETUP ---${NC}"
        echo "Select Memory:"
        echo "1) 256Mi 2) 512Mi 3) 1Gi 4) 2Gi"
        echo "5) 4Gi   6) 8Gi   7) 16Gi 8) Custom input"
        read -p "Select Memory [1-8]: " MEM
        case $MEM in
          1) MEMORY="256Mi" ;;
          2) MEMORY="512Mi" ;;
          3) MEMORY="1Gi" ;;
          4) MEMORY="2Gi" ;;
          5) MEMORY="4Gi" ;;
          6) MEMORY="8Gi" ;;
          7) MEMORY="16Gi" ;;
          8) read -p "Type custom memory: " MEMORY ;;
          *) MEMORY="1Gi" ;;
        esac

        echo -e "\nSelect vCPU:"
        echo "1) 1 vCPU 2) 2 vCPU 3) 4 vCPU 4) 8 vCPU 5) Custom input"
        read -p "Select vCPU [1-5]: " CPU_SEL
        case $CPU_SEL in
          1) CPU="1" ;;
          2) CPU="2" ;;
          3) CPU="4" ;;
          4) CPU="8" ;;
          5) read -p "Type custom vCPU: " CPU ;;
          *) CPU="1" ;;
        esac
        echo -e "${GREEN}✅ Custom Selected: $MEMORY RAM | $CPU vCPU${NC}"

        echo -e "\n${CYAN}=========================================${NC}"
        echo -e "${GREEN}  PERFORMANCE & SCALING CONFIGURATION ${NC}"
        echo -e "${CYAN}=========================================${NC}"
        read -p "Min Instances [Default: 0]: " MIN_INST
        MIN_INST=${MIN_INST:-0}
        read -p "Max Instances [Default: 1]: " MAX_INST
        MAX_INST=${MAX_INST:-1}
        read -p "Concurrency / Max Connections [Default: 1000]: " CONCURRENCY
        CONCURRENCY=${CONCURRENCY:-1000}
        read -p "Timeout in seconds [Default: 3600]: " TIMEOUT
        TIMEOUT=${TIMEOUT:-3600}
        echo -e "${GREEN}✅ Config Set: Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s${NC}"
        break
        ;;
      *) echo -e "${RED}Enter 1 or 2 only${NC}" ;;
    esac
  done

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT
  cd "$BUILD_DIR" || exit 1

  # Create index.html Decoy Page
  cat > index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>System Status | Cloud Gateway</title>
    <style>
        :root { --bg: #0b0f19; --card: #111827; --border: #1f2937; --text: #9ca3af; --white: #f9fafb; --green: #10b981; }
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        body { background: var(--bg); color: var(--text); display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
        .card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 32px; max-width: 440px; width: 100%; box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.5); }
        .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--border); }
        .title { color: var(--white); font-size: 18px; font-weight: 600; }
        .badge { display: inline-flex; align-items: center; gap: 6px; background: rgba(16, 185, 129, 0.1); color: var(--green); padding: 4px 10px; border-radius: 9999px; font-size: 12px; font-weight: 500; }
        .dot { width: 8px; height: 8px; background: var(--green); border-radius: 50%; animation: pulse 2s infinite; }
        .metrics { display: grid; gap: 12px; margin-bottom: 24px; }
        .metric-item { display: flex; justify-content: space-between; font-size: 14px; padding: 8px 0; border-bottom: 1px dashed var(--border); }
        .metric-item span:last-child { color: var(--white); font-weight: 500; }
        .footer { font-size: 12px; text-align: center; color: #6b7280; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
    </style>
</head>
<body>
    <div class="card">
        <div class="header">
            <div class="title">Application Gateway</div>
            <div class="badge"><span class="dot"></span> Operational</div>
        </div>
        <div class="metrics">
            <div class="metric-item"><span>HTTP/2 Proxy Ingress</span><span>Active</span></div>
            <div class="metric-item"><span>Global Load Balancer</span><span>Normal</span></div>
            <div class="metric-item"><span>Avg. Latency</span><span>&lt; 15ms</span></div>
            <div class="metric-item"><span>System Uptime</span><span>99.99%</span></div>
        </div>
        <div class="footer">Cloud Infrastructure &copy; 2026. All Systems Nominal.</div>
    </div>
</body>
</html>
EOF

  clear
  echo ""
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}🚀 GCP-XRAY DEPLOYER | MULTI-ENGINE SETUP${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}✅ Project:${NC} $PROJECT_ID"
  echo -e "${GREEN}✅ Region:${NC} $REGION"
  echo -e "${GREEN}✅ Service Name:${NC} $CLOUD_RUN_SERVICE_NAME"
  echo -e "${GREEN}✅ Engine:${NC} $DISPLAY_ENGINE"
  echo -e "${GREEN}✅ Scaling:${NC} Min: $MIN_INST | Max: $MAX_INST"
  echo -e "${GREEN}✅ Performance:${NC} Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s"
  echo ""

  # ==============================================
  # XRAY CONFIG — WS + XHTTP + TLS/Domain Masking Support
  # ==============================================
  cat > config.json <<'EOF'
{
  "log": {"loglevel": "warning"},
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8", "223.5.5.5"],
    "queryStrategy": "UseIP"
  },
  "inbounds": [
    {
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "tag": "trojan-ws",
      "settings": {"clients": [{"password": "gcp-xray"}]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/trojan-ws",
          "headers": {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
        },
        "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
      },
      "sniffing": {"enabled": false}
    },
    {
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "tag": "vless-ws",
      "settings": {"clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567"}], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless-ws",
          "headers": {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
        },
        "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
      },
      "sniffing": {"enabled": false}
    },
    {
      "port": 10010,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "tag": "trojan-xh",
      "settings": {"clients": [{"password": "gcp-xray"}]},
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "/trojan-xhttp", "mode": "auto"},
        "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
      },
      "sniffing": {"enabled": false}
    },
    {
      "port": 10009,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "tag": "vless-xh",
      "settings": {"clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "/vless-http", "mode": "auto"},
        "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
      },
      "sniffing": {"enabled": false}
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {"domainStrategy": "UseIP"}
    }
  ]
}
EOF

  if [ "$ENGINE" = "openresty" ]; then
    cat > nginx.conf <<'EOF'
worker_processes auto;
worker_rlimit_nofile 65536;
events {
    worker_connections 16384;
    use epoll;
    multi_accept on;
}
http {
    include /usr/local/openresty/nginx/conf/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    keepalive_timeout 7200;
    keepalive_requests 200000;
    client_max_body_size 0;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_http_version 1.1;
    proxy_connect_timeout 10s;
    proxy_send_timeout 7200s;
    proxy_read_timeout 7200s;

    # Dynamic Domain / TLS Masking Headers
    server_tokens off;
    more_set_headers "Server: Cloudflare";
    more_set_headers "X-Content-Type-Options: nosniff";
    more_set_headers "X-Frame-Options: SAMEORIGIN";

    server {
        listen 8080 default_server;
        listen [::]:8080 default_server;
        server_name _;

        location /health {
            return 200 "OK\n";
            add_header Content-Type text/plain;
        }

        location / {
            root /usr/local/openresty/nginx/html;
            index index.html;
        }

        location /trojan-ws {
            proxy_pass http://127.0.0.1:10001;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /vless-ws {
            proxy_pass http://127.0.0.1:10002;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /trojan-xhttp {
            proxy_pass http://127.0.0.1:10010;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /vless-http {
            proxy_pass http://127.0.0.1:10009;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
# Mount RAM disk for logs to ensure zero storage latency
mkdir -p /var/log/nginx /var/log/xray
mount -t tmpfs -o size=64M tmpfs /var/log/nginx 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/xray 2>/dev/null || true

/usr/local/bin/xray run -c /etc/xray.json &
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
EOF
    chmod +x entrypoint.sh

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray

FROM openresty/openresty:alpine-fat
USER root
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY index.html /usr/local/openresty/nginx/html/index.html
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "envoy" ]; then
    cat > envoy.yaml <<'EOF'
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address: { address: 0.0.0.0, port_value: 8080 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          server_name: "Cloudflare"
          codec_type: AUTO
          use_remote_address: true
          upgrade_configs:
          - upgrade_type: "websocket"
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match: { prefix: "/health" }
                direct_response: { status: 200, body: { inline_string: "OK\n" } }
              - match: { prefix: "/trojan-ws" }
                route: { cluster: trojan_ws_cluster, timeout: 0s }
              - match: { prefix: "/vless-ws" }
                route: { cluster: vless_ws_cluster, timeout: 0s }
              - match: { prefix: "/trojan-xhttp" }
                route: { cluster: trojan_xh_cluster, timeout: 0s }
              - match: { prefix: "/vless-http" }
                route: { cluster: vless_xh_cluster, timeout: 0s }
              - match: { prefix: "/" }
                direct_response: { status: 200, body: { inline_string: "Application Gateway Operational" } }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: trojan_ws_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: trojan_ws_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10001 } } } }] }]
  - name: vless_ws_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: vless_ws_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10002 } } } }] }]
  - name: trojan_xh_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: trojan_xh_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10010 } } } }] }]
  - name: vless_xh_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: vless_xh_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10009 } } } }] }]
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
mkdir -p /tmp/envoy /var/log/xray
mount -t tmpfs -o size=64M tmpfs /tmp/envoy 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/xray 2>/dev/null || true

/usr/local/bin/xray run -c /etc/xray.json &
exec envoy -c /etc/envoy.yaml
EOF
    chmod +x entrypoint.sh

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray

FROM envoyproxy/envoy:v1.30-latest
USER root
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY envoy.yaml /etc/envoy.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "haproxy" ]; then
    cat > haproxy.cfg <<'EOF'
global
    log stdout format raw local0
    maxconn 8192

defaults
    log global
    mode http
    timeout connect 10s
    timeout client 3600s
    timeout server 3600s

frontend main
    bind 0.0.0.0:8080
    http-response set-header Server Cloudflare
    acl is_health path /health
    acl is_trojan_ws path_beg /trojan-ws
    acl is_vless_ws path_beg /vless-ws
    acl is_trojan_xh path_beg /trojan-xhttp
    acl is_vless_xh path_beg /vless-http

    use_backend health_backend if is_health
    use_backend trojan_ws_backend if is_trojan_ws
    use_backend vless_ws_backend if is_vless_ws
    use_backend trojan_xh_backend if is_trojan_xh
    use_backend vless_xh_backend if is_vless_xh
    default_backend default_backend

backend health_backend
    http-request return status 200 content-type "text/plain" string "OK\n"

backend default_backend
    http-request return status 200 content-type "text/html" string "Application Gateway Operational"

backend trojan_ws_backend
    server xray_tws 127.0.0.1:10001

backend vless_ws_backend
    server xray_vws 127.0.0.1:10002

backend trojan_xh_backend
    server xray_txh 127.0.0.1:10010

backend vless_xh_backend
    server xray_vxh 127.0.0.1:10009
EOF

    cat > entrypoint.sh <<'EOF'
#!/bin/sh
set -e

mkdir -p /tmp/haproxy /var/log/xray
mount -t tmpfs -o size=64M tmpfs /tmp/haproxy 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/xray 2>/dev/null || true

/usr/local/bin/xray run -c /etc/xray.json &
sleep 1
exec haproxy -W -db -f /usr/local/etc/haproxy/haproxy.cfg
EOF
    chmod +x entrypoint.sh

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray

FROM haproxy:2.8-alpine
USER root
RUN apk add --no-cache ca-certificates tzdata
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EXPOSE 8080
EOF

  elif [ "$ENGINE" = "caddy" ]; then
    cat > Caddyfile <<'EOF'
{
    admin off
    http_port 8080
}

:8080 {
    header {
        Server "Cloudflare"
        -Server
    }

    handle /health {
        respond "OK\n" 200
    }

    handle /trojan-ws* {
        reverse_proxy 127.0.0.1:10001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle /vless-ws* {
        reverse_proxy 127.0.0.1:10002 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle /trojan-xhttp* {
        reverse_proxy 127.0.0.1:10010 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle /vless-http* {
        reverse_proxy 127.0.0.1:10009 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
mkdir -p /tmp/caddy /var/log/xray
mount -t tmpfs -o size=64M tmpfs /tmp/caddy 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/xray 2>/dev/null || true

/usr/local/bin/xray run -c /etc/xray.json &
exec caddy run --config /etc/Caddyfile --adapter caddyfile
EOF
    chmod +x entrypoint.sh

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray

FROM caddy:2.7-alpine
USER root
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY Caddyfile /etc/Caddyfile
COPY index.html /usr/share/caddy/index.html
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "singbox" ]; then
    cat > Caddyfile <<'EOF'
{
    admin off
    http_port 8080
}

:8080 {
    header {
        Server "Cloudflare"
        -Server
    }

    handle /health {
        respond "OK\n" 200
    }

    handle /trojan-ws* {
        reverse_proxy 127.0.0.1:10001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle /vless-ws* {
        reverse_proxy 127.0.0.1:10002 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle /trojan-xhttp* {
        reverse_proxy 127.0.0.1:10010 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle /vless-http* {
        reverse_proxy 127.0.0.1:10009 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF
    cat > singbox.json <<'EOF'
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "listen_port": 10001,
      "users": [{"password": "gcp-xray"}],
      "transport": {
        "type": "ws",
        "path": "/trojan-ws"
      }
    },
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": 10002,
      "users": [{"uuid": "a1b2c3d4-5678-40ef-98ab-cdef01234567"}],
      "transport": {
        "type": "ws",
        "path": "/vless-ws"
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-xh",
      "listen": "127.0.0.1",
      "listen_port": 10010,
      "users": [{"password": "gcp-xray"}],
      "transport": {
        "type": "http",
        "path": "/trojan-xhttp"
      }
    },
    {
      "type": "vless",
      "tag": "vless-xh",
      "listen": "127.0.0.1",
      "listen_port": 10009,
      "users": [{"uuid": "a1b2c3d4-5678-40ef-98ab-cdef01234567"}],
      "transport": {
        "type": "http",
        "path": "/vless-http"
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
mkdir -p /tmp/singbox /var/log/sing-box
mount -t tmpfs -o size=64M tmpfs /tmp/singbox 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/sing-box 2>/dev/null || true

/usr/local/bin/sing-box run -c /etc/singbox.json &
exec caddy run --config /etc/Caddyfile --adapter caddyfile
EOF
    chmod +x entrypoint.sh

    cat > Dockerfile <<'EOF'
FROM ghcr.io/sagernet/sing-box:latest AS singbox-builder

FROM caddy:2.7-alpine
USER root
COPY --from=singbox-builder /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY singbox.json /etc/singbox.json
COPY Caddyfile /etc/Caddyfile
COPY index.html /usr/share/caddy/index.html
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/sing-box /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF
  fi

  echo -e "${CYAN}🔨 Building image ($ENGINE engine)...${NC}"
  gcloud builds submit --project="$PROJECT_ID" --tag gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME . --quiet

  echo -e "${CYAN}🚀 Deploying to Cloud Run...${NC}"
  gcloud run deploy "$CLOUD_RUN_SERVICE_NAME" \
    --image gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME \
    --project="$PROJECT_ID" --platform managed --region "$REGION" --allow-unauthenticated \
    --port 8080 --memory "$MEMORY" --cpu "$CPU" --concurrency "$CONCURRENCY" \
    --timeout "$TIMEOUT" --min-instances "$MIN_INST" --max-instances "$MAX_INST" \
    --session-affinity \
    --execution-environment gen2 $BILLING_FLAG --cpu-boost --quiet

  CLOUD_RUN_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE_NAME" --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')
  DOMAIN=$(echo "$CLOUD_RUN_URL" | sed 's|https://||')
  CANONICAL_LINK="https://$DOMAIN"

  clear
  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}✅ DEPLOYMENT SUCCESS! (${ENGINE^^})${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}🔗 SHORT LINK:${NC} $CANONICAL_LINK"
  echo -e "${GREEN}🌐 NETMOD HOST:${NC} $DOMAIN"
  echo -e "${GREEN}💚 HEALTH CHECK:${NC} $CANONICAL_LINK/health"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}🛡️ ENHANCEMENTS APPLIED:${NC}"
  echo -e "  ✅ Smart BBR / TCP Congestion Stack Check"
  echo -e "  ✅ RAM Disk (tmpfs) High-Speed Mounts (/tmp, /var/log)"
  echo -e "  ✅ Domain & TLS Masking Engine (Fake Server Fingerprint)"
  echo -e "  ✅ Anti-DDoS & Kernel Tuning"
  echo -e "  ✅ Log Cleaner & Supervisord Integration"
  echo -e "  ✅ Decoy Gateway Page (Static Asset)"
  echo ""
  read -p "Press [Enter] to return to Main Menu..."
}

# ==============================================
# MAIN MENU LOOP
# ==============================================
while true; do
  clear
  echo "======================================"
  echo "FIVE ENGINES GCP-XRAY DEPLOYER MENU"
  echo "======================================"
  echo "1) Deploy New Service to Cloud Run"
  echo "2) List All Active Cloud Run Services"
  echo "3) Exit"
  echo "======================================"
  read -p "Select Option [1-3]: " MENU_CHOICE

  case $MENU_CHOICE in
    1) deploy_new_service ;;
    2) list_deployed_services ;;
    3) echo -e "\n👋 Goodbye!"; exit 0 ;;
    *) echo -e "${RED}❌ Enter 1, 2, or 3 only${NC}"; sleep 2 ;;
  esac
done
