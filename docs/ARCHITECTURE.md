# Architecture Overview

## Network Topology

```
                         ┌─────────────────────────────────────────────────┐
                         │              INTERNET                           │
                         │                                                 │
    ┌────────────────────┤                    │                            │
    │  randazzo.ar       │  0b.ar             │  i.ar                     │
    │  randazzo.com.ar   │                    │  grafana.i.ar             │
    │  (→redirect)       │                    │  camaras.randazzo.ar       │
    │                    │                    │                            │
    ▼                    ▼                    ▼                            │
┌──────────────┐  ┌──────────────┐  ┌──────────────┐                     │
│  rammstein   │  │   greenday   │  │   daftpunk   │                     │
│  VPS 2c/4GB  │  │  VPS 16c/16G │  │  16c/64GB    │                     │
│  Proxy Hub   │  │  AI Play     │  │ Ollama CPU  │                     │
│  Caddy + TLS │  │  Podman      │  │ Static page │                     │
│  WG:10.66.0.1│  │  WG:10.66.0.2│  │ Grafana      │                     │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘                     │
       │   WireGuard      │   WireGuard      │   WireGuard                 │
       │   (hub)          │   (spoke→hub)    │   (spoke→hub)              │
       ═══════════════════════════════════════════════════════════════════ │
       │                  │                  │                              │
       ▼                                              ▼                     │
┌──────────────┐                              ┌──────────────┐             │
│    yoga      │                              │   sophon     │             │
│  Intel Ultra │                              │ 12c/96GB    │             │
│  Silverblue  │                              │ RTX 3080    │             │
│  WG:10.66.0.4│                              │ Ollama GPU  │             │
└──────────────┘                              │ Frigate NVR │             │
                                               │ WG:10.66.0.5│             │
                                               └──────────────┘             │
                                                                            │
                         └─────────────────────────────────────────────────┘
```

## Host Inventory

| Host | WG IP | Domain | Role | Hardware |
|------|-------|--------|------|----------|
| rammstein | 10.66.0.1 | randazzo.ar, randazzo.com.ar, camaras.randazzo.ar | Proxy hub, Caddy, WG hub | VPS 2c/4GB |
| greenday | 10.66.0.2 | 0b.ar | AI playground, Podman | VPS 16c/16GB |
| daftpunk | 10.66.0.3 | i.ar, grafana.i.ar | Ollama CPU, static page, Grafana | 16c/64GB |
| yoga | 10.66.0.4 | (none) | Laptop (Silverblue) | Intel Core Ultra |
| sophon | 10.66.0.5 | (none) | Ollama GPU, Frigate NVR, i.ar agents | 12c/96GB, RTX 3080 |

## Inventory Groups

| Group | Hosts | Purpose |
|-------|-------|---------|
| cloud | rammstein, greenday, daftpunk | All VPS hosts |
| local | sophon, yoga | All local machines |
| proxy | rammstein | Caddy reverse proxy |
| ai_playground | greenday | AI agent environment |
| ollama_hosts | daftpunk, sophon | Ollama instances |
| frigate_hosts | sophon | Frigate NVR |
| wg_hub | rammstein | WireGuard hub (single host) |
| wg_peers | rammstein, greenday, daftpunk, sophon, yoga | All WG mesh participants |
| gpu_hosts | sophon | NVIDIA GPU hosts |
| web_servers | rammstein, daftpunk | Static site hosts |
| monitoring | daftpunk | Prometheus + Grafana stack |

## Server Roles

### rammstein -- Proxy Hub
- Caddy reverse proxy with automatic TLS for randazzo.ar, randazzo.com.ar (redirect), camaras.randazzo.ar (Frigate proxy)
- WireGuard hub -- all inter-server traffic routes through here
- Public ports: 80 (HTTP), 443 (HTTPS), 51820/udp (WireGuard)

### greenday -- AI Playground
- Podman + AI agent user with SSH access
- Caddy reverse proxy for 0b.ar
- WireGuard spoke

### daftpunk -- Ollama + Monitoring
- Ollama (CPU-only, 64GB RAM for large models)
- Static landing page (i.ar)
- Grafana + Prometheus monitoring stack
- Caddy reverse proxy for i.ar, grafana.i.ar
- WireGuard spoke

### yoga -- Laptop
- Fedora Silverblue (rpm-ostree, not dnf)
- WireGuard spoke
- Package management skipped (manage_packages: false)

### sophon -- Local GPU Server
- Ollama with GPU offloading (RTX 3080)
- Frigate NVR with NVIDIA TensorRT (8 cameras)
- i.ar agent infrastructure (librarian agent)
- WireGuard spoke

## Security Model

1. **Single entry point:** Only rammstein has public web ports (80/443). All other services are WireGuard-only.
2. **TLS everywhere:** Caddy handles Let's Encrypt automatically for all domains.
3. **No exposed Ollama:** Ollama binds to WireGuard IP only. Access requires VPN.
4. **Key-only SSH:** Password authentication disabled. Per-host admin usernames prevent terminal confusion.
5. **Firewalld:** Every host runs firewalld -- default deny incoming, allow SSH + WireGuard only.
6. **AI agent isolation:** On greenday, the `ai-agent` user has Podman access but limited sudo. Resource limits prevent runaway.
7. **Least privilege:** Ansible connects as per-host admin user, escalates to root only per-play via `become: true`.

## Known Limitations

1. **Ollama has no authentication:** Relies on network isolation (WireGuard IP only).
2. **AI agent has Podman access:** Podman is root-equivalent in practice. Resource limits are advisory.
3. **Single hub (rammstein):** If the hub goes down, the WireGuard mesh breaks.
4. **No backup of runtime data:** IaC covers configuration, not data. Backup role is planned.