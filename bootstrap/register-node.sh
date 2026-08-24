#!/bin/bash
# ============================================================
# register-node.sh
#
# Chạy SAU KHI đã cài Ubuntu + Tailscale + SSH key trên node.
# Script này SSH vào node qua Tailscale, verify mọi thứ hoạt động,
# rồi cập nhật nodes.env + Ansible inventory.
#
# Cách dùng:
#   bash register-node.sh <hostname> <role>
#   bash register-node.sh userver-master master
#   bash register-node.sh userver-home-worker worker
#
# Yêu cầu:
#   - Tailscale đang chạy trên máy local VÀ trên node
#   - SSH key đã được cài trên node
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODES_ENV="${SCRIPT_DIR}/nodes.env"
BOOTSTRAP_ENV="${SCRIPT_DIR}/bootstrap.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Load config ──────────────────────────────────────────────
ADMIN_USER="johnnaeder"
SSH_PRIVATE_KEY="~/.ssh/id_ed25519"

if [[ -f "${BOOTSTRAP_ENV}" ]]; then
    # shellcheck source=/dev/null
    source "${BOOTSTRAP_ENV}"
fi

# ── Args ─────────────────────────────────────────────────────
HOSTNAME="${1:-}"
ROLE="${2:-}"

if [[ -z "${HOSTNAME}" || -z "${ROLE}" ]]; then
    echo "Usage: bash register-node.sh <hostname> <role>"
    echo ""
    echo "  hostname   Tailscale hostname của node (vd: userver-master)"
    echo "  role       master | worker"
    echo ""
    echo "Ví dụ:"
    echo "  bash register-node.sh userver-master master"
    echo "  bash register-node.sh userver-home-worker worker"
    exit 1
fi

if [[ "${ROLE}" != "master" && "${ROLE}" != "worker" ]]; then
    echo -e "${RED}ERROR: Role phải là 'master' hoặc 'worker'${NC}"
    exit 1
fi

echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD} Register Node: ${HOSTNAME} [${ROLE}]${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""

# ── Step 1: Detect Tailscale IP ───────────────────────────────
echo -e "${CYAN}[1/4] Detecting Tailscale IP...${NC}"

TS_IP=""
# Thử detect từ tailscale status (local machine)
if command -v tailscale &>/dev/null; then
    TS_IP=$(tailscale status --json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
# Check peers
for key, peer in data.get('Peer', {}).items():
    if peer.get('HostName','') == '${HOSTNAME}':
        for a in peer.get('TailscaleIPs', []):
            if '.' in a:
                print(a)
                sys.exit(0)
# Check self
self_node = data.get('Self', {})
if self_node.get('HostName','') == '${HOSTNAME}':
    for a in self_node.get('TailscaleIPs', []):
        if '.' in a:
            print(a)
            sys.exit(0)
" 2>/dev/null || echo "")
fi

if [[ -z "${TS_IP}" ]]; then
    echo -e "${RED}ERROR: Không tìm thấy '${HOSTNAME}' trên tailnet${NC}"
    echo ""
    echo "Kiểm tra:"
    echo "  1. Node đã cài Tailscale chưa?"
    echo "  2. Node đã chạy 'tailscale up' chưa?"
    echo "  3. Hostname trên node có đúng '${HOSTNAME}' không?"
    echo "     (tailscale up --hostname=${HOSTNAME})"
    echo ""
    echo "Xem danh sách nodes trên tailnet:"
    echo "  tailscale status"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Tailscale IP: ${BOLD}${TS_IP}${NC}"

# ── Step 2: Test SSH ──────────────────────────────────────────
echo ""
echo -e "${CYAN}[2/4] Testing SSH connection...${NC}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_PRIVATE_KEY}"

if ssh ${SSH_OPTS} "${ADMIN_USER}@${TS_IP}" "echo ok" &>/dev/null; then
    echo -e "${GREEN}[OK]${NC} SSH via ${ADMIN_USER}@${TS_IP}"
else
    echo -e "${RED}ERROR: Không SSH được vào ${ADMIN_USER}@${TS_IP}${NC}"
    echo ""
    echo "Kiểm tra:"
    echo "  1. SSH key đã được cài trên node?"
    echo "  2. User '${ADMIN_USER}' tồn tại trên node?"
    echo "  3. Thử thủ công: ssh ${SSH_OPTS} ${ADMIN_USER}@${TS_IP}"
    exit 1
fi

# ── Step 3: Verify node state ────────────────────────────────
echo ""
echo -e "${CYAN}[3/4] Verifying node state...${NC}"

NODE_INFO=$(ssh ${SSH_OPTS} "${ADMIN_USER}@${TS_IP}" bash <<'REMOTE_SCRIPT'
echo "HOSTNAME=$(hostname)"
echo "OS=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || echo "unknown")"
echo "TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo 'NOT_INSTALLED')"
echo "TAILSCALE_STATUS=$(tailscale status &>/dev/null && echo 'connected' || echo 'disconnected')"
echo "PYTHON3=$(python3 --version 2>/dev/null || echo 'NOT_INSTALLED')"
echo "SUDO=$(sudo -n true 2>/dev/null && echo 'ok' || echo 'need_password')"
REMOTE_SCRIPT
)

# Parse results
# Parse results safely (không dùng eval)
while IFS='=' read -r key value; do
    case "$key" in
        HOSTNAME) HOSTNAME="$value" ;;
        OS) OS="$value" ;;
        TAILSCALE_IP) TAILSCALE_IP="$value" ;;
        TAILSCALE_STATUS) TAILSCALE_STATUS="$value" ;;
        PYTHON3) PYTHON3="$value" ;;
        SUDO) SUDO="$value" ;;
    esac
