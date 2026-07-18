# Refactor Notes: roles/ai-environment/

## Files reviewed
- `tasks/main.yml` (55 lines)
- `defaults/main.yml` (4 lines)
- No handlers, no templates

## Decisions

### 1. Remove "Ensure Podman is enabled" task
Podman role owns this. After "podman always-on" decision, podman runs on all hosts before ai-environment. Duplicated work. Remove.

### 2. `ai_agent_ssh_public_key` -- blank default, real value in vault
Change placeholder to empty string. Real key in vault. Blank = fail closed (authorized_key task fails or adds nothing if key is empty). Add to vault.yml.template.

### 3. Add `ai_agent_user` variable, replace all hardcoded `ai-agent` references
8 hardcoded references to `ai-agent` in tasks. Add `ai_agent_user: "ai-agent"` to defaults. All tasks, file paths, and content reference the variable.

### 4. Resource limits as template with variables
Convert the inline `copy` content to a template file with variables for limits:

```yaml
ai_agent_soft_nproc: 500
ai_agent_hard_nproc: 1000
ai_agent_soft_fsize: 10485760    # 10MB
ai_agent_hard_fsize: 52428800   # 50GB
```

Template `limits.conf.j2`:
```jinja2
{{ ai_agent_user }} soft nproc {{ ai_agent_soft_nproc }}
{{ ai_agent_user }} hard nproc {{ ai_agent_hard_nproc }}
{{ ai_agent_user }} soft fsize {{ ai_agent_soft_fsize }}
{{ ai_agent_user }} hard fsize {{ ai_agent_hard_fsize }}
```

### 5. tmux config and bash profile as templates
Convert inline `copy` content to template files. Use `{{ ai_agent_user }}` for ownership. Content is static configuration but templates allow variable substitution for paths.

### 6. Remove stale comments
- "Sets up the AI playground VPS (ob-ar)" -- `ob-ar` is old domain, now `0b.ar`. Remove.
- "All servers run Fedora Server 44 or AlmaLinux 10" -- redundant per comments guideline.

### 7. Derive home directory path, handle /var/home on immutable distros
Some distros (Fedora Silverblue) use `/var/home` instead of `/home`. The `~` expansion or `{{ ai_agent_user }}` home path should be derived, not hardcoded.

However, `~` expansion inside templates (especially systemd units) can fail because systemd doesn't expand `~` the same way shells do. The safe approach:
- Use `{{ ansible_user_dir }}` or a custom variable for the home path when inside templates
- Or use the `user` module's `home` parameter and register it

Pragmatic approach for this role: the AI agent user is created with `create_home: true`, so the home directory is `/home/ai-agent` on standard distros. For immutable distros, the operator can override `ai_agent_home` in host_vars.

```yaml
# defaults
ai_agent_home: "/home/{{ ai_agent_user }}"
```

All paths derive from `ai_agent_home`:
```yaml
loop:
  - "{{ ai_agent_home }}/workspace"
  - "{{ ai_agent_home }}/workspace/projects"
  - ...
```

### 8. `create_home: true` -- correct, no change
The AI agent needs a home directory for workspace, tmux config, bashrc.

### 9. `become: true` at play level
No task-level changes needed.

### 10. SSH key comment -- use variable or remove
Remove the hardcoded `comment: "ai-agent-ed25519"`. The key itself carries its own comment. No need to override.

## Proposed defaults/main.yml

```yaml
---
# roles/ai-environment/defaults/main.yml

# AI agent user
ai_agent_user: "ai-agent"
ai_agent_home: "/home/{{ ai_agent_user }}"

# SSH public key -- MUST be set in vault. Blank = fail closed.
ai_agent_ssh_public_key: ""

# Resource limits
ai_agent_soft_nproc: 500
ai_agent_hard_nproc: 1000
ai_agent_soft_fsize: 10485760    # 10MB
ai_agent_hard_fsize: 52428800    # 50GB
```

## Proposed tasks/main.yml

```yaml
---
# roles/ai-environment/tasks/main.yml
# Sets up the AI agent user, workspace, and resource limits.

# -- Create AI agent user --
- name: Create AI agent user
  user:
    name: "{{ ai_agent_user }}"
    shell: /bin/bash
    create_home: true

# -- Deploy SSH key --
- name: Add AI agent SSH key
  authorized_key:
    user: "{{ ai_agent_user }}"
    key: "{{ ai_agent_ssh_public_key }}"

# -- Working directories --
- name: Create AI working directories
  file:
    path: "{{ item }}"
    state: directory
    owner: "{{ ai_agent_user }}"
    group: "{{ ai_agent_user }}"
    mode: '0755'
  loop:
    - "{{ ai_agent_home }}/workspace"
    - "{{ ai_agent_home }}/workspace/projects"
    - "{{ ai_agent_home }}/workspace/containers"
    - "{{ ai_agent_home }}/workspace/scripts"
    - "{{ ai_agent_home }}/workspace/data"

# -- Resource limits --
- name: Set process limits for AI agent
  template:
    src: limits.conf.j2
    dest: "/etc/security/limits.d/{{ ai_agent_user }}.conf"
    owner: root
    group: root
    mode: '0644'

# -- tmux config --
- name: Create tmux config for AI agent
  template:
    src: tmux.conf.j2
    dest: "{{ ai_agent_home }}/.tmux.conf"
    owner: "{{ ai_agent_user }}"
    group: "{{ ai_agent_user }}"
    mode: '0644'

# -- Bash profile --
- name: Configure bash profile for AI agent
  template:
    src: bashrc.j2
    dest: "{{ ai_agent_home }}/.bashrc"
    owner: "{{ ai_agent_user }}"
    group: "{{ ai_agent_user }}"
    mode: '0644'
```

## Proposed templates

### templates/limits.conf.j2
```jinja2
# {{ ansible_managed }}
{{ ai_agent_user }} soft nproc {{ ai_agent_soft_nproc }}
{{ ai_agent_user }} hard nproc {{ ai_agent_hard_nproc }}
{{ ai_agent_user }} soft fsize {{ ai_agent_soft_fsize }}
{{ ai_agent_user }} hard fsize {{ ai_agent_hard_fsize }}
```

### templates/tmux.conf.j2
```jinja2
# {{ ansible_managed }}
set -g mouse on
set -g history-limit 50000
set -g default-terminal "screen-256color"
setw -g mode-keys vi
set -g status-interval 5
set -g status-left '[#S] '
set -g status-right '%Y-%m-%d %H:%M'
```

### templates/bashrc.j2
```jinja2
# {{ ansible_managed }}
export PS1='\u@\h:\w\$ '
export PATH="$HOME/workspace/scripts:$PATH"
export EDITOR=vim
alias ll='ls -alF'
```

Note: `bashrc.j2` uses `$HOME` which the shell expands at login. This is correct -- `$HOME` is a shell variable, not an Ansible variable. The `\\u`, `\\h`, `\\w` in the original were double-escaped for the YAML string. In a template file, single backslash is correct.

## Emerging Guidelines

### Guideline: Derive Home Directory Paths
Home directory paths should be derived from a variable, not hardcoded as `/home/username`. Some distros (Fedora Silverblue) use `/var/home` instead of `/home`. Define a `*_home` variable in role defaults that can be overridden per-host.

Evidence: All paths in ai-environment are hardcoded as `/home/ai-agent/...`. On an immutable distro with `/var/home`, these paths would be wrong. Defining `ai_agent_home: "/home/{{ ai_agent_user }}"` in defaults with override capability in host_vars handles both cases.

Note: `~` expansion is unreliable inside systemd templates and should be avoided. Use explicit path variables instead.