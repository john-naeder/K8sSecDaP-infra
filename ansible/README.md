# K8s Cluster Ansible Automation

Tự động hóa việc provision Kubernetes cluster trên Ubuntu Server 24.04 (bare metal) qua Tailscale VPN.

## Workflow 2 pha

```
 ┌─────────────────────────────────────────────────────────────────┐
 │  Phase 1: THỦ CÔNG (trên mỗi bare metal node)                  │
 │                                                                 │
 │  1. Cài Ubuntu Server 24.04                                     │
 │  2. curl -fsSL https://tailscale.com/install.sh | sh            │
 │  3. sudo tailscale up --hostname=<tên-node>                     │
 │  4. Copy SSH public key vào node                                │
 │  5. (Optional) Setup passwordless sudo                          │
 └──────────────────────┬──────────────────────────────────────────┘
                        │
                        ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Bridge: sync-inventory.sh                                      │
 │                                                                 │
 │  Chạy từ máy local (cũng trên tailnet):                         │
 │    cd bootstrap && bash sync-inventory.sh                       │
 │                                                                 │
 │  → Detect Tailscale IPs từ tailnet                              │
 │  → Auto-generate ansible/inventory/hosts.yml                    │
 │  → Auto-generate ansible/inventory/host_vars/*.yml              │
 └──────────────────────┬──────────────────────────────────────────┘
                        │
                        ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Phase 2: ANSIBLE (tự động)                                     │
 │                                                                 │
 │  make ping            # Test SSH qua Tailscale                  │
 │  make master          # Provision + init master                 │
 │  make worker          # Provision + join workers                │
 │                                                                 │
 │  Ansible roles:                                                 │
 │    tailscale (verify) → common → containerd → kubernetes        │
 │    → cni_plugins → firewall → master_init → cni_calico          │
 │    → worker_join                                                │
 └─────────────────────────────────────────────────────────────────┘
```

## Kiến trúc

```
                    Tailscale VPN (100.x.x.x)
                            │
              ┌─────────────┼─────────────┐
              │             │             │
        ┌─────────┐  ┌─────────┐  ┌─────────┐
        │ Master  │  │ Worker1 │  │ Worker2 │
        │ 100.95. │  │ 100.94. │  │  (mới)  │
        │ 126.102 │  │ 203.28  │  │         │
        └─────────┘  └─────────┘  └─────────┘
```

## Cấu trúc thư mục

```
infra/
├── bootstrap/                           # Phase 1 — bridge scripts
│   ├── nodes.env                        # Node registry (hostname|role|IP)
│   ├── bootstrap.env.example            # Template config
│   ├── sync-inventory.sh               # Detect IPs + generate inventory
│   └── register-node.sh                # Register + verify từng node
│
├── ansible/                             # Phase 2 — K8s provisioning
│   ├── ansible.cfg
│   ├── Makefile                         # Quick commands
│   ├── inventory/
│   │   ├── hosts.yml                    # ← AUTO-GENERATED bởi sync-inventory.sh
│   │   ├── group_vars/
│   │   │   ├── all/
│   │   │   │   ├── versions.yml         # K8s, containerd, CNI versions
│   │   │   │   ├── network.yml          # CIDR, ports, vpn_interface
│   │   │   │   └── vault.yml           # Secrets (mã hóa!)
│   │   │   ├── masters.yml
│   │   │   └── workers.yml
│   │   └── host_vars/                   # ← AUTO-GENERATED bởi sync-inventory.sh
│   │       ├── userver-master.yml
│   │       └── userver-home-worker.yml
│   ├── roles/
│   │   ├── tailscale/       # VERIFY-ONLY: kiểm tra TS running + IP khớp
│   │   ├── common/          # Kernel modules, sysctl, swap
│   │   ├── containerd/      # Container runtime (+ fix CRI 2.2.x)
│   │   ├── kubernetes/      # kubeadm, kubelet, kubectl
│   │   ├── cni_plugins/     # CNI binary plugins
│   │   ├── firewall/        # UFW rules
│   │   ├── master_init/     # kubeadm init + kubeconfig
│   │   ├── cni_calico/      # Deploy Calico (Tigera Operator + Installation CR)
│   │   └── worker_join/     # kubeadm join
│   └── playbooks/
│       ├── site.yml         # Full cluster setup
│       ├── master.yml       # Master only
│       ├── worker.yml       # Workers only
│       └── reset.yml        # Reset K8s
│
└── k8s/setup/                           # Reference scripts (shell gốc)
```

## Phân chia trách nhiệm

