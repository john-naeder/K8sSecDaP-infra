#!/bin/bash
# ============================================================
# sync-inventory.sh
#
# Auto-detect Tailscale IPs từ tailnet và generate Ansible inventory.
# Chạy từ máy local (cũng đang bật Tailscale) sau khi đã cài
# Ubuntu + Tailscale trên các bare metal nodes.
#
# Cách dùng:
#   bash sync-inventory.sh              # Detect + generate
#   bash sync-inventory.sh --dry-run    # Chỉ hiển thị, không ghi file
#   bash sync-inventory.sh --detect     # Chỉ detect IP, cập nhật nodes.env
#
# Yêu cầu:
#   - Tailscale đang chạy trên máy local
#   - Các node đã cài Tailscale và join tailnet
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODES_ENV="${SCRIPT_DIR}/nodes.env"
BOOTSTRAP_ENV="${SCRIPT_DIR}/bootstrap.env"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DRY_RUN=false
DETECT_ONLY=false

# ── Parse args ───────────────────────────────────────────────
case "${1:-}" in
    --dry-run)  DRY_RUN=true ;;
    --detect)   DETECT_ONLY=true ;;
    --help|-h)
        echo "Usage: bash sync-inventory.sh [--dry-run|--detect]"
        echo "  --dry-run   Chỉ hiển thị kết quả, không ghi file"
        echo "  --detect    Chỉ detect Tailscale IPs, cập nhật nodes.env"
        exit 0 ;;
esac

# ── Load bootstrap.env ───────────────────────────────────────
ADMIN_USER="johnnaeder"
SSH_PRIVATE_KEY="~/.ssh/id_ed25519"

if [[ -f "${BOOTSTRAP_ENV}" ]]; then
    # shellcheck source=/dev/null
    source "${BOOTSTRAP_ENV}"
fi

# ── Validate ─────────────────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
    echo -e "${RED}ERROR: tailscale CLI không có trên máy local${NC}"
    echo "Cài Tailscale: curl -fsSL https://tailscale.com/install.sh | sh"
    exit 1
fi

if ! tailscale status &>/dev/null; then
    echo -e "${RED}ERROR: Tailscale chưa kết nối trên máy local${NC}"
    echo "Chạy: sudo tailscale up"
    exit 1
fi

if [[ ! -f "${NODES_ENV}" ]]; then
    echo -e "${RED}ERROR: ${NODES_ENV} không tồn tại${NC}"
    exit 1
fi

echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD} K8s Cluster — Inventory Sync${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""

# ── Step 1: Lấy danh sách Tailscale từ tailnet ───────────────
echo -e "${CYAN}[1/3] Scanning tailnet...${NC}"
TS_STATUS=$(tailscale status --json 2>/dev/null || echo "{}")

# ── Step 2: Đọc nodes.env và match với Tailscale IPs ─────────
echo -e "${CYAN}[2/3] Matching nodes...${NC}"
echo ""

declare -A NODE_HOSTS=()     # hostname → tailscale_ip
declare -A NODE_ROLES=()     # hostname → role
declare -a MASTERS=()
declare -a WORKERS=()
UPDATED_NODES_ENV=""
HAS_CHANGES=false

while IFS= read -r line; do
    # Giữ comment và dòng trống
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// /}" ]]; then
        UPDATED_NODES_ENV+="${line}"$'\n'
        continue
    fi

    HOSTNAME=$(echo "$line" | cut -d'|' -f1 | xargs)
    ROLE=$(echo "$line" | cut -d'|' -f2 | xargs)
    CONFIGURED_IP=$(echo "$line" | cut -d'|' -f3 | xargs)

    # Auto-detect IP từ tailnet nếu chưa có hoặc cần verify
    DETECTED_IP=""
    DETECTED_IP=$(echo "${TS_STATUS}" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
peers = data.get('Peer', {})
for key, peer in peers.items():
    if peer.get('HostName','') == '${HOSTNAME}':
        addrs = peer.get('TailscaleIPs', [])
        for a in addrs:
            if '.' in a:  # IPv4
                print(a)
                break
        break
# Also check self
self_node = data.get('Self', {})
if self_node.get('HostName','') == '${HOSTNAME}':
    addrs = self_node.get('TailscaleIPs', [])
    for a in addrs:
        if '.' in a:
            print(a)
            break
" 2>/dev/null || echo "")

    # Quyết định IP cuối cùng
    FINAL_IP=""
    STATUS_MSG=""

    if [[ -n "${DETECTED_IP}" ]]; then
        if [[ -n "${CONFIGURED_IP}" && "${CONFIGURED_IP}" != "${DETECTED_IP}" ]]; then
            STATUS_MSG="${YELLOW}IP CHANGED${NC}: ${CONFIGURED_IP} → ${DETECTED_IP}"
            FINAL_IP="${DETECTED_IP}"
            HAS_CHANGES=true
        elif [[ -z "${CONFIGURED_IP}" ]]; then
            STATUS_MSG="${GREEN}DETECTED${NC}: ${DETECTED_IP}"
            FINAL_IP="${DETECTED_IP}"
            HAS_CHANGES=true
        else
            STATUS_MSG="${GREEN}OK${NC}: ${CONFIGURED_IP}"
            FINAL_IP="${CONFIGURED_IP}"
        fi
    elif [[ -n "${CONFIGURED_IP}" ]]; then
        STATUS_MSG="${YELLOW}OFFLINE${NC}: using configured ${CONFIGURED_IP}"
        FINAL_IP="${CONFIGURED_IP}"
    else
        STATUS_MSG="${RED}NOT FOUND${NC}: node chưa join tailnet"
        FINAL_IP=""
    fi

    printf "  %-25s %-8s %b\n" "${HOSTNAME}" "[${ROLE}]" "${STATUS_MSG}"

    # Lưu kết quả
    if [[ -n "${FINAL_IP}" ]]; then
        NODE_HOSTS["${HOSTNAME}"]="${FINAL_IP}"
        NODE_ROLES["${HOSTNAME}"]="${ROLE}"
        if [[ "${ROLE}" == "master" ]]; then
            MASTERS+=("${HOSTNAME}")
        else
            WORKERS+=("${HOSTNAME}")
        fi
    fi

    UPDATED_NODES_ENV+="${HOSTNAME}|${ROLE}|${FINAL_IP}"$'\n'

done < <(cat "${NODES_ENV}")

echo ""

# ── Cập nhật nodes.env với IPs mới ───────────────────────────
if [[ "${HAS_CHANGES}" == true && "${DRY_RUN}" == false ]]; then
    echo -e "${CYAN}Updating nodes.env...${NC}"
    echo -n "${UPDATED_NODES_ENV}" > "${NODES_ENV}"
    echo -e "${GREEN}[OK]${NC} nodes.env updated"
fi

if [[ "${DETECT_ONLY}" == true ]]; then
    echo ""
    echo -e "${GREEN}Done (detect only).${NC}"
    exit 0
fi

# ── Step 3: Generate Ansible inventory ────────────────────────
echo ""
echo -e "${CYAN}[3/3] Generating Ansible inventory...${NC}"

if [[ ${#NODE_HOSTS[@]} -eq 0 ]]; then
    echo -e "${RED}ERROR: Không có node nào có Tailscale IP. Không thể generate inventory.${NC}"
    exit 1
fi

# --- hosts.yml ---
HOSTS_YML="---
# =============================================================================
# Kubernetes Cluster Inventory
# AUTO-GENERATED by sync-inventory.sh — $(date '+%Y-%m-%d %H:%M:%S')
#
# Sử dụng Tailscale IP để SSH vào các node.
# KHÔNG sửa file này trực tiếp — sửa nodes.env rồi chạy lại sync-inventory.sh
# =============================================================================

all:
  children:
    masters:
      hosts:"

for host in "${MASTERS[@]}"; do
    HOSTS_YML+="
        ${host}:
          ansible_host: ${NODE_HOSTS[$host]}"
done

HOSTS_YML+="
    workers:
      hosts:"

if [[ ${#WORKERS[@]} -gt 0 ]]; then
    for host in "${WORKERS[@]}"; do
        HOSTS_YML+="
        ${host}:
          ansible_host: ${NODE_HOSTS[$host]}"
    done
else
    HOSTS_YML+=" {}"
fi

HOSTS_YML+="

    # Group gộp tất cả K8s nodes
    k8s_cluster:
      children:
        masters:
        workers:
"

# --- host_vars ---
if [[ "${DRY_RUN}" == true ]]; then
    echo ""
    echo -e "${BOLD}── hosts.yml (preview) ──${NC}"
    echo "${HOSTS_YML}"
    echo ""
    echo -e "${BOLD}── host_vars (preview) ──${NC}"
    for host in "${!NODE_HOSTS[@]}"; do
        echo "  ${host}.yml → tailscale_ip: ${NODE_HOSTS[$host]}, role: ${NODE_ROLES[$host]}"
    done
    echo ""
    echo -e "${YELLOW}Dry-run mode — không ghi file.${NC}"
    exit 0
fi

# Ghi hosts.yml
mkdir -p "${ANSIBLE_DIR}/inventory"
echo "${HOSTS_YML}" > "${ANSIBLE_DIR}/inventory/hosts.yml"
echo -e "  ${GREEN}✓${NC} inventory/hosts.yml"

# Ghi host_vars
mkdir -p "${ANSIBLE_DIR}/inventory/host_vars"
for host in "${!NODE_HOSTS[@]}"; do
    cat > "${ANSIBLE_DIR}/inventory/host_vars/${host}.yml" <<EOF
---
# =============================================================================
# ${host} — AUTO-GENERATED by sync-inventory.sh
# =============================================================================

tailscale_ip: "${NODE_HOSTS[$host]}"
node_role: "${NODE_ROLES[$host]}"
EOF
    echo -e "  ${GREEN}✓${NC} inventory/host_vars/${host}.yml"
done

echo ""
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${GREEN} Inventory synced!${NC}"
echo ""
echo -e " Masters: ${#MASTERS[@]}  Workers: ${#WORKERS[@]}"
echo ""
echo -e " Tiếp theo:"
echo -e "   cd ../ansible && make ping     ${CYAN}# Test SSH${NC}"
echo -e "   cd ../ansible && make master   ${CYAN}# Provision master${NC}"
echo -e "   cd ../ansible && make worker   ${CYAN}# Provision workers${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
