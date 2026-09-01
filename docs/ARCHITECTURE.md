# Architecture Overview

## Network Topology

```
                         ┌─────────────────────────────────────────────────┐
                         │              INTERNET                           │
                         │                                                 │
    ┌────────────────────┤                    │                            │
    │  randazzo.ar       │                    │  camaras.randazzo.ar       │
    │  randazzo.com.ar   │                    │  wiki.randazzo.ar (off)    │
    │  caldav.randazzo.ar│                    │                            │
    │  (→redirect)       │                    │                            │
    ▼                    ▼                    ▼                            │
┌──────────────────────────────────────────────────────────────────────┐  │
│  rammstein (sole VPS)                                                │  │
│  VPS 2c/4GB -- Fedora 44                                            │  │
│  Caddy + TLS (all domains)                                           │  │
│  Static pages: randazzo.ar                                           │  │
│  Caddy proxy: camaras.randazzo.ar -> sophon:8971 (Frigate)           │  │
│  Caddy proxy: caldav.randazzo.ar -> localhost:5232 (Radicale)        │  │
│  Caddy static: wiki.randazzo.ar -> /var/lib/wiki/build (DISABLED)    │  │
│  Caddy proxy: agora.randazzo.ar -> sophon:8090 (Zulip)             │  │
│  Radicale CalDAV server (localhost:5232)                             │  │
│  Wiki build (ruby + pandoc + pagefind) -- DISABLED (wiki_enabled)    │  │
│  Git bare repos (auto-discovered, mirrors to sophon)                │  │
│  Restic remote target (SFTP, restic user)                            │  │
│  WireGuard hub: 10.66.0.1                                            │  │
└──────┬───────────────────────────────────────────────────────────────┘  │
       │   WireGuard (hub)                                                │
       ═══════════════════════════════════════════════════════════════════ │
       │                                                                  │
       ▼                                              ▼                     │
┌──────────────┐                              ┌──────────────────────────┐ │
│    yoga      │                              │   sophon                 │ │
│  Intel Ultra │                              │ 12c/96GB, RTX 3080      │ │
│  Silverblue  │                              │ Ollama GPU              │ │
│  WG:10.66.0.4│                              │ Frigate NVR             │ │
│  pass client │                              │ Git bare repos          │ │
│  restic      │                              │ (mirror of rammstein)   │ │
│  backup      │                              │ Restic local target     │ │
│              │                              │ WG:10.66.0.5            │ │
└──────────────┘                              └──────────────────────────┘ │
                                                                            │
                         └─────────────────────────────────────────────────┘
```

## Host Inventory

| Host | WG IP | Domain | Role | Hardware |
|------|-------|--------|------|----------|
| rammstein | 10.66.0.1 | randazzo.ar, randazzo.com.ar (redirect), camaras.randazzo.ar (proxy), caldav.randazzo.ar (proxy), wiki.randazzo.ar (static, disabled) | Caddy, WG hub, git bare repos, restic remote target, Radicale CalDAV, wiki build (disabled) | VPS 2c/4GB, Fedora 44 |
| yoga | 10.66.0.4 | (none) | Laptop (Silverblue), pass client, restic backup client | Intel Core Ultra |
| sophon | 10.66.0.5 | (none, proxied via rammstein) | Ollama GPU, Frigate NVR, Zulip, i.ar agents, git bare repo mirror, restic local target | 12c/96GB, RTX 3080 |

## Inventory Groups

| Group | Hosts | Purpose |
|-------|-------|---------|
| cloud | rammstein | All VPS hosts (single VPS) |
| local | sophon, yoga | All local machines |
| proxy | rammstein | Caddy reverse proxy |
| git_servers | rammstein, sophon | Git bare repo hosts |
| ollama_hosts | sophon | Ollama instances |
| frigate_hosts | sophon | Frigate NVR |
| secplatform_hosts | sophon | SecPlatform (podman compose) -- DECOMMISSIONED 2026-09-01, i.ar handed off |
| wg_hub | rammstein | WireGuard hub (single host) |
| wg_peers | rammstein, sophon, yoga | All WG mesh participants |
| gpu_hosts | sophon | NVIDIA GPU hosts |
| web_servers | rammstein | Static site hosts |

