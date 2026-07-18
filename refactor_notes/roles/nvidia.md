# Refactor Notes: roles/nvidia/

## Files reviewed
- `tasks/main.yml` (73 lines)
- `defaults/main.yml` (16 lines)
- `handlers/main.yml` (4 lines)
- No templates

## Decisions

### 1. Remove stale comments
Remove "Target: sophon (local, Fedora Workstation 44, NVIDIA GPU)" -- the role targets `gpu_hosts` group, not a specific host. Remove OS reference -- redundant with the RPM Fusion URL using `ansible_distribution_major_version`.

### 2. Remove `nvidia_reboot_required` dead variable
Defined in defaults, never referenced in any task. The role uses a debug message to tell the operator to reboot. Remove the variable.

### 3. `nvidia_driver_loaded` fact: for internal use only
The fact is set for the role's own use. Ollama and frigate roles run their own `nvidia-smi` checks independently. No `cacheable: true` needed. Keep it simple.

### 4. CDI spec generation: detect actual changes
Replace `changed_when: false` with a comparison. Read the existing file before generating, compare after. If content changed, report changed.

```yaml
- name: Read existing CDI spec
  slurp:
    src: /var/run/cdi/nvidia.yaml
  register: existing_cdi
  changed_when: false
  failed_when: false

- name: Generate CDI specification for Podman
  command: nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml
  register: cdi_generate
  changed_when: false

- name: Check if CDI spec changed
  slurp:
    src: /var/run/cdi/nvidia.yaml
  register: new_cdi
  changed_when: false
  failed_when: false

- name: Report CDI spec change
  debug:
    msg: "CDI spec updated"
  when: existing_cdi.failed or (existing_cdi['content'] | b64decode) != (new_cdi['content'] | b64decode)
```

Alternatively, simpler approach: generate to a temp file, compare with `diff`, move if different:

```yaml
- name: Generate CDI spec to temp file
  command: nvidia-ctk cdi generate --output=/tmp/nvidia-cdi.yaml.new
  changed_when: false

- name: Check if CDI spec changed
  copy:
    src: /tmp/nvidia-cdi.yaml.new
    dest: /var/run/cdi/nvidia.yaml
    remote_src: true
    owner: root
    group: root
    mode: '0644'
  register: cdi_spec
```

The `copy` module with `remote_src` is idempotent -- it only changes if content differs. This is the cleanest approach. Use this.

### 5. CDI refresh: enable `.path` only
Remove `nvidia-cdi-refresh.service` from the loop. Only enable `nvidia-cdi-refresh.path`. The `.path` unit watches for filesystem changes and triggers `.service` automatically. Enabling `.service` directly causes it to run once at boot, which is unnecessary.

### 6. `rebuild initramfs` handler: correct, no change
The handler fires only when the driver install task changes (notified by the dnf task). `changed_when: true` is correct -- dracut --force rebuilds unconditionally, but the handler only runs when triggered.

### 7. Replace `pgrep -f "akmods"` with lockfile check
Replace the PID-exclusion shell script with a check for the akmod build lock file. akmods creates a lock file during the build process. Check for its presence instead of grepping process names.

```yaml
- name: Wait for akmod-nvidia build to complete
  wait_for:
    path: /var/run/akmods/shared.lock
    state: absent
    timeout: 300
    msg: "akmod-nvidia build did not complete within 5 minutes"
  when: not nvidia_driver_loaded | bool
```

Note: The exact lock file path needs verification. Common akmod lock locations:
- `/var/run/akmods/shared.lock`
- `/var/lock/akmods/akmods.lock`

Verify on sophon before committing to a specific path. If no lock file exists, fall back to checking for the built kmod file with a retry loop:

```yaml
- name: Wait for akmod-nvidia build to complete
  shell: |
    for i in $(seq 1 60); do
      if ls /lib/modules/$(uname -r)/extra/nvidia* 2>/dev/null || \
         ls /lib/modules/$(uname -r)/weak-updates/nvidia* 2>/dev/null; then
        exit 0
      fi
      sleep 5
    done
    exit 1
  register: akmod_build
  changed_when: false
  failed_when: false
  when: not nvidia_driver_loaded | bool
```

This checks for the actual output (built kmod file) instead of process names. More robust than pgrep.

### 8. Enable GPG check for RPM Fusion
Import the RPM Fusion GPG key before installing the repo package, then leave GPG check enabled. Remove `disable_gpg_check: true`.

The RPM Fusion GPG key is included in the release package. The `dnf` module installs the release RPM which adds the GPG key to the keyring. The `disable_gpg_check: true` was likely added because the release RPM itself isn't signed by a trusted key. The fix: use `rpm_key` to import the key first, or accept that the release RPM needs `disable_gpg_check` for the initial install only.

