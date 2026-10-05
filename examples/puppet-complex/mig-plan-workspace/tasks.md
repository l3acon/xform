# Migration Tasks: Puppet Complex → Ansible

## Task Group 1: Scaffold Ansible Structure

- [ ] 1.1 Create `examples/ansible-complex/` with role layout for all 6 profiles
- [ ] 1.2 Create inventory structure: `group_vars/`, `host_vars/`, `hosts`
- [ ] 1.3 Create `site.yml` with plays for webserver and dbserver roles
- [ ] 1.4 Create `ansible.cfg`

## Task Group 2: Translate Hiera Hierarchy → Ansible Inventory Variables

- [ ] 2.1 Translate `data/common.yaml` → `inventory/group_vars/all.yml`
- [ ] 2.2 Translate `data/os/RedHat.yaml` → `inventory/group_vars/RedHat.yml`
- [ ] 2.3 Translate `data/roles/webserver.yaml` → `inventory/group_vars/webserver.yml`
- [ ] 2.4 Translate `data/roles/dbserver.yaml` → `inventory/group_vars/dbserver.yml`
- [ ] 2.5 Translate `data/nodes/web01.yaml` → `inventory/host_vars/web01.yml`
- [ ] 2.6 Flatten Puppet-namespaced keys (e.g. `profile::base::ntp_servers` → `ntp_servers`)
- [ ] 2.7 Create inventory `hosts` file with role groups

## Task Group 3: Translate profile::base → roles/base/

- [ ] 3.1 Create `roles/base/tasks/main.yml` — timezone, chrony, packages, users, firewall
- [ ] 3.2 Create `roles/base/handlers/main.yml` — restart chronyd
- [ ] 3.3 Translate `chrony.conf.erb` → `roles/base/templates/chrony.conf.j2`
- [ ] 3.4 Create `roles/base/defaults/main.yml` from profile params

## Task Group 4: Translate profile::security → roles/security/

- [ ] 4.1 Create `roles/security/tasks/main.yml` — SELinux, SSH, password policy, fail2ban
- [ ] 4.2 Create `roles/security/handlers/main.yml` — restart sshd, fail2ban
- [ ] 4.3 Translate 4 ERB templates → Jinja2: selinux_config, sshd_hardening, login.defs, fail2ban_jail
- [ ] 4.4 Create `roles/security/defaults/main.yml`

## Task Group 5: Translate profile::web → roles/web/

- [ ] 5.1 Create `roles/web/tasks/main.yml` — httpd, SSL, vhosts, docroot, firewall
- [ ] 5.2 Create `roles/web/handlers/main.yml` — restart httpd
- [ ] 5.3 Translate `httpd.conf.erb` → `roles/web/templates/httpd.conf.j2` (T3: .downcase method chain)
- [ ] 5.4 Translate `index.html.erb` → `roles/web/templates/index.html.j2` (T2+T3: facts, scope lookups)
- [ ] 5.5 Translate `vhost.conf.erb` → `roles/web/templates/vhost.conf.j2` (T3: .downcase.gsub, nested hash iteration)
- [ ] 5.6 Translate dynamic vhost iteration (`$vhosts.each`) → Jinja2 loop or `with_dict`
- [ ] 5.7 Replace `exec` firewall pattern → `ansible.posix.firewalld`
- [ ] 5.8 Create `roles/web/defaults/main.yml`

## Task Group 6: Translate profile::app → roles/app/

- [ ] 6.1 Create `roles/app/tasks/main.yml` — Java, user/group, dirs, config, systemd, firewall
- [ ] 6.2 Create `roles/app/handlers/main.yml` — systemd daemon-reload, restart app
- [ ] 6.3 Translate `application.yml.erb` → `roles/app/templates/application.yml.j2` (T3: .upcase, unless nil)
- [ ] 6.4 Translate `app.service.erb` → `roles/app/templates/app.service.j2` (T3: unless nil/localhost)
- [ ] 6.5 Translate directory iteration (`[$dir1, $dir2].each`) → `loop` in Ansible
- [ ] 6.6 Replace `exec` firewall pattern → `ansible.posix.firewalld`
- [ ] 6.7 Create `roles/app/defaults/main.yml`

## Task Group 7: Translate profile::database → roles/database/

- [ ] 7.1 Create `roles/database/tasks/main.yml` — PostgreSQL install, initdb, config, HBA, databases
- [ ] 7.2 Create `roles/database/handlers/main.yml` — restart postgresql
- [ ] 7.3 Translate `postgresql.conf.erb` → `roles/database/templates/postgresql.conf.j2`
- [ ] 7.4 Translate `pg_hba.conf.erb` → `roles/database/templates/pg_hba.conf.j2` (T2: conditional)
- [ ] 7.5 Translate dynamic database creation (`$databases.each`) → `loop` with `community.postgresql`
- [ ] 7.6 Replace `exec` firewall pattern → `ansible.posix.firewalld`
- [ ] 7.7 Create `roles/database/defaults/main.yml`

## Task Group 8: Translate profile::monitoring → roles/monitoring/

- [ ] 8.1 Create `roles/monitoring/tasks/main.yml` — node_exporter, custom metrics, firewall
- [ ] 8.2 Create `roles/monitoring/handlers/main.yml` — restart node_exporter
- [ ] 8.3 Translate `node_exporter_sysconfig.erb` → `roles/monitoring/templates/node_exporter_sysconfig.j2`
- [ ] 8.4 Translate `custom_metrics.prom.erb` → `roles/monitoring/templates/custom_metrics.prom.j2`
- [ ] 8.5 Replace `exec` firewall pattern → `ansible.posix.firewalld`
- [ ] 8.6 Create `roles/monitoring/defaults/main.yml`

## Task Group 9: Translate Custom Type/Provider → Ansible Module

- [ ] 9.1 Create `library/webapp.py` — Ansible module from Puppet type params (argument_spec)
- [ ] 9.2 Implement create/destroy/exists? logic from provider as module state management
- [ ] 9.3 Map type properties (version, running) to module return values

## Task Group 10: Translate Custom Fact → facts.d Script

- [ ] 10.1 Create `facts.d/webapp_status.sh` (or .py) — scan deploy dirs, check PIDs
- [ ] 10.2 Output JSON for `ansible_local.webapp_status` fact

## Task Group 11: Verify

- [ ] 11.1 Syntax check: `ansible-playbook --syntax-check site.yml`
- [ ] 11.2 Cross-reference: every rgctl PuppetResource node has an Ansible task equivalent
- [ ] 11.3 Cross-reference: every rgctl USES edge has a Jinja2 variable mapping
- [ ] 11.4 Cross-reference: every Hiera key appears in inventory vars
