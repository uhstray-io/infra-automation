# Infrastructure Automation

Ansible playbooks and Proxmox automation for uhstray.io infrastructure. Managed by Semaphore.

## Playbooks

| Playbook | Purpose |
|----------|---------|
| `deploy-all.yml` | Deploy all services in dependency order |
| `deploy-service.yml` | Deploy a single service (`-e target_service=<name>`) |
| `deploy-openbao.yml` | Clone openbao repo + run deploy.sh on target VM |
| `update-service.yml` | Pull latest images + restart + validate |
| `validate-all.yml` | Health check all services |
| `proxmox-validate.yml` | Pre/post Proxmox cluster validation (9 checks) |
| `provision-template.yml` | Create Ubuntu 24.04 VM template from ISO |
| `provision-vm.yml` | Clone template, configure cloud-init, start VM |

## Secrets

This is a **public repository**. All secrets and credentials are injected at runtime:

| Variable | Source | Used By |
|----------|--------|---------|
| `bao_role_id` | Semaphore environment | All playbooks (OpenBao AppRole auth) |
| `bao_secret_id` | Semaphore environment | All playbooks (OpenBao AppRole auth) |
| `openbao_addr` | Semaphore environment | All playbooks (OpenBao URL) |

Playbooks authenticate to OpenBao via AppRole and fetch all other credentials (Proxmox tokens, SSH keys, etc.) at runtime using the `community.hashi_vault` Ansible collection.

## Inventory

The `inventory/` directory contains **template inventories** with placeholder values. Actual host IPs and credentials are managed in a private repository and injected via Semaphore.

## Usage

### Via Semaphore (recommended)
Run task templates from the Semaphore UI.

### Via CLI
```bash
# Set OpenBao AppRole credentials
export BAO_ROLE_ID="your-role-id"
export BAO_SECRET_ID="your-secret-id"

# Run a playbook
ansible-playbook -i inventory/production.yml playbooks/proxmox-validate.yml
ansible-playbook -i inventory/production.yml playbooks/deploy-openbao.yml
```

## Dependencies

- `community.hashi_vault` Ansible collection (see `collections/requirements.yml`)
- `hvac` Python library (must be installed in the Ansible Python environment)
