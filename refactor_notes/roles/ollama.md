# Refactor Notes: roles/ollama/

## Files reviewed
- `tasks/main.yml` (88 lines)
- `defaults/main.yml` (12 lines)
- `handlers/main.yml` (5 lines)
- `templates/ollama.service.j2` (17 lines)

## Decisions

### 1. Wrap 7 tasks in `block:` with single `when`
Replace 7 repeated `when: > not (ollama_gpu | bool) or (ollama_nvidia_check.rc | default(0)) == 0` with a single block:

```yaml
- name: Install and configure Ollama (when GPU ready or CPU-only)
  block:
    - name: Download and install Ollama
      # ...
    - name: Create systemd override directory
      # ...
    - name: Create Ollama systemd service
      # ...
    - name: Create Ollama environment override
      # ...
    - name: Enable and start Ollama
      # ...
    - name: Pull Ollama models
      # ...
  when: >
    not (ollama_gpu | bool)
    or (ollama_nvidia_check.rc | default(0)) == 0
```

The nvidia-smi check and the "skip" debug message stay outside the block.

### 2. `ollama_listen: ""` in defaults (fail closed)
Change from `"0.0.0.0"` to empty string. Force explicit configuration in host_vars. A missing override causes a clear failure (Ollama can't bind), not a silent security hole.

### 3. Template owns everything -- remove environment override file
The `ollama.service.j2` template already sets all three Environment variables. The override file is redundant. Remove:
- The "Create Ollama environment override" task
- The override file at `/etc/systemd/system/ollama.service.d/override.conf`

The template is the single source of truth for the service file. Changes to `OLLAMA_HOST`, `OLLAMA_MODELS`, or `OLLAMA_KEEP_ALIVE` are made in the template via variables, and `notify: restart ollama` handles the restart.

### 4. Document `ollama_keepalive: "-1"`
Add comment explaining: `-1` means models never unload from memory. Good for dedicated Ollama hosts, surprising on shared hosts.

### 5. Remove standalone `Reload systemd` task
The task runs every role execution even if no service file changed. The `restart ollama` handler already has `daemon_reload: true`, which handles the reload. Remove the standalone task entirely.

### 6. Model pull: check `ollama list` before pulling
Replace `changed_when: false` with a pre-check:

```yaml
- name: List installed Ollama models
  command: "{{ ollama_install_dir }}/ollama list"
  become: true
  become_user: "{{ ollama_user }}"
  environment:
    OLLAMA_HOST: "{{ ollama_listen }}:{{ ollama_port }}"
    OLLAMA_MODELS: "{{ ollama_models_dir }}"
  register: ollama_installed_models
  changed_when: false

- name: Pull Ollama models
  command: "{{ ollama_install_dir }}/ollama pull {{ item }}"
  become: true
  become_user: "{{ ollama_user }}"
  environment:
    OLLAMA_HOST: "{{ ollama_listen }}:{{ ollama_port }}"
    OLLAMA_MODELS: "{{ ollama_models_dir }}"
  loop: "{{ ollama_models }}"
  when: item not in ollama_installed_models.stdout
  async: 600
  poll: 5
```

This only pulls models that aren't already installed. Reports "changed" when a model is actually pulled.

### 7. `ollama_version: ""` comment -- keep
The comment about empty string vs "latest" causing 404 is exactly the kind of comment our guideline calls for. No change.

### 8. `ollama_gpu: false` -- correct safe default
No change.

### 9. Replace `creates` with version-check idempotency
The `creates: "{{ ollama_install_dir }}/ollama"` guard means the only way to upgrade is to delete the binary. Replace with a version check:

```yaml
- name: Check installed Ollama version
  command: "{{ ollama_install_dir }}/ollama --version"
  register: ollama_installed_version
  changed_when: false
  failed_when: false

- name: Download and install Ollama
  shell: |
    curl -fsSL https://ollama.com/install.sh | sh
  environment:
    OLLAMA_VERSION: "{{ ollama_version | default('') }}"
  when: ollama_installed_version.failed or ollama_needs_upgrade | default(false)
```

For the upgrade check: compare installed version against desired version. If `ollama_version` is empty (latest), we can't know if an upgrade is needed without checking. Options:
- Add an `ollama_upgrade` flag (default `false`) that forces reinstall when set to `true`
- Or check the latest version against installed version via an API call (over-engineered)

Pragmatic approach: use `ollama_upgrade: false` as a variable. When the operator wants to upgrade, they set `ollama_upgrade: true` in host_vars or pass `--extra-vars ollama_upgrade=true` on the CLI. The install task runs when: binary doesn't exist OR `ollama_upgrade` is true.

```yaml
- name: Check if Ollama is installed
  stat:
    path: "{{ ollama_install_dir }}/ollama"
  register: ollama_binary

- name: Download and install Ollama
  shell: |
    curl -fsSL https://ollama.com/install.sh | sh
  environment:
    OLLAMA_VERSION: "{{ ollama_version | default('') }}"
  when: >
    not ollama_binary.stat.exists
    or ollama_upgrade | default(false) | bool
```

After install, reset `ollama_upgrade` to false (or just let it be -- it's a run-time flag, not persistent).

### 10. `poll: 30` -> `poll: 5` on model pull
More responsive polling. If a model pull finishes in 5 seconds, Ansible notices in 5 seconds instead of 30.

### 11. Remove stale "Runs on" comment
Per comments guideline. Playbook targeting shows this.

### 12. `become` on model pull -- correct
The model pull explicitly uses `become_user: "{{ ollama_user }}"`. This is correct -- models should be owned by the ollama user. No change.

## Proposed defaults/main.yml

```yaml
---
# roles/ollama/defaults/main.yml

# Ollama version: empty string = latest release. Do NOT set to "latest" --
# the install script treats it as a literal version tag and will 404.
ollama_version: ""

# Set ollama_upgrade: true to force reinstall (upgrade). Default: false.
# Pass as --extra-vars ollama_upgrade=true or set in host_vars.
ollama_upgrade: false

ollama_port: 11434
ollama_install_dir: "/usr/local/bin"
ollama_models_dir: "/usr/share/ollama"
ollama_user: ollama

# Listen address: MUST be set in host_vars. Empty = fail closed (not 0.0.0.0).
ollama_listen: ""

ollama_gpu: false
ollama_models: []

# -1 = never unload models from memory. Good for dedicated Ollama hosts.
ollama_keepalive: "-1"
```

## Proposed tasks/main.yml (structure)

```yaml
---
# roles/ollama/tasks/main.yml
# Installs Ollama and pulls specified models.
# NVIDIA driver installation is handled by the nvidia role -- must run first on GPU hosts.

# -- Create ollama user --
- name: Create ollama user
  user:
    name: "{{ ollama_user }}"
    system: true
    create_home: false
    shell: /sbin/nologin

# -- Create models directory --
- name: Create models directory
  file:
    path: "{{ ollama_models_dir }}"
    state: directory
    owner: "{{ ollama_user }}"
    group: "{{ ollama_user }}"
    mode: '0755'

# -- Pre-flight: check NVIDIA GPU status (GPU hosts only) --
- name: Check if nvidia-smi is available (GPU hosts)
  command: nvidia-smi --query-gpu=name --format=csv,noheader
  register: ollama_nvidia_check
  changed_when: false
  failed_when: false
  when: ollama_gpu | bool

- name: Skip Ollama install until NVIDIA driver is loaded
  debug:
    msg: |
      ============================================================
      NVIDIA driver installed but not yet loaded (needs reboot).
      Skipping Ollama install. Reboot and re-run the playbook.
      ============================================================
  when:
    - ollama_gpu | bool
    - ollama_nvidia_check.rc | default(0) != 0

# -- Install and configure Ollama (when GPU ready or CPU-only) --
- name: Install and configure Ollama
  block:
    - name: Check if Ollama is installed
      stat:
        path: "{{ ollama_install_dir }}/ollama"
      register: ollama_binary

    - name: Download and install Ollama
      shell: |
        curl -fsSL https://ollama.com/install.sh | sh
      environment:
        OLLAMA_VERSION: "{{ ollama_version | default('') }}"
      when: >
        not ollama_binary.stat.exists
        or ollama_upgrade | default(false) | bool

    - name: Create Ollama systemd service
      template:
        src: ollama.service.j2
        dest: /etc/systemd/system/ollama.service
        owner: root
        group: root
        mode: '0644'
      notify: restart ollama

    - name: Enable and start Ollama
      service:
        name: ollama
        state: started
        enabled: true

    - name: List installed Ollama models
      command: "{{ ollama_install_dir }}/ollama list"
      become: true
      become_user: "{{ ollama_user }}"
      environment:
        OLLAMA_HOST: "{{ ollama_listen }}:{{ ollama_port }}"
        OLLAMA_MODELS: "{{ ollama_models_dir }}"
      register: ollama_installed_models
      changed_when: false

    - name: Pull Ollama models
      command: "{{ ollama_install_dir }}/ollama pull {{ item }}"
      become: true
      become_user: "{{ ollama_user }}"
      environment:
        OLLAMA_HOST: "{{ ollama_listen }}:{{ ollama_port }}"
        OLLAMA_MODELS: "{{ ollama_models_dir }}"
      loop: "{{ ollama_models }}"
      when: item not in ollama_installed_models.stdout
      async: 600
      poll: 5
  when: >
    not (ollama_gpu | bool)
    or (ollama_nvidia_check.rc | default(0)) == 0
```

## Proposed ollama.service.j2 (unchanged)

```jinja2
# {{ ansible_managed }}
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
Type=simple
User={{ ollama_user }}
ExecStart={{ ollama_install_dir }}/ollama serve
Restart=always
RestartSec=3
Environment="OLLAMA_HOST={{ ollama_listen }}:{{ ollama_port }}"
Environment="OLLAMA_MODELS={{ ollama_models_dir }}"
Environment="OLLAMA_KEEP_ALIVE={{ ollama_keepalive }}"

[Install]
WantedBy=multi-user.target
```

Note: the systemd override directory and override file are removed. Template owns everything.

## Emerging Guidelines

### Guideline: Block for Repeated Conditions
When multiple consecutive tasks share the same `when` condition, wrap them in a `block:` with the condition on the block. One change, one place.

Evidence: 7 tasks in the ollama role each carry `when: > not (ollama_gpu | bool) or (ollama_nvidia_check.rc | default(0)) == 0`. If the condition changes, 7 tasks must be updated. A block makes it 1.

### Guideline: Upgrade-Friendly Idempotency
Idempotency guards that prevent upgrades (like `creates:` on an install task) should be paired with an explicit upgrade mechanism. A `*_upgrade: false` variable lets the operator force a reinstall without removing the guard.

Evidence: `creates: "{{ ollama_install_dir }}/ollama"` means Ollama never upgrades unless the binary is manually deleted. Adding `ollama_upgrade: false` (set to `true` to force upgrade) gives Ansible control over upgrades without sacrificing idempotency.