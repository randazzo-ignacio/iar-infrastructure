# Step-by-Step Deployment -- Read This First

> You have 3 fresh cloud servers and 2 local machines. Domains already point
> to the right IPs. This guide takes you from zero to running, one step at a time.
>
> **Do these steps in order. Don't skip ahead. Each one depends on the last.**
>
> **All servers run Fedora Server 44 or AlmaLinux 10.**

---

## STEP 0: Get the files to your local machine

```bash
git clone <your-repo-url> ~/infrastructure
cd ~/infrastructure
```

You should be inside the `infrastructure/` folder for every step from here on.

---

## STEP 1: Install Ansible

```bash
# Fedora / AlmaLinux
sudo dnf install -y ansible
```

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

## STEP 3: Generate a separate SSH key for the AI agent

```bash
ssh-keygen -t ed25519 -C "ai-agent" -f ~/.ssh/ai_agent_key
```

You now have:
- `~/.ssh/ai_agent_key` (private -- give this to the AI later)
- `~/.ssh/ai_agent_key.pub` (public -- goes in the vault file)

---

## STEP 4: Generate WireGuard keys

```bash
# Install wireguard-tools if needed:
sudo dnf install -y wireguard-tools

# Generate keys for all 5 hosts:
bash scripts/generate-wg-keys.sh
```

This creates `wg-keys/` with keypairs and `wg-keys/vault-snippet.yml` ready to paste into the vault.

---

## STEP 5: Fill in the vault

```bash
cp vault.yml.template inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
```

Replace all placeholder values:
- `wg_private_keys` / `wg_public_keys` (from `wg-keys/vault-snippet.yml`)
- `grafana_admin_password` (set a strong password)
- `frigate_camera_rtsp_user` / `frigate_camera_rtsp_password` (camera credentials)
- `ai_agent_ssh_public_key` (contents of `~/.ssh/ai_agent_key.pub`)
- `iar_telegram_bot_token` / `iar_telegram_chat_id` (from Telegram BotFather)

Encrypt:
```bash
ansible-vault encrypt inventory/group_vars/all/vault.yml --ask-vault-pass
```

---

## STEP 6: Configure host variables

Each host needs `host_vars/<host>.yml` with:
- `ansible_user` (per-host admin username)
- `wg_ip` (WireGuard IP)
- Service enable flags and configuration

Review and edit:
```bash
vim inventory/host_vars/rammstein.yml
vim inventory/host_vars/daftpunk.yml
vim inventory/host_vars/greenday.yml
vim inventory/host_vars/sophon.yml
vim inventory/host_vars/yoga.yml
```

---

## STEP 7: Configure SSH config

Add host entries to `~/.ssh/config` so Ansible can resolve hosts:

```
Host rammstein
  Hostname randzzo.ar
  User riemann
  IdentityFile ~/.ssh/id_ed25519

Host daftpunk
  Hostname i.ar
  User daft
  IdentityFile ~/.ssh/id_ed25519

Host greenday
  Hostname 0b.ar
  User green
  IdentityFile ~/.ssh/id_ed25519

Host sophon
  Hostname 192.168.2.69
  User nacho
  IdentityFile ~/.ssh/id_ed25519

Host yoga
  Hostname 192.168.2.66
  User nacho
  IdentityFile ~/.ssh/id_ed25519
```

---

## STEP 8: Provision admin users on new servers

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

## STEP 9: Test that Ansible can reach your servers

```bash
ansible all -m ping --ask-vault-pass
```

You should see `SUCCESS` for each server. Fix any unreachable hosts before continuing.

---

## STEP 10: Run the full deployment

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass --limit cloud
```

`--limit cloud` means it only touches your 3 cloud servers. Local machines are done separately.

**This will take 5-15 minutes.** Green = OK, Yellow = Changed, Red = Failed.

If it gets stuck on Ollama model pulling, that's normal -- large models take a while to download.

---

## STEP 11: Verify the cloud servers

### Check WireGuard:
```bash
ssh rammstein "wg show"
```

### Check Caddy:
```bash
curl -I https://randazzo.ar
```

### Check Ollama:
```bash
ssh rammstein "curl http://10.66.0.3:11434/api/tags"
```

### Check AI playground:
```bash
ssh greenday "su - ai-agent -c 'podman ps'"
```

---

## STEP 12: Set up local machines

```bash
# Base + WireGuard for all local machines:
ansible-playbook playbooks/base.yml --ask-vault-pass --limit local
ansible-playbook playbooks/wireguard.yml --ask-vault-pass --limit local

# GPU + Ollama + Frigate for sophon:
ansible-playbook playbooks/nvidia.yml --ask-vault-pass --limit sophon
ansible-playbook playbooks/ollama.yml --ask-vault-pass --limit sophon
```

Note: On sophon, the nvidia role requires two runs -- first run installs drivers, then reboot, then second run completes the toolkit setup.

---

## STEP 13: Clean up

```bash
rm -rf wg-keys/
```

---

## STEP 14: Save your backups

Store in a secure location (password manager, encrypted USB):

1. Vault password
2. `~/.ssh/id_ed25519` (admin SSH private key)
3. `~/.ssh/ai_agent_key` (AI agent private key)
4. Git remote URL

---

## You're done. Here's what you have:

- **3 cloud servers**, hardened, updated, firewalled
- **WireGuard mesh** -- all servers communicate privately
- **Caddy reverse proxy** -- randazzo.ar, i.ar, 0b.ar all serve HTTPS
- **Ollama** on daftpunk (CPU) and sophon (GPU)
- **Frigate NVR** on sophon with 8 cameras
- **Grafana + Prometheus** monitoring on daftpunk
- **AI playground** on greenday -- Podman ready, AI agent can SSH in
- **i.ar agents** on sophon -- librarian timer running
- **Everything in code** -- rebuild by running the playbook on fresh servers

## If something breaks later:

```bash
# Re-run everything:
ansible-playbook playbooks/site.yml --ask-vault-pass

# Or just one piece:
ansible-playbook playbooks/wireguard.yml --ask-vault-pass
ansible-playbook playbooks/caddy.yml --ask-vault-pass
ansible-playbook playbooks/ollama.yml --ask-vault-pass
ansible-playbook playbooks/nvidia.yml --ask-vault-pass
```

Ansible is idempotent -- running it again won't break anything.