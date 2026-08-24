ansible-playbook playbooks/reset.yml --limit userver-worker-home --ask-become-pass.PHONY: help sync register setup master worker reset ping lint vault-encrypt vault-edit

ANSIBLE_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
BOOTSTRAP_DIR := $(ANSIBLE_DIR)/../bootstrap

help: ## Hiển thị help
	@echo "K8s Cluster Ansible Automation"
	@echo "=============================="
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Bootstrap (chạy trước Ansible) ---

sync: ## Detect Tailscale IPs & generate Ansible inventory
	cd $(BOOTSTRAP_DIR) && bash sync-inventory.sh

sync-dry: ## Preview inventory changes (không ghi file)
	cd $(BOOTSTRAP_DIR) && bash sync-inventory.sh --dry-run

register: ## Register node mới (make register HOST=<hostname> ROLE=<master|worker>)
	cd $(BOOTSTRAP_DIR) && bash register-node.sh $(HOST) $(ROLE)

# --- Cluster Operations ---

setup: ## Setup toàn bộ cluster (master + workers)
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml

master: ## Setup chỉ master node
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/master.yml

worker: ## Setup workers (tuỳ chọn: make worker NODE=userver-worker-2)
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/worker.yml $(if $(NODE),--limit $(NODE),)

reset: ## Reset K8s trên tất cả nodes
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/reset.yml

reset-workers: ## Reset chỉ worker nodes
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/reset.yml --limit workers

# --- Utility ---

ping: ## Kiểm tra kết nối tới tất cả nodes
	cd $(ANSIBLE_DIR) && ansible all -m ping

check: ## Dry-run setup toàn bộ (không thực thi)
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml --check --diff

lint: ## Lint playbooks (cần ansible-lint)
	cd $(ANSIBLE_DIR) && ansible-lint playbooks/ roles/

# --- Vault ---

vault-encrypt: ## Mã hóa file vault.yml
	cd $(ANSIBLE_DIR) && ansible-vault encrypt inventory/group_vars/all/vault.yml

vault-edit: ## Sửa vault.yml (đã mã hóa)
	cd $(ANSIBLE_DIR) && ansible-vault edit inventory/group_vars/all/vault.yml

vault-view: ## Xem vault.yml (đã mã hóa)
	cd $(ANSIBLE_DIR) && ansible-vault view inventory/group_vars/all/vault.yml
