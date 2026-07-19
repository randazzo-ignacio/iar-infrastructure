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
          │   rammstein (Proxy)      │
          │   Caddy + TLS + firewalld │
          │   WG hub                 │
          └────────────┬────────────┘
                       │
           WireGuard (encrypted tunnel)
                       │
     ┌─────────────────┼─────────────────┐
     │                 │                 │
     ▼                 ▼                 ▼
┌─────────┐     ┌─────────┐      ┌──────────┐
│greenday │     │daftpunk │      │ sophon   │
│firewalld│     │firewalld│      │firewalld │
│ Podman  │     │ Ollama  │      │ Ollama   │
│ AI user │     │ Grafana │      │ Frigate  │
│ (lim.)  │     │ (WG IP  │      │ (WG IP   │
│         │     │  only)  │      │  only)   │
└─────────┘     └─────────┘      └──────────┘
```

## Security Layers

### Layer 1: Network (firewalld + WireGuard)
- **firewalld:** Default deny all incoming. Only SSH (22/tcp), WireGuard (51820/udp), and on the proxy: HTTP/HTTPS.
- **WireGuard:** All inter-server communication is encrypted. No service listens on a public interface except Caddy and SSH.
- **Ollama:** Binds to `10.66.0.x` (WireGuard IP) only. Not accessible without VPN.

### Layer 2: Host Hardening
- **SSH:** Key-only authentication. No passwords. Root login restricted to key-based (`prohibit-password`).
- **Per-host admin users:** Each host has a unique admin username (e.g. `riemann` on rammstein) to prevent terminal confusion when working on multiple hosts.
- **Sysctl:** SYN cookies, no redirects, kptr/dmesg restrictions. IP forwarding on hub only.
- **Automatic updates:** Security patches applied automatically via dnf-automatic.
- **Firewalld:** Running on all hosts including local machines.

### Layer 3: Application
- **Caddy:** Automatic TLS via Let's Encrypt. Security headers (HSTS, X-Frame-Options, nosniff, no-referrer) on all sites.
- **Ollama:** No authentication built-in -- relies on network isolation (WireGuard IP only).
- **Podman:** AI agent has Podman access but limited sudo. Process/file limits set.

### Layer 4: AI Agent Isolation (greenday)
- **Separate user:** `ai-agent` with its own SSH key.
- **Resource limits:** Max 1000 processes (hard), 500 (soft). Max 50GB file size (hard), 10MB (soft).
- **Workspace structure:** `/home/ai-agent/workspace/{projects,containers,scripts,data}`

### Layer 5: Ansible Security
- **Least privilege:** `become = False` globally. Each play declares `become: true` explicitly where needed.
- **Host key checking:** Enabled (`host_key_checking = True`). SSH host keys verified on first connection.
- **Vault:** All secrets encrypted with ansible-vault. Template file (`vault.yml.template`) documents every secret.
- **GPG checks:** Package repositories have GPG verification enabled. Only one-time bootstrap RPMs disable it.

## Threat Model

| Threat | Mitigation |
|--------|-----------|
| Server compromise | firewalld + key-only SSH + automatic updates |
| Network sniffing | WireGuard encryption + TLS (Caddy) |
| Ollama API abuse | Binds to WG IP only -- requires VPN |
| AI agent runaway | Resource limits + limited sudo + Podman isolation |
| Key compromise | Ansible Vault encryption + rotation procedure |
| DNS hijack | Registrar-locked DNS |
| Provider outage | Full IaC -- rebuild from scratch in minutes |
| Data loss | All config in Git. Backup role planned. |

## Known Limitations

1. **Ollama has no authentication:** Relies entirely on network isolation. If WireGuard is compromised, Ollama is open.

2. **AI agent has Podman access:** Podman is root-equivalent in practice (can mount host filesystem). Resource limits are advisory, not enforced by cgroups.

3. **Single hub (rammstein):** If the proxy/hub goes down, the WireGuard mesh breaks. Peers can't reach each other.

4. **No backup of runtime data:** IaC covers configuration, not data. Frigate recordings, Grafana dashboards, AI-generated work -- none are backed up. Backup role is planned.