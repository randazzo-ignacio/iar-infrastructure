# Refactor Notes: roles/base/

## Files reviewed
- `tasks/main.yml` (48 lines)
- `defaults/main.yml` (14 lines)
- `handlers/main.yml` (4 lines)
- `templates/sshd_config.j2` (20 lines)

## Issues found

### 1. SSH config double-managed (template + lineinfile)
The `sshd_config.j2` template already sets `PermitRootLogin {{ ssh_permit_root_login }}` and `PasswordAuthentication {{ ssh_password_auth }}`. Then two `lineinfile` tasks patch the same values on top. The lineinfile tasks are redundant -- they will always report "ok" (no change) because the template already wrote the correct values.

**Fix:** Delete the two lineinfile tasks. The template owns the full sshd_config.

### 2. WireGuard firewalld port opened in base role
Task "Allow WireGuard through firewalld" opens `{{ wg_port }}/udp`. This belongs in the wireguard role, not base. Base should only open SSH. The wireguard role already opens this port -- it's duplicated work.

**Fix:** Delete the WireGuard firewalld task from base.

### 3. `when: inventory_hostname != 'yoga'` -- hardcoded hostname exclusion
Appears 5 times: system update, essential packages, firewalld install, firewalld running, SSH through firewalld, dnf-automatic install, dnf-automatic timer. That's 7 tasks with the same hardcoded exclusion.

Per our decision: replace with `manage_packages: false` on yoga (covers dnf update, essential packages, dnf-automatic). Firewalld should still run on yoga -- only package operations are excluded.

Wait -- the firewalld tasks also have `!= 'yoga'`. But we decided firewalld runs on all hosts. So the firewalld tasks need the yoga exclusion removed, and only package-related tasks use `manage_packages`.

**Fix:**
- Package tasks (dnf update, install packages, dnf-automatic install, dnf-automatic timer): `when: manage_packages | default(true) | bool`
- Firewalld tasks: remove `!= 'yoga'` condition entirely. Firewalld runs on all hosts.

### 4. sysctl IP forwarding on all hosts
`net.ipv4.ip_forward` and `net.ipv4.conf.all.forwarding` are set to '1' on every host. Only the WG hub (rammstein) needs IP forwarding. Spokes don't route traffic.

**Fix:** Split sysctl settings into two groups:
- `base_sysctl_hardening` -- applied to all hosts (syncookies, rp_filter, redirects, dmesg, kptr)
- `base_sysctl_forwarding` -- applied to hub only (ip_forward, forwarding)

Or: move the forwarding sysctl to the wireguard role where it belongs (the wireguard role already sets ip_forward on hub). Remove forwarding from base entirely.

### 5. SSH defaults conflict between role defaults and group_vars
Role defaults: `ssh_permit_root_login: "no"`, `timezone: "UTC"`
Group_vars/all: `ssh_permit_root_login: "prohibit-password"`, `timezone: "America/Argentina/Buenos_Aires"`

Group_vars wins, but the discrepancy is confusing. Per our decision, role defaults are the authoritative source. Group_vars should not duplicate these.

**Fix:** Role defaults should have the correct values. Remove SSH and timezone from group_vars/all/main.yml (already covered in group_vars notes). Set role defaults to the actual desired values:
- `ssh_permit_root_login: "prohibit-password"` (not "no")
- `timezone: "America/Argentina/Buenos_Aires"` (not "UTC")

### 6. Admin user creation uses generic "admin" name
Tasks create a user named `admin` with SSH key from `~/.ssh/id_ed25519.pub`. Per our decision, each host has a unique admin username (e.g. `riemann` on rammstein). The user creation should use a per-host variable.

But wait -- the user creation is currently `when: "'cloud' in group_names"`. With per-host admin usernames, this needs to be per-host. The admin username should come from host_vars (where `ansible_user` is set).