## Server Roles

### rammstein -- Sole VPS (Proxy Hub + Data Host)
- Caddy reverse proxy with automatic TLS for all domains
- Static pages: randazzo.ar (portfolio)
- Caddy proxy: camaras.randazzo.ar -> sophon:8971 (Frigate)
- Caddy proxy: caldav.randazzo.ar -> localhost:5232 (Radicale)
- Caddy static: wiki.randazzo.ar -> /var/lib/wiki/build (wiki, DISABLED -- wiki_enabled=false)
- Radicale CalDAV server (localhost only, Caddy provides TLS + public access)
- Wiki build pipeline (ruby + kramdown + pandoc + pagefind, auto-build on push) -- DISABLED (wiki_enabled=false, wiki.git not created yet; enable when i.ar/agora content is ready)
- Caddy proxy: agora.randazzo.ar -> sophon:8090 (Zulip chat)
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
- Zulip chat server (podman compose, proxied via rammstein)
- Git bare repo mirror (auto-mirror from rammstein)
- Restic local target (/home/restic/backups, fast local backup for yoga)
- WireGuard spoke

## Security Model

1. **Single entry point:** Only rammstein has public web ports (80/443). All other services are WireGuard-only.
2. **TLS everywhere:** Caddy handles Let's Encrypt automatically for all domains.
3. **No exposed Ollama:** Ollama binds to WireGuard IP only. Access requires VPN.
4. **Radicale behind Caddy:** Radicale binds to localhost only. Caddy provides TLS + public access via caldav.randazzo.ar. Basic auth protects the CalDAV endpoint.
5. **Wiki behind Caddy:** Wiki is static HTML served by Caddy. No server-side processing, no database.
6. **Key-only SSH:** Password authentication disabled. Per-host admin usernames prevent terminal confusion.
7. **Firewalld:** Every host runs firewalld -- default deny incoming, allow SSH + WireGuard only.
8. **Least privilege:** Ansible connects as per-host admin user, escalates to root only per-play via `become: true`.
9. **Shared SSH keys:** The ansible user's authorized_keys are copied to git and restic users. No separate keys -- if the ansible key is compromised, everything else is too. Separate keys add complexity without adding security.

## Known Limitations

1. **Ollama has no authentication:** Relies on network isolation (WireGuard IP only).
2. **Single hub (rammstein):** If the hub goes down, the WireGuard mesh breaks. Spokes can still reach each other if they have direct routes, but the hub-and-spoke topology means they only see the hub as a peer.
3. **Silverblue package lag:** yoga can't install new packages via Ansible without a reboot (rpm-ostree atomic updates). pass role requires reboot to take effect.
4. **Restic SSH authorization:** The restic role copies ansible user's authorized_keys to the restic user on rammstein. If the ansible user's keys change, the restic role must be re-run.
## Zulip (agora.randazzo.ar)

Self-hosted Zulip chat server for the AI research laboratory project. Deployed on sophon via podman compose. Caddy on rammstein terminates TLS and reverse-proxies to sophon:8090.

- **Domain:** agora.randazzo.ar
- **Backend:** sophon:8090 (Zulip HTTP, no TLS -- Caddy handles TLS)
- **Stack:** Zulip server + PostgreSQL + Memcached + RabbitMQ + Redis (5 containers)
- **Image:** ghcr.io/zulip/zulip-server:12.2-0
- **Deployment:** `ansible-playbook playbooks/zulip.yml --ask-vault-pass`
- **Secrets:** All passwords in vault (zulip_postgres_password, zulip_memcached_password, zulip_rabbitmq_password, zulip_redis_password, zulip_secret_key)
- **No email:** Outgoing email disabled (MVP). User accounts created manually via admin panel.
- **No open registration:** SETTING_OPEN_REALM_CREATION: False. Accounts created by admin.