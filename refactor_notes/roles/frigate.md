# Refactor Notes: roles/frigate/

## Files reviewed
- `tasks/main.yml` (55 lines)
- `defaults/main.yml` (52 lines)
- `handlers/main.yml` (8 lines)
- `templates/config.yaml.j2` (45 lines)
- `templates/docker-compose.yml.j2` (25 lines)
- `templates/frigate.service.j2` (15 lines)

## Decisions

### 1. Remove stale comments
Remove "Target: sophon" and "Requires: nvidia role" from role comments. Targeting is in the playbook. Prerequisites are documented by playbook ordering (nvidia play runs before frigate).

### 2. Remove per-task `frigate_enabled | bool` guards (8 occurrences)
The playbook already guards with `when: frigate_enabled`. Per-task guards are redundant. Trust the playbook's `when`. If the role runs, it's enabled. Matches the nvidia role pattern.

### 3. Remove standalone `Reload systemd` task
The `restart frigate` handler already has `daemon_reload: true`. The standalone task runs every time and is redundant. Remove.

### 4. Switch to `podman compose` and rename compose template
- `frigate.service.j2`: `podman-compose up` -> `podman compose up`, `podman-compose down` -> `podman compose down`
- `docker-compose.yml.j2` -> rename to `compose.yml.j2` (podman compose convention)
- Update task that deploys the compose file to reference the new name

### 5. `frigate_rtsp_password: ""` in defaults -- remove (dead variable)
The template uses `frigate_camera_rtsp_user` and `frigate_camera_rtsp_password` (from vault). `frigate_rtsp_password` in defaults is a stale variable with no known purpose. Remove it.

### 6. `frigate_camera_rtsp_user` and `frigate_camera_rtsp_password` -- vault, correct
These are the per-camera RTSP credentials used in the go2rtc config. They come from vault. The template references are correct. No change needed.

### 7. Document `privileged: true` as known trade-off
Add a comment in `compose.yml.j2`:
```yaml
# privileged: true is required for TensorRT GPU access per Frigate docs.
# Future: check if specific device mappings + capabilities can replace this.
```

### 8. `frigate_media_dir` derived from `frigate_media_mount` -- correct
Follows the "derive, don't duplicate" guideline. No change.

### 9. Replace `local_ssh_user` with `ansible_user` throughout
`local_ssh_user` is used in frigate tasks and templates for file ownership and the systemd service user. In practice, `local_ssh_user` is always the same as `ansible_user` on local hosts (both are `nacho`). The variable is redundant -- replace all instances with `ansible_user`.

This eliminates a cross-role variable entirely. `local_ssh_user` can be removed from:
- `group_vars/all/main.yml` (where it currently lives)
- `group_vars/local.yml` (where we planned to move it)
- All roles that reference it (frigate, iar-agent, ai-environment)

Roles use `ansible_user` instead, which is always available from inventory.

### 10. Remove unused `restart podman` handler
Never notified by any task. Remove.

### 11. Document `frigate_webrtc_tcp_port` and `frigate_webrtc_udp_port`
Add comment: WebRTC uses TCP for signaling and UDP for media. They can be different ports but default to the same (8555).

### 12. go2rtc restream pattern -- correct, no change
The config uses `preset-rtsp-restream` for ffmpeg input and go2rtc for the actual RTSP source. Correct Frigate architecture.

## Proposed tasks/main.yml

