# Refactor Notes: playbooks/*.yml (all playbooks except site.yml)

## Cross-cutting observations

### 1. Stale usage comments
Every playbook references `--vault-password-file .vault_pass` but user uses `--ask-vault-pass`. Fix all.

### 2. cloudflare.yml -- delete entirely
Role is being deleted. Playbook references it. Delete `playbooks/cloudflare.yml`.

### 3. proxy.yml -- remove cloudflare-tunnel role
After deletion, proxy.yml only runs caddy. Rename to `caddy.yml` or keep as `proxy.yml` with only caddy.

### 4. portfolio-page.yml and static-page.yml -- merge after role merge
After merging static-page + portfolio-page into one parameterized `static-site` role, these playbooks become:
```yaml
# playbooks/portfolio-page.yml
- name: Deploy portfolio page
  hosts: web_servers
  become: true
  roles:
    - role: static-site
      vars:
        static_site_src: "{{ portfolio_src_dir }}"
        static_site_dest: "{{ portfolio_page_root }}"
      when: portfolio_page_enabled | default(false) | bool
      tags: [static-site]
```
Both individual playbooks can stay (they're convenience entry points) but they use the merged role.

### 5. No `become: true` on any playbook
Same as site.yml. Every playbook needs `become: true` after the ansible.cfg change.

### 6. No tags on any playbook
Same as site.yml. Every role invocation should be tagged.

### 7. base.yml -- missing hub-first WireGuard ordering
`base.yml` runs wireguard on all hosts without the hub-first serial pattern. This can cause spoke lockout if the hub config changes. The wireguard.yml playbook has the correct hub-first pattern. base.yml should either:
- Not include wireguard (just base hardening), or
- Include the same hub-first pattern as wireguard.yml

### 8. monitoring.yml -- hardcoded `hosts: daftpunk`
Should target `hosts: monitoring` group after the inventory restructure.

### 9. monitoring.yml -- podman runs unconditionally
`podman` role has no `when` guard. After the "podman always-on" decision, this is fine, but the role should still be tagged.

### 10. iar-agents.yml -- podman guard
Uses `when: podman_enabled`. After the "podman always-on" decision, remove the guard. Podman runs unconditionally.

### 11. ollama.yml -- podman guard + nvidia missing
Uses `when: podman_enabled` (remove after podman always-on decision). Missing nvidia role -- if someone runs ollama.yml standalone on a GPU host, nvidia drivers won't be checked. The standalone playbook should either include nvidia or document that nvidia must be run first.

## Per-playbook notes

### ai_playground.yml
- Add `become: true`
- Add tags `[podman]`, `[ai-environment]`
- Fix usage comment

### base.yml
- Add `become: true`
- Add tags `[base]`, `[wireguard]`
- Fix usage comment
- **Decision needed**: Should base.yml include wireguard? If yes, use hub-first pattern. If no, rename to just base hardening and remove wireguard play.

### cloudflare.yml
- **Delete entirely**

### iar-agents.yml
- Add `become: true`
- Add tags `[podman]`, `[iar-agent]`
- Remove `podman_enabled` guard (podman always-on)
- Fix usage comment

### monitoring.yml
- Add `become: true`
- Add tags `[podman]`, `[monitoring]`, `[node-exporter]`
- Change `hosts: daftpunk` -> `hosts: monitoring`
- Fix usage comment

### ollama.yml
- Add `become: true`
- Add tags `[podman]`, `[ollama]`
- Remove `podman_enabled` guard
- Add nvidia role with `when: nvidia_enabled` or document prerequisite
- Fix usage comment

### portfolio-page.yml
- Add `become: true`
- Use merged `static-site` role with vars
- Target `hosts: web_servers` with `when: portfolio_page_enabled`
- Add tags `[static-site]`
- Fix usage comment

### proxy.yml
- Remove cloudflare-tunnel role
- Add `become: true`
- Add tags `[caddy]`
- Fix usage comment
- Consider rename to `caddy.yml`

### static-page.yml
- Add `become: true`
- Use merged `static-site` role with vars
- Target `hosts: web_servers` with `when: tool_static_page_enabled`
- Add tags `[static-site]`
- Fix usage comment

### wireguard.yml
- Add `become: true`
- Add tags `[wireguard]`
- Fix usage comment
- Otherwise correct -- hub-first pattern is good

## Emerging Guideline: Playbook Conventions

Every playbook must:
1. Use `--ask-vault-pass` in usage comments (not `--vault-password-file`)
2. Declare `become: true` on every play that needs root
3. Tag every role invocation with the role name
4. Target groups, not individual hostnames
5. Use `when` guards for conditional roles, not hardcoded host targeting

## Emerging Guideline: Standalone Playbook Completeness

Standalone playbooks (those meant to run independently of site.yml) must include all prerequisite roles or document them explicitly. A standalone playbook that silently depends on a role not included in it is a trap.

Evidence: ollama.yml doesn't include nvidia. Running it standalone on sophon (GPU host) would install Ollama without checking GPU drivers. The playbook should either include nvidia or document "run nvidia.yml first."

## Open Questions

- **base.yml + wireguard**: Should base.yml include wireguard, or should it be base hardening only?
- **proxy.yml rename**: Rename to `caddy.yml` or keep as `proxy.yml`?
- **ollama.yml + nvidia**: Include nvidia in ollama.yml, or document the prerequisite?
- **cloudflare.yml deletion**: Confirmed, but should we keep a stub playbook that does nothing (for tooling that references it)?
## Resolved Open Questions

1. **base.yml + wireguard**: Keep base.yml as hardening only. Remove the WireGuard play from base.yml. If a host needs both, run `base.yml` then `wireguard.yml` separately, or use `site.yml`.

2. **proxy.yml rename**: Rename to `caddy.yml`. Cloudflare tunnel is gone, the playbook only runs caddy now.

3. **ollama.yml + nvidia**: Document the prerequisite. Add a comment to ollama.yml:
   ```yaml
   # NOTE: On GPU hosts, run nvidia playbook first:
   #   ansible-playbook playbooks/nvidia.yml --ask-vault-pass
   # Or use site.yml which includes nvidia before ollama.
   ```
   This means we need a standalone `nvidia.yml` playbook that targets `gpu_hosts` group.