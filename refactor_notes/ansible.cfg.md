# Refactor Notes: ansible.cfg

## Decisions

1. **`host_key_checking = False` -> `True`**
   - Security: accept SSH host keys only on first connection with verification, not blindly.

2. **`stdout_callback = default` -> `community.general.yaml`**
   - Readability: structured YAML output during playbook runs.

3. **`fact_caching_timeout = 86400` -> `900` (15 min)**
   - Stale-fact prevention: 24h cache risks decisions based on yesterday's host state. 15 min balances re-discovery cost vs freshness.

4. **`become = True` -> `False` (least privilege)**
   - Global become=True means every task runs as root unless overridden. Switch to per-task opt-in. Roles must declare `become: true` where needed.

5. **Add `pipelining = True`**
   - Performance: reduces SSH round-trips by sending Python directly instead of temp files. Free win on RHEL/Fedora (requiretty is off by default).

6. **Add `timeout = 60` (1 min)**
   - Headroom for slow hosts (CPU-bound Ollama, GPU-bound sophon). Default 10s is too tight.

7. **Remove `vault_password_file = .vault_pass`**
   - User prefers `--ask-vault-pass` on the CLI. Config references a file that may not exist. Remove the dead reference.

## Proposed ansible.cfg

```ini
[defaults]
inventory = inventory/hosts.yml
host_key_checking = True
retry_files_enabled = False
stdout_callback = community.general.yaml
callbacks_enabled = profile_tasks
forks = 5
gathering = smart
fact_caching = jsonfile
fact_caching_connection = .ansible/facts
fact_caching_timeout = 900
interpreter_python = auto_silent
pipelining = True
timeout = 60
ssh_args = -o ControlMaster=auto -o ControlPersist=60s

[privilege_escalation]
become = False
become_method = sudo
become_user = root
```