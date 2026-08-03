## 2026-08-03: pass role ordering fix

Fixed bug in pass role: `git_config` with `scope: local` was running before `pass git init`, causing "fatal: --local can only be used inside a git repository" because there was no `.git` directory yet. Moved the "Initialize git in password store" task to run BEFORE the "Configure git identity" task. Simple ordering fix -- the git init creates the `.git` dir that git_config needs.
## 2026-08-03: restic role fix

Fixed restic role: `restic_user` was hardcoded to "nacho" in defaults, but rammstein's ansible_user is "riemann" and rammstein doesn't have a "nacho" user. Replaced all `restic_user` references with `ansible_user` (which is per-host in host_vars). Removed `restic_user` from defaults entirely. Also gated all client-side tasks (password file, systemd services/timers) on `restic_backup_paths | length > 0` so rammstein (which has no backup paths, only serves as SFTP target) skips them.
## 2026-08-03: pass role git init fix (second pass)

The git init task was gated on `not pass_store.stat.exists` (checking for `.gpg-id`). But `pass init` had already run successfully on the first (broken) playbook run -- it created `.gpg-id` before the git_config task failed. On the second run (after the ordering fix), `.gpg-id` existed, so `not pass_store.stat.exists` was false, and ALL git tasks were skipped -- including git init itself. The store had no `.git` directory.

Fix: added an independent stat check for `~/.password-store/.git` (`pass_git`), and gated all git-related tasks on `not pass_git.stat.exists` instead of `not pass_store.stat.exists`. This way git init/config/remotes/commit run independently of whether pass init already happened. Handles partial-failure recovery correctly.
## 2026-08-03: restic role -- sophon SFTP target setup missing

Yoga's primary backup target is `sftp:restic@10.66.0.5:/srv/restic` (sophon over WireGuard). But the restic role only set up the restic user + authorized_keys on rammstein. Sophon had `/srv/restic` owned by `nacho` (from the sophon-specific local repo tasks), with no restic user, no `.ssh/authorized_keys` for SFTP access. When yoga tried to SFTP in as `restic@10.66.0.5`, the connection was rejected -- no such user with proper SSH setup.

Fix: merged the rammstein and sophon SFTP target setup into shared tasks gated on `inventory_hostname in ['rammstein', 'sophon']`. Both hosts now get: restic user (nologin shell), /srv/restic owned by restic, .ssh/authorized_keys copied from ansible user, and repo init. Removed the separate sophon-only local repo tasks that were a subset of the same work.
## 2026-08-03: restic SFTP -- nologin shell corrupts SFTP protocol

The restic user has `shell: /usr/sbin/nologin`. When SFTP connects, sshd first starts the user's shell, which prints "This account is currently not available" to stdout, then exits. That text gets sent before the SFTP protocol handshake, corrupting it -- restic sees it as a malformed packet ("packet too long" / "unexpected EOF").

Fix: added a `Match User restic` block to `sshd_config.j2` with `ForceCommand internal-sftp`. This bypasses the user's shell entirely and uses sshd's built-in SFTP handler. The nologin message never gets printed. This is the standard pattern for SFTP-only users -- same as the git user uses git-shell, but for SFTP you use internal-sftp.

This also means the `Subsystem sftp` line is effectively overridden for the restic user -- `internal-sftp` is sshd's built-in, not the external `/usr/libexec/openssh/sftp-server`.
## 2026-08-03: restic SELinux fix -- three denials blocking SFTP

SELinux was blocking SFTP in three ways:

1. **authorized_keys context:** `/srv/restic/.ssh/authorized_keys` had `var_t` context (inherited from `/srv`). `sshd_session_t` can't read files with `var_t`. Fix: `sefcontext` to set `ssh_home_t` on `/srv/restic/.ssh(/.*)?`, then `restorecon -R`.

2. **internal-sftp dyntransition:** `ForceCommand internal-sftp` transitions the process from `sshd_session_t` to `sftpd_t`. This `dyntransition` was denied. Once in `sftpd_t`, the process also couldn't read a pipe from `sshd_session_t` or create a unix_dgram_socket. Fix: custom SELinux module (`restic_sftp`) compiled with `checkmodule` + `semodule_package`, installed with `semodule -i`. The module allows: `sftpd_t -> sshd_session_t:process dyntransition`, `sftpd_t -> sshd_session_t:fifo_file read`, `sftpd_t -> self:unix_dgram_socket create`.

3. **Repo ownership:** The repo was initialized by `nacho` in a previous run (before the restic user existed on sophon). Files in `/srv/restic` were owned by `nacho`, not `restic`. Fix: recursive chown of `/srv/restic` to `restic:restic`.

Also added `checkpolicy` and `policycoreutils-python-utils` to the package install list (needed for `checkmodule`, `semodule_package`, `semodule`).
## 2026-08-03: moved restic + git-repo from /srv to /home (SELinux avoidance)

User decided to move both restic and git-repo data from /srv to /home to avoid SELinux entirely. Home directories get `user_home_t` context automatically, which sshd and SFTP can access without custom policy modules.

Changes:
- **restic role:** `/srv/restic` -> `/home/restic/backups`. Removed all SELinux tasks (sefcontext, restorecon, custom module compile/install). Removed `checkpolicy` and `policycoreutils-python-utils` from package list. Changed `create_home: false` to `create_home: true` so the home directory is created with proper context.
- **git-repo role:** `/srv/git` -> `/home/git/repos`. Updated defaults and comments.
- **host_vars/yoga.yml:** `restic_primary_repo` -> `sftp:restic@10.66.0.5:/home/restic/backups`
- **host_vars/sophon.yml:** `restic_primary_repo` -> `/home/restic/backups`, `git_mirror_target` -> `git@10.66.0.1:/home/git/repos`
- **host_vars/rammstein.yml:** `git_mirror_target` -> `git@10.66.0.5:/home/git/repos`
- **restic defaults:** `restic_remote_repo` -> `sftp:restic@10.66.0.1:/home/restic/backups`
- **sshd_config.j2:** Kept `Match User restic` block with `ForceCommand internal-sftp` (still needed to bypass nologin shell).
- **Old /srv/restic and /srv/git dirs:** Need manual cleanup on rammstein + sophon (delete old repos/data, remove old SELinux module with `semodule -r restic_sftp`).
## 2026-08-03: restic SFTP -- eliminated SELinux denials by changing approach

Moving to /home didn't fix the SELinux issue because the denials were not about file context -- they were about the `ForceCommand internal-sftp` triggering a domain transition from `sshd_session_t` to `sftpd_t`. Once in `sftpd_t`, the process was denied pipe read/write and unix_dgram_socket create. This is Fedora's default SELinux policy for the SFTP subsystem, and it's locked down hard.

New approach: instead of using `ForceCommand internal-sftp` with a `nologin` shell, set the restic user's shell directly to `/usr/libexec/openssh/sftp-server`. This means:
- No `ForceCommand` needed -- the shell IS the SFTP server
- No domain transition to `sftpd_t` -- the process stays in the user's login context
- No `Match User restic` block needed in sshd_config -- removed it
- Added `/usr/libexec/openssh/sftp-server` to `/etc/shells` so it's accepted as a valid shell

When SSH connects as the restic user, sshd starts the user's shell, which is the SFTP server binary. The SFTP protocol starts immediately. No nologin message, no domain transition, no SELinux denials.