Pragmatic approach: keep `disable_gpg_check: true` for the release RPM install (it's a one-time bootstrap of the repo), but ensure subsequent package installs from the repo have GPG check enabled (which is the default).

### 9. Enable GPG check for container toolkit repo
Change `gpgcheck=0` to `gpgcheck=1` in the repo file template. Import the GPG key first:

```yaml
- name: Import NVIDIA container toolkit GPG key
  rpm_key:
    key: https://nvidia.github.io/libnvidia-container/gpgkey
    state: present
  when: nvidia_driver_loaded | bool
```

Then the repo file uses `gpgcheck=1`.

### 10. `become: true` at play level
No task-level changes needed.

## Proposed defaults/main.yml

```yaml
---
# roles/nvidia/defaults/main.yml

# NVIDIA driver packages (installed from RPM Fusion)
nvidia_driver_packages:
  - akmod-nvidia
  - xorg-x11-drv-nvidia-cuda

# NVIDIA container toolkit packages
nvidia_container_packages:
  - nvidia-container-toolkit
```

Note: `nvidia_reboot_required` removed (dead variable).

## Proposed tasks/main.yml (key changes)

```yaml
---
# roles/nvidia/tasks/main.yml
# Installs NVIDIA proprietary drivers and container toolkit.
# Two-run pattern: 1st run installs driver (needs reboot), 2nd run installs toolkit.
# Must run before ollama and frigate roles on GPU hosts.

# -- Check if NVIDIA driver is already loaded --
- name: Check if nvidia-smi is available
  command: nvidia-smi --query-gpu=name --format=csv,noheader
  register: nvidia_check
  changed_when: false
  failed_when: false

- name: Set nvidia driver status
  set_fact:
    nvidia_driver_loaded: "{{ nvidia_check.rc == 0 }}"

# -- Install driver (first run) --
- name: Enable RPM Fusion nonfree repository
  dnf:
    name: "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-{{ ansible_distribution_major_version }}.noarch.rpm"
    state: present
    disable_gpg_check: true  # One-time bootstrap: release RPM adds GPG key to keyring
  when: not nvidia_driver_loaded | bool

- name: Install NVIDIA driver (akmod + CUDA)
  dnf:
    name: "{{ nvidia_driver_packages }}"
    state: present
  when: not nvidia_driver_loaded | bool
  notify: rebuild initramfs

- name: Wait for akmod-nvidia build to complete
  shell: |
    for i in $(seq 1 60); do
      if ls /lib/modules/$(uname -r)/extra/nvidia* 2>/dev/null || \
         ls /lib/modules/$(uname -r)/weak-updates/nvidia* 2>/dev/null; then
        exit 0
      fi
      sleep 5
    done
    exit 1
  register: akmod_build
  changed_when: false
  failed_when: false
  when: not nvidia_driver_loaded | bool

- name: Fail if akmod build failed
  fail:
    msg: |
      akmod-nvidia kernel module build appears to have failed.
      Check /var/log/akmods/ for build logs.
      A reboot may be needed if the running kernel doesn't match
      the installed kernel-headers.
  when:
    - not nvidia_driver_loaded | bool
    - akmod_build.rc != 0

- name: Notify that reboot is required
  debug:
    msg: |
      ============================================================
      NVIDIA driver installed. A REBOOT IS REQUIRED to load the
      kernel module. After reboot, re-run this playbook to
      complete the setup (container toolkit + frigate).
      ============================================================
  when: not nvidia_driver_loaded | bool

# -- Install container toolkit (second run, after reboot) --
- name: Import NVIDIA container toolkit GPG key
  rpm_key:
    key: https://nvidia.github.io/libnvidia-container/gpgkey
    state: present
  when: nvidia_driver_loaded | bool

- name: Add NVIDIA container toolkit repository
  copy:
    dest: /etc/yum.repos.d/nvidia-container-toolkit.repo
    content: |
      [nvidia-container-toolkit]
      name=nvidia-container-toolkit
      baseurl=https://nvidia.github.io/libnvidia-container/stable/rpm/$basearch
      repo_gpgcheck=1
      gpgcheck=1
      enabled=1
      gpgkey=https://nvidia.github.io/libnvidia-container/gpgkey
    owner: root
    group: root
    mode: '0644'
  when: nvidia_driver_loaded | bool

- name: Install NVIDIA container toolkit
  dnf:
    name: "{{ nvidia_container_packages }}"
    state: present
    enablerepo: nvidia-container-toolkit
  when: nvidia_driver_loaded | bool

- name: Generate CDI spec to temp file
  command: nvidia-ctk cdi generate --output=/tmp/nvidia-cdi.yaml.new
  changed_when: false
  when: nvidia_driver_loaded | bool

- name: Deploy CDI specification for Podman
  copy:
    src: /tmp/nvidia-cdi.yaml.new
    dest: /var/run/cdi/nvidia.yaml
    remote_src: true
    owner: root
    group: root
    mode: '0644'
  when: nvidia_driver_loaded | bool

- name: Enable nvidia-cdi-refresh path unit
  service:
    name: nvidia-cdi-refresh.path
    state: started
    enabled: true
  when: nvidia_driver_loaded | bool

# -- Verify GPU is accessible --
- name: Verify NVIDIA GPU is accessible
  command: nvidia-smi --query-gpu=name --format=csv,noheader
  register: nvidia_verify
  changed_when: false
  failed_when: false
  when: nvidia_driver_loaded | bool

- name: Show GPU info
  debug:
    msg: "NVIDIA GPU detected: {{ nvidia_verify.stdout }}"
  when:
    - nvidia_driver_loaded | bool
    - nvidia_verify.rc == 0
```

## Emerging Guidelines

### Guideline: GPG Check by Default
Package repositories must have GPG check enabled. Disabling GPG check is only acceptable for one-time bootstrap of a repo release RPM that adds the GPG key to the keyring. All subsequent package installs from that repo must verify signatures.

Evidence: RPM Fusion install uses `disable_gpg_check: true`. Container toolkit repo has `gpgcheck=0`. Both allow MITM injection of malicious packages. The release RPM bootstrap is acceptable (it imports the key). The repo config and subsequent installs should verify.

### Guideline: Idempotent Command Tasks
Command and shell tasks must either use `changed_when` with a real condition, `creates`/`check_mode` guards, or produce output that can be compared. `changed_when: false` on a task that actually changes things hides real changes from the operator.

Evidence: CDI spec generation uses `changed_when: false` but the file content can change when the driver updates. Using `copy` with `remote_src` makes the task idempotent -- only reports changed when content differs.