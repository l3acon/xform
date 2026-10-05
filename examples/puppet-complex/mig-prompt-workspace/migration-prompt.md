# Migration Prompt: Puppet Complex → Ansible

## Current Application Summary

**Source technology:** Puppet 8 control repo with Hiera 5, roles/profiles pattern
**Architecture:** 3 roles composing 6 profiles, Hiera 4-level data hierarchy, custom type/provider/fact

### From rgctl knowledge graph (308 nodes, 755 edges)

**Profiles (6):**
- `profile::base` — NTP, timezone, admin users, extra packages, firewall baseline
- `profile::security` — SELinux, SSH hardening, password policy, fail2ban
- `profile::web` — Apache httpd, vhosts from Hiera, SSL, reverse proxy, firewall
- `profile::app` — Java app deployment, systemd unit, config from Hiera, firewall
- `profile::database` — PostgreSQL server, initdb, config, HBA, databases from Hiera
- `profile::monitoring` — Prometheus node_exporter, custom metrics from Hiera

**Roles (3):**
- `role::base` → base + security + monitoring
- `role::webserver` → base + security + web + app + monitoring (ordered)
- `role::dbserver` → base + security + database + monitoring (ordered)

**Resource types (from graph):** 18 file, 13 exec, 10 package, 8 service, 3 user, 1 group, 1 ssh_authorized_key

**ERB templates (14):** 125 blocks, 56 USES edges, 4 USES_FACT edges, 47 REFERENCES edges

**Custom Ruby code:**
- Custom fact: `webapp_status` / `webapp_count` (dir iteration, PID checking)
- Custom type: `webapp` (ensurable, params: deploy_dir, user, group; properties: version, running)
- Custom provider: `webapp::systemd` (create/destroy/exists?, systemd unit generation)

**Hiera hierarchy (4 levels):**
1. `nodes/%{trusted.certname}.yaml` — per-node overrides
2. `roles/%{facts.role}.yaml` — per-role config (webserver, dbserver)
3. `os/%{facts.os.family}.yaml` — OS-specific packages/paths (RedHat)
4. `common.yaml` — global defaults

**Migration plan (from rgctl):** 3 scheduled steps: profiles → roles → site.pp

## Target Platform

**Target technology:** Ansible roles + playbooks
**Target structure:**
```
examples/ansible-complex/
├── inventory/
│   ├── group_vars/
│   │   ├── all.yml          ← common.yaml
│   │   ├── webserver.yml    ← roles/webserver.yaml
│   │   ├── dbserver.yml     ← roles/dbserver.yaml
│   │   └── RedHat.yml       ← os/RedHat.yaml
│   ├── host_vars/
│   │   └── web01.yml        ← nodes/web01.yaml
│   └── hosts
├── roles/
│   ├── base/
│   ├── security/
│   ├── web/
│   ├── app/
│   ├── database/
│   └── monitoring/
├── library/                  ← custom webapp module (from type/provider)
├── facts.d/                  ← custom webapp_status fact
├── site.yml                  ← role::webserver / role::dbserver plays
└── templates/ (per-role)
```

## Migration Approach

**Strategy:** Profile-by-profile translation following rgctl migration plan order

### Mapping rules
- Puppet profiles → Ansible roles (1:1)
- Puppet roles → Ansible plays in site.yml (compose roles)
- Hiera hierarchy → Ansible group_vars/host_vars (4 levels → inventory structure)
- Puppet class params with `lookup()` → Ansible role `defaults/main.yml` + inventory overrides
- ERB templates → Jinja2 templates (56 USES edges guide variable mapping)
- Puppet `exec` firewall pattern → `ansible.posix.firewalld` module
- Puppet `subscribe`/`notify` → Ansible handlers
- Custom type/provider → Ansible custom module in `library/`
- Custom fact → `facts.d/` executable script
- Facter facts → Ansible facts (4 mappings: os.family, networking.ip, memory, role)

## Success Criteria

1. Every PuppetClass has a corresponding Ansible role
2. Every PuppetResource has a corresponding Ansible task
3. Every ERB variable (56 USES edges) maps to a Jinja2 variable
4. Every Hiera data key appears in the correct group_vars/host_vars file
5. Custom type/provider translated to working Ansible module
6. Custom fact translated to working facts.d script
7. `ansible-playbook site.yml` applies cleanly on a RHEL 9 target
