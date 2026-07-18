# Refactor Notes: roles/monitoring/

## Files reviewed
- `tasks/main.yml` (52 lines)
- `defaults/main.yml` (23 lines)
- `handlers/main.yml` (9 lines)
- `templates/compose.yml.j2` (50 lines)
- `templates/prometheus.yml.j2` (35 lines)
- `templates/alert_rules.yml.j2` (80 lines)

## Decisions

### 1. Replace hardcoded WG IPs with `hostvars`
- `compose.yml.j2`: `10.66.0.3` -> `{{ wg_ip }}` for port bindings
- `prometheus.yml.j2`: hardcoded node_exporter targets -> iterate `groups['wg_peers']` with `hostvars[host]['wg_ip']`

Proposed prometheus.yml.j2 scrape section:
```jinja2
  - job_name: "node_exporters"
    static_configs:
      - targets:
{% for host in groups['wg_peers'] %}
          - "{{ hostvars[host]['wg_ip'] }}:{{ node_exporter_port }}"
{% endfor %}
        labels:
          group: "hosts"
```

### 2. Remove cAdvisor entirely
- Remove `cadvisor_port` from defaults
- Remove cAdvisor scrape targets from prometheus.yml.j2
- cAdvisor can be added in the future when needed

### 3. `podman-compose` -> `podman compose` (3 occurrences)
- `Start monitoring stack` task (being removed anyway -- see decision 6)
- `monitoring-stack.service` ExecStart/ExecStop in the copy task
- `restart monitoring` handler

### 4. `grafana_admin_password`: blank default, real value in vault
Remove `"changeme"` default. Set to empty string. The real password must be in vault. If vault is missing the password, Grafana starts with an empty admin password (or fails, depending on version) -- fail closed, not fail with a known default.

### 5. Remove `node_exporter_version` and `node_exporter_port` from monitoring defaults
Both unused. The prometheus template uses hardcoded `9100` (being replaced with `hostvars` iteration). `node_exporter_version` is never referenced. Remove both.

Note: `node_exporter_port` IS needed in the prometheus template for the scrape targets. But it should come from the node-exporter role defaults, not be duplicated here. Use `hostvars[host]['node_exporter_port']` in the template, or define `node_exporter_port` in group_vars/all if it's shared.

Actually, the simplest approach: keep `node_exporter_port` in the node-exporter role defaults (where it already is) and reference it via `hostvars` in the prometheus template. Since all hosts run node-exporter, `hostvars[host]['node_exporter_port']` resolves from the node-exporter role's defaults via fact caching.

Wait -- role defaults are not available via `hostvars` on other hosts. Only facts set by `set_fact` or gathered facts are. Role defaults are only available on the host where the role runs.

The pragmatic fix: define `node_exporter_port` in `group_vars/all/main.yml` since it's used by both the node-exporter role and the monitoring role's prometheus template. It's a truly global value.

### 6. Remove standalone `podman compose up -d` task
The `monitoring-stack.service` systemd service handles container lifecycle. The standalone task is redundant. Remove it. The systemd service starts the containers on boot and on service start. Config changes notify `restart monitoring` which restarts the service.

### 7. Consolidate handlers
Convert `restart monitoring` to use the `service` module with `daemon_reload: true`:
```yaml
- name: restart monitoring
  service:
    name: monitoring-stack
    state: restarted
    daemon_reload: true
```

Remove the `reload systemd` handler -- `daemon_reload: true` on the restart handler covers it.

### 8. Add `notify: restart monitoring` to `Deploy compose.yml`
The compose file template doesn't notify restart. If the image version or ports change, the stack isn't restarted. Add `notify: restart monitoring`.

### 9. Remove stale "Runs on: daftpunk" comment
Per comments guideline. Playbook targeting shows this.

### 10. `alert_rules.yml.j2` -- no change needed
The `{% raw %}` / `{% endraw %}` wrapper correctly prevents Jinja2 from interpreting Prometheus `$labels` syntax. The alert rules are well-structured. No change.

