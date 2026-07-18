# Infrastructure as Code -- Ansible

Complete, reproducible infrastructure for 3 cloud servers + 2 local machines,
unified by a WireGuard mesh network.

**All servers run Fedora Server 44 or AlmaLinux 10.** The playbooks target
RHEL-family systems only -- no Debian/Ubuntu or Arch Linux branches.

## Quick Start

```bash
# 1. Generate WireGuard keys (one-time)
./scripts/generate-wg-keys.sh

# 2. Copy vault template and fill in secrets
cp vault.yml.template inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml

# 3. Encrypt the vault file
ansible-vault encrypt inventory/group_vars/all/vault.yml --ask-vault-pass

# 4. Edit inventory with your actual IPs and host_vars
vim inventory/host_vars/<host>.yml

# 5. Run the full playbook
ansible-playbook playbooks/site.yml --ask-vault-pass

# Or run individual playbooks:
ansible-playbook playbooks/base.yml          --ask-vault-pass
ansible-playbook playbooks/wireguard.yml     --ask-vault-pass
ansible-playbook playbooks/caddy.yml         --ask-vault-pass
ansible-playbook playbooks/ai_playground.yml --ask-vault-pass
ansible-playbook playbooks/ollama.yml        --ask-vault-pass
```

## Architecture Summary

| Host          | Domain         | WG IP       | Role                          |
|---------------|----------------|-------------|-------------------------------|
| rammstein     | randazzo.ar    | 10.66.0.1   | Proxy hub, Caddy              |
| greenday      | 0b.ar          | 10.66.0.2   | AI playground, Podman          |
| daftpunk      | i.ar           | 10.66.0.3   | Ollama, static page, Grafana   |
| yoga          | (local)        | 10.66.0.4   | Laptop (Silverblue)            |
| sophon        | (local)        | 10.66.0.5   | GPU Ollama, Frigate NVR        |

## Variable Hierarchy (DRY)

Variables are defined in a layered hierarchy -- each layer overrides the one above:

| Layer | File | Purpose |
|-------|------|---------|
| 1. Role defaults | `roles/<name>/defaults/main.yml` | Safe defaults for standalone role use |
| 2. Group vars (all) | `inventory/group_vars/all/main.yml` | Global settings: packages, domains, WG |
| 3. Group vars (group) | `inventory/group_vars/<group>.yml` | Per-group settings |
| 4. Host vars | `inventory/host_vars/<host>.yml` | Per-host settings: WG IP, enabled services |
| 5. Vault | `inventory/group_vars/all/vault.yml` | Secrets (encrypted) |

**Rule:** Define a variable at the *highest* layer where it is constant.
Only push it down to host_vars when it varies per host.

## Inventory Groups

The inventory uses functional groups so playbooks target by *role*, not hostname:

- `cloud` -- all VPS hosts
- `local` -- all local machines
- `proxy` -- hosts running Caddy (rammstein)
- `ai_playground` -- hosts running Podman + AI agent (greenday)
- `ollama_hosts` -- hosts running Ollama (daftpunk, sophon)
- `frigate_hosts` -- hosts running Frigate NVR (sophon)
- `wg_hub` -- WireGuard hub (rammstein)
- `wg_peers` -- all hosts in the WireGuard mesh
- `gpu_hosts` -- NVIDIA GPU hosts (sophon)
- `web_servers` -- static site hosts (rammstein, daftpunk)
- `monitoring` -- Prometheus + Grafana stack (daftpunk)

Hosts can belong to multiple groups. Adding a new host to a group
automatically includes it in the relevant playbooks.

See `docs/` for full documentation and `GUIDELINES.org` for coding conventions.