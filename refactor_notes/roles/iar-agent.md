# Refactor Notes: roles/iar-agent/

## Files reviewed
- `tasks/main.yml` (90 lines)
- `defaults/main.yml` (30 lines)
- `handlers/main.yml` (4 lines)
- `templates/iar-agent.service.j2` (20 lines)
- `templates/iar-agent.timer.j2` (9 lines)
- `templates/telegram.sh.j2` (25 lines)

## Decisions

### 1. Replace `local_ssh_user | default('nacho')` with `ansible_user` (12 occurrences)
All 12 references to `local_ssh_user | default('nacho')` in tasks and templates change to `ansible_user`. The `| default('nacho')` fallback is removed -- `ansible_user` is always defined by inventory.

### 2. Derive repo paths from `ansible_user`
Replace hardcoded `/home/nacho/repos/...` with paths derived from `ansible_user`:

```yaml
iar_repos_base: "/home/{{ ansible_user }}/repos"
iar_repo_dir: "{{ iar_repos_base }}/i.ar"
iar_personalization_dir: "{{ iar_repos_base }}/iar-personalization"
iar_gptel_fork_dir: "{{ iar_repos_base }}/gptel"
```

Note: `~` expansion does not work in systemd templates or Ansible file paths. Use explicit `/home/{{ ansible_user }}` construction. On Silverblue hosts with `/var/home`, override `iar_repos_base` in host_vars.

### 3. Fix `state: touch` on cycle.log with `copy` + `force: false`
Replace `file: state: touch` (always reports changed) with:
```yaml
- name: Ensure cycle.log exists
  copy:
    content: ""
    dest: "{{ iar_personalization_dir }}/audit/{{ item.name }}/cycle.log"
    force: false
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0644'
  loop: "{{ iar_agents }}"
```

`copy` with `force: false` only creates the file if it doesn't exist. Idempotent.

### 4. Remove standalone `Reload systemd daemon` task
Convert to a handler notified by the service/timer template tasks. Or add `daemon_reload: true` to the timer enable task. The handler approach:

```yaml
# handlers/main.yml
- name: reload systemd
  systemd:
    daemon_reload: true
```

Service and timer template tasks notify `reload systemd`. The enable/start task runs after handlers flush.

### 5. `iar.sh` is correct -- no change
The script was previously named `emacboros.sh` but has been unified and renamed to `iar.sh`. The references in tasks and the service template are correct.

### 6. Guard debug task with verbosity
```yaml
- name: Debug image check result
  debug:
    msg: "Image exists check: rc={{ iar_image_check.rc }}, will build={{ iar_image_check.rc != 0 }}"
  when: ansible_verbosity >= 2
```

Only shows in verbose mode (`-v` or higher).

### 7. Add explicit `changed_when: true` to build task
The build task runs `command` which defaults to `changed_when: true`. Add it explicitly for clarity:
```yaml
- name: Build i.ar container image
  command: >
    /bin/bash {{ iar_repo_dir }}/containers/build.sh
  become_user: "{{ ansible_user }}"
  when: iar_image_check.rc != 0
  changed_when: true
```

### 8. Telegram credentials -- blank defaults, real values in vault
```yaml
iar_telegram_bot_token: ""
iar_telegram_chat_id: ""
```

Add to vault.yml.template:
```yaml
# -- i.ar agent Telegram notifications --
iar_telegram_bot_token: "BOT_TOKEN_HERE"
iar_telegram_chat_id: "CHAT_ID_HERE"
```

### 9. `iar_ollama_host` -- blank default, required per-host
```yaml
iar_ollama_host: ""
```

