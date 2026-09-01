# Disaster Recovery

## Scenario 1: Full Rebuild (all servers lost)

### Prerequisites
- Ansible installed on your local machine
- SSH private key (`~/.ssh/id_ed25519`)
- Vault password
- Git clone of this infrastructure repo
- Access to your domain registrar (to point DNS to new IPs)

### Steps

1. **Provision new servers** at your provider(s). Note the new public IPs.

2. **Update SSH config** (`~/.ssh/config`) with new IPs for each host.

3. **Update DNS** at your registrar:
   - randazzo.ar -> new proxy IP

4. **Provision admin users** on each new server (manual, pre-Ansible):
   - Create per-host admin user with passwordless sudo
   - Add your SSH public key to the admin user's authorized_keys

5. **Generate new WireGuard keys** (if keys were lost):
   ```bash
   ./scripts/generate-wg-keys.sh
   # Copy keys into inventory/group_vars/all/vault.yml
   ansible-vault encrypt inventory/group_vars/all/vault.yml --ask-vault-pass
   ```
   If you still have the vault file with keys, skip this step.

6. **Run the full playbook**:
   ```bash
   ansible-playbook playbooks/site.yml --ask-vault-pass
   ```

7. **Verify**:
   ```bash
   # WireGuard mesh
   ssh rammstein 'wg show wg0'
   # Web services
   curl -I https://randazzo.ar
   # Ollama
   ssh sophon 'curl http://10.66.0.5:11434/api/tags'
   ```

---

## Scenario 2: Single Server Replacement

1. Provision new server, note IP.
2. Update `~/.ssh/config` with new IP.
3. Provision admin user with SSH key (manual, pre-Ansible).
4. If replacing the hub (rammstein): regenerate WireGuard keys for it, update vault.
5. Run the relevant playbook:
   ```bash
   ansible-playbook playbooks/base.yml --ask-vault-pass --limit <host>
   ansible-playbook playbooks/wireguard.yml --ask-vault-pass
   ansible-playbook playbooks/caddy.yml --ask-vault-pass --limit <host>
   ```

---

## Scenario 3: WireGuard Key Compromise

1. Generate new keys for the compromised host:
   ```bash
   wg genkey | tee /tmp/new.key | wg pubkey > /tmp/new.pub
   ```

2. Update vault:
   ```bash
   ansible-vault edit inventory/group_vars/all/vault.yml
   # Replace the affected host's private and public keys
   ```

3. Re-run WireGuard on all hosts:
   ```bash
   ansible-playbook playbooks/wireguard.yml --ask-vault-pass
   ```

---

## Backup Checklist

Store these in a secure, encrypted location:

- [ ] `~/.ssh/id_ed25519` (Ansible SSH key)
- [ ] Vault password
- [ ] `inventory/group_vars/all/vault.yml` (encrypted secrets)
- [ ] Domain registrar credentials
- [ ] VPS provider credentials
- [ ] Git remote URL for this infrastructure repo

---

## Quick Health Check

```bash
# Check all hosts reachable
ansible all -m ping --ask-vault-pass

# Check WireGuard mesh
ssh rammstein 'wg show wg0'

# Check web services
curl -I https://randazzo.ar
curl -I https://camaras.randazzo.ar

# Check Ollama
ssh sophon 'curl -s http://10.66.0.5:11434/api/tags | jq -r ".models[].name"'

# Check git repos (list bare repos on rammstein)
ssh rammstein 'ls /home/git/repos/'

# Check restic snapshots (on sophon, local target)
ssh sophon 'RESTIC_PASSWORD_FILE=/home/nacho/.config/restic-password restic --repo /home/restic/backups snapshots'
```