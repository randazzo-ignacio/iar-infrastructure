# Step-by-Step Deployment -- Read This First

> You have 1 cloud server (rammstein) and 2 local machines (sophon, yoga).
> Domains already point to rammstein's IP. This guide takes you from zero
> to running, one step at a time.
>
> **Do these steps in order. Don't skip ahead. Each one depends on the last.**
>
> **All servers run Fedora Server 44 or Fedora Silverblue.**

---

## STEP 0: Get the files to your local machine

```bash
git clone <your-repo-url> ~/repos/iar-infrastructure
cd ~/repos/iar-infrastructure
```

You should be inside the `iar-infrastructure/` folder for every step from here on.

---

## STEP 1: Install Ansible

```bash
# Fedora Workstation / Server
sudo dnf install -y ansible
```

On Fedora Silverblue (yoga), Ansible is available in the base image or via `rpm-ostree install ansible` (requires reboot).

Verify:
```bash
ansible --version
```

---

## STEP 2: Make sure you have an SSH key

```bash
ls ~/.ssh/id_ed25519.pub
```

If not, generate one:
```bash
ssh-keygen -t ed25519 -C "infrastructure" -f ~/.ssh/id_ed25519
```

---

## STEP 3: Generate WireGuard keys

```bash
# Install wireguard-tools if needed:
sudo dnf install -y wireguard-tools

# Generate keys for all 3 hosts:
bash scripts/generate-wg-keys.sh
```

This creates `wg-keys/` with keypairs and `wg-keys/vault-snippet.yml` ready to paste into the vault.

---

## STEP 4: Fill in the vault

```bash
cp vault.yml.template inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
```

Replace all placeholder values:
- `wg_private_keys` / `wg_public_keys` (from `wg-keys/vault-snippet.yml`)
- `pass_gpg_id.yoga` (generate: `gpg --full-generate-key`, then `gpg --list-secret-keys --keyid-format long`)
- `restic_password` (strong passphrase for backup encryption)
- `frigate_camera_rtsp_user` / `frigate_camera_rtsp_password` (camera credentials)
- `iar_telegram_bot_token` / `iar_telegram_chat_id` (from Telegram BotFather)

Encrypt:
```bash
ansible-vault encrypt inventory/group_vars/all/vault.yml --ask-vault-pass
```

---

## STEP 5: Configure host variables

Each host needs `host_vars/<host>.yml` with:
- `ansible_user` (per-host admin username)
- `wg_ip` (WireGuard IP)
- Service enable flags and configuration

Review and edit:
```bash
vim inventory/host_vars/rammstein.yml
vim inventory/host_vars/sophon.yml
vim inventory/host_vars/yoga.yml
```

---

## STEP 6: Configure SSH config

Add host entries to `~/.ssh/config` so Ansible can resolve hosts:

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

## STEP 7: Provision admin users on new servers

Before Ansible can run, each server needs:
1. A passwordless sudo admin user (matching the `ansible_user` in host_vars)
2. Your SSH public key in the admin user's `authorized_keys`

This is a manual one-time step per server:
```bash
# SSH in as root (initial access)
ssh root@<server-ip>

# Create admin user with passwordless sudo
useradd -m -G wheel <admin-username>
echo "<admin-username> ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/<admin-username>
chmod 440 /etc/sudoers.d/<admin-username>

# Add your SSH key
mkdir -p /home/<admin-username>/.ssh
cp ~/.ssh/authorized_keys /home/<admin-username>/.ssh/
chown -R <admin-username>:<admin-username> /home/<admin-username>/.ssh
chmod 700 /home/<admin-username>/.ssh
chmod 600 /home/<admin-username>/.ssh/authorized_keys
```

Or use `ssh-copy-id`:
```bash
ssh-copy-id <admin-username>@<server-ip>
```

---

## STEP 8: Test that Ansible can reach your servers

```bash
ansible all -m ping --ask-vault-pass
```

You should see `SUCCESS` for each server. Fix any unreachable hosts before continuing.

---

## STEP 9: Run the full deployment

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass
```

**This will take 5-15 minutes.** Green = OK, Yellow = Changed, Red = Failed.

The playbook scans `~/repos/` on your local machine for git repositories
and creates matching bare repos on rammstein + sophon with auto-mirroring.
Make sure any repos you want hosted are cloned in `~/repos/` before running.

If it gets stuck on Ollama model pulling, that's normal -- large models take a while to download.

---

## STEP 10: Verify the deployment

### Check WireGuard:
```bash
ssh rammstein "wg show wg0"
```

### Check Caddy:
```bash
curl -I https://randazzo.ar
curl -I https://i.ar
```

### Check Ollama (on sophon):
```bash
ssh sophon "curl -s http://10.66.0.5:11434/api/tags | jq -r '.models[].name'"
```

### Check Git repos:
```bash
# List bare repos on rammstein
ssh rammstein "ls /home/git/repos/"
# List bare repos on sophon (should mirror)
ssh sophon "ls /home/git/repos/"
```

### Check Restic:
```bash
# List snapshots on sophon (local target)
ssh sophon "RESTIC_PASSWORD_FILE=/home/nacho/.config/restic-password restic --repo /home/restic/backups snapshots"
```

---

## STEP 11: Clean up

```bash
rm -rf wg-keys/
```

---

## STEP 12: Save your backups

Store in a secure location (password manager, encrypted USB):

1. Vault password
2. `~/.ssh/id_ed25519` (admin SSH private key)
3. Restic password (also in pass + on paper for DRP)
4. GPG key (pass encryption key)

---

## You're done. Here's what you have:

- **1 cloud server** (rammstein): Caddy reverse proxy, TLS for all domains, git bare repos, restic remote target, WireGuard hub
- **1 local GPU server** (sophon): Ollama with GPU, Frigate NVR with 8 cameras, git bare repo mirror, restic local target
- **1 laptop** (yoga): pass password manager, restic backup client, daily driver
- **WireGuard mesh** -- all machines communicate privately
- **Git bare repos** -- auto-discovered from ~/repos/, mirrored between rammstein + sophon
- **Restic backups** -- daily automated, dual-target (sophon local + rammstein offsite)
- **pass** -- password manager with GPG encryption, backed up to git
- **Everything in code** -- rebuild by running the playbook on fresh servers

## If something breaks later:

```bash
# Re-run everything:
ansible-playbook playbooks/site.yml --ask-vault-pass

# Or just one piece:
ansible-playbook playbooks/wireguard.yml --ask-vault-pass
ansible-playbook playbooks/caddy.yml --ask-vault-pass
ansible-playbook playbooks/git-repos.yml --ask-vault-pass
ansible-playbook playbooks/pass.yml --ask-vault-pass
ansible-playbook playbooks/restic.yml --ask-vault-pass
ansible-playbook playbooks/ollama.yml --ask-vault-pass
ansible-playbook playbooks/nvidia.yml --ask-vault-pass
```

Ansible is idempotent -- running it again won't break anything.