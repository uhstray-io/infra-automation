# Infrastructure Automation

Ansible playbooks and Proxmox automation for uhstray.io infrastructure. Managed by [Semaphore](http://192.168.1.117:3000).

## Playbooks

| Playbook | Purpose |
|----------|---------|
| `deploy-all.yml` | Deploy all services in dependency order |
| `deploy-service.yml` | Deploy a single service (`-e target_service=<name>`) |
| `deploy-openbao.yml` | Clone openbao repo + run deploy.sh on OpenBao VM |
| `update-service.yml` | Pull latest images + restart + validate |
| `validate-all.yml` | Health check all services |
| `proxmox-validate.yml` | Pre/post Proxmox cluster validation (8 checks) |
| `provision-template.yml` | Create Ubuntu 24.04 VM template from ISO |
| `provision-vm.yml` | Clone template, configure cloud-init, start VM |

## Secrets

This is a **public repository**. All secrets are injected at runtime via Semaphore environment variables:

| Variable | Source | Used By |
|----------|--------|---------|
| `PVE_TOKEN_SECRET` | Semaphore env | proxmox-validate, provision-* playbooks |
| `SSH_PUBLIC_KEY` | Semaphore env | provision-template, provision-vm |
| `SEMAPHORE_RUNNER_TOKEN` | Semaphore env | provision-vm (runner setup) |

## Usage

### Via Semaphore (recommended)
Run task templates from the Semaphore UI at `http://192.168.1.117:3000`.

### Via CLI
```bash
# Set secrets as env vars
export PVE_TOKEN_SECRET="your-proxmox-token"

# Run a playbook
ansible-playbook -i inventory/production.yml playbooks/proxmox-validate.yml
ansible-playbook -i inventory/production.yml playbooks/deploy-openbao.yml
ansible-playbook -i inventory/production.yml playbooks/provision-vm.yml -e target_service=openbao
```