**Fix:** Use a variable like `admin_user` (or reuse `ansible_user`) for the admin username. Each host_vars file sets this. The base role creates the user with that name.

Actually -- the user said these admin users are created manually during initial host setup. So the base role doesn't need to create them at all. The base role only needs to:
- Add the SSH key for the existing admin user
- Configure passwordless sudo for the existing admin user

**Fix:** Remove the user creation task. Keep the authorized_key and sudoers tasks. Use `ansible_user` (or a dedicated `admin_user` variable) for the username.

### 7. SSH key lookup uses local file path
`{{ lookup('file', '~/.ssh/id_ed25519.pub') }}` reads the SSH public key from the Ansible controller. This works but couples the role to the controller's filesystem. If someone else runs the playbook, they need the same key file. Consider putting the admin SSH public key in vault (like the ai_agent key).

**Fix:** Move admin SSH public key to vault. Reference it as `admin_ssh_public_key` variable.

### 8. No `become: true` on tasks
After ansible.cfg change to `become = False`, these tasks need `become: true`. Most tasks need root (dnf, sshd_config, firewalld, sysctl, user creation, sudoers). The play-level `become: true` in site.yml handles this, but the standalone base.yml playbook also needs it.

**Fix:** Add `become: true` at the play level in base.yml (already covered in playbook notes).

### 9. Comment says "Fedora Workstation 44" for local hosts
Sophon runs Fedora Workstation 44, but yoga runs Fedora Silverblue. The comment is inaccurate.

**Fix:** Update comment or remove it -- the role doesn't behave differently based on OS variant (except the `manage_packages` exclusion for yoga).

### 10. `ListenAddress 0.0.0.0` in sshd_config template
SSH listens on all interfaces. This is standard but worth noting: with firewalld controlling access, 0.0.0.0 is fine. If you ever want SSH to only listen on the WG interface, this would need to change. Not a bug, just a note.

### 11. No `manage_packages` default in role defaults
After adding the `manage_packages` variable, the role defaults should include `manage_packages: true` so hosts without explicit override get package management.

**Fix:** Add `manage_packages: true` to role defaults.

## Proposed tasks/main.yml

```yaml
---
# roles/base/tasks/main.yml
# Applied to every host -- hardening, packages, SSH, firewall, sysctl.
# Yoga (Fedora Silverblue) excludes package management via manage_packages: false.

# -- System update --
- name: Update all packages
  dnf:
    name: "*"
    state: latest
  when: manage_packages | default(true) | bool

# -- Essential packages --
- name: Install essential packages
  dnf:
    name: "{{ base_packages }}"
    state: present
  when: manage_packages | default(true) | bool

# -- Timezone --
- name: Set timezone
  timezone:
    name: "{{ timezone }}"

# -- SSH hardening --
- name: Configure sshd
  template:
    src: sshd_config.j2
    dest: /etc/ssh/sshd_config
    owner: root
    group: root
    mode: '0644'
    validate: 'sshd -t -f %s'
  notify: restart sshd

# -- Firewall (firewalld) --
- name: Ensure firewalld is installed
  dnf:
    name: firewalld
    state: present
  when: manage_packages | default(true) | bool

- name: Ensure firewalld is running
  service:
    name: firewalld
    state: started
    enabled: true

- name: Allow SSH through firewalld
  ansible.posix.firewalld:
    port: "{{ ssh_port }}/tcp"
    permanent: true
    state: enabled
    immediate: true

# -- Automatic security updates --
- name: Install dnf-automatic
  dnf:
    name: dnf-automatic
    state: present
  when: manage_packages | default(true) | bool

- name: Enable dnf-automatic timer
  service:
    name: dnf-automatic.timer
    state: started
    enabled: true
  when: manage_packages | default(true) | bool

# -- Sysctl hardening --
- name: Apply sysctl hardening
  sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    state: present
    reload: true
  loop: "{{ base_sysctl_settings }}"

# -- Admin user SSH key + sudo (cloud servers) --
- name: Add SSH key for admin user
  authorized_key:
    user: "{{ ansible_user }}"
    key: "{{ admin_ssh_public_key }}"
  when: "'cloud' in group_names"

- name: Allow admin passwordless sudo
  copy:
    dest: "/etc/sudoers.d/{{ ansible_user }}"
    content: "{{ ansible_user }} ALL=(ALL) NOPASSWD:ALL\n"
    mode: '0440'
  when: "'cloud' in group_names"
```