## Proposed defaults/main.yml

```yaml
---
# roles/monitoring/defaults/main.yml

# -- Prometheus --
prometheus_version: "v2.52.0"
prometheus_retention: "30d"
prometheus_port: 9090

# -- Grafana --
grafana_version: "11.0.0"
grafana_port: 3000
grafana_admin_user: "admin"
# Password MUST be set in vault. Blank = fail closed.
grafana_admin_password: ""

# -- Storage paths --
monitoring_data_dir: "/var/lib/monitoring"
prometheus_data_dir: "{{ monitoring_data_dir }}/prometheus"
grafana_data_dir: "{{ monitoring_data_dir }}/grafana"

# -- Compose file location --
monitoring_compose_dir: "/opt/monitoring"
```

Note: `node_exporter_version`, `node_exporter_port`, `cadvisor_port` removed.

## Proposed tasks/main.yml

```yaml
---
# roles/monitoring/tasks/main.yml
# Deploys Prometheus + Grafana monitoring stack via podman compose.
# All services bind to WireGuard IP only -- no public exposure.
# Prometheus scrapes all hosts over WireGuard (pull model).

# -- Create directories --
- name: Create monitoring compose directory
  file:
    path: "{{ monitoring_compose_dir }}"
    state: directory
    owner: root
    group: root
    mode: '0755'

- name: Create Prometheus data directory
  file:
    path: "{{ prometheus_data_dir }}"
    state: directory
    owner: 65534
    group: 65534
    mode: '0755'

- name: Create Grafana data directory
  file:
    path: "{{ grafana_data_dir }}"
    state: directory
    owner: 472
    group: 472
    mode: '0755'

# -- Deploy compose file and configs --
- name: Deploy compose.yml
  template:
    src: compose.yml.j2
    dest: "{{ monitoring_compose_dir }}/compose.yml"
    owner: root
    group: root
    mode: '0644'
  notify: restart monitoring

- name: Deploy prometheus.yml
  template:
    src: prometheus.yml.j2
    dest: "{{ monitoring_compose_dir }}/prometheus.yml"
    owner: root
    group: root
    mode: '0644'
  notify: restart monitoring

- name: Deploy alert_rules.yml
  template:
    src: alert_rules.yml.j2
    dest: "{{ monitoring_compose_dir }}/alert_rules.yml"
    owner: root
    group: root
    mode: '0644'
  notify: restart monitoring

# -- Create systemd service --
- name: Deploy monitoring-stack systemd service
  copy:
    dest: /etc/systemd/system/monitoring-stack.service
    content: |
      [Unit]
      Description=Monitoring Stack (Prometheus + Grafana)
      After=network-online.target podman.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/bin/podman compose -f {{ monitoring_compose_dir }}/compose.yml up -d
      ExecStop=/usr/bin/podman compose -f {{ monitoring_compose_dir }}/compose.yml down

      [Install]
      WantedBy=multi-user.target
    owner: root
    group: root
    mode: '0644'
  notify: restart monitoring

# -- Enable and start --
- name: Enable and start monitoring-stack
  service:
    name: monitoring-stack
    state: started
    enabled: true
```

## Proposed handlers/main.yml

```yaml
---
# roles/monitoring/handlers/main.yml

- name: restart monitoring
  service:
    name: monitoring-stack
    state: restarted
    daemon_reload: true
```

## Proposed compose.yml.j2