| Giai đoạn | Công việc | Ai làm |
|-----------|-----------|--------|
| Phase 1 | Cài Ubuntu Server | Thủ công |
| Phase 1 | Cài Tailscale + join tailnet | Thủ công |
| Phase 1 | SSH key setup | Thủ công |
| Bridge | Detect Tailscale IPs | `sync-inventory.sh` |
| Bridge | Generate Ansible inventory | `sync-inventory.sh` |
| Phase 2 | Verify Tailscale đang chạy | Ansible (`tailscale` role) |
| Phase 2 | containerd, kubeadm, kubelet | Ansible |
| Phase 2 | kubeadm init, Calico CNI | Ansible |
| Phase 2 | Worker join | Ansible |
| Phase 2 | Firewall rules | Ansible |

## Yêu cầu

### Trên máy local (chạy Ansible)
```bash
# Ansible
pip install ansible

# Collection cho UFW
ansible-galaxy collection install community.general

# Tailscale (cần để detect IPs)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

### Trên target nodes (cài thủ công)
- Ubuntu Server 24.04
- Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --hostname=<tên>`
- SSH key: copy public key vào `~/.ssh/authorized_keys`
- Sudo: `echo 'johnnaeder ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/johnnaeder`

## Sử dụng

### 1. Setup bare metal nodes (thủ công)

Trên mỗi node, cài Ubuntu + Tailscale + SSH key (xem Requirements ở trên).

### 2. Register nodes & sync inventory

```bash
# Cách 1: Đăng ký từng node (verify SSH + auto detect IP)
cd bootstrap
bash register-node.sh userver-master master
bash register-node.sh userver-home-worker worker

# Cách 2: Nếu nodes.env đã có đủ hostnames, sync tất cả
cd bootstrap
bash sync-inventory.sh

# Preview trước khi ghi file:
bash sync-inventory.sh --dry-run
```

### 3. Cấu hình secrets

```bash
cd ansible

# Tạo vault password
echo "your-vault-password" > .vault_password
chmod 600 .vault_password

# Sửa secrets
make vault-edit
```

### 4. Provision cluster

```bash
cd ansible

# Kiểm tra kết nối
make ping

# Full cluster setup
make setup

# Hoặc từng bước:
make master     # Master trước
make worker     # Workers sau
```

### 5. Thêm worker mới

```bash
# 1. Cài Ubuntu + Tailscale + SSH trên node mới

# 2. Thêm vào nodes.env
echo "userver-new-worker|worker|" >> bootstrap/nodes.env

# 3. Register + sync
cd bootstrap
bash register-node.sh userver-new-worker worker

# 4. Provision
cd ansible
make worker-one NODE=userver-new-worker
```

### 6. Reset cluster

```bash
make reset           # Reset tất cả
make reset-workers   # Chỉ workers
```

## Commands

| Command | Mô tả |
|---------|--------|
| `make sync` | Detect Tailscale IPs & generate inventory |
| `make sync-dry` | Preview inventory changes |
| `make register HOST=x ROLE=y` | Register node mới |
| `make setup` | Full cluster setup |
| `make master` | Setup master only |
| `make worker` | Setup + join all workers |
| `make worker-one NODE=x` | Join single worker |
| `make reset` | Reset toàn bộ cluster |
| `make ping` | Test SSH connection |
| `make check` | Dry-run (không thực thi) |
| `make lint` | Lint playbooks |
| `make vault-edit` | Sửa encrypted secrets |

## Thành phần

| Thành phần | Version | Ghi chú |
|------------|---------|---------|
| Kubernetes | v1.32 | kubeadm-based |
| containerd | 2.2.x | Docker official repo |
| Calico | v3.28.2 | CNI, Tigera Operator + Installation CR (autodetect tailscale0, MTU 1230) |
| CNI plugins | v1.6.2 | Binary plugins |
| Tailscale | latest | VPN inter-node (cài thủ công) |
| UFW | system | Firewall |

## Troubleshooting

### containerd CRI không phản hồi
```bash
sudo systemctl restart containerd
sleep 2
crictl info
```

### Node ở trạng thái NotReady
```bash
journalctl -xeu kubelet --no-pager | tail -30
kubectl -n calico-system get pods
```

### Tailscale IP thay đổi
```bash
cd bootstrap
bash sync-inventory.sh   # Re-detect + update inventory
```

### sync-inventory.sh báo "NOT FOUND"
- Node đã cài Tailscale chưa?
- Node đã `tailscale up` chưa?
- Hostname trên node có đúng không? (`tailscale up --hostname=<tên>`)
- Xem danh sách: `tailscale status`

### Reset và thử lại
```bash
make reset-workers
# Hoặc
ansible-playbook playbooks/reset.yml --limit <hostname>
```
