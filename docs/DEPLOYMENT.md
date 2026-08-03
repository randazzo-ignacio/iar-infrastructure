# Deployment Guide

## Phase 1: Preparation (Local Machine)

### 1.1 Install Ansible
```bash
# Fedora
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
- `pass_gpg_id.yoga` (generate: `gpg --full-generate-key`, then `gpg --list-secret-keys --keyid-format long`)
- `restic_password` (strong passphrase for backup encryption)
- `frigate_camera_rtsp_user` / `frigate_camera_rtsp_password`
- `iar_telegram_bot_token` / `iar_telegram_chat_id`

### 1.6 Encrypt the Vault
```bash
ansible-vault encrypt inventory/group_vars/all/vault.yml --ask-vault-pass
```

### 1.7 Configure SSH Config
Add host entries to `~/.ssh/config` for Ansible to resolve hosts:
```
Host rammstein
  Hostname randazzo.ar
  User riemann
  IdentityFile ~/.ssh/id_ed25519

Host sophon
  Hostname 10.66.0.5
  User nacho
  IdentityFile ~/.ssh/id_ed25519

Host yoga
  Hostname 10.66.0.4
  User nacho
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
3. **caddy** -- reverse proxy with TLS (rammstein only)
4. **git-repo** -- bare repos on rammstein + sophon with auto-mirroring
5. **pass** -- password manager on yoga (GPG + git backup)
6. **restic** -- backup client on yoga + sophon, remote target on rammstein
7. **podman** -- container runtime on all hosts
8. **nvidia** -- GPU drivers and toolkit (sophon only)
9. **ollama** -- model serving (sophon only)
10. **frigate** -- NVR with TensorRT (sophon only)
11. **static-site** -- portfolio and landing pages (rammstein only)
12. **iar-agent** -- i.ar agent timers (sophon only)

### 3.2 Verify WireGuard
```bash
ssh rammstein 'wg show wg0'
```

### 3.3 Verify Web Services
```bash
curl -I https://randazzo.ar
curl -I https://i.ar
curl -I https://camaras.randazzo.ar
```

### 3.4 Verify Git Repos
```bash
# On yoga, test clone:
git clone git@10.66.0.1:/srv/git/notes.git
cd notes && echo "test" > README.md && git add . && git commit -m "test" && git push
# Verify mirror on sophon:
ssh sophon 'ls /srv/git/notes.git/objects'
```

### 3.5 Verify Restic
```bash
# Manual backup test on yoga:
sudo restic --repo sftp:restic@10.66.0.5:/srv/restic backup /home/nacho/Documents
sudo restic --repo sftp:restic@10.66.0.1:/srv/restic backup /home/nacho/Documents
# Check snapshots:
sudo restic --repo sftp:restic@10.66.0.5:/srv/restic snapshots
```

---

## Phase 4: Post-Deployment

### 4.1 Cleanup
```bash
rm -rf wg-keys/
```

### 4.2 Save Backup
Store in a secure location:
- Vault password
- SSH private key (`~/.ssh/id_ed25519`)
- Restic password (also store in pass + on paper for DRP)
- GPG key (pass encryption key)

### 4.3 Document Any Manual Changes
If you make manual changes to any server, update the Ansible playbooks to match.
The goal is: **if the playbooks are run on fresh servers, the result is identical.**

---

## Standalone Playbooks

Individual roles can be run independently:

| Playbook | Purpose | Hosts |
|----------|---------|-------|
| `playbooks/site.yml` | Full deployment | All |
| `playbooks/base.yml` | Base hardening only | All |
| `playbooks/wireguard.yml` | WG mesh only | All |
| `playbooks/caddy.yml` | Caddy only | web_servers |
| `playbooks/git-repos.yml` | Git bare repos only | rammstein, sophon |
| `playbooks/pass.yml` | pass password manager | yoga |
| `playbooks/restic.yml` | Restic backup setup | rammstein, sophon, yoga |
| `playbooks/portfolio-page.yml` | Deploy portfolio page | web_servers |
| `playbooks/static-page.yml` | Deploy i.ar landing page | web_servers |