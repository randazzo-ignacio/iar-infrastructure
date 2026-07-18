# Refactor Notes: roles/static-site/ (merged from static-page + portfolio-page)

## Files reviewed
- `roles/static-page/tasks/main.yml` (18 lines)
- `roles/static-page/defaults/main.yml` (4 lines)
- `roles/static-page/files/` (index.html, style.css, script.js)
- `roles/static-page/templates/static-page.service.j2` (dead code)
- `roles/portfolio-page/tasks/main.yml` (16 lines)
- `roles/portfolio-page/defaults/main.yml` (4 lines)
- `roles/portfolio-page/files/` (index.html, style.css, script.js)
- `roles/portfolio-page/handlers/main.yml` (empty, no handlers needed)

## Merge Plan

### New role: `roles/static-site/`

Structure:
```
roles/static-site/
  defaults/main.yml
  tasks/main.yml
  files/
    portfolio/      -- from portfolio-page/files/
      index.html
      style.css
      script.js
    landing/         -- from static-page/files/
      index.html
      style.css
      script.js
```

### Decisions

#### 1. Merge into one parameterized role
Both roles do the same thing: copy static files to a web root with caddy ownership. One role with `static_site_src` and `static_site_dest` variables replaces both.

#### 2. Use directory copy (one task instead of three)
```yaml
- name: Deploy static files
  copy:
    src: "{{ static_site_src }}/"
    dest: "{{ static_site_dest }}/"
    owner: "{{ static_site_owner }}"
    group: "{{ static_site_group }}"
    mode: '0644'
```

The `copy` module with a directory `src` and trailing `/` copies all files in the directory. One task, idempotent, handles any number of files.

#### 3. Web root creation moves here from caddy role
The `Ensure web root exists` task creates the directory. The caddy role no longer creates web roots (per caddy decision).

#### 4. Remove dead Python HTTP server template
`static-page.service.j2` is a Python HTTP server fallback that's never used (Caddy serves files directly). References undefined variables (`static_page_user`, `static_page_group`, `static_page_port`). Delete the template and the `templates/` directory.

#### 5. Remove empty handlers file
`portfolio-page/handlers/main.yml` is a comment-only file. No handlers needed. Don't create a handlers directory in the new role.

#### 6. `caddy` user as variable for file ownership
```yaml
static_site_owner: "caddy"
static_site_group: "caddy"
```

Variables instead of hardcoded. If a different web server is used, override in host_vars.

#### 7. Enable flags: `portfolio_page_enabled` and `tool_static_page_enabled`
Both are explicit per-host flags. Set in host_vars:
```yaml
# rammstein.yml
portfolio_page_enabled: true

# daftpunk.yml
tool_static_page_enabled: true
```

#### 8. Path variables move to host_vars
```yaml
# rammstein.yml
portfolio_page_root: "/var/www/randazzo.ar"

# daftpunk.yml
static_page_root: "/var/www/emacboros"
```

Role default for `static_site_dest` is blank (required per "no defaults for per-host variables" guideline).

#### 9. Delete old roles
After merge is complete and tested:
- Delete `roles/static-page/` (entire directory)
- Delete `roles/portfolio-page/` (entire directory)
- Update `playbooks/site.yml` to use `static-site` role
- Update standalone playbooks `playbooks/static-page.yml` and `playbooks/portfolio-page.yml`
- Update docs

## Proposed defaults/main.yml

```yaml
---
# roles/static-site/defaults/main.yml

# Source directory (relative to role files/) -- REQUIRED
static_site_src: ""

# Destination path -- REQUIRED, set in host_vars
static_site_dest: ""

# File ownership (Caddy serves the files)
static_site_owner: "caddy"
static_site_group: "caddy"
```

## Proposed tasks/main.yml

```yaml
---
# roles/static-site/tasks/main.yml
# Deploys static site files to a web root. Caddy serves them via file_server.

- name: Ensure web root exists
  file:
    path: "{{ static_site_dest }}"
    state: directory
    owner: "{{ static_site_owner }}"
    group: "{{ static_site_group }}"
    mode: '0755'

- name: Deploy static files
  copy:
    src: "{{ static_site_src }}/"
    dest: "{{ static_site_dest }}/"
    owner: "{{ static_site_owner }}"
    group: "{{ static_site_group }}"
    mode: '0644'
```

## Playbook usage (in site.yml)

```yaml
- name: Static sites
  hosts: web_servers
  become: true
  roles:
    - role: static-site
      vars:
        static_site_src: "portfolio"
        static_site_dest: "{{ portfolio_page_root }}"
      when: portfolio_page_enabled | default(false) | bool
      tags: [static-site]
    - role: static-site
      vars:
        static_site_src: "landing"
        static_site_dest: "{{ static_page_root }}"
      when: tool_static_page_enabled | default(false) | bool
      tags: [static-site]
```

## Host_vars additions

```yaml
# rammstein.yml
portfolio_page_root: "/var/www/randazzo.ar"
portfolio_page_enabled: true

# daftpunk.yml
static_page_root: "/var/www/emacboros"
tool_static_page_enabled: true
```

## No new emerging guidelines
This merge applies existing guidelines:
- Eliminate redundant variables (two roles -> one)
- No hardcoded hostnames (group targeting + when guards)
- Explicit host identity (enable flags per-host)
- No defaults for per-host variables (blank static_site_dest)
- Comments add context not redundancy (remove "Deploys to daftpunk" comments)