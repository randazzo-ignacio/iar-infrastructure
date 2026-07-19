# Deployment Guide

## Phase 1: Preparation (Local Machine)

### 1.1 Install Ansible
```bash
# Fedora / AlmaLinux
sudo dnf install ansible
```

### 1.2 Generate SSH Key (if not existing)
```bash
ssh-keygen -t ed25519 -C "infrastructure-admin" -f ~/.ssh/id_ed25519
```

### 1.3 Clone This Repo
```bash
git clone <your-repo-url> infrastructure
cd infrastructure
```

### 1.4 Generate WireGuard Keys
```bash
./scripts/generate-wg-keys.sh
```
This creates `wg-keys/` with private/public keypairs for each host and a YAML snippet to paste into the vault file.

### 1.5 Copy Vault Template and Fill In Secrets
```bash
cp vault.yml.template inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
```
Replace all placeholder values:
- `wg_private_keys` / `wg_public_keys` (from `wg-keys/vault-snippet.yml`)
- `grafana_admin_password`
- `frigate_camera_rtsp_user` / `frigate_camera_rtsp_password`
- `ai_agent_ssh_public_key` (generate: `ssh-keygen -t ed25519 -f ~/.ssh/ai_agent_key`)
- `iar_telegram_bot_token` / `iar_telegram_chat_id`

### 1.6 Encrypt the Vault
```bash
ansible-vault encrypt inventory/group_vars/all/vault.yml --ask-vault-pass
```

### 1.7 Configure Host Variables
Set per-host settings in `inventory/host_vars/<host>.yml`:
- `ansible_user` (per-host admin username)
- `wg_ip` (WireGuard IP)
- Service enable flags and configuration

### 1.8 Configure SSH Config
Add host entries to `~/.ssh/config` for Ansible to resolve hosts:
```
Host rammstein
  Hostname randazzo.ar
  User riemann
  IdentityFile ~/.ssh/id_ed25519
```

---

## Phase 2: Provision Hosts

Before running Ansible, each host must have:
1. A passwordless sudo admin user (the `ansible_user` for that host)
2. Your SSH public key in the admin user's `authorized_keys`
3. The host reachable via your SSH config

This is a manual one-time provisioning step. See `docs/STEP_BY_STEP.md` for details.

---

## Phase 3: Deploy

### 3.1 Full Deployment
```bash
ansible-playbook playbooks/site.yml --ask-vault-pass
```

This runs in order:
1. **base** -- hardening, updates, firewalld, sysctl, SSH
2. **wireguard** -- mesh network (hub first, then spokes)
3. **caddy** -- reverse proxy with TLS
4. **podman** -- container runtime on all hosts
5. **nvidia** -- GPU drivers and toolkit (gpu_hosts only)
6. **ai-environment** -- AI agent user, workspace, limits
7. **ollama** -- model serving (ollama_hosts)
8. **frigate** -- NVR with TensorRT (frigate_hosts)
9. **static-site** -- portfolio and landing pages (web_servers)
10. **monitoring** -- Prometheus + Grafana (monitoring group)
11. **node-exporter** -- host metrics on all hosts
12. **iar-agent** -- i.ar agent timers (hosts with iar_agents_enabled)

### 3.2 Verify WireGuard
```bash
ssh rammstein 'wg show wg0'
```

### 3.3 Verify Web Services
```bash
curl -I https://randazzo.ar
curl -I https://i.ar
curl -I https://0b.ar
curl -I https://grafana.i.ar
curl -I https://camaras.randazzo.ar
```

### 3.4 Verify Ollama
```bash
ssh rammstein 'curl http://10.66.0.3:11434/api/tags'  # daftpunk
ssh rammstein 'curl http://10.66.0.5:11434/api/tags'  # sophon
```

---

## Phase 4: Local Machines

```bash
# Base + WireGuard for all local machines:
ansible-playbook playbooks/base.yml --ask-vault-pass --limit local
ansible-playbook playbooks/wireguard.yml --ask-vault-pass --limit local

# GPU + Ollama + Frigate for sophon:
ansible-playbook playbooks/nvidia.yml --ask-vault-pass --limit sophon
ansible-playbook playbooks/ollama.yml --ask-vault-pass --limit sophon
```

---

## Phase 5: Post-Deployment

### 5.1 Cleanup
```bash
rm -rf wg-keys/
```

### 5.2 Save Backup
Store in a secure location:
- Vault password
- SSH private key (`~/.ssh/id_ed25519`)
- AI agent SSH key (`~/.ssh/ai_agent_key`)
- Git remote URL

### 5.3 Document Any Manual Changes
If you make manual changes to any server, update the Ansible playbooks to match.
The goal is: **if the playbooks are run on fresh servers, the result is identical.**