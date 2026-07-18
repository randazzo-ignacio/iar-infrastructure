# Refactor Notes: roles/caddy/

## Files reviewed
- `tasks/main.yml` (44 lines)
- `defaults/main.yml` (5 lines)
- `handlers/main.yml` (8 lines)
- `templates/Caddyfile.j2` (75 lines)

## Decisions

### 1. Replace `command` for COPR repo with `dnf` module
Use the `dnf` module's copr support instead of `command: "dnf copr enable -y @caddy/caddy"`. The `dnf` module handles idempotency natively.

### 2. Remove `caddy_version` variable
Dead variable. Never used. The install task uses `state: present` (correct per our decision). Remove from defaults.

### 3. `caddy_email`: placeholder default, real value in vault or group_vars
Personal email should NOT go in role defaults (public repo). Keep a placeholder default (`change-me@example.com`) in role defaults. Real value (`ignacio@randazzo.ar`) stays in group_vars/all or vault. If someone clones the repo, they get the placeholder -- no misdirected emails.

### 4. Remove `caddy_config_path` from group_vars
Duplicated in defaults and group_vars. Keep in role defaults only. Remove from group_vars/all/main.yml.

### 5. Web root creation: move to static-site role
The two web root creation tasks (`when: inventory_hostname == 'daftpunk'` and `when: inventory_hostname == 'rammstein'`) use hardcoded hostnames. After merging static-page + portfolio-page into the `static-site` role, web root creation moves there. The caddy role only installs Caddy, deploys Caddyfile, configures firewalld, and enables the service.

### 6. Data-driven Caddyfile template
Replace the giant `if/elif` on hostname with a data-driven template. Each host defines a `caddy_sites` list in host_vars. The template iterates the list. No hardcoded hostnames, no hardcoded IPs, no hardcoded paths.

Per-host variables should be inferred from facts/variables, not hardcoded:
- WG IPs: use `hostvars[host]['wg_ip']` not `10.66.0.5`
- Web roots: use variables from the static-site role, not `/var/www/randazzo.ar`
- Ports: use variables, not `8971` or `3000`

Example host_vars:
```yaml
# host_vars/rammstein.yml
caddy_sites:
  - domain: "{{ domains.proxy }}"
    type: static
    root: "{{ portfolio_page_root }}"
  - domain: "{{ domains.proxy_alt }}"
    type: redirect
    target: "https://{{ domains.proxy }}{uri}"
  - domain: "camaras.{{ domains.proxy }}"
    type: proxy
    backend_host: sophon
    backend_port: "{{ frigate_web_port }}"
```

Example template (simplified):
```jinja2
# {{ ansible_managed }}
# Caddyfile for {{ inventory_hostname }}
{
    email {{ caddy_email }}
}

{% for site in caddy_sites %}
{{ site.domain }} {
{% if site.type == 'static' %}
    root * {{ site.root }}
    file_server
    encode gzip zstd
{% elif site.type == 'proxy' %}
    reverse_proxy {{ hostvars[site.backend_host]['wg_ip'] }}:{{ site.backend_port }}
    encode gzip zstd
{% elif site.type == 'redirect' %}
    redir {{ site.target }} permanent
{% endif %}
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy no-referrer
    }
}

{% endfor %}
```

### 7. Security headers as default snippet
Define security headers once. All sites inherit them. Per-site overrides are possible but the default is complete. This fixes the inconsistency where greenday was missing X-Frame-Options and Referrer-Policy.

In the data-driven template, headers are rendered for every site block unconditionally. Per-site header overrides can be added via a `headers` key in the site dict if needed in the future.

### 8. Replace hardcoded WG IPs with `hostvars`
All `reverse_proxy` backends use `hostvars[host]['wg_ip']` instead of hardcoded IPs. The backend host is specified by name in host_vars, the IP is resolved at template time.

### 9. Remove unused `restart caddy` handler
The handler is defined but never notified. Only `reload caddy` is used. Remove the unused handler. (This explains why restart wasn't working -- the handler was never notified.)

### 10. Add firewalld defensive check
Add a `systemctl is-active firewalld` check before the firewalld tasks, same pattern as the wireguard role. Don't assume base role guarantees firewalld is running.

## Proposed defaults/main.yml

```yaml
---
# roles/caddy/defaults/main.yml

caddy_email: "change-me@example.com"  # Override in group_vars or vault
caddy_config_path: "/etc/caddy/Caddyfile"
caddy_sites: []  # Define per-host in host_vars
```

## Proposed tasks/main.yml

```yaml
---
# roles/caddy/tasks/main.yml
# Installs Caddy on web_servers. Each host gets a data-driven Caddyfile
# generated from its caddy_sites list (defined in host_vars).

# -- Install Caddy --
- name: Add Caddy COPR repo
  dnf:
    name: "@caddy/caddy"
    state: present
  # dnf module handles copr idempotently

- name: Install Caddy
  dnf:
    name: caddy
    state: present

# -- Configure Caddy --
- name: Deploy Caddyfile
  template:
    src: Caddyfile.j2
    dest: "{{ caddy_config_path }}"
    owner: root
    group: root
    mode: '0644'
  notify: reload caddy

# -- Firewall --
- name: Check if firewalld is running
  command: systemctl is-active firewalld
  register: caddy_firewalld_status
  changed_when: false
  failed_when: false

- name: Allow HTTP through firewalld
  ansible.posix.firewalld:
    service: http
    permanent: true
    state: enabled
    immediate: true
  when: caddy_firewalld_status.stdout == 'active'

- name: Allow HTTPS through firewalld
  ansible.posix.firewalld:
    service: https
    permanent: true
    state: enabled
    immediate: true
  when: caddy_firewalld_status.stdout == 'active'

# -- Enable Caddy --
- name: Enable and start Caddy
  service:
    name: caddy
    state: started
    enabled: true
```

## Emerging Guidelines

### Guideline: Data-Driven Templates
Templates should iterate over data structures, not branch on hostnames. Per-host configuration is data in host_vars, not conditional logic in templates.

Evidence: Caddyfile.j2 has a 75-line if/elif chain on `inventory_hostname`. Adding a host or domain means editing the template. A data-driven template with a `caddy_sites` list means adding a host is adding data to host_vars -- no template changes.

### Guideline: No Personal Data in Role Defaults
Role defaults live in a public repo. Personal email addresses, names, IPs, and domains belong in group_vars or vault (private). Role defaults use placeholders.

Evidence: `caddy_email: "ignacio@randazzo.ar"` in group_vars is fine (private repo). But if it were in role defaults (public repo), someone cloning the repo would register Caddy with the wrong email. Placeholder `change-me@example.com` in defaults, real value in group_vars.

### Guideline: Resolve Host Data via hostvars, Not Hardcoded IPs
When a template needs another host's IP, use `hostvars[host]['wg_ip']`. Never hardcode `10.66.0.5`.

Evidence: Caddyfile hardcodes `10.66.0.5:8971` for Frigate and `10.66.0.3:3000` for Grafana. If WG IP scheme changes, every hardcoded IP must be found and updated. `hostvars` resolves at template time from inventory data.