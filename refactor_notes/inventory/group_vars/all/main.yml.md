# Refactor Notes: inventory/group_vars/all/main.yml

## Decisions

1. **Move `local_ssh_user` to `group_vars/local.yml`**
   - Only applies to local hosts. Having it in `all` means cloud hosts see a meaningless variable.

2. **SSH defaults: move to base role defaults (or separate ssh role)**
   - `ssh_port`, `ssh_password_auth`, `ssh_permit_root_login` are defined here AND in `roles/base/defaults/main.yml` with conflicting values (`ssh_permit_root_login: "no"` in defaults vs `"prohibit-password"` in group_vars). Group_vars wins, but the discrepancy is confusing.
   - Role defaults should be the authoritative source for SSH config. Group_vars should not duplicate them.
   - Ideal: extract a dedicated `ssh` role that owns SSH hardening. For now, base role defaults are the single source.

3. **`ollama_listen` default: blank, not `0.0.0.0`**
   - `0.0.0.0` as a global default is dangerous -- publicly exposes Ollama with no auth if a host_vars override is missing.
   - Set to empty string in ollama role defaults. Force the deployer to explicitly set the listen address in host_vars.
   - This variable belongs in `roles/ollama/defaults/main.yml`, not `group_vars/all/main.yml`.

4. **`ollama_gpu` default: keep `false` in role defaults, not group_vars**
   - Correct default. Override is a host_var. But the default belongs in `roles/ollama/defaults/main.yml`, not `group_vars/all/main.yml`.

5. **`caddy_version: "latest"` -> remove, use `state: present`**
   - "latest" means every playbook run could install a different version. Breaks idempotency.
   - Drop the version variable. Use `state: present` in the dnf task. Upgrades happen through the package manager (dnf-automatic).

6. **`base_packages`: group with comments by category**
   - Essential (git, curl, python3), convenience (vim, tmux), diagnostic (net-tools, bind-utils). Comments explain why each is there.

7. **`domains` dict: no change needed**
   - Clean, well-structured, single source of truth.

8. **WireGuard section: no change needed**
   - Clean. `wg_hub: rammstein` is the right place.

## Variables to remove from group_vars/all/main.yml

| Variable | Reason | New Location |
|----------|--------|--------------|
| `local_ssh_user` | Only applies to local hosts | `group_vars/local.yml` |
| `ssh_port` | Role default, not global | `roles/base/defaults/main.yml` (or ssh role) |
| `ssh_password_auth` | Role default, not global | `roles/base/defaults/main.yml` (or ssh role) |
| `ssh_permit_root_login` | Role default, not global | `roles/base/defaults/main.yml` (or ssh role) |
| `ollama_version` | Role default | `roles/ollama/defaults/main.yml` |
| `ollama_port` | Role default | `roles/ollama/defaults/main.yml` |
| `ollama_install_dir` | Role default | `roles/ollama/defaults/main.yml` |
| `ollama_models_dir` | Role default | `roles/ollama/defaults/main.yml` |
| `ollama_user` | Role default | `roles/ollama/defaults/main.yml` |
| `ollama_listen` | Role default, set to blank | `roles/ollama/defaults/main.yml` |
| `ollama_gpu` | Role default | `roles/ollama/defaults/main.yml` |
| `ollama_models` | Role default (empty list) | `roles/ollama/defaults/main.yml` |
| `caddy_version` | Remove entirely | N/A (use `state: present`) |
| `caddy_email` | Role default | `roles/caddy/defaults/main.yml` |
| `caddy_config_path` | Role default | `roles/caddy/defaults/main.yml` |

## Variables that stay in group_vars/all/main.yml

| Variable | Reason |
|----------|--------|
| `domains` | Global, used by multiple roles (caddy, static-page, portfolio-page) |
| `wg_interface` | Global, used by wireguard role |
| `wg_port` | Global, used by wireguard + base roles |
| `wg_network` | Global, used by wireguard role |
| `wg_dns` | Global, used by wireguard role |
| `wg_keepalive` | Global, used by wireguard role |
| `wg_mtu` | Global, used by wireguard role |
| `wg_hub` | Global, used by wireguard role + playbooks |
| `timezone` | Global, used by base role |
| `base_packages` | Global, used by base role |

## Proposed group_vars/all/main.yml

```yaml
# ── Domains ───────────────────────────────────────────────
# Single source of truth for domain names. Used by caddy, static-page, portfolio-page.
domains:
  proxy: "randazzo.ar"
  proxy_alt: "randazzo.com.ar"
  ollama: "i.ar"
  ai: "0b.ar"

# ── WireGuard (shared) ─────────────────────────────────────
# Hub-and-spoke mesh. rammstein is the hub.
wg_interface: wg0
wg_port: 51820
wg_network: "10.66.0.0/16"
wg_dns: "10.66.0.1"
wg_keepalive: 25
wg_mtu: 1420
wg_hub: rammstein

# ── Timezone ───────────────────────────────────────────────
timezone: "America/Argentina/Buenos_Aires"

# ── Essential packages ────────────────────────────────────
# Installed on all hosts by the base role.
base_packages:
  # Essential
  - git
  - curl
  - wget
  - python3
  - rsync
  - unzip
  - tar
  # Convenience
  - vim
  - tmux
  - jq
  - zstd
  # Diagnostic
  - net-tools
  - bind-utils
```

## Emerging Guideline: Variable Placement

Variables should be defined at the highest layer where they are constant:

1. **Role defaults** -- per-role settings (port, user, paths, version, enable flags). Safe fallback values.
2. **group_vars/all** -- truly global settings shared across roles (domains, WireGuard, timezone, packages).
3. **group_vars/<group>** -- settings shared by a functional group (cloud, local, ollama_hosts).
4. **host_vars** -- per-host overrides (WG IP, enabled services, models, camera definitions).
5. **vault** -- secrets (keys, tokens, credentials).

Rule: if a variable is only used by one role, it belongs in that role's defaults. If it's used by multiple roles, it belongs in group_vars. If it varies per host, it belongs in host_vars.

## Emerging Guideline: Safe Defaults

Role defaults must be safe, not convenient. A missing override should fail closed, not open:

- `ollama_listen: ""` (blank, forces explicit configuration) not `"0.0.0.0"` (exposes service)
- `ollama_gpu: false` (opt-in) not `true`
- `frigate_enabled: false` (opt-in) not `true`

If a blank default causes a task to fail, that's correct behavior -- the deployer forgot to configure something critical.