# Disaster Recovery Plan

## Scope

This DRP covers the personal data architecture defined in the long-term plan: git repos, restic backups, pass, Radicale, and key material. For server/infrastructure rebuild (Ansible, WireGuard, Caddy, Ollama), see `RECOVERY.md`.

The two documents are complementary:
- `RECOVERY.md` = how to rebuild servers from infrastructure-as-code
- `DRP.md` (this document) = how to recover personal data if machines or services are lost

## 1. Asset Inventory

| Category | What | Primary Location | Backup Location | Format |
|-----------|------|-----------------|-----------------|--------|
| Text data | finance (hledger), inventory, notes, concepts, references, infra | Local clone (yoga) | Git bare repo on rammstein + cloud sync (Proton Drive, possibly Google Drive) | Git |
| Passwords | pass store (~/.password-store) | Local clone (yoga) | Git bare repo on rammstein + cloud sync | GPG-encrypted git |
| Binaries | scans, reference PDFs, FreeCAD (.FCStd), Blender (.blend), KiCad gerbers | Local disk (yoga/sophon) | Restic local (sophon) + Restic remote (rammstein) + cloud sync | Restic snapshots |
| Calendar | Radicale data directory | rammstein disk | Git backup via cron + cloud sync | Files (iCalendar) |
| Infrastructure | Ansible repo, vault, .vault_pass, SSH keys | Local clone (yoga) | Git remote + cloud sync | Git + plaintext secrets |
| Server state | Caddy configs, WG configs, service configs | rammstein/sophon (derived) | Regeneratable from Ansible repo | N/A (IaC) |

### Cloud Sync

Git repos and restic snapshots are synced to Proton Drive as a tertiary backup. Google Drive may be added as a fourth copy to avoid single-provider dependency. This covers the total-loss scenario where both local machines and rammstein are unavailable.

## 2. Failure Scenarios

### Scenario A: yoga (laptop) dies

**What's lost:** Local working copies of all git repos, local pass clone, local restic repo (if configured), SSH keys, .vault_pass.

**Recovery:**
1. On new laptop: install git, pass, restic, ansible
2. Clone all git repos from rammstein (or cloud sync if rammstein is also down)
3. `pass clone` from git remote
4. `restic restore latest` from rammstein remote repo (or cloud sync)
5. Restore SSH keys and .vault_pass from encrypted backup (see Section 4)
6. Reconnect Radicale CalDAV account
7. Resume work

**Time estimate:** 2-4 hours (assuming repos and backups are current)

### Scenario B: sophon (compute server) dies

**What's lost:** Restic local backup target, Ollama GPU, Frigate NVR recordings, heavy compute capability.

