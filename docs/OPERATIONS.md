# Daily Operations Guide

> This document covers day-to-day usage of the infrastructure.
> For setup, see `STEP_BY_STEP.md`. For architecture, see `ARCHITECTURE.md`.
> For disaster recovery, see `DRP.md` and `RECOVERY.md`.

---

## Table of Contents

1. [Git Repos](#1-git-repos)
2. [pass (Password Manager)](#2-pass-password-manager)
3. [Restic (Backups)](#3-restic-backups)
4. [WireGuard](#4-wireguard)
5. [Caddy (Web Server)](#5-caddy-web-server)
6. [Ansible (Infrastructure Management)](#6-ansible-infrastructure-management)
7. [Ollama (LLM Inference)](#7-ollama-llm-inference)
8. [Frigate (NVR)](#8-frigate-nvr)
9. [Common Workflows](#9-common-workflows)
10. [Troubleshooting](#10-troubleshooting)
11. [Radicale (Calendar)](#11-radicale-calendar)

---

## 1. Git Repos

### What exists

All git repos live as bare repos on rammstein (primary) and sophon (mirror).
Repos are auto-discovered from `~/repos/` on yoga -- any directory containing
`.git` gets a matching bare repo created on both servers. Post-receive hooks
on each server auto-mirror to the other over WireGuard.

### Where repos live

| Location | Path | Role |
|----------|------|------|
| yoga (local) | `~/repos/<name>/` | Working copies (clone, edit, commit) |
| rammstein | `/home/git/repos/<name>.git` | Bare repo (primary remote) |
| sophon | `/home/git/repos/<name>.git` | Bare repo (mirror, auto-synced) |

### Adding a new repo

```bash
# 1. Clone or init the repo in ~/repos/
cd ~/repos/
git clone https://github.com/nacho/project.git
# or: git init my-project && cd my-project && git remote add origin ...

# 2. Re-run the git-repos playbook (creates bare repos on rammstein + sophon)
cd ~/repos/iar-infrastructure
ansible-playbook playbooks/git-repos.yml --ask-vault-pass

# 3. Add rammstein as a remote and push
cd ~/repos/my-project
git remote add rammstein git@10.66.0.1:/home/git/repos/my-project.git
git push rammstein --all
git push rammstein --tags

# 4. Verify mirror on sophon
ssh sophon 'ls /home/git/repos/my-project.git/objects'
```

### Cloning an existing repo to a new machine

```bash
# Clone from rammstein (primary)
git clone git@10.66.0.1:/home/git/repos/<name>.git
```

### Pushing and pulling

```bash
# Push to rammstein (auto-mirrors to sophon via post-receive hook)
git push rammstein main

# Pull from rammstein
git pull rammstein main

# If rammstein is down, pull from sophon directly
git pull git@10.66.0.5:/home/git/repos/<name>.git main
```

### Removing a repo

Repos are never auto-deleted. To remove one:

```bash
# Delete on rammstein
ssh rammstein 'rm -rf /home/git/repos/<name>.git'

# Delete on sophon
ssh sophon 'rm -rf /home/git/repos/<name>.git'

# Delete locally
rm -rf ~/repos/<name>/
```

### Insurance clones of external tools

To keep a copy of an external project (e.g., pass, restic) on your servers:

```bash
# Clone upstream to ~/repos/
cd ~/repos/
git clone https://git.zx2c4.com/password-store pass

# Re-run playbook to create bare repos
cd ~/repos/iar-infrastructure
ansible-playbook playbooks/git-repos.yml --ask-vault-pass

# Add rammstein remote and push
cd ~/repos/pass
git remote add rammstein git@10.66.0.1:/home/git/repos/pass.git
git push rammstein --all
git push rammstein --tags
```

### Checking mirror status

```bash
# List repos on rammstein
ssh rammstein 'ls /home/git/repos/'

# List repos on sophon (should match)
ssh sophon 'ls /home/git/repos/'

# Check if a specific repo is mirrored
ssh sophon 'git --git-dir=/home/git/repos/<name>.git log --oneline -1'
```

---

## 2. pass (Password Manager)

### What it is

`pass` is the standard Unix password manager. Passwords are stored as
GPG-encrypted text files in `~/.password-store/`, version-controlled with git,
and backed up to rammstein + sophon via the password-store bare repo.

pass is used as a **password book**, not an autofill system. No browser
extension, no mobile sync. You look up a password when you need it:
`pass show email/gmail.com`.

### Where data lives

| Location | Path | Content |
|----------|------|---------|
| yoga | `~/.password-store/` | GPG-encrypted password files + git repo |
| rammstein | `/home/git/repos/password-store.git` | Bare repo (primary) |
| sophon | `/home/git/repos/password-store.git` | Bare repo (mirror) |

### Looking up a password

```bash
# Show a password (prompts for GPG passphrase)
pass show email/gmail.com

# Copy to clipboard (auto-clears after 45 seconds)
pass -c email/gmail.com

# List all passwords
pass ls

# Search for a password
pass find gmail
```

### Adding a password

```bash
# Interactive (prompts for password)
pass insert email/new-service.com

# Generate a random password (20 chars)
pass generate email/new-service.com 20

# Generate and copy to clipboard
pass generate -c email/new-service.com 20
```

### Organizing passwords

Passwords are organized as files in a directory tree. Use directories for
categories:

```bash
pass insert email/gmail.com
pass insert email/outlook.com
pass insert servers/rammstein
pass insert servers/sophon
pass insert banking/galicia
```

### Syncing to servers

pass uses git. Push to rammstein to sync (auto-mirrors to sophon):

```bash
# Push new passwords to rammstein
pass git push

# Pull changes (e.g., from another machine)
pass git pull
```

### Git operations

pass stores its git repo at `~/.password-store/`. Git commands run there:

```bash
# View history
pass git log

# See what changed
pass git diff

# Manual push/pull
cd ~/.password-store
git push origin main
```

### Restoring from backup

If `~/.password-store/` is lost:

```bash
# Clone from rammstein
git clone git@10.66.0.1:/home/git/repos/password-store.git ~/.password-store

# Verify GPG can decrypt (needs your GPG private key)
pass show email/gmail.com
```

Note: You need your GPG private key to decrypt passwords. The git repo only
stores encrypted files. If you lose your GPG key, the passwords are gone.
The GPG key is part of the DRP key material (see `docs/DRP.md`).

---

## 3. Restic (Backups)

### What it is

Restic performs encrypted, deduplicated, incremental backups. It runs
automatically via systemd timers. Two targets per machine:

| Machine | Primary Target | Remote Target |
|---------|---------------|---------------|
| yoga | sophon (SFTP, local network, fast) | rammstein (SFTP, offsite) |
| sophon | Local disk (`/home/restic/backups`) | rammstein (SFTP, offsite) |

Both targets are backed up in a single systemd service run. If the remote
target is unreachable, the local backup still succeeds.

### What gets backed up

Configured in `inventory/host_vars/<host>.yml`:

**yoga:**
- `/home/nacho/Documents`
- `/home/nacho/repos`
- `/home/nacho/.config`
- `/home/nacho/.ssh`

**sophon:**
- `/home/nacho/repos`
- `/home/nacho/.config`

Excludes: `.cache`, `__pycache__`, `node_modules`, `.git/objects`

### Schedule

| Task | Schedule | What it does |
|------|----------|-------------|
| Backup | Daily (systemd timer) | Backs up to both targets, prunes old snapshots |
| Check | Weekly (systemd timer) | Verifies repository integrity on both targets |

Retention: 7 daily, 4 weekly, 6 monthly, 1 yearly snapshots.

### Checking backup status

```bash
# Check if the timer is enabled and when it last ran
systemctl status restic-backup.timer
systemctl status restic-check.timer

# See last backup run (journalctl)
journalctl -u restic-backup.service -n 50

# List snapshots (on sophon, local target)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo /home/restic/backups snapshots

# List snapshots (on yoga, primary target = sophon via SFTP)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups snapshots

# List snapshots (remote target = rammstein)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.1:/home/restic/backups snapshots
```

### Running a manual backup

```bash
# On yoga (backs up to sophon + rammstein)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups \
  backup ~/Documents ~/repos ~/.config ~/.ssh

# On sophon (backs up to local disk + rammstein)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo /home/restic/backups \
  backup ~/repos ~/.config
```

### Restoring a file

```bash
# List snapshots to find the one you want
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups snapshots

# Restore a specific file from latest snapshot
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups \
  restore latest --target /tmp/restore --include /home/nacho/Documents/important.txt

# Restore entire snapshot to /tmp/restore
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups \
  restore latest --target /tmp/restore
```

### Running a repository check

```bash
# Check repository integrity (on sophon, local target)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo /home/restic/backups check

# Check and verify data (slower, reads all data packs)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo /home/restic/backups check --read-data
```

### Managing snapshots

```bash
# See what would be pruned (dry run)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups \
  forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 1 --prune --dry-run

# Actually prune (removes old snapshots and reclaims space)
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups \
  forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 1 --prune
```

### Changing what gets backed up

Edit `inventory/host_vars/<host>.yml` and modify `restic_backup_paths`:

```yaml
restic_backup_paths:
  - /home/nacho/Documents
  - /home/nacho/repos
  - /home/nacho/.config
  - /home/nacho/.ssh
  - /home/nacho/Pictures    # new path
```

Then re-run:
```bash
ansible-playbook playbooks/restic.yml --ask-vault-pass
```

---

## 4. WireGuard

### Topology

Hub and spoke. rammstein is the hub. All traffic between spokes routes through
rammstein. If rammstein is down, spokes cannot reach each other.

```
rammstein (hub, 10.66.0.1) -- public endpoint on port 51820/udp
  ├── sophon (spoke, 10.66.0.5)
  └── yoga (spoke, 10.66.0.4)
```

### Checking status

```bash
# On any host (shows peers, handshakes, transfer stats)
ssh <host> 'wg show'

# Latest handshakes (should be recent, < 5 min ago)
ssh <host> 'wg show wg0 latest-handshakes'

# Transfer stats
ssh <host> 'wg show wg0 transfer'
```

### Troubleshooting

```bash
# Check if WireGuard is running
ssh <host> 'systemctl status wg-quick@wg0'

# View logs
ssh <host> 'journalctl -u wg-quick@wg0 -f'

# Restart WireGuard on a host
ssh <host> 'sudo systemctl restart wg-quick@wg0'

# Ping a peer over WireGuard
ping 10.66.0.1    # rammstein
ping 10.66.0.5    # sophon
ping 10.66.0.4    # yoga
```

### Adding a new peer

1. Generate keys: `wg genkey | tee /tmp/new.key | wg pubkey > /tmp/new.pub`
2. Add to vault:
   ```bash
   ansible-vault edit inventory/group_vars/all/vault.yml
   # Add to wg_private_keys and wg_public_keys
   ```
3. Add host to `inventory/hosts.yml` in the `wg_peers` group with `wg_ip: 10.66.0.6`
4. Create `inventory/host_vars/<new-host>.yml` with `wg_ip` and `ansible_user`
5. Add to `~/.ssh/config`
6. Re-run: `ansible-playbook playbooks/wireguard.yml --ask-vault-pass`

---

## 5. Caddy (Web Server)

### What it does

Caddy runs on rammstein and serves all domains with automatic TLS (Let's
Encrypt). It handles three site types: static pages, reverse proxies, and
redirects.

### Current sites

| Domain | Type | Backend |
|--------|------|---------|
| randazzo.ar | static | /var/www/randazzo.ar |
| randazzo.com.ar | redirect | -> https://randzzo.ar |
| camaras.randazzo.ar | proxy | sophon:8971 (Frigate) |

### Checking status

```bash
# Caddy running?
ssh rammstein 'systemctl status caddy'

# Test a domain
curl -I https://randazzo.ar
curl -I https://camaras.randazzo.ar

# View Caddyfile
ssh rammstein 'cat /etc/caddy/Caddyfile'

# View logs
ssh rammstein 'journalctl -u caddy -f'
```

### Adding a new domain

1. Point DNS to rammstein's IP at your registrar.
2. Add site to `inventory/host_vars/rammstein.yml`:
   ```yaml
   caddy_sites:
     - domain: "new.randazzo.ar"
       type: static
       root: "/var/www/new.randazzo.ar"
   ```
3. Re-run: `ansible-playbook playbooks/caddy.yml --ask-vault-pass`
4. Caddy obtains the TLS certificate automatically on first request.

### Updating static site content

Static site files are deployed by the `static-site` role. To update content:

```bash
# Update the source files in the infra repo (roles/static-site/templates/ or files/)
# Then re-run the playbook
ansible-playbook playbooks/static-page.yml --ask-vault-pass
# or
ansible-playbook playbooks/portfolio-page.yml --ask-vault-pass
```

---

## 6. Ansible (Infrastructure Management)

### What it is

All server state is defined in Ansible playbooks. Running the playbooks on
fresh servers reproduces the entire infrastructure. Ansible is idempotent --
running it again won't break anything.

### Vault

All secrets are in `inventory/group_vars/all/vault.yml`, encrypted with
ansible-vault. The vault password is stored in pass and on paper (DRP).

```bash
# Edit vault
ansible-vault edit inventory/group_vars/all/vault.yml --ask-vault-pass

# View vault (read-only)
ansible-vault view inventory/group_vars/all/vault.yml --ask-vault-pass

# Re-encrypt after changes
ansible-vault encrypt inventory/group_vars/all/vault.yml --ask-vault-pass
```

### Running playbooks

```bash
# Full deployment (everything)
ansible-playbook playbooks/site.yml --ask-vault-pass

# Individual roles
ansible-playbook playbooks/base.yml --ask-vault-pass
ansible-playbook playbooks/wireguard.yml --ask-vault-pass
ansible-playbook playbooks/caddy.yml --ask-vault-pass
ansible-playbook playbooks/git-repos.yml --ask-vault-pass
ansible-playbook playbooks/pass.yml --ask-vault-pass
ansible-playbook playbooks/restic.yml --ask-vault-pass
ansible-playbook playbooks/ollama.yml --ask-vault-pass
ansible-playbook playbooks/nvidia.yml --ask-vault-pass

# Limit to a specific host
ansible-playbook playbooks/base.yml --ask-vault-pass --limit sophon
```

### Checking connectivity

```bash
# Ping all hosts
ansible all -m ping --ask-vault-pass

# Ping a specific host
ansible rammstein -m ping --ask-vault-pass
```

### Adding a new host

1. Provision the server (manual, see `STEP_BY_STEP.md` Step 7)
2. Add to `inventory/hosts.yml` in the appropriate groups
3. Create `inventory/host_vars/<host>.yml` with `ansible_user` and `wg_ip`
4. Add to `~/.ssh/config`
5. Run: `ansible-playbook playbooks/site.yml --ask-vault-pass --limit <host>`
6. For WireGuard: add keys to vault, add to `wg_peers` group, re-run wireguard playbook

---

## 7. Ollama (LLM Inference)

### What it is

Ollama runs on sophon with GPU offloading (RTX 3080). It serves local LLMs
over the WireGuard network. No cloud, no telemetry.

### Checking status

```bash
# Is Ollama running?
ssh sophon 'systemctl status ollama'

# List installed models
ssh sophon 'curl -s http://10.66.0.5:11434/api/tags | jq -r ".models[].name"'

# Test inference
ssh sophon 'curl -s http://10.66.0.5:11434/api/generate -d "{\"model\":\"glm-5.2:cloud\",\"prompt\":\"Hello\",\"stream\":false}" | jq -r ".response"'
```

### Managing models

```bash
# Pull a new model
ssh sophon 'ollama pull <model-name>'

# Remove a model
ssh sophon 'ollama rm <model-name>'

# List models
ssh sophon 'ollama list'
```

### Accessing from yoga

Ollama binds to `10.66.0.5:11434` (WireGuard only). From yoga:

```bash
# Test connectivity
curl http://10.66.0.5:11434/api/tags

# Use with any OpenAI-compatible client
# Endpoint: http://10.66.0.5:11434
```

---

## 8. Frigate (NVR)

### What it is

Frigate runs on sophon with NVIDIA TensorRT object detection. 8 cameras
(3 interior, 5 exterior). Web UI accessible via camaras.randazzo.ar (proxied
through Caddy on rammstein).

### Checking status

```bash
# Frigate running?
ssh sophon 'podman ps | grep frigate'

# Access web UI (from any browser)
# https://camaras.randazzo.ar
```

---

## 9. Common Workflows

### Adding a new project to git hosting

```bash
cd ~/repos/
git init my-project && cd my-project
# ... create files, commit ...
cd ~/repos/iar-infrastructure
ansible-playbook playbooks/git-repos.yml --ask-vault-pass
cd ~/repos/my-project
git remote add rammstein git@10.66.0.1:/home/git/repos/my-project.git
git push rammstein --all
```

### Insurance cloning an external tool

```bash
cd ~/repos/
git clone https://github.com/upstream/tool.git
cd ~/repos/iar-infrastructure
ansible-playbook playbooks/git-repos.yml --ask-vault-pass
cd ~/repos/tool
git remote add rammstein git@10.66.0.1:/home/git/repos/tool.git
git push rammstein --all
git push rammstein --tags
```

### Monthly backup verification

```bash
# 1. Check that backups are running
journalctl -u restic-backup.service -n 20

# 2. List recent snapshots
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups snapshots

# 3. Restore a random file and verify it's correct
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups \
  restore latest --target /tmp/restore-test --include /home/nacho/.ssh/authorized_keys
diff ~/.ssh/authorized_keys /tmp/restore-test/home/nacho/.ssh/authorized_keys

# 4. Clean up
rm -rf /tmp/restore-test

# 5. Run repository check
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups check
```

### Full health check

```bash
# All hosts reachable
ansible all -m ping --ask-vault-pass

# WireGuard
ssh rammstein 'wg show wg0'

# Web services
curl -I https://randazzo.ar
curl -I https://camaras.randazzo.ar

# Git repos
ssh rammstein 'ls /home/git/repos/'
ssh sophon 'ls /home/git/repos/'

# Restic snapshots
RESTIC_PASSWORD_FILE=~/.config/restic-password \
  restic --repo sftp:restic@10.66.0.5:/home/restic/backups snapshots

# Ollama
ssh sophon 'curl -s http://10.66.0.5:11434/api/tags | jq -r ".models[].name"'
```

---

## 10. Troubleshooting

### Can't push to git remote

```bash
# Test SSH access to git user on rammstein
ssh git@10.66.0.1  # should say "interactive shell not allowed" (git-shell)

# Test git operations
ssh git@10.66.0.1 'git-upload-pack /home/git/repos/<name>.git'

# Check if repo exists
ssh rammstein 'ls /home/git/repos/<name>.git/'

# Check permissions
ssh rammstein 'ls -la /home/git/repos/<name>.git/'
```

### Restic backup failing

```bash
# Check service logs
journalctl -u restic-backup.service -n 50

# Common causes:
# 1. SFTP target unreachable (WireGuard down, host down)
# 2. Password file missing (~/.config/restic-password)
# 3. Disk full on target

# Test SFTP access
sftp restic@10.66.0.5
sftp restic@10.66.0.1
```

### WireGuard handshake failing

```bash
# Check if both sides have matching keys
ssh rammstein 'wg show wg0'
ssh sophon 'wg show wg0'

# Check if endpoint is reachable
nc -zu randazzo.ar 51820

# Restart WireGuard on both sides
ssh rammstein 'sudo systemctl restart wg-quick@wg0'
ssh sophon 'sudo systemctl restart wg-quick@wg0'
```

### Caddy not serving a domain

```bash
# Check Caddy logs for TLS errors
ssh rammstein 'journalctl -u caddy -f'

# Verify DNS points to rammstein
dig <domain> +short

# Check Caddyfile
ssh rammstein 'cat /etc/caddy/Caddyfile'

# Restart Caddy
ssh rammstein 'sudo systemctl restart caddy'
```

### Ansible playbook failing

```bash
# Syntax check
ansible-playbook playbooks/<name>.yml --syntax-check --ask-vault-pass

# Verbose output
ansible-playbook playbooks/<name>.yml --ask-vault-pass -vvv

# Common causes:
# 1. Vault password wrong
# 2. Host unreachable (SSH config, WireGuard down)
# 3. Host key changed (remove from ~/.ssh/known_hosts)
# 4. Missing variable (check host_vars/group_vars)
```

### pass can't decrypt

```bash
# Check if GPG key is available
gpg --list-secret-keys --keyid-format long

# Check if .gpg-id points to the right key
cat ~/.password-store/.gpg-id

# Test GPG decryption
echo "test" | gpg --encrypt --recipient <key-id> | gpg --decrypt

# If GPG key is lost, passwords are unrecoverable.
# Restore GPG key from DRP backup (see docs/DRP.md).
```

---


## 11. Radicale (Calendar)

### What it is

Radicale is a lightweight CalDAV server running on rammstein. It provides
calendar sync to phone and laptop without depending on a provider. Caddy
handles TLS and reverse proxies to Radicale on localhost:5232.

### Architecture

```
Phone/Laptop -> https://caldav.randazzo.ar (Caddy, TLS + basic auth)
               -> localhost:5232 (Radicale, CalDAV)
                 -> /var/lib/radicale/collections/ (calendar data on disk)

Daily at 3:00 AM:
  systemd timer -> backup-calendar.sh -> git clone/pull notes repo
                                         -> rsync calendar data
                                         -> git commit + push
```

Calendar data is backed up to the `notes` git bare repo via a systemd timer
that runs daily at 3:00 AM. The timer copies calendar files to a git working
copy, commits, and pushes to rammstein (auto-mirrors to sophon).

### Where data lives

| Location | Path | Content |
|----------|------|---------|
| rammstein | `/var/lib/radicale/collections/` | Calendar data (plain files on disk) |
| rammstein | `/var/lib/radicale/backup/` | Git working copy for backup |
| rammstein + sophon | `notes` bare repo | Calendar backup in `calendar/` directory |

### Setup (one-time, already done by Ansible)

The Radicale role handles everything. What was deployed:
- `radicale3` package installed on rammstein
- `httpd-tools` installed (for htpasswd)
- Radicale config at `/etc/radicale/config` (localhost bind, bcrypt auth)
- htpasswd file at `/etc/radicale/users` (user: nacho, bcrypt-hashed)
- Hardened systemd service `radicale.service`
- Caddy reverse proxy block for `caldav.randazzo.ar`
- SSH key for radicale user (to push to git bare repo)
- systemd timer `radicale-backup.timer` (daily at 3:00 AM)
- Backup script at `/etc/radicale/backup-calendar.sh`

### Prerequisites (manual, one-time)

1. **DNS:** Point `caldav.randazzo.ar` to rammstein's IP at your registrar
2. **Vault:** Add `radicale_password` to the Ansible vault:
   ```bash
   ansible-vault edit inventory/group_vars/all/vault.yml
   # Add: radicale_password: "your-strong-password"
   ```
3. **pass:** Store the password for easy lookup:
   ```bash
   pass insert calendar/radicale
   ```
4. **Deploy:** Run the playbook:
   ```bash
   ansible-playbook playbooks/radicale.yml --ask-vault-pass
   ```

### Connecting your phone

1. Open your phone's calendar app settings
2. Add a new CalDAV account:
   - **Server:** `https://caldav.randazzo.ar`
   - **Username:** `nacho`
   - **Password:** (look it up with `pass show calendar/radicale`)
3. The phone will sync calendars over HTTPS

**Android:** Settings -> Accounts -> Add Account -> CalDAV.
If your phone doesn't have a built-in CalDAV client, use DAVx5 (open source,
F-Droid). Enter the server URL, username, and password. DAVx5 syncs
automatically in the background.

**iOS:** Settings -> Calendar -> Accounts -> Add Account -> Other ->
Add CalDAV Account. Server: `https://caldav.randazzo.ar`.

### Connecting your laptop

**GNOME Calendar:** Settings -> Online Accounts -> Add CalDAV.
Server: `https://caldav.randazzo.ar`, username: `nacho`.

**Thunderbird:** File -> New -> Calendar -> On the Network -> CalDAV.
URL: `https://caldav.randzzo.ar`, username: `nacho`.

### Verifying the deployment

```bash
# 1. Radicale service running?
ssh rammstein 'systemctl status radicale'

# 2. Caddy proxying correctly?
curl -I https://caldav.randazzo.ar
# Should return 401 (Unauthorized) without credentials, 200 with

# 3. Test with credentials (prompts for password)
curl -u nacho -I https://caldav.randazzo.ar
# Should return 200

# 4. Radicale responding on localhost?
ssh rammstein 'curl -u nacho -I http://localhost:5232'
# Should return 200

# 5. Calendar data directory exists?
ssh rammstein 'ls -la /var/lib/radicale/collections/'
# Empty until a client creates a calendar

# 6. Backup timer enabled?
ssh rammstein 'systemctl status radicale-backup.timer'

# 7. Backup script exists?
ssh rammstein 'cat /etc/radicale/backup-calendar.sh'
```

### Checking status

```bash
# Radicale running?
ssh rammstein 'systemctl status radicale'

# Check calendar data on disk
ssh rammstein 'ls -R /var/lib/radicale/collections/'

# Backup timer status
ssh rammstein 'systemctl status radicale-backup.timer'

# When is the next backup?
ssh rammstein 'systemctl list-timers radicale-backup.timer'
```

### Checking backup status

```bash
# Check last backup run
ssh rammstein 'journalctl -u radicale-backup.service -n 20'

# Check the backup repo log
ssh rammstein 'cd /var/lib/radicale/backup && git log --oneline -5'

# Verify calendar data is in the notes repo
ssh rammstein 'ls /var/lib/radicale/backup/calendar/'

# Run backup manually (test)
ssh rammstein 'sudo systemctl start radicale-backup.service'
ssh rammstein 'journalctl -u radicale-backup.service -n 20'
```

### Troubleshooting

```bash
# Radicale not starting
ssh rammstein 'journalctl -u radicale -f'

# Caddy proxy not working
curl -I https://caldav.randazzo.ar
ssh rammstein 'grep -A10 "radicale" /etc/caddy/Caddyfile'

# Calendar not syncing to phone
# 1. Check phone has internet (doesn't need WireGuard -- Caddy is public)
# 2. Check password is correct (pass show calendar/radicale)
# 3. Check Radicale is running (ssh rammstein 'systemctl status radicale')
# 4. Check Caddy is proxying (curl -I https://caldav.randazzo.ar)
# 5. Check Radicale responds on localhost (ssh rammstein 'curl -u nacho -I http://localhost:5232')

# Backup not running
ssh rammstein 'systemctl status radicale-backup.timer'
ssh rammstein 'journalctl -u radicale-backup.service -n 50'

# DNS not resolving
dig caldav.randazzo.ar +short
# Should return rammstein's IP
```

---

## Quick Reference: File Locations

| What | Where | Notes |
|------|-------|-------|
| Ansible playbooks | `~/repos/iar-infrastructure/playbooks/` | All infrastructure as code |
| Ansible roles | `~/repos/iar-infrastructure/roles/` | One role per service |
| Vault (secrets) | `inventory/group_vars/all/vault.yml` | Encrypted, never commit plaintext |
| Host configs | `inventory/host_vars/<host>.yml` | Per-host variables |
| Inventory | `inventory/hosts.yml` | Host groups and assignments |
| Git bare repos | `git@10.66.0.1:/home/git/repos/<name>.git` | rammstein (primary) |
| Git bare repos | `git@10.66.0.5:/home/git/repos/<name>.git` | sophon (mirror) |
| Password store | `~/.password-store/` | GPG-encrypted, git-backed |
| Restic password | `~/.config/restic-password` | Plain text, mode 0600 |
| Restic repos | sophon: `/home/restic/backups`, rammstein: `/home/restic/backups` | Encrypted |
| Caddyfile | `/etc/caddy/Caddyfile` on rammstein | Generated by Ansible |
| WireGuard config | `/etc/wireguard/wg0.conf` on each host | Generated by Ansible |
| Radicale config | `/etc/radicale/config` on rammstein | Generated by Ansible |
| Radicale htpasswd | `/etc/radicale/users` on rammstein | bcrypt-hashed, mode 0640 |
| Radicale data | `/var/lib/radicale/collections/` on rammstein | Calendar data on disk |
| Radicale backup | `/var/lib/radicale/backup/` on rammstein | Git working copy for backup |
| Radicale backup script | `/etc/radicale/backup-calendar.sh` on rammstein | Runs daily via systemd timer |
