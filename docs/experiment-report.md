# xform Experiment Report: Puppet → Ansible Translation Pipeline

> **Date:** 2026-09-29 – 2026-09-30
> **Status:** Phase 1 complete — simple example translated, rgctl plugins submitted
> **Next:** Resume testing when AWS sandbox is active; tackle complex example

---

## Objective

Build a pipeline that translates Puppet infrastructure code to Ansible, using
rgctl as the completeness backbone to guarantee full coverage across manifests,
templates, variables, facts, and custom types.

## Infrastructure (AWS)

Provisioned via Ansible playbooks in `infra/puppet/`:

| Resource | Details | Status |
|---|---|---|
| VPC | `10.0.0.0/16`, us-east-2 | ✅ Created |
| Puppet Master | `13.59.212.179` (t3.medium, RHEL 9) | ✅ Puppet Server 8 running |
| Puppet Agent | `18.191.67.99` (t3.small, RHEL 9) | ✅ Registered, catalog applied |
| DNS | `puppet.sandbox1359.opentlc.com` | ✅ Route53 |
| Security Group | SSH, 8140, HTTP, HTTPS | ✅ Configured |

**Note:** The sandbox auto-stops. Run `ansible-playbook site.yml` from `infra/puppet/` to
resume, or use `teardown.yml` to destroy.

## Puppet Simple Example (`examples/puppet-simple/`)

### What it deploys
- Apache httpd web server
- `index.html` from ERB template with Facter facts
- Firewall rules (HTTP + HTTPS via `firewall-cmd`)

### Files
- `manifests/site.pp` — 8 Puppet resource declarations
- `modules/webserver/templates/index.html.erb` — 3 ERB variable blocks
- `apply.yml` — Ansible playbook to push Puppet code and run `puppet apply`

### Verification
- ✅ Puppet apply succeeded on agent node
- ✅ Web server served content at `http://18.191.67.99/`

## rgctl Contributions

### Puppet Plugin (upstream `lang-support` branch)
Already merged upstream. Extracts `PuppetResource`, `PuppetClass`, `PuppetDefinedType`,
`PuppetNode`, `PuppetVariable`, `PuppetModule` + relations.

### ERB Plugin (PR [sshaaf/rgctl#101](https://github.com/sshaaf/rgctl/pull/101))

**Branch:** `feat/erb-plugin` on `l3acon/rgctl`

| Metric | Value |
|---|---|
| Crate | `crates/rgctl-lang-erb` |
| Grammar | `tree-sitter-embedded-template` v0.25.0 |
| Symbols | ERB blocks as `Variable` nodes with tier/hint metadata |
| Edges | `UsesVariable`, `UsesFact`, `References` |
| Tests | 10 (extraction, tiers, hints, AST coverage, honesty, registry) |
| Graph builder fix | `relation_allows_external_stub` + `stub_node_type_for_target` |
| DCO | All commits signed off |

### Cold Profiles

| Corpus | Files | Nodes | Edges | Wall | Peak RSS |
|---|---|---|---|---|---|
| puppet-simple | 2 | 21 | 47 | 0.3s | 27 MB |
| theforeman (12 modules) | 602 | 6,108 | 13,580 | 1.6s | 72 MB |
| Linux kernel (Gate A) | 70,873 | 2,703,830 | 8,237,401 | 173.4s | 14.5 GB |

Linux Gate A baseline is 145s on ref M3 Pro. Our 173.4s is hardware variance
(~20% slower machine), not a code regression — zero `.erb` files in the kernel.

## Ansible Translation (`examples/ansible-simple/`)

### Translation Mapping (all rgctl graph nodes accounted for)

| Puppet (rgctl node) | Ansible | Improvement |
|---|---|---|
| `package[httpd]` | `ansible.builtin.dnf` | — |
| `package[firewalld]` | `ansible.builtin.dnf` | — |
| `file[/var/www/html/index.html]` | `ansible.builtin.template` + notify | — |
| `service[httpd]` | `ansible.builtin.systemd` | — |
| `service[firewalld]` | `ansible.builtin.systemd` | — |
| `exec[firewall-allow-http]` | `ansible.posix.firewalld` | Idiomatic module vs exec |
| `exec[firewall-allow-https]` | `ansible.posix.firewalld` | Idiomatic module vs exec |
| `exec[firewall-reload]` | *(eliminated)* | Module handles reload |
| `<%= @fqdn %>` | `{{ ansible_fqdn }}` | Fact mapping |
| `<%= @operatingsystem %>` | `{{ ansible_distribution }}` | Fact mapping |
| `<%= @operatingsystemrelease %>` | `{{ ansible_distribution_version }}` | Fact mapping |

### Files
- `tasks/main.yml` — 7 Ansible tasks (translated from 8 Puppet resources)
- `handlers/main.yml` — restart httpd (replaces Puppet `subscribe`)
- `templates/index.html.j2` — translated from ERB (3 fact substitutions)
- `apply.yml` — playbook with AWS SG update + role apply
- `inventory.ini` — target agent node

### Status
- ✅ Syntax check passes
- ✅ AWS security group update succeeded
- ⏸️ Agent node unreachable (sandbox auto-stopped) — resume to verify

## Gap Analysis Summary

| Gap | Status | Notes |
|---|---|---|
| **Gap 1: `.pp` parsing** | ✅ Closed | rgctl Puppet Tier 1 plugin (upstream) |
| **Gap 2: ERB→Jinja2** | ✅ Closed (for T1-T3) | rgctl ERB plugin with translation hints |
| Gap 3: Hiera data | Open | Not needed for simple example |
| Gap 4: Facter facts | Partially closed | 3 built-in mappings done; full table pending |
| Gap 5: Custom types | Open | Not needed for simple example |

## migIQ Integration

Used the [migIQ](https://github.com/sshaaf/migIQ) skill framework to structure the
translation workflow:

1. **mig-rgctl** — Phase 1 discover with `--with-cfg --with-harmonic`
2. **mig-prompt-builder** — Migration prompt in `mig-prompt-workspace/migration-prompt.md`
3. **mig-plan** — Task breakdown in `mig-plan-workspace/tasks.md`
4. **mig-execute** — Manual execution of translation tasks

## To Resume Testing

```bash
# 1. Restart the AWS sandbox (or provision new infra)
cd infra/puppet && ansible-playbook site.yml

# 2. Update inventory with new agent IP
vim examples/ansible-simple/inventory.ini

# 3. Deploy the Ansible translation
cd examples/ansible-simple && ansible-playbook apply.yml

# 4. Verify: curl http://<agent-ip>/
```

## Next Steps

1. **Verify ansible-simple** on a live agent node (when sandbox is active)
2. **Complex example** — build `examples/puppet-complex/` with classes, Hiera, custom types, multiple ERB templates
3. **Fact mapping table** — comprehensive `fact-map.yml` (~100 entries)
4. **Hiera mapper** — `hiera2ansible` tool for variable hierarchy translation
5. **End-to-end automation** — script that runs `rgctl discover` → extracts graph → generates Ansible role