**Recovery:**
1. Rebuild sophon via Ansible: `ansible-playbook playbooks/site.yml --vault-password-file .vault_pass --limit sophon`
2. Restic local repo is lost but remote copy on rammstein is intact. Re-establish local restic repo on rebuilt sophon.
3. Frigate recordings are lost (not backed up -- they're ephemeral). Frigate config is in Ansible and will be recreated.
4. Ollama models will re-pull via Ansible.

**Time estimate:** 2-6 hours (depends on model pull time and GPU driver rebuild)

### Scenario C: rammstein (single VPS) dies

**What's lost:** Git bare repos (remotes), restic remote target, Radicale calendar, WireGuard hub, Caddy reverse proxy, all web services.

**Recovery:**
1. Provision new VPS, note new IP
2. Update DNS at registrar to point to new IP
3. Update Ansible inventory with new IP
4. If WG keys lost: regenerate for rammstein, update vault, re-run wireguard on all hosts
5. Run: `ansible-playbook playbooks/site.yml --vault-password-file .vault_pass --limit rammstein`
6. Re-establish git bare repos: push from local clones (all data is in local clones)
7. Re-establish restic remote: create new restic repo on new rammstein, push from local
8. Radicale: fresh install, reconnect phone, calendar data was backed up to git via cron -- restore from git
9. Reconfigure WireGuard spokes to new hub IP

**Key insight:** Local clones contain all git data. rammstein being down does not lose data -- it loses the remote sync target. The data survives in local clones and cloud sync.

**Time estimate:** 4-8 hours (DNS propagation, VPS provisioning, service reconfiguration)

### Scenario D: Local machines + rammstein both die (house fire + VPS outage)

**What's lost:** All local data, all remote data, all services.

**Recovery:**
1. New laptop: install git, pass, restic, ansible
2. Clone all git repos from Proton Drive cloud sync
3. `pass clone` from cloud sync
4. `restic restore latest` from cloud sync (if restic snapshots are synced) or from Google Drive (if configured)
5. Restore SSH keys and .vault_pass from encrypted backup (see Section 4)
6. Provision new VPS, rebuild via Ansible
7. Push all repos to new VPS to re-establish remotes
8. Reconnect Radicale (restore calendar data from git in cloud sync)

**Time estimate:** 1-2 days (cloud restore speeds, VPS provisioning, DNS propagation)

**This is the worst case.** It's covered by the cloud sync layer. The critical dependency is that cloud sync is current and the encryption key for key material is accessible (in your head + on paper).

## 3. Emergency Access

**Current decision:** No emergency access setup for service continuity. Services are personal -- no one else depends on them. If something happens to Nacho, services can stay down.

**Trusted backup:** A monthly backup (git bundle + restic snapshot) is given to a trusted person as a last-resort offline copy. This person does not need credentials, keys, or technical knowledge -- they just hold a physical/offline copy that Nacho (or someone acting on his behalf) could retrieve if all other copies are lost.

**Revisit:** This section should be revisited if circumstances change (dependents, business services, shared infrastructure).

## 4. Key Material

### What Constitutes Key Material

| Item | Purpose | Loss Impact |
|------|---------|-------------|
| `~/.ssh/id_ed25519` | SSH access to all servers | Locked out of everything |
| `.vault_pass` | Decrypts Ansible vault (WG keys, RTSP creds, CF tokens) | Can't deploy infrastructure |
| GPG private key | Decrypts pass store | Can't access any passwords |
| Restic repository password | Decrypts restic backups | Can't restore binary backups |
| Domain registrar credentials | DNS control | Can't redirect domains |
| VPS provider credentials | Server provisioning | Can't provision new servers |
| Proton Drive credentials | Cloud sync access | Can't access tertiary backup |

### Storage Strategy

- **Primary copy:** On yoga (daily driver), in standard locations
- **Backup copy:** Encrypted archive alongside the restic backups (in the restic repo itself or as a separate encrypted file in git)
- **Encryption key for the archive:** In Nacho's head (memorized passphrase) + on paper stored in a secure physical location (safe, safety deposit box, or equivalent)

### What Goes in the Encrypted Archive

```
key-material/
  id_ed25519           # SSH private key
  id_ed25519.pub       # SSH public key
  .vault_pass          # Vault password file
  gpg-private-key.asc  # GPG private key export (gpg --export-secret-keys)
  restic-password      # Restic repo password
  registrar-creds.txt  # Domain registrar credentials
  vps-creds.txt        # VPS provider credentials
  proton-creds.txt     # Proton Drive credentials
```

This archive is encrypted with a passphrase (GPG symmetric or age) and stored:
1. In the restic backup (goes to sophon local + rammstein remote + cloud sync)
2. As a separate encrypted file in a git repo (goes to rammstein + cloud sync)

The passphrase is memorized and written on paper stored in a secure physical location.

### Recovery of Key Material

If all machines are lost:
1. Retrieve the encrypted archive from cloud sync (Proton Drive)
2. Enter the memorized passphrase to decrypt
3. Restore SSH keys, .vault_pass, GPG key, restic password, provider credentials
4. Proceed with infrastructure and data recovery

If the passphrase is also lost (Nacho incapacitated):
1. The paper copy of the passphrase is in the secure physical location
2. The trusted person (Section 3) or someone acting on Nacho's behalf retrieves the paper
3. They can decrypt the archive and access everything

## 5. Testing Cadence

| Test | Frequency | What to Verify |
|------|-----------|----------------|
| Restic restore (random file) | Monthly | Pick a random file from restic backup, restore it, verify contents match |
| Git clone from remote | Monthly | Clone a random repo from rammstein, verify it matches local |
| Pass entry lookup | Monthly | `pass show` a random entry, verify it works |
| Cloud sync verification | Monthly | Verify Proton Drive sync is current (check last sync timestamp) |
| Full DR drill | Quarterly | Simulate a failure scenario end-to-end (e.g., "rammstein is down" -- can you rebuild from Ansible + local clones?) |
| Key material restore | Quarterly | Decrypt the key material archive, verify all items are present and valid |
| Encrypted archive passphrase | Biannually | Verify the memorized passphrase still works (prevents silent forgetting) |

## 6. Gap Analysis

These are things the DRP assumes exist but are not yet implemented. Each gap becomes a task in the roadmap.

| Gap | Impact if not resolved | Roadmap phase |
|-----|----------------------|---------------|
| Git bare repos on rammstein not yet created | No remote for git repos -- data only exists locally | Phase 1: Foundation |
| Restic not yet configured (local or remote) | No binary backup -- FreeCAD, Blender, PDFs are unprotected | Phase 1: Foundation |
| pass not yet set up | No password manager -- credentials scattered or unmanaged | Phase 1: Foundation |
| Radicale not yet deployed on rammstein | No calendar sync | Phase 2: Daily Operations |
| Cloud sync to Proton Drive not yet configured | No tertiary backup -- total loss scenario is uncovered | Phase 1: Foundation |
| Encrypted key material archive not yet created | Key material only exists on yoga -- single point of failure | Phase 1: Foundation |
| Trusted person monthly backup not yet arranged | No offline last-resort copy | Phase 1: Foundation |
| Server consolidation not yet done | rammstein doesn't have all services yet, greenday/daftpunk still running | Phase 1: Foundation |
| Ansible repo does not cover new services (Radicale, git repos, restic) | Can't auto-provision new services on rammstein rebuild | Phase 1: Foundation |
| Restic backup automation (systemd timer/cron) not set up | Backups are manual -- likely to be skipped | Phase 1: Foundation |

## 7. Implementation Priority

Based on gap analysis, the critical path for DRP readiness is:

1. **Server consolidation** -- rammstein becomes the single VPS with all services
2. **Git bare repos on rammstein** -- all text data gets a remote
3. **pass setup** -- passwords get managed and backed up
4. **Restic setup** -- binaries get backed up (local on sophon + remote on rammstein)
5. **Encrypted key material archive** -- key material gets backed up
6. **Cloud sync to Proton Drive** -- tertiary backup for total loss scenario
7. **Trusted person monthly backup** -- offline last-resort copy
8. **Restic automation** -- systemd timer for daily backups
9. **Radicale deployment** -- calendar gets backed up

Until items 1-5 are done, the DRP is a plan without implementation. The document is the target state.