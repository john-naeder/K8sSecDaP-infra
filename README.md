# K8sSecDaP-infra

Cluster Infrastructure-as-Code cho **K8sSecDaP** (Port-scan K8s Detect-and-Prevent).

Ansible-based bootstrap cho bare-metal Kubernetes cluster qua Tailscale, dùng **Calico CNI**.

## Layout
- `ansible/` — playbooks (`site/master/worker/reset`), roles (tailscale, common, containerd,
  kubernetes, cni_plugins, firewall, master_init, **cni_calico**, worker_join), inventory.
- `bootstrap/` — script đồng bộ Tailscale IP → inventory (`sync-inventory.sh`, `register-node.sh`).

## Dùng
```bash
cd ansible
make ping       # kiểm tra kết nối
make check      # dry-run
make setup      # dựng toàn bộ cluster (master + workers + Calico)
```

## Lưu ý
- `.vault_password`, `bootstrap.env`, `nodes.env` KHÔNG được commit (xem `.gitignore`).
- Calico manifests được vendor trong `ansible/roles/cni_calico/files/`; bản canonical cho
  GitOps nằm ở repo **K8sSecDaP-deploy** (`cni/calico`, do ArgoCD quản lý).
