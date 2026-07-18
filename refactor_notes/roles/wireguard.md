# Refactor Notes: roles/wireguard/

## Files reviewed
- `tasks/main.yml` (70 lines)
- `defaults/main.yml` (8 lines)
- `handlers/main.yml` (7 lines)
- `templates/wg0.conf.j2` (40 lines)

## Decisions

### 1. `wg_network` default: `/24` -> `/16`
Role defaults say `10.66.0.0/24`, group_vars says `10.66.0.0/16`. The `/16` is correct -- allows all 10.66.x.x addresses. Fix the default to match.

### 2. `wg_dns` should be derived, not a variable
`wg_dns: "10.66.0.1"` is always the first usable IP in the WG network. It should be derived from `wg_network` by replacing the last octet's 0 with 1. Remove `wg_dns` from both defaults and group_vars. Derive in the template or in a set_fact.

Example derivation (Jinja2):
```jinja2
{{ wg_network | regex_replace('0/(.*)', '1/\\1') }}
```
Or more robustly, split and reassemble. Document that `wg_network` must be a full CIDR (e.g. `10.66.0.0/16`).

### 3. `wg_hub`: document as required, create `wg_hub` group
Don't hardcode a hostname as default. Instead:
- Create a `wg_hub` group in inventory with one host (rammstein)
- Document that `wg_hub` group must not be empty if WireGuard is enabled
- The template and tasks reference `groups['wg_hub'][0]` instead of the `wg_hub` variable

This means `wg_hub` becomes a group, not a variable. The playbook targeting changes from `hosts: "{{ wg_hub | default('rammstein') }}"` to `hosts: wg_hub`.

### 4. Add `wg_peers` group
Not every host in inventory needs to be a WireGuard peer. Create a `wg_peers` group in inventory. The template iterates `groups['wg_peers']` instead of `groups['all']`. Hosts not in `wg_peers` don't get WG config.

### 5. Remove stale yoga firewalld comment
```
# The base role skips firewalld on some hosts (e.g. yoga laptop).
# We need to know if it's running before trying to configure it.
```
Firewalld runs on all hosts now. The `systemctl is-active firewalld` check is still reasonable (firewalld could be down for other reasons) but the comment is wrong. Update or remove.

### 6. Document `wg_network` must be full CIDR
The regex-based subnet mask extraction (`regex_replace('^.*\\/', '')`) requires `wg_network` to be a full CIDR (e.g. `10.66.0.0/16`). If it's just `10.66.0.0`, the regex produces the full string as the mask. Document this requirement in the variable comment.

### 7. Add guards for missing vault keys / `wg_ip`
The template references `wg_private_keys[inventory_hostname]`, `wg_public_keys[host]`, and `hostvars[host]['wg_ip']`. If a host is in `wg_peers` but missing from vault dicts or lacks `wg_ip`, the template fails with an opaque Jinja2 error. Add a pre-task that validates all `wg_peers` hosts have `wg_ip` defined and exist in the vault key dicts. Fail with a clear message.

### 8. `ListenPort` on spokes: conditional, hub only
Remove `ListenPort` from spoke config. Spokes initiate connections, they don't need to listen. Keep on hub (or any host with `wg_endpoint`).

### 9. IP forwarding stays in wireguard role
After removing from base, this is the correct home. `net.ipv4.ip_forward` on hub only. No change.

### 10. Hub-first pattern confirmed correct
`meta: flush_handlers` on hub + serial ordering in playbook. No change.

## Proposed inventory additions

```yaml
all:
  children:
    # ...
    wg_hub:            # Single host, the WG hub. Must not be empty if WG is enabled.
      hosts:
        rammstein:
    wg_peers:          # All hosts that participate in the WG mesh
      hosts:
        rammstein:
        daftpunk:
        greenday:
        sophon:
        yoga:
```

## Proposed defaults/main.yml