## Proposed defaults/main.yml

```yaml
---
# roles/base/defaults/main.yml

# -- SSH --
ssh_port: 22
ssh_password_auth: "no"
ssh_permit_root_login: "prohibit-password"

# -- Timezone --
timezone: "America/Argentina/Buenos_Aires"

# -- Package management --
manage_packages: true

# -- Sysctl hardening (all hosts) --
base_sysctl_settings:
  - { key: 'net.ipv4.conf.default.rp_filter', value: '1' }
  - { key: 'net.ipv4.tcp_syncookies', value: '1' }
  - { key: 'net.ipv4.conf.all.accept_redirects', value: '0' }
  - { key: 'net.ipv4.conf.all.send_redirects', value: '0' }
  - { key: 'net.ipv6.conf.all.accept_redirects', value: '0' }
  - { key: 'kernel.dmesg_restrict', value: '1' }
  - { key: 'kernel.kptr_restrict', value: '2' }
```

Note: `net.ipv4.ip_forward` and `net.ipv4.conf.all.forwarding` removed -- moved to wireguard role (hub only).

## Emerging Guidelines

### Guideline: Template Owns the File
When a template deploys a configuration file, no other task modifies that file. No `lineinfile` on top of a template-managed file. The template is the single source of truth for that file's content.

Evidence: sshd_config.j2 sets PasswordAuthentication and PermitRootLogin, then two lineinfile tasks patch the same values. Redundant and confusing -- if the template says X and lineinfile says Y, which wins?

### Guideline: Role Boundaries
A role manages its own concerns only. Base does hardening + packages + SSH + firewall basics. WireGuard port management belongs in the wireguard role. IP forwarding belongs in the wireguard role (it's needed for WG routing).

Evidence: base role opens WG firewalld port (wireguard role also does this). base role sets ip_forward sysctl (wireguard role also sets this on hub). Cross-role duplication.

### Guideline: No Hardcoded Hostnames
Use variables, not `inventory_hostname` comparisons. Hostnames in `when` conditions don't scale and are brittle.

Evidence: `when: inventory_hostname != 'yoga'` appears 7 times in this role. Adding another laptop means adding more exclusions. `manage_packages: false` on yoga is one variable, one place.

### Guideline: Admin SSH Key in Vault
SSH public keys for admin users belong in vault, not in `lookup('file', ...)` from the controller's filesystem. Decouples the role from the controller's SSH key setup.

Evidence: `lookup('file', '~/.ssh/id_ed25519.pub')` only works if the controller has that exact key file. Another operator running the playbook would need the same key.
## Resolved Questions

- **`ansible_user` is sufficient** -- it's the admin user. No separate `admin_user` variable needed. On cloud hosts, `ansible_user` is the per-host admin name (e.g. `riemann`). On local hosts, it's `nacho`.
- **Admin user creation, SSH key, and sudoers are NOT Ansible's job** -- these are pre-Ansible provisioning requirements. The base role does NOT create users, add SSH keys, or configure sudoers. These are documented prerequisites in operations.md.
- **Delete the entire "Create ansible user" section** (3 tasks: user creation, authorized_key, sudoers). The base role is simpler: SSH config, packages, firewalld, sysctl, timezone.

## Updated proposed tasks/main.yml (admin section removed)

The final 3 tasks of the role are deleted. The role ends with sysctl hardening. No user management.