# Refactor Notes: roles/podman/

## Files reviewed
- `tasks/main.yml` (18 lines)
- `defaults/main.yml` (3 lines)
- No handlers, no templates

## Decisions

### 1. `podman_enabled: false` -> `true`
Podman is always-on. Default to `true`. Hosts can override to `false` if ever needed. Remove `podman_enabled` guards from all playbook invocations (already covered in playbook notes).

### 2. EPEL guard: OS-based, not group-based
Replace `when: "'cloud' in group_names"` with `when: ansible_distribution != "Fedora"`. The actual requirement is "does this OS need EPEL?" not "is this host in the cloud group?". AlmaLinux needs EPEL, Fedora doesn't. OS-based check expresses the real requirement without coupling to inventory groups.

### 3. Comments should add context, not repeat code
Remove the "Used on: greenday, sophon" comment. It repeats what the playbook targeting already says and will go stale. Comments should provide context that isn't visible from the code -- like "nvidia role must run before ollama/frigate" or "dnf-automatic requires dnf, skipped on Silverblue hosts".

### 4. `become: true` at play level
No task-level changes needed. Play-level `become: true` handles root.

### 5. Tags at playbook level
Role invocations get tagged `[podman]` in playbooks. No role-level changes.

### 6. Switch to `podman compose` (built-in subcommand)
Replace `podman-compose` package with the built-in `podman compose` subcommand (available in podman 4.7+). Fedora 44 and AlmaLinux 10 ship podman new enough. Remove `podman-compose` from the dnf install list. Any role that calls `podman-compose` (monitoring, frigate) must be updated to use `podman compose` instead.

## Proposed defaults/main.yml

```yaml
---
# roles/podman/defaults/main.yml

podman_enabled: true
```

## Proposed tasks/main.yml

```yaml
---
# roles/podman/tasks/main.yml
# Installs Podman on all hosts. EPEL required for non-Fedora RHEL family.

- name: Install EPEL (non-Fedora only)
  dnf:
    name: epel-release
    state: present
  when: ansible_distribution != "Fedora"

- name: Install Podman
  dnf:
    name: podman
    state: present

- name: Enable and start Podman
  service:
    name: podman
    state: started
    enabled: true
```

## Emerging Guideline: Comments Add Context, Not Redundancy

Comments should explain WHY, not WHAT. Don't repeat what the code already says. Don't list which hosts a role runs on (the playbook shows that). Don't describe what a task does (the task name says that). Comments are for:
- Ordering constraints ("nvidia must run before ollama")
- Non-obvious decisions ("dnf-automatic skipped on Silverblue via manage_packages")
- External references ("Fedora 44 removed dnf config-manager, see ollama role")
- Gotchas ("OLLAMA_VERSION must be empty, not 'latest' -- causes 404")

Evidence: podman role comment "Used on: greenday (AI playground), sophon (local, Frigate + Ollama GPU)" is stale after the always-on decision and repeats what the playbook targeting already shows. The ollama role's comment about OLLAMA_VERSION is a good example of a useful comment -- it explains a non-obvious gotcha that can't be derived from the code.

## Impact on other roles

The `podman compose` switch affects:
- `roles/monitoring/tasks/main.yml`: `podman-compose -f ... up -d` -> `podman compose -f ... up -d`
- `roles/frigate/`: systemd service and docker-compose.yml references
- Any other role that calls `podman-compose`

These will be noted when we read those roles.