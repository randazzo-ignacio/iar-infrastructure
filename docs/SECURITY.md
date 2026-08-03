# Security Model

## Defense in Depth

```
┌─────────────────────────────────────────────────────┐
│                    INTERNET                           │
│                                                       │
│  Only ports: 80, 443 (Caddy), 51820/udp (WireGuard) │
│  Everything else: DENIED by firewalld                 │
└──────────────────────┬──────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │   rammstein (Sole VPS)    │
          │   Caddy + TLS + firewalld │
          │   WG hub                 │
          │   Git bare repos (SSH)    │
          │   Restic target (SFTP)    │
          └────────────┬────────────┘
                       │
           WireGuard (encrypted tunnel)
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
   ┌────────────┐           ┌──────────────┐
   │   yoga     │           │   sophon     │
   │ firewalld  │           │ firewalld    │
   │ pass client│           │ Ollama GPU   │
   │ restic     │           │ Frigate NVR  │
   │ backup     │           │ Git mirror   │
   │            │           │ Restic local │
   └────────────┘           └──────────────┘
```

## Security Layers

### Layer 1: Network (firewalld + WireGuard)
- **firewalld:** Default deny all incoming. Only SSH (22/tcp), WireGuard (51820/udp), and on the proxy: HTTP/HTTPS.
- **WireGuard:** All inter-server communication is encrypted. No service listens on a public interface except Caddy and SSH.
- **Ollama:** Binds to `10.66.0.5` (WireGuard IP) only. Not accessible without VPN.

### Layer 2: Host Hardening
- **SSH:** Key-only authentication. No passwords. Root login restricted to key-based (`prohibit-password`).
- **Per-host admin users:** Each host has a unique admin username (e.g. `riemann` on rammstein, `nacho` on sophon/yoga) to prevent terminal confusion when working on multiple hosts.
- **Sysctl:** SYN cookies, no redirects, kptr/dmesg restrictions. IP forwarding on hub only.
- **Automatic updates:** Security patches applied automatically via dnf-automatic.
- **Firewalld:** Running on all hosts including local machines.

### Layer 3: Application
- **Caddy:** Automatic TLS via Let's Encrypt. Security headers (HSTS, X-Frame-Options, nosniff, no-referrer) on all sites.
- **Ollama:** No authentication built-in -- relies on network isolation (WireGuard IP only).
- **Git:** git-shell for the git user (no interactive shell access, git operations only).
- **Restic:** restic user has nologin shell (SFTP access only for backup transfers).

### Layer 4: SSH Key Strategy
- **Shared keys:** The ansible user's authorized_keys are copied to the git and restic users. No separate SSH keys per service.
- **Rationale:** The ansible key already has root-level access to every host via `become: true`. A separate key for git or restic is a lock on a door that's already open. If the ansible key is compromised, the attacker can `sudo` to any user. Separate keys add complexity without adding security.
- **git user:** git-shell (git operations only, no command execution)
- **restic user:** nologin (SFTP only, no shell access at all)

### Layer 5: Ansible Security
- **Least privilege:** `become = False` globally. Each play declares `become: true` explicitly where needed.
- **Host key checking:** Enabled (`host_key_checking = True`). SSH host keys verified on first connection.
- **Vault:** All secrets encrypted with ansible-vault. Template file (`vault.yml.template`) documents every secret.
- **GPG checks:** Package repositories have GPG verification enabled.

## Threat Model

| Threat | Mitigation |
|--------|-----------|
| Server compromise | firewalld + key-only SSH + automatic updates |
| Network sniffing | WireGuard encryption + TLS (Caddy) |
| Ollama API abuse | Binds to WG IP only -- requires VPN |
| Key compromise | Ansible Vault encryption + rotation procedure |
| DNS hijack | Registrar-locked DNS |
| Provider outage | Full IaC -- rebuild from scratch in minutes |
| Data loss | Git repos (text) + Restic (binaries) with dual targets |
| Git repo tampering | git-shell (no shell access, git operations only) |
| Restic target breach | Restic encryption (passphrase-protected, even if repo is stolen) |

## Known Limitations

1. **Ollama has no authentication:** Relies entirely on network isolation. If WireGuard is compromised, Ollama is open.

2. **Single hub (rammstein):** If the proxy/hub goes down, the WireGuard mesh breaks. Spokes can't reach each other (hub-and-spoke topology).

3. **Silverblue package lag:** yoga can't install new packages via Ansible without a reboot (rpm-ostree atomic updates). This affects pass and any future dnf-based roles.

4. **Shared SSH keys:** If the ansible user's SSH key is compromised, the attacker has access to git repos, restic targets, and all hosts. This is a conscious trade-off -- separate keys add complexity without adding security given the ansible key's root-level access.

5. **Restic password is shared:** All restic repositories (local + remote) use the same password. If the password is compromised, all backups are decryptable. Mitigated by storing the password in pass (GPG-encrypted) + on paper (DRP).