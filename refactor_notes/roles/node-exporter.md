# Refactor Notes: roles/node-exporter/

## Files reviewed
- `tasks/main.yml` (42 lines)
- `defaults/main.yml` (12 lines)
- `handlers/main.yml` (4 lines)
- `templates/node_exporter.service.j2` (22 lines)

## Decisions

### 1. Simplify download+extract+install+cleanup with `unarchive` module
Replace 5 tasks (download, extract, install, clean archive, clean extracted) with 3 tasks using the `unarchive` module:

```yaml
- name: Download and extract node_exporter
  unarchive:
    src: "https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}/node_exporter-{{ node_exporter_version }}.linux-amd64.tar.gz"
    dest: /tmp
    remote_src: true
    creates: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64/node_exporter"
  register: node_exporter_download

- name: Install node_exporter binary
  copy:
    src: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64/node_exporter"
    dest: "{{ node_exporter_bin }}"
    remote_src: true
    owner: root
    group: root
    mode: '0755'
  when: node_exporter_download.changed

- name: Clean up extracted files
  file:
    path: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64"
    state: absent
  when: node_exporter_download.changed
```

The `unarchive` module handles download + extract + idempotency in one task. The `creates` guard checks for the extracted binary. Version upgrades work by changing `node_exporter_version` (different URL -> different `creates` path -> re-download).

### 2. Remove `node_exporter_listen: "0.0.0.0"` dead variable
The template uses `{{ wg_ip }}:{{ node_exporter_port }}` directly. `node_exporter_listen` is never referenced. Remove from defaults.

### 3. Remove standalone `Reload systemd` task
Add `daemon_reload: true` to the `restart node_exporter` handler. Remove the standalone task that runs every execution.

### 4. `node_exporter_user: "node-exporter"` -> `"node_exporter"`
Change hyphenated username to underscore. Matches Prometheus convention and avoids potential POSIX username issues.

### 5. Version-based idempotency is correct
The `unarchive` `creates` guard uses the version in the path. Changing `node_exporter_version` triggers re-download and re-install. No upgrade flag needed. No change.

### 6. `node_exporter_version: "1.8.1"` -- explicit, visible
Standard pattern for binary installs. No change.

### 7. Role header comment -- keep
Role header explaining purpose ("Installs node_exporter as systemd service, listens on WG IP only") is useful context, not redundancy. Keep.

### 8. Systemd hardening in template -- keep, good practice
The hardening directives (NoNewPrivileges, ProtectHome, PrivateTmp, ProtectKernelModules, ProtectKernelTunables) and the comment explaining the relaxation are exactly the right pattern. No change.

### 9. `wg_ip` in template -- document as required
`wg_ip` comes from host_vars. The role doesn't work without it. Add a comment in defaults documenting this requirement.

## Proposed defaults/main.yml

```yaml
---
# roles/node-exporter/defaults/main.yml

# Version -- change to upgrade. Re-download triggered by version in path.
node_exporter_version: "1.8.1"

# Port to listen on
node_exporter_port: 9100

# Binary location
node_exporter_bin: "/usr/local/bin/node_exporter"

# User (underscore, not hyphen -- POSIX convention)
node_exporter_user: "node_exporter"

# Required: wg_ip must be set in host_vars. The service binds to the
# WireGuard IP only -- no public exposure.
```

## Proposed handlers/main.yml

```yaml
---
# roles/node-exporter/handlers/main.yml

- name: restart node_exporter
  service:
    name: node_exporter
    state: restarted
    daemon_reload: true
```

## Proposed tasks/main.yml

```yaml
---
# roles/node-exporter/tasks/main.yml
# Installs node_exporter as a systemd service on each host.
# Listens on the host's WireGuard IP only -- no public exposure.
# Prometheus on the monitoring host scrapes these endpoints over the mesh.

# -- Create user --
- name: Create node_exporter user
  user:
    name: "{{ node_exporter_user }}"
    system: true
    create_home: false
    shell: /sbin/nologin

# -- Download and install binary --
- name: Download and extract node_exporter
  unarchive:
    src: "https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}/node_exporter-{{ node_exporter_version }}.linux-amd64.tar.gz"
    dest: /tmp
    remote_src: true
    creates: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64/node_exporter"
  register: node_exporter_download

- name: Install node_exporter binary
  copy:
    src: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64/node_exporter"
    dest: "{{ node_exporter_bin }}"
    remote_src: true
    owner: root
    group: root
    mode: '0755'
  when: node_exporter_download.changed

- name: Clean up extracted files
  file:
    path: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64"
    state: absent
  when: node_exporter_download.changed

# -- Configure systemd service --
- name: Deploy node_exporter systemd service
  template:
    src: node_exporter.service.j2
    dest: /etc/systemd/system/node_exporter.service
    owner: root
    group: root
    mode: '0644'
  notify: restart node_exporter

# -- Enable and start --
- name: Enable and start node_exporter
  service:
    name: node_exporter
    state: started
    enabled: true
```

## Proposed node_exporter.service.j2 (unchanged except username)

```jinja2
# {{ ansible_managed }}
# node_exporter.service -- Prometheus host metrics exporter
# Listens on WireGuard IP only -- scraped by Prometheus over the mesh.

[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{ node_exporter_user }}
Group={{ node_exporter_user }}
ExecStart={{ node_exporter_bin }} \
    --web.listen-address={{ wg_ip }}:{{ node_exporter_port }}

Restart=on-failure
RestartSec=5

# Hardening (relaxed for node_exporter -- needs to read /proc, /sys, filesystems)
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
ProtectKernelModules=true
ProtectKernelTunables=true

[Install]
WantedBy=multi-user.target
```

## No new emerging guidelines
This role is clean. The fixes are mechanical applications of existing guidelines:
- Remove dead variables (safe defaults guideline)
- Remove standalone systemd reload (idempotent command tasks guideline)
- Use specialized modules over command/shell (unarchive vs tar)
- POSIX naming conventions