Forces explicit configuration in host_vars. Blank = fail closed (agent can't connect to Ollama).

### 10. `iar_model` and `iar_ctx` -- blank defaults, required per-host
```yaml
iar_model: ""
iar_ctx: ""
```

Per-host variables should not have defaults. If a variable is genuinely per-host (different RAM = different model/ctx), it must be explicitly set in host_vars. Blank = fail closed.

### 11. `iar_container_image: "iar-emacboros"` -- constant, no change
This is the image name built by `build.sh`. Not a variable that needs overriding.

### 12. `iar_agents` default -- reasonable, no change
Default has one agent (librarian). Host_vars override with the full list.

### 13. Stale comment: "Runs on: sophon" -- remove
Per comments guideline. Playbook targeting shows this.

## Proposed defaults/main.yml

```yaml
---
# roles/iar-agent/defaults/main.yml

# -- Repository paths --
# Derived from ansible_user. Override iar_repos_base for Silverblue (/var/home).
# Must be absolute paths -- systemd does not expand ~user/.
iar_repos_base: "/home/{{ ansible_user }}/repos"
iar_repo_dir: "{{ iar_repos_base }}/i.ar"
iar_personalization_dir: "{{ iar_repos_base }}/iar-personalization"
iar_gptel_fork_dir: "{{ iar_repos_base }}/gptel"

# -- Git remotes --
iar_repo_remote: "git@github.com:emacboros/i.ar.git"
iar_personalization_remote: "git@github.com:emacboros/iar-personalization.git"
iar_gptel_fork_remote: "https://github.com/randazzo-ignacio/gptel.git"

# -- Ollama connection (REQUIRED per-host, no default) --
iar_ollama_host: ""
iar_model: ""
iar_ctx: ""

# -- Agent configuration --
iar_agents:
  - name: librarian
    interval: "30min"
    timeout: 3600

# -- Telegram notifications (REQUIRED, set in vault) --
iar_telegram_bot_token: ""
iar_telegram_chat_id: ""

# -- Container image --
iar_container_image: "iar-emacboros"
```

## Proposed tasks/main.yml (structure)

```yaml
---
# roles/iar-agent/tasks/main.yml
# Deploys i.ar agent infrastructure: repos, container image, systemd timers.
# Prerequisites: podman role must run first.

# -- 1. Repository setup --
- name: Create repos directory
  file:
    path: "{{ iar_repos_base }}"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0755'

- name: Clone i.ar repository
  git:
    repo: "{{ iar_repo_remote }}"
    dest: "{{ iar_repo_dir }}"
    version: main
    accept_hostkey: true
  become_user: "{{ ansible_user }}"
  register: iar_repo_clone

- name: Clone iar-personalization repository
  git:
    repo: "{{ iar_personalization_remote }}"
    dest: "{{ iar_personalization_dir }}"
    version: main
    accept_hostkey: true
  become_user: "{{ ansible_user }}"
  register: iar_personalization_clone

- name: Clone gptel fork repository
  git:
    repo: "{{ iar_gptel_fork_remote }}"
    dest: "{{ iar_gptel_fork_dir }}"
  become_user: "{{ ansible_user }}"
  register: iar_gptel_clone

- name: Ensure iar.sh is executable
  file:
    path: "{{ iar_repo_dir }}/utils/iar.sh"
    mode: '0755'

- name: Deploy telegram.sh with credentials
  template:
    src: telegram.sh.j2
    dest: "{{ iar_repo_dir }}/utils/telegram.sh"
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0644'

# -- 2. Personalization directory structure --
- name: Ensure personalization subdirectories exist
  file:
    path: "{{ iar_personalization_dir }}/{{ item }}"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0755'
  loop:
    - knowledge
    - tasks
    - audit

- name: Ensure per-agent audit directories exist
  file:
    path: "{{ iar_personalization_dir }}/audit/{{ item.name }}"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0755'
  loop: "{{ iar_agents }}"

- name: Ensure cycle.log exists
  copy:
    content: ""
    dest: "{{ iar_personalization_dir }}/audit/{{ item.name }}/cycle.log"
    force: false
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0644'
  loop: "{{ iar_agents }}"

- name: Ensure per-agent task directories exist
  file:
    path: "{{ iar_personalization_dir }}/tasks/{{ item.name }}"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0755'
  loop: "{{ iar_agents }}"

# -- 3. Container image build --
- name: Check if i.ar container image exists
  command: podman image exists {{ iar_container_image }}
  become_user: "{{ ansible_user }}"
  register: iar_image_check
  changed_when: false
  failed_when: false

- name: Debug image check result
  debug:
    msg: "Image exists check: rc={{ iar_image_check.rc }}, will build={{ iar_image_check.rc != 0 }}"
  when: ansible_verbosity >= 2

- name: Ensure build.sh is executable
  file:
    path: "{{ iar_repo_dir }}/containers/build.sh"
    mode: '0755'

- name: Build i.ar container image
  command: >
    /bin/bash {{ iar_repo_dir }}/containers/build.sh
  become_user: "{{ ansible_user }}"
  when: iar_image_check.rc != 0
  changed_when: true

# -- 4. Systemd timers for agents --
- name: Create systemd service units for agents
  template:
    src: iar-agent.service.j2
    dest: "/etc/systemd/system/iar-{{ item.name }}.service"
    owner: root
    group: root
    mode: '0644'
  loop: "{{ iar_agents }}"
  notify: reload systemd

- name: Create systemd timer units for agents
  template:
    src: iar-agent.timer.j2
    dest: "/etc/systemd/system/iar-{{ item.name }}.timer"
    owner: root
    group: root
    mode: '0644'
  loop: "{{ iar_agents }}"
  notify: reload systemd

- name: Enable and start agent timers
  systemd:
    name: "iar-{{ item.name }}.timer"
    state: started
    enabled: true
  loop: "{{ iar_agents }}"
```

## Proposed handlers/main.yml

```yaml
---
# roles/iar-agent/handlers/main.yml

- name: reload systemd
  systemd:
    daemon_reload: true
```

## Proposed iar-agent.service.j2

```jinja2
# {{ ansible_managed }}
[Unit]
Description=i.ar {{ item.name }} agent
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User={{ ansible_user }}
ExecStart=/bin/bash {{ iar_repo_dir }}/utils/iar.sh --loop \
  --personalization {{ iar_personalization_dir }} \
  --agent {{ item.name }} \
  --max-cycles 1 \
  --knowledge iar/ \
  --ollama-host {{ iar_ollama_host }} \
  --model {{ iar_model }} \
  --ctx {{ iar_ctx }} \
  --gptel-fork {{ iar_gptel_fork_dir }}
WorkingDirectory={{ iar_repo_dir }}
TimeoutStartSec={{ item.timeout | default(3600) }}

[Install]
WantedBy=multi-user.target
```

## Emerging Guidelines

### Guideline: No Defaults for Per-Host Variables
Variables that are genuinely per-host (different value on each host by nature) must not have defaults. They must be blank in role defaults and required in host_vars. A default creates a false sense of "it works without configuration" when the default is wrong for most hosts.

Evidence: `iar_ollama_host`, `iar_model`, `iar_ctx` have defaults that are correct for sophon but wrong for any other host. A new host with `iar_agents_enabled: true` would silently use sophon's Ollama host and model, which may not exist or may not fit the host's resources. Blank defaults force explicit configuration.

### Guideline: Guard Debug Tasks with Verbosity
Debug tasks that exist for troubleshooting should be guarded with `when: ansible_verbosity >= 2` so they don't pollute normal output. They appear only when the operator runs with `-v` or higher.

Evidence: "Debug image check result" task runs every execution, showing internal state that's only useful during troubleshooting. In normal operation, it's noise.