done <<< "${NODE_INFO}"

echo "  Hostname       : ${HOSTNAME}"
echo "  OS             : ${OS}"
echo "  Tailscale IP   : ${TAILSCALE_IP}"
echo "  Tailscale      : ${TAILSCALE_STATUS}"
echo "  Python3        : ${PYTHON3}"
echo "  Sudo           : ${SUDO}"

# Validate
ERRORS=0
if [[ "${TAILSCALE_STATUS}" != "connected" ]]; then
    echo -e "  ${RED}✗ Tailscale chưa kết nối!${NC}"
    ((ERRORS++))
fi

if [[ "${PYTHON3}" == "NOT_INSTALLED" ]]; then
    echo -e "  ${YELLOW}! Python3 chưa có — Ansible cần python3${NC}"
    echo -e "    Fix: ssh ${ADMIN_USER}@${TS_IP} 'sudo apt install -y python3'"
fi

if [[ "${SUDO}" != "ok" ]]; then
    echo -e "  ${YELLOW}! Sudo cần password — Ansible cần NOPASSWD${NC}"
    echo -e "    Fix: ssh ${ADMIN_USER}@${TS_IP}"
    echo -e "         echo '${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/${ADMIN_USER}"
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo -e "\n${RED}Có lỗi. Fix rồi chạy lại.${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓ Node sẵn sàng cho Ansible${NC}"

# ── Step 4: Update nodes.env + regenerate inventory ───────────
echo ""
echo -e "${CYAN}[4/4] Updating registry & inventory...${NC}"

# Kiểm tra node đã có trong nodes.env chưa
NODE_HOSTNAME="${1}"  # Dùng lại arg gốc, không phải biến từ remote
NODE_ROLE="${2}"

if grep -q "^${NODE_HOSTNAME}|" "${NODES_ENV}" 2>/dev/null; then
    # Cập nhật dòng có sẵn
    sed -i "s#^${NODE_HOSTNAME}|.*#${NODE_HOSTNAME}|${NODE_ROLE}|${TS_IP}#" "${NODES_ENV}"
    echo -e "  ${GREEN}✓${NC} Updated ${NODE_HOSTNAME} in nodes.env"
else
    # Thêm dòng mới
    echo "${NODE_HOSTNAME}|${NODE_ROLE}|${TS_IP}" >> "${NODES_ENV}"
    echo -e "  ${GREEN}✓${NC} Added ${NODE_HOSTNAME} to nodes.env"
fi

# Regenerate Ansible inventory
echo ""
bash "${SCRIPT_DIR}/sync-inventory.sh"
