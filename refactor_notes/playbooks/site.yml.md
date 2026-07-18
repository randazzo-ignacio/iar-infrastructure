# Refactor Notes: playbooks/site.yml

## Decisions

1. **Fix usage comment**
   - `--vault-password-file .vault_pass` -> `--ask-vault-pass`

2. **Remove cloudflare-tunnel role from site.yml**
   - Role is being deleted entirely. Remove the role entry from the "Cloud servers" play.

3. **Podman: always installed, remove `podman_enabled` guard**
   - Podman is a base requirement on all servers. Remove the `podman_enabled` variable from host_vars and the `when: podman_enabled` guards from site.yml.
   - Podman runs unconditionally on all hosts (or at least all hosts in the relevant plays).
   - This is a justified exception to the "explicit host identity" rule -- podman is always present, only explicitly disabled if ever needed.
   - Remove `podman_enabled: true` from sophon.yml and greenday.yml host_vars.
   - Remove the dead `podman: true` from greenday.yml.
   - Add a `podman_enabled: true` default in the podman role defaults, so it can be overridden to `false` if ever needed, but defaults to on.

4. **NVIDIA: separate independent play, runs before ollama and frigate**
   - nvidia becomes its own play in site.yml, running before both ollama and frigate plays.
   - The nvidia play targets hosts that need GPU (guarded by `nvidia_enabled: true` or by group membership).
   - Ollama and frigate roles no longer include or depend on nvidia running inline. They check `nvidia_enabled: true` (or check nvidia-smi) to add their GPU-specific configs, but the driver installation is handled by the separate nvidia play.
   - This eliminates the double-run: nvidia runs once, before both ollama and frigate.
   - Site.yml order becomes: base -> wireguard -> caddy -> podman (all) -> nvidia (GPU hosts) -> ollama -> frigate -> ai-environment -> static sites -> iar-agent

5. **Merge static-page + portfolio-page into one parameterized role**
   - One role (e.g. `static-site`) with `src_dir` and `dest_dir` variables.
   - Per-host content targeting: the role deploys files from a specified source directory to a specified destination.
   - In site.yml, two role invocations with different parameters:
     ```yaml
     - role: static-site
       vars:
         static_site_src: files/portfolio
         static_site_dest: "{{ portfolio_page_root }}"
       when: inventory_hostname == 'rammstein'  # or group-based
     ```
   - This requires the hardcoded hostname fix (point 6) to work cleanly.

6. **Replace hardcoded hostnames with groups or variables**
   - `hosts: daftpunk` -> target a group (e.g. `static_sites` or `web_servers`) or use `hosts: cloud` with `when` guards.
   - `hosts: rammstein` -> same approach.
   - Could create a `web_content` group or use existing groups + `when` guards on enabled flags.
   - The `when: tool_static_page_enabled` and portfolio equivalent guards already exist -- just need the `hosts:` to be group-based.

7. **i.ar + personal infrastructure merged via WireGuard -- acknowledged, not fixed**
   - rammstein is the only purely personal host but also serves as WG hub for i.ar.
   - This is an architectural reality, not a bug. No action needed beyond documenting it.
   - The iar-agent play targeting `hosts: all` is fine -- the `when: iar_agents_enabled` guard handles which hosts actually run it.

8. **`become: true` per-play, not global**
   - Each play declares `become: true` if it needs root (most do).
   - Individual tasks opt out with `become: false` where needed (e.g. git clone as nacho).
   - Plays that don't need root (if any) omit `become`.

9. **Consistent tagging: every role gets a tag matching its name**
   - `base` -> `[base]`
   - `wireguard` -> `[wireguard]`
   - `caddy` -> `[caddy]`
   - `podman` -> `[podman]`
   - `nvidia` -> `[nvidia]`
   - `ollama` -> `[ollama]`
   - `frigate` -> `[frigate]`
   - `static-site` -> `[static-site]`
   - `ai-environment` -> `[ai-environment]`
   - `iar-agent` -> `[iar-agent]`
   - `monitoring` -> `[monitoring]`
   - `node-exporter` -> `[node-exporter]`
   - Allows `--tags nvidia` or `--skip-tags frigate` consistently.

## Proposed site.yml structure (after refactor)

```yaml
---
# playbooks/site.yml -- Master playbook: runs all roles in order.
# Usage: ansible-playbook playbooks/site.yml --ask-vault-pass

- name: Base configuration (all hosts)
  hosts: all
  become: true
  roles:
    - role: base
      tags: [base]

- name: WireGuard mesh -- hub first (prevents spoke lockout)
  hosts: "{{ wg_hub | default('rammstein') }}"
  become: true
  roles:
    - role: wireguard
      tags: [wireguard]

- name: WireGuard mesh -- spokes
  hosts: all
  serial: 1
  become: true
  roles:
    - role: wireguard
      when: inventory_hostname != wg_hub
      tags: [wireguard]

- name: Cloud servers -- Caddy
  hosts: cloud
  become: true
  roles:
    - role: caddy
      tags: [caddy]

- name: Podman (all hosts)
  hosts: all
  become: true
  roles:
    - role: podman
      tags: [podman]

- name: NVIDIA GPU drivers (GPU hosts)
  hosts: all
  become: true
  roles:
    - role: nvidia
      when: nvidia_enabled | default(false) | bool
      tags: [nvidia]

- name: AI playground
  hosts: ai_playground
  become: true
  roles:
    - role: ai-environment
      tags: [ai-environment]

- name: Ollama hosts
  hosts: ollama_hosts
  become: true
  roles:
    - role: ollama
      when: ollama_enabled | default(false) | bool
      tags: [ollama]

- name: Frigate NVR
  hosts: frigate_hosts
  become: true
  roles:
    - role: frigate
      when: frigate_enabled | default(false) | bool
      tags: [frigate]

- name: Static sites
  hosts: cloud
  become: true
  roles:
    - role: static-site
      vars:
        static_site_src: "{{ portfolio_src_dir }}"
        static_site_dest: "{{ portfolio_page_root }}"
      when: portfolio_page_enabled | default(false) | bool
      tags: [static-site]
    - role: static-site
      vars:
        static_site_src: "{{ landing_src_dir }}"
        static_site_dest: "{{ static_page_root }}"
      when: tool_static_page_enabled | default(false) | bool
      tags: [static-site]

- name: Monitoring
  hosts: daftpunk  # TODO: replace with monitoring group
  become: true
  roles:
    - role: monitoring
      when: monitoring_enabled | default(false) | bool
      tags: [monitoring]

- name: Node exporters (all hosts)
  hosts: all
  become: true
  roles:
    - role: node-exporter
      tags: [node-exporter]

- name: i.ar Agent Infrastructure
  hosts: all
  become: true
  roles:
    - role: iar-agent
      when: iar_agents_enabled | default(false) | bool
      tags: [iar-agent]
```

## Open Questions

- **NVIDIA play targeting**: Should nvidia target `hosts: all` with `when: nvidia_enabled`, or should there be a `gpu_hosts` group? A group is cleaner but adds inventory maintenance. A variable is more flexible.
- **Static site targeting**: The proposed structure targets `hosts: cloud` with `when` guards. Is this right, or should there be a `web_servers` group?
- **Monitoring play**: Currently hardcoded to daftpunk. Should this be a `monitoring` group or variable-guarded?
- **Podman play ordering**: Podman now runs on all hosts before nvidia/ollama/frigate. Is there any case where podman should NOT be installed on a server? If so, the `podman_enabled` override (defaulting to true) handles it.
- **Role ordering**: Does nvidia need to run before caddy? No. Does podman need to run before base? No. The proposed order is: base -> wireguard -> caddy -> podman -> nvidia -> ai-environment -> ollama -> frigate -> static sites -> monitoring -> node-exporter -> iar-agent. Is this correct?

## Emerging Guideline: Play Structure

Every play in site.yml must declare:
1. `become: true` or omit (explicit privilege decision)
2. Role tags matching the role name
3. `when` guards for conditional roles (no hardcoded hostname targeting)
4. Group-based `hosts:` targeting (no individual hostnames)

## Emerging Guideline: Role Independence

Roles must not depend on other roles having run in the same playbook execution. Each role must be self-contained:
- Check its own prerequisites (e.g. nvidia-smi available)
- Declare its own dependencies (e.g. package installed)
- Not assume another role's state

Evidence: nvidia role ran twice on sophon because both ollama and frigate plays included it. The role was idempotent (no harm), but the double inclusion is a playbook structure problem, not a role problem. Making nvidia a separate play eliminates the issue.
## Resolved Open Questions

1. **NVIDIA targeting**: Create a `gpu_hosts` group in inventory. NVIDIA play targets `hosts: gpu_hosts`, no `when` guard needed. Cleaner than variable-based targeting.

2. **Static site targeting**: Create a `web_servers` group in inventory. Static sites play targets `hosts: web_servers`. Individual `when` guards on each role invocation control which host gets which content. No hardcoded hostnames.

3. **Monitoring targeting**: Create a `monitoring` group in inventory. Monitoring play targets `hosts: monitoring`. Node-exporter stays on `hosts: all`.

## Proposed inventory groups (updated)

```yaml
all:
  children:
    cloud:
      hosts:
        daftpunk:
        rammstein:
        greenday:
    local:
      hosts:
        sophon:
        yoga:
    # Functional groups
    proxy:
      hosts:
        rammstein:
    ai_playground:
      hosts:
        greenday:
    ollama_hosts:
      hosts:
        daftpunk:
        sophon:
    gpu_hosts:          # NEW
      hosts:
        sophon:
    web_servers:         # NEW
      hosts:
        rammstein:
        daftpunk:
    monitoring:          # NEW
      hosts:
        daftpunk:
    frigate_hosts:
      hosts:
        sophon:
```

## Updated proposed site.yml (relevant plays)

```yaml
- name: NVIDIA GPU drivers (GPU hosts)
  hosts: gpu_hosts
  become: true
  roles:
    - role: nvidia
      tags: [nvidia]

- name: Static sites
  hosts: web_servers
  become: true
  roles:
    - role: static-site
      vars:
        static_site_src: "{{ portfolio_src_dir }}"
        static_site_dest: "{{ portfolio_page_root }}"
      when: portfolio_page_enabled | default(false) | bool
      tags: [static-site]
    - role: static-site
      vars:
        static_site_src: "{{ landing_src_dir }}"
        static_site_dest: "{{ static_page_root }}"
      when: tool_static_page_enabled | default(false) | bool
      tags: [static-site]

- name: Monitoring
  hosts: monitoring
  become: true
  roles:
    - role: monitoring
      when: monitoring_enabled | default(false) | bool
      tags: [monitoring]
```