```jinja2
# {{ ansible_managed }}
# Prometheus + Grafana monitoring stack
# All services bind to WireGuard IP only -- no public exposure.

services:
  prometheus:
    image: docker.io/prom/prometheus:{{ prometheus_version }}
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "{{ wg_ip }}:{{ prometheus_port }}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./alert_rules.yml:/etc/prometheus/alert_rules.yml:ro
      - {{ prometheus_data_dir }}:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time={{ prometheus_retention }}"
      - "--web.console.libraries=/usr/share/prometheus/console_libraries"
      - "--web.console.templates=/usr/share/prometheus/consoles"
    networks:
      - monitoring

  grafana:
    image: docker.io/grafana/grafana:{{ grafana_version }}
    container_name: grafana
    restart: unless-stopped
    ports:
      - "{{ wg_ip }}:{{ grafana_port }}:3000"
    volumes:
      - {{ grafana_data_dir }}:/var/lib/grafana
    environment:
      GF_SECURITY_ADMIN_USER: "{{ grafana_admin_user }}"
      GF_SECURITY_ADMIN_PASSWORD: "{{ grafana_admin_password }}"
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SERVER_ROOT_URL: "https://grafana.i.ar"
      GF_SERVER_DOMAIN: "grafana.i.ar"
      GF_AUTH_ANONYMOUS_ENABLED: "false"
      GF_AUTH_BASIC_ENABLED: "true"
    depends_on:
      - prometheus
    networks:
      - monitoring

networks:
  monitoring:
    driver: bridge
```

## Proposed prometheus.yml.j2

```jinja2
# {{ ansible_managed }}
# Prometheus configuration
# Scrape targets across the WireGuard mesh.

global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "alert_rules.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node_exporters"
    static_configs:
      - targets:
{% for host in groups['wg_peers'] %}
          - "{{ hostvars[host]['wg_ip'] }}:{{ node_exporter_port }}"
{% endfor %}
        labels:
          group: "hosts"
```

## Emerging Guidelines

### Guideline: Vault Template File
The repository must include a `vault.yml.template` file that documents every secret the infrastructure needs. The template lists variable names with placeholder values and comments explaining what each secret is for. Operators copy the template to `vault.yml`, fill in real values, and encrypt with ansible-vault.

Evidence: `grafana_admin_password` in monitoring defaults, `frigate_camera_rtsp_user`/`frigate_camera_rtsp_password` in vault, `ai_agent_ssh_public_key` moving to vault, `wg_private_keys`/`wg_public_keys` in vault. No central reference for what belongs in vault. A template file makes the vault requirements explicit and discoverable.

Proposed `vault.yml.template`:
```yaml
# vault.yml.template
# Copy to vault.yml, fill in real values, encrypt with:
#   ansible-vault encrypt inventory/group_vars/all/vault.yml --ask-vault-pass

# -- WireGuard private keys (per host) --
wg_private_keys:
  rammstein: "PRIVATE_KEY_HERE"
  daftpunk: "PRIVATE_KEY_HERE"
  greenday: "PRIVATE_KEY_HERE"
  sophon: "PRIVATE_KEY_HERE"
  yoga: "PRIVATE_KEY_HERE"

# -- WireGuard public keys (per host) --
wg_public_keys:
  rammstein: "PUBLIC_KEY_HERE"
  daftpunk: "PUBLIC_KEY_HERE"
  greenday: "PUBLIC_KEY_HERE"
  sophon: "PUBLIC_KEY_HERE"
  yoga: "PUBLIC_KEY_HERE"

# -- Grafana admin credentials --
grafana_admin_password: "PASSWORD_HERE"

# -- Frigate RTSP camera credentials --
frigate_camera_rtsp_user: "CAMERA_USER_HERE"
frigate_camera_rtsp_password: "CAMERA_PASSWORD_HERE"

# -- AI agent SSH public key (greenday) --
ai_agent_ssh_public_key: "ssh-ed25519 AAAA... ai-agent"
```

### Guideline: Blank Defaults for Secrets
Secret variables in role defaults must be blank (empty string), not placeholder values like `"changeme"`. A blank default forces the operator to set the value in vault. A placeholder default creates a false sense of security -- the service starts with a known weak credential.

Evidence: `grafana_admin_password: "changeme"` is a known weak password that could be deployed to production if vault is not configured. Blank default means the service fails to start (or starts with no admin access) -- fail closed.