```yaml
---
# roles/frigate/tasks/main.yml
# Deploys Frigate NVR with NVIDIA TensorRT on Podman.
# Prerequisites: nvidia role (drivers + toolkit) and podman role must run first.

# -- Verify prerequisites --
- name: Verify NVIDIA GPU is present
  command: nvidia-smi --query-gpu=name --format=csv,noheader
  register: nvidia_check
  changed_when: false
  failed_when: false

- name: Fail if no NVIDIA GPU detected
  fail:
    msg: |
      Frigate with TensorRT requires an NVIDIA GPU.
      nvidia-smi did not detect a GPU on this host.
      The nvidia role should have installed drivers -- a reboot
      may be required after the first run. Reboot and re-run.
  when:
    - "'stable-tensorrt' in frigate_image"
    - nvidia_check.rc != 0

# -- Create directory structure --
- name: Create Frigate directories
  file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "{{ item.mode | default('0755') }}"
  loop:
    - path: "{{ frigate_base_dir }}"
    - path: "{{ frigate_config_dir }}"
    - path: "{{ frigate_storage_dir }}"

- name: Ensure external media mount directory exists
  file:
    path: "{{ frigate_media_dir }}"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0755'

# -- Deploy configuration files --
- name: Deploy Frigate config.yaml
  template:
    src: config.yaml.j2
    dest: "{{ frigate_config_dir }}/config.yaml"
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0644'
  notify: restart frigate

- name: Deploy compose.yml
  template:
    src: compose.yml.j2
    dest: "{{ frigate_base_dir }}/compose.yml"
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0644'
  notify: restart frigate

# -- Create systemd service --
- name: Create Frigate systemd service
  template:
    src: frigate.service.j2
    dest: "/etc/systemd/system/{{ frigate_container_name }}.service"
    owner: root
    group: root
    mode: '0644'
  notify: restart frigate

- name: Enable and start Frigate
  service:
    name: "{{ frigate_container_name }}"
    state: started
    enabled: true
```

## Proposed handlers/main.yml

```yaml
---
# roles/frigate/handlers/main.yml

- name: restart frigate
  service:
    name: "{{ frigate_container_name }}"
    state: restarted
    daemon_reload: true
```

Note: `restart podman` handler removed (never notified).

## Proposed frigate.service.j2

```jinja2
# {{ ansible_managed }}
[Unit]
Description=Frigate NVR (Podman Compose)
After=network-online.target podman.service
Wants=network-online.target

[Service]
Type=simple
User={{ ansible_user }}
WorkingDirectory={{ frigate_base_dir }}
ExecStart=/usr/bin/podman compose up
ExecStop=/usr/bin/podman compose down
Restart=always
RestartSec=10
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
```

## Proposed compose.yml.j2 (renamed from docker-compose.yml.j2)

```jinja2
# {{ ansible_managed }}
# Frigate NVR -- compose.yml
# Do not edit manually; changes will be overwritten.

services:
  frigate:
    container_name: {{ frigate_container_name }}
    # privileged: true is required for TensorRT GPU access per Frigate docs.
    # Future: check if specific device mappings + capabilities can replace this.
    privileged: true
    restart: unless-stopped
    stop_grace_period: {{ frigate_stop_grace_period }}
    image: {{ frigate_image }}
    devices:
      - nvidia.com/gpu=all
    shm_size: "{{ frigate_shm_size }}"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - {{ frigate_config_dir }}:/config
      - {{ frigate_media_dir }}:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: {{ frigate_tmpfs_cache_size }}
    ports:
      - "{{ frigate_web_port }}:{{ frigate_web_port }}"
      - "{{ frigate_rtsp_port }}:{{ frigate_rtsp_port }}"
      - "{{ frigate_webrtc_tcp_port }}:{{ frigate_webrtc_tcp_port }}/tcp"
      - "{{ frigate_webrtc_udp_port }}:{{ frigate_webrtc_udp_port }}/udp"
    environment:
      FRIGATE_RTSP_PASSWORD: "{{ frigate_camera_rtsp_password }}"
```

Note: `FRIGATE_RTSP_PASSWORD` now uses `frigate_camera_rtsp_password` (from vault), not the stale `frigate_rtsp_password`.

## Proposed defaults/main.yml changes

- Remove `frigate_rtsp_password: ""` (dead variable)
- Add comment on `frigate_webrtc_tcp_port` and `frigate_webrtc_udp_port`: "WebRTC: TCP for signaling, UDP for media. Can differ but default to same port."
- All `local_ssh_user` references replaced with `ansible_user`

## Emerging Guidelines

### Guideline: Trust Playbook Guards
When a playbook guards a role with `when: <feature>_enabled`, the role's tasks should not repeat the same guard. The role runs only if enabled. Per-task guards are redundant noise.

Evidence: 8 tasks in frigate each carry `when: frigate_enabled | bool`. The playbook already has `when: frigate_enabled`. If the guard changes, 8 tasks must be updated. Trust the playbook.

### Guideline: Eliminate Redundant Variables
If two variables always have the same value, eliminate one. Use the more general one.

Evidence: `local_ssh_user` is always the same as `ansible_user` on local hosts. Two variables for the same value means two places to update. Replace `local_ssh_user` with `ansible_user` everywhere. Remove `local_ssh_user` from group_vars entirely.