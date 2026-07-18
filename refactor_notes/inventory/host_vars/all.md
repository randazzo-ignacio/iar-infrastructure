# Refactor Notes: inventory/host_vars/*.yml (all 5 files)

## Cross-cutting decisions

1. **`podman: true` on greenday -> `podman_enabled: true`**
   - Typo. Every other host uses `_enabled` suffix convention. The podman role checks `podman_enabled`, so `podman: true` is a dead variable that does nothing. Fix the name.

2. **`ai_agent_ssh_public_key` -> move to vault**
   - Public keys are not secrets, but vault is better practice for credential-adjacent data. Prevents accidental modification and keeps all credential data in one encrypted location.

3. **Explicit host identity: set all relevant flags per-host, even when matching defaults**
   - Daftpunk should explicitly set `ollama_gpu: false` even though the role default covers it. Explicit is better than implicit for host identity. The number of variables is small enough that verbosity is cheap.

4. **`ansible_user` goes in host_vars, not inventory file**
   - Each host has a unique per-host admin username (e.g. `riemann` on rammstein). These go in host_vars to keep the inventory file clean.

5. **`manage_packages: false` on yoga**
   - Yoga runs Fedora Silverblue (rpm-ostree, not dnf). Only package-manager operations are excluded. Firewalld and dnf-automatic... actually dnf-automatic is a package manager operation, so yoga skips both dnf update and dnf-automatic. The `manage_packages: false` flag covers both.

6. **Cloudflare tunnel: remove entirely**
   - User doesn't use the fallback tunnel and maintaining it is unnecessary clutter. Delete:
     - `roles/cloudflare-tunnel/` (entire role)
     - `cloudflare_tunnel_enabled` and `cloudflare_domain` from `host_vars/rammstein.yml`
     - Cloudflare tunnel role from `playbooks/site.yml` and `playbooks/cloudflare.yml`
     - Cloudflare tunnel references from docs (operations.md, overview.md, roles.md, security.md, playbooks.md)
   - If needed in the future, it can be re-added on clean foundations.

7. **i.ar agent vars: per-host with role defaults**
   - `iar_ollama_host`, `iar_model`, `iar_ctx` are genuinely per-host (different RAM capacities mean different models and context sizes). But they should also have safe defaults in `roles/iar-agent/defaults/main.yml` so a host without explicit overrides gets reasonable values.

8. **Role-specific variables in host_vars: move defaults to role defaults**
   - `cloudflare_domain` was in rammstein.yml but only used by cloudflare-tunnel role -> role is being deleted, moot.
   - `ollama_listen`, `ollama_models`, `ollama_gpu`, `ollama_enabled` are genuinely per-host (vary by host) but their defaults belong in `roles/ollama/defaults/main.yml`, not `group_vars/all/main.yml`. Already covered in group_vars notes.

## Per-host notes

### rammstein.yml
- Remove `cloudflare_tunnel_enabled` and `cloudflare_domain` (cloudflare tunnel role deleted)
- Add `ansible_user: riemann`

### daftpunk.yml
- Add explicit `ollama_gpu: false`
- Add `ansible_user: <admin name>`

### greenday.yml
- Fix `podman: true` -> `podman_enabled: true`
- Move `ai_agent_ssh_public_key` to vault
- Add `ansible_user: <admin name>`

### sophon.yml
- Keep camera definitions per-host (fine for now)
- Keep `iar_ollama_host`, `iar_model`, `iar_ctx` per-host (different RAM = different model/ctx)
- Add `ansible_user: nacho`
- `podman_enabled: true` already correct

### yoga.yml
- Add `manage_packages: false`
- Add `ansible_user: nacho`

## Proposed host_vars after refactor

### rammstein.yml
```yaml
ansible_user: riemann
wg_ip: "10.66.0.1"
wg_endpoint: "randazzo.ar"
```

### daftpunk.yml
```yaml
ansible_user: <admin name>
wg_ip: "10.66.0.3"
wg_endpoint: "i.ar"

ollama_enabled: true
ollama_gpu: false
ollama_models:
  - "llama3.3:70b"
  - "north-mini-code-1.0:q8_0"
ollama_listen: "10.66.0.3"

tool_static_page_enabled: true
```

### greenday.yml
```yaml
ansible_user: <admin name>
wg_ip: "10.66.0.2"
wg_endpoint: "0b.ar"

podman_enabled: true
# ai_agent_ssh_public_key moved to vault
```

### sophon.yml
```yaml
ansible_user: nacho
wg_ip: "10.66.0.5"
# No wg_endpoint -- spoke, no public endpoint

ollama_enabled: true
ollama_gpu: true
ollama_models:
  - "nemotron-3-super:120b"
  - "gpt-oss:120b"
ollama_listen: "10.66.0.5"

podman_enabled: true

# i.ar Agent Infrastructure
iar_agents_enabled: true
iar_ollama_host: "10.66.0.5:11434"
iar_model: "glm-5.2:cloud"
iar_ctx: 1048576
iar_agents:
  - name: librarian
    interval: "30min"
    timeout: 3600

# Frigate NVR
frigate_enabled: true
frigate_cameras:
  interior_1:
    friendly_name: "Interior 1"
    rtsp_host: "192.168.2.201"
    rtsp_path: "/ch0"
    roles: [detect, record]
  # ... (rest of cameras unchanged)
```

### yoga.yml
```yaml
ansible_user: nacho
wg_ip: "10.66.0.4"
# No wg_endpoint -- spoke, no public endpoint

manage_packages: false
```

## Emerging Guideline: Naming Consistency

Feature enable flags use the pattern `<feature>_enabled: true/false`. No bare feature names as booleans. No `<feature>: true`.

Evidence: `podman: true` in greenday.yml was a dead variable because the podman role checks `podman_enabled`. The naming inconsistency caused a silent failure -- the feature was supposed to be enabled but the variable was never read.

## Emerging Guideline: Explicit Host Identity

Host_vars should explicitly set all flags that define what a host does, even when the value matches the role default. A host_vars file should read as a complete description of the host's role in the infrastructure.

Evidence: daftpunk doesn't set `ollama_gpu: false`, relying on the global default. If the default changes, daftpunk silently becomes a GPU host. Explicit declaration prevents this.