# Architecture Overview

## Network Topology

```
                         ┌─────────────────────────────────────────────────┐
                         │              INTERNET                           │
                         │                                                 │
    ┌────────────────────┤                    │                            │
    │  randazzo.ar       │                    │  i.ar                     │
    │  randazzo.com.ar   │                    │  camaras.randazzo.ar       │
    │  caldav.randazzo.ar│                    │                            │
    │  (→redirect)       │                    │                            │
    ▼                    ▼                    ▼                            │
┌──────────────────────────────────────────────────────────────────────┐  │
│  rammstein (sole VPS)                                                │  │
│  VPS 2c/4GB -- Fedora 44                                            │  │
│  Caddy + TLS (all domains)                                           │  │
│  Static pages: randazzo.ar + i.ar                                    │  │
│  Caddy proxy: camaras.randazzo.ar -> sophon:8971 (Frigate)           │  │
│  Caddy proxy: caldav.randazzo.ar -> localhost:5232 (Radicale)        │  │
│  Radicale CalDAV server (localhost:5232)                             │  │
│  Git bare repos (auto-discovered, mirrors to sophon)                │  │
│  Restic remote target (SFTP, restic user)                             │  │
│  WireGuard hub: 10.66.0.1                                            │  │
└──────┬───────────────────────────────────────────────────────────────┘  │
       │   WireGuard (hub)                                                │
       ═══════════════════════════════════════════════════════════════════ │
       │                                                                  │
       ▼                                              ▼                     │
┌──────────────┐                              ┌──────────────────┐       │
│    yoga      │                              │   sophon         │       │
│  Intel Ultra │                              │ 12c/96GB        │       │
│  Silverblue  │                              │ RTX 3080        │       │
│  WG:10.66.0.4│                              │ Ollama GPU      │       │
│  pass client │                              │ Frigate NVR     │       │
│  restic      │                              │ Git bare repos  │       │
│  backup      │                              │ (mirror of      │       │
│              │                              │  rammstein)     │       │
│              │                              │ Restic local    │       │
│              │                              │  target         │       │
│              │                              │ WG:10.66.0.5    │       │
└──────────────┘                              └──────────────────┘       │
                                                                            │
                         └─────────────────────────────────────────────────┘
```

## Host Inventory

| Host | WG IP | Domain | Role | Hardware |
|------|-------|--------|------|----------|
| rammstein | 10.66.0.1 | randazzo.ar, randazzo.com.ar (redirect), i.ar, camaras.randazzo.ar (proxy), caldav.randazzo.ar (proxy) | Caddy, WG hub, git bare repos, restic remote target, Radicale CalDAV | VPS 2c/4GB, Fedora 44 |
| yoga | 10.66.0.4 | (none) | Laptop (Silverblue), pass client, restic backup client | Intel Core Ultra |
| sophon | 10.66.0.5 | (none) | Ollama GPU, Frigate NVR, i.ar agents, git bare repo mirror, restic local target | 12c/96GB, RTX 3080 |

## Inventory Groups

| Group | Hosts | Purpose |
|-------|-------|---------|
| cloud | rammstein | All VPS hosts (single VPS) |
| local | sophon, yoga | All local machines |
| proxy | rammstein | Caddy reverse proxy |
| git_servers | rammstein, sophon | Git bare repo hosts |
| ollama_hosts | sophon | Ollama instances |
| frigate_hosts | sophon | Frigate NVR |
| wg_hub | rammstein | WireGuard hub (single host) |
| wg_peers | rammstein, sophon, yoga | All WG mesh participants |
| gpu_hosts | sophon | NVIDIA GPU hosts |
| web_servers | rammstein | Static site hosts |

## Server Roles

### rammstein -- Sole VPS (Proxy Hub + Data Host)
- Caddy reverse proxy with automatic TLS for all domains
- Static pages: randazzo.ar (portfolio), i.ar (landing page)
- Caddy proxy: camaras.randazzo.ar -> sophon:8971 (Frigate)
- Caddy proxy: caldav.randazzo.ar -> localhost:5232 (Radicale)
- Radicale CalDAV server (localhost only, Caddy provides TLS + public access)
- WireGuard hub -- all inter-server traffic routes through here
- Git bare repos (auto-discovered from ~/repos/ on yoga, auto-mirror to sophon)
- Restic remote target (restic user, SFTP access, /home/restic/backups)
- Public ports: 80 (HTTP), 443 (HTTPS), 51820/udp (WireGuard)

### yoga -- Laptop
- Fedora Silverblue (rpm-ostree, not dnf -- manage_packages: false)
- WireGuard spoke
- pass client (password manager, GPG-encrypted, backed up to git)
- Restic backup client (backs up to sophon primary + rammstein remote)

### sophon -- Local GPU Server + Data Mirror
- Ollama with GPU offloading (RTX 3080)
- Frigate NVR with NVIDIA TensorRT (8 cameras)
- i.ar agent infrastructure (librarian agent)
- Git bare repo mirror (auto-mirror from rammstein)
- Restic local target (/home/restic/backups, fast local backup for yoga)
- WireGuard spoke

## Security Model

1. **Single entry point:** Only rammstein has public web ports (80/443). All other services are WireGuard-only.
2. **TLS everywhere:** Caddy handles Let's Encrypt automatically for all domains.
3. **No exposed Ollama:** Ollama binds to WireGuard IP only. Access requires VPN.
4. **Radicale behind Caddy:** Radicale binds to localhost only. Caddy provides TLS + public access via caldav.randazzo.ar. Basic auth protects the CalDAV endpoint.
5. **Key-only SSH:** Password authentication disabled. Per-host admin usernames prevent terminal confusion.
6. **Firewalld:** Every host runs firewalld -- default deny incoming, allow SSH + WireGuard only.
7. **Least privilege:** Ansible connects as per-host admin user, escalates to root only per-play via `become: true`.
8. **Shared SSH keys:** The ansible user's authorized_keys are copied to git and restic users. No separate keys -- if the ansible key is compromised, everything else is too. Separate keys add complexity without adding security.

## Known Limitations

1. **Ollama has no authentication:** Relies on network isolation (WireGuard IP only).
2. **Single hub (rammstein):** If the hub goes down, the WireGuard mesh breaks. Spokes can still reach each other if they have direct routes, but the hub-and-spoke topology means they only see the hub as a peer.
3. **Silverblue package lag:** yoga can't install new packages via Ansible without a reboot (rpm-ostree atomic updates). pass role requires reboot to take effect.
4. **Restic SSH authorization:** The restic role copies ansible user's authorized_keys to the restic user on rammstein. If the ansible user's keys change, the restic role must be re-run.