```yaml
---
# roles/wireguard/defaults/main.yml
# WireGuard defaults. Overridden by group_vars/all/main.yml in practice.
# Kept here for role self-documentation and standalone usability.

# wg_network MUST be a full CIDR (e.g. 10.66.0.0/16). The subnet mask
# is extracted via regex; a bare IP without /prefix will produce wrong results.
wg_network: "10.66.0.0/16"
wg_interface: wg0
wg_port: 51820
wg_keepalive: 25
wg_mtu: 1420
```

Note: `wg_dns` removed -- derived from `wg_network`. `wg_hub` removed -- now a group, not a variable.

## Proposed wg0.conf.j2 changes

```jinja2
# {{ ansible_managed }}
# WireGuard configuration for {{ inventory_hostname }}
# Topology: hub-and-spoke -- {{ groups['wg_hub'][0] }} is the hub
# All traffic between peers is routed through the hub.

{% set wg_hub_host = groups['wg_hub'][0] %}
{% set wg_dns_ip = wg_network | regex_replace('0/(.*)', '1/\\1') %}

[Interface]
PrivateKey = {{ wg_private_keys[inventory_hostname] }}
Address = {{ wg_ip }}/{{ wg_network | regex_replace('^.*\\/', '') }}
{% if inventory_hostname == wg_hub_host %}
ListenPort = {{ wg_port }}
{% endif %}
MTU = {{ wg_mtu }}

{% if inventory_hostname == wg_hub_host %}
# Hub: All peers listed here, hub routes between them
{% for host in groups['wg_peers'] %}
{% if host != inventory_hostname %}
# Peer: {{ host }} ({{ hostvars[host]['wg_ip'] }})
[Peer]
PublicKey = {{ wg_public_keys[host] }}
AllowedIPs = {{ hostvars[host]['wg_ip'] }}/32
{% if hostvars[host].get('wg_endpoint') %}
Endpoint = {{ hostvars[host]['wg_endpoint'] }}:{{ wg_port }}
{% endif %}
PersistentKeepalive = {{ wg_keepalive }}

{% endif %}
{% endfor %}
{% else %}
# Spoke: Connect to hub, route all WG traffic through it
[Peer]
PublicKey = {{ wg_public_keys[wg_hub_host] }}
Endpoint = {{ hostvars[wg_hub_host]['wg_endpoint'] }}:{{ wg_port }}
AllowedIPs = {{ wg_network }}
PersistentKeepalive = {{ wg_keepalive }}
{% endif %}
```

## Proposed tasks/main.yml changes

- Replace `inventory_hostname == wg_hub` with `inventory_hostname == groups['wg_hub'][0]`
- Add validation pre-task: check all `wg_peers` hosts have `wg_ip` and exist in vault key dicts
- Remove `wg_dns` references (derived now)
- Update firewalld comment
- Keep `meta: flush_handlers` on hub
- Keep IP forwarding sysctl on hub

## Emerging Guidelines

### Guideline: Derive, Don't Duplicate
If a value can be computed from another variable, derive it. Don't define it as a separate variable that must be kept in sync manually.

Evidence: `wg_dns` is always the first usable IP in `wg_network`. Defining it separately means if `wg_network` changes, `wg_dns` must be manually updated. Deriving it eliminates a class of bugs.

### Guideline: Groups Over Variables for Host Identity
Use inventory groups to identify hosts by role, not variables. A `wg_hub` group is clearer than a `wg_hub: rammstein` variable. Groups are visible in the inventory file, enforced by Ansible's targeting, and don't require variables to be defined in the right layer.

Evidence: `wg_hub` as a variable requires a default or a documented prerequisite. `wg_hub` as a group is self-documenting in the inventory. Adding a second hub means adding it to the group, not changing a variable.

### Guideline: Document Variable Format Requirements
When a variable is used in a regex or filter that expects a specific format, document the format requirement in the variable comment. A bare IP without CIDR prefix will silently produce wrong results.

Evidence: `wg_network` must be a full CIDR because the subnet mask is extracted via `regex_replace('^.*\\/', '')`. Without the `/prefix`, the regex returns the full string as the mask.