# Refactor Notes: inventory/hosts.yml

## Decisions

1. **Remove host count comment**
   - `# 4 hosts: 3 cloud VPS + 1 local workstation (sophon).` will grow stale with every host addition/removal. Delete it.

2. **`ansible_user: root` -> per-group users**
   - Cloud hosts: connect as `admin` (created by base role with passwordless sudo). Bootstrap exception: first run uses `--user root` on the CLI.
   - Local hosts: connect as `nacho`.
   - Passwordless sudo is effectively root, but connecting as a non-root user enforces better role conventions (roles must declare `become: true` where needed, matching the ansible.cfg least-privilege decision).

3. **No `ansible_host` in inventory -- rely on SSH config**
   - User manages host resolution in `~/.ssh/config` (IPs, domains, identity files). Ansible connects via `ssh://<hostname>` and SSH config resolves the actual endpoint. Inventory stays clean, SSH config stays the single source of truth for connection details.
   - Example SSH config:
     ```
     Host rammstein
       Hostname randazzo.ar
       User riemann
       Port 22
       IdentityFile ~/.ssh/id_ed25519
     Host yoga
       Hostname 192.168.2.66
       User nacho
       Port 22
       IdentityFile ~/.ssh/id_ed25519
     ```

4. **No `ansible_port` in inventory -- same as point 3**
   - Port managed in SSH config. If SSH port ever changes, update SSH config + sshd_config in the same run.

5. **Replace `when: inventory_hostname != 'yoga'` with variable-based conditionals**
   - Hardcoded hostname exclusions don't scale. Use per-host or per-group variables:
     - `manage_packages: true/false`
     - `manage_firewall: true/false`
   - Yoga gets `manage_packages: false`, `manage_firewall: false`.
   - Base role checks the variable, not the hostname.

6. **Create `group_vars/cloud.yml` and `group_vars/local.yml`**
   - Move `local_ssh_user: "nacho"` from `group_vars/all/main.yml` to `group_vars/local.yml`.
   - Cloud-specific settings (e.g. `ansible_user: admin`) go in `group_vars/cloud.yml`.
   - Local-specific settings (e.g. `ansible_user: nacho`, `local_ssh_user: nacho`) go in `group_vars/local.yml`.

7. **Create group_vars for functional groups when shared settings emerge**
   - `proxy`, `ai_playground`, `ollama_hosts`, `frigate_hosts` -- currently no group_vars. All config in host_vars or role defaults.
   - When a second host joins a functional group, extract shared settings to `group_vars/<group>.yml` to avoid duplication.

## Proposed inventory/hosts.yml

```yaml
all:
  children:
    cloud:
      vars:
        ansible_user: admin
      hosts:
        daftpunk:
        rammstein:
        greenday:
    local:
      vars:
        ansible_user: nacho
      hosts:
        sophon:
        yoga:

    # Functional groups (hosts can belong to multiple)
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
    frigate_hosts:
      hosts:
        sophon:
```

## Proposed group_vars structure

```
inventory/
  group_vars/
    all/
      main.yml          -- global settings (domains, WG, packages, defaults)
      vault.yml         -- encrypted secrets
    cloud.yml           -- cloud-specific (ansible_user: admin)
    local.yml           -- local-specific (ansible_user: nacho, local_ssh_user: nacho)
    ollama_hosts.yml    -- (when second Ollama host is added)
    frigate_hosts.yml   -- (when second Frigate host is added)
```

## Open Questions
- Bootstrap procedure: first run against a fresh host needs `--user root` on CLI since `admin` doesn't exist yet. Document this in operations.md.
- Yoga exclusions: what exactly should yoga skip? Currently: package updates, firewalld, dnf-automatic. Anything else?

## Clarifications (from discussion)

- **Per-host admin usernames, not generic "admin":** Each host gets a unique admin username (e.g. `riemann` on rammstein) to prevent terminal confusion when working on multiple hosts. These users are created manually during initial host setup -- no bootstrap-as-root needed. The inventory should set `ansible_user` per host, not per group, since each host has a different admin name.
- **Yoga exclusions:** Only package-manager operations. Yoga runs Fedora Silverblue (rpm-ostree, not dnf). Firewalld and dnf-automatic should still be managed on yoga. A single `manage_packages: false` host var on yoga is the only exclusion needed.
- **No `manage_firewall` variable needed** -- firewalld is managed on all hosts including yoga.
## New functional groups (from site.yml discussion)

```yaml
    gpu_hosts:          # NVIDIA GPU hosts
      hosts:
        sophon:
    web_servers:         # Static site hosts
      hosts:
        rammstein:
        daftpunk:
    monitoring:          # Prometheus + Grafana
      hosts:
        daftpunk:
```

These groups replace hardcoded hostname targeting in playbooks. Every play targets a group, not an individual host.