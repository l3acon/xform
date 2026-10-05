# xform — Puppet to Ansible Translation: Findings Report

> **Period:** 2026-09-29 – 2026-10-05
> **Authors:** Matt Fernandez
> **Status:** Two examples translated, rgctl plugins submitted upstream, awaiting live deployment verification

---

## 1. Project Goal

Build a repeatable, graph-backed pipeline for translating Puppet infrastructure code to Ansible — ensuring completeness across manifests, templates, variables, facts, and custom types at arbitrary scale.

## 2. Approach

Rather than iterative LLM-driven task-by-task translation (which misses edge cases and has coverage gaps), we used **rgctl** as a code knowledge graph to:

1. **Index** the entire Puppet codebase (manifests + ERB templates + Ruby custom code) into a single graph
2. **Query** the graph for complete resource inventories, variable provenance, and dependency chains
3. **Plan** the translation order using the migration planner (dependency-aware scheduling)
4. **Translate** each component with full context from the graph
5. **Verify** by cross-referencing every graph node against the Ansible output

The **migIQ** skill framework was used to orchestrate the workflow (discover → prompt → plan → execute).

## 3. Infrastructure

Provisioned on AWS via Ansible playbooks (`infra/puppet/`):

| Component | Details |
|---|---|
| Puppet Master | t3.medium, RHEL 9, Puppet Server 8, us-east-2 |
| Puppet Agent | t3.small, RHEL 9, puppet-agent registered to master |
| Networking | VPC, subnet, IGW, security group (22, 80, 443, 8140) |
| DNS | Route53: `puppet.sandbox1359.opentlc.com` |

Automated end-to-end: `ansible-playbook site.yml` provisions infrastructure, configures Puppet master, registers agents, and applies initial catalog. Teardown via `ansible-playbook teardown.yml`.

## 4. rgctl Contributions

### 4.1 Puppet Language Plugin (upstream `lang-support` branch)

Already merged upstream by maintainer. Tier 1 plugin using `tree-sitter-puppet` v1.3.0.

**Extracts:** `PuppetResource`, `PuppetClass`, `PuppetDefinedType`, `PuppetNode`, `PuppetVariable`, `PuppetModule` symbols + `IncludesClass`, `InheritsClass`, `RequiresResource`, `UsesFact`, `DependsOnModule`, `Calls`, `References` relations. CFG/complexity analysis on class/define/node bodies.

### 4.2 ERB Template Plugin (PR [sshaaf/rgctl#101](https://github.com/sshaaf/rgctl/pull/101))

New Tier 1 plugin using `tree-sitter-embedded-template` v0.25.0.

**Extracts:** ERB blocks as symbols with translation metadata (tier 1–4 classification, Jinja2 hints), `UsesVariable` edges for `@var` references, `UsesFact` edges for `@facts[...]`, `References` edges for `scope['class::param']`.

**Graph builder fixes:** Added `UsesVariable`/`UsesFact` to `relation_allows_external_stub` and Puppet type hints to `stub_node_type_for_target` so ERB edges survive into the snapshot after `discover`.

**Compliance:** AGENTS.md compliant — no `unwrap()` in library paths (regexes via `OnceLock`), AST coverage manifest with bidirectional drift assertion, 10 unit tests including honesty-gap negative tests, theforeman smoke corpus added to `scripts/fetch-profile-repos.sh`.

### 4.3 Cold Profiles

| Corpus | Files | Nodes | Edges | Wall | Peak RSS |
|---|---|---|---|---|---|
| puppet-simple | 2 | 21 | 47 | 0.3s | 27 MB |
| puppet-complex | 24 | 308 | 755 | 0.3s | 35 MB |
| theforeman (12 modules) | 602 | 6,108 | 13,580 | 1.6s | 72 MB |
| Linux kernel (Gate A) | 70,873 | 2,703,830 | 8,237,401 | 173.4s | 14.5 GB |

No performance regression on the Linux kernel Gate A (zero `.erb` files — the ERB plugin has no hot-path cost on non-ERB corpora).

## 5. Translation Results

### 5.1 Simple Example: `puppet-simple` → `ansible-simple`

**Source:** 1 manifest (8 resources), 1 ERB template (3 variables)

| Metric | Puppet | Ansible |
|---|---|---|
| Resources / Tasks | 8 | 7 (firewall-reload eliminated) |
| Templates | 1 `.erb` | 1 `.j2` |
| Variables | 3 Facter facts | 3 Ansible facts |

**Key translations:**
- `exec` firewall-cmd pattern → `ansible.posix.firewalld` (idiomatic improvement)
- `subscribe` → `notify:` handler
- `<%= @fqdn %>` → `{{ ansible_fqdn }}`

**Status:** ✅ Syntax check passes. Deployed and verified on live agent (web server served translated page). Agent node auto-stopped with sandbox — re-deploy to re-verify.

### 5.2 Complex Example: `puppet-complex` → `ansible-complex`

**Source:** 10 manifests, 14 ERB templates, 3 Ruby files, 5 Hiera data files, Hiera 5 hierarchy

| Metric | Puppet | Ansible |
|---|---|---|
| Profiles / Roles | 6 profiles, 3 roles | 6 roles, 2 plays |
| Manifests | 10 `.pp` | 6 `tasks/main.yml` + 6 `handlers/main.yml` |
| Templates | 14 `.erb` | 14 `.j2` |
| Hiera data files | 5 `.yaml` (4-level hierarchy) | 5 inventory var files |
| Custom type + provider | 2 Ruby files | 1 Python module (`library/webapp.py`) |
| Custom fact | 1 Ruby file | 1 Bash script (`facts.d/webapp_status.sh`) |
| Graph nodes | 308 | — |
| Graph edges | 755 | — |

**Complexity features exercised:**

| Challenge | Puppet Pattern | Ansible Solution |
|---|---|---|
| Hiera 4-level hierarchy | `nodes/` → `roles/` → `os/` → `common.yaml` | `host_vars/` → `group_vars/{role}.yml` → `group_vars/{os}.yml` → `group_vars/all.yml` |
| Namespace flattening | `profile::base::ntp_servers` | `ntp_servers` |
| Dynamic resource iteration | `$vhosts.each \|$name, $vhost\|` | `loop: "{{ vhosts \| dict2items }}"` |
| Cross-class scope lookups | `scope['profile::app::environment']` | Direct variable reference (flattened scope) |
| Ruby method chains (ERB) | `@hostname.downcase`, `.gsub(/[^a-z0-9]/, '_')` | `{{ ansible_hostname \| lower }}`, `{{ \| regex_replace }}` |
| Structured fact access | `@facts['os']['family']` | `{{ ansible_os_family }}` |
| Conditional blocks | `unless @db_host.nil? \|\| @db_host == 'localhost'` | `{% if db_host is defined and db_host != 'localhost' %}` |
| Custom type/provider | Ruby class with create/destroy/exists? | Python `AnsibleModule` with state management |
| Custom fact | `Facter.add` with dir iteration + PID check | Bash script outputting JSON for `ansible_local` |
| Puppet `exec` firewall-cmd | 2 execs + refreshonly reload | `ansible.posix.firewalld` with `immediate: true` |
| Puppet ordering arrows | `Class[a] -> Class[b] -> Class[c]` | Role ordering in play's `roles:` list |
| Hiera-driven classification | `lookup('role')` → `case` in site.pp | Inventory groups → play `hosts:` |

**Status:** ✅ Syntax check passes. Awaiting live infrastructure to deploy and verify end-to-end.

## 6. Gap Analysis Status

| Gap | Original Status | Current Status | Notes |
|---|---|---|---|
| **Gap 1: `.pp` parsing** | Open | ✅ **Closed** | rgctl Puppet Tier 1 plugin (upstream) |
| **Gap 2: ERB→Jinja2** | Open | ✅ **Closed** (T1–T3) | rgctl ERB plugin with translation hints ([PR #101](https://github.com/sshaaf/rgctl/pull/101)) |
| **Gap 3: Hiera hierarchy** | Open | ✅ **Closed** (manual) | Demonstrated in puppet-complex: 4-level hierarchy → inventory vars. Automated mapper tool still pending. |
| **Gap 4: Facter facts** | Open | ✅ **Partially closed** | ~10 mappings used in examples. Full mapping table (~100 entries) pending. |
| **Gap 5: Custom types** | Open | ✅ **Demonstrated** | webapp type/provider → Python Ansible module. LLM-assisted at scale. |

## 7. Tools and Skills Used

| Tool | Role |
|---|---|
| **rgctl** (Puppet + ERB plugins) | Knowledge graph: index → query → migration plan |
| **migIQ** (mig-rgctl, mig-plan, mig-execute) | Workflow orchestration: discover → prompt → plan → execute |
| **Ansible** | Infrastructure provisioning + target deployment |
| **AWS** (sandbox) | EC2 instances, VPC, Route53, security groups |

## 8. Key Findings

### 8.1 Graph-backed translation provides completeness guarantees

Every Puppet resource, template variable, fact reference, and class dependency is a node or edge in the rgctl graph. After translation, cross-referencing the graph against the Ansible output confirms 100% coverage — no silent gaps.

### 8.2 ERB→Jinja2 is ~95% deterministic

Of the 125 ERB blocks in puppet-complex, all fell into Tiers 1–3 (regex, structural rules, Jinja2 filters). Zero blocks required LLM fallback. The tier classification and Jinja2 hints in the ERB plugin metadata made translation mechanical.

### 8.3 Hiera→Ansible variable mapping is the hardest conceptual gap

While the actual file conversion is straightforward (YAML→YAML), the semantic mapping requires understanding:
- Puppet namespace flattening (`profile::base::ntp_servers` → `ntp_servers`)
- Hierarchy level → inventory precedence mapping
- Merge strategy differences (Hiera deep merge vs Ansible variable precedence)

This is the area most likely to need a dedicated tool for enterprise-scale codebases.

### 8.4 Custom types/providers are rare but high-effort

Most Puppet modules use built-in types (`package`, `service`, `file`, `exec`). Custom types are the exception. When they exist, graph-assisted LLM translation (with call graph and blast radius context) produces better results than raw file-by-file LLM translation.

### 8.5 Idiomatic improvements happen naturally

Several Puppet patterns translate to better Ansible idioms:
- `exec` + `unless` + `notify` (firewall-cmd) → single `ansible.posix.firewalld` call
- `exec` with `refreshonly` → eliminated entirely (module handles state)
- Puppet ordering arrows → Ansible role ordering in play definition

## 9. Repository Structure

```
xform/
├── docs/
│   ├── experiment-report.md      ← this report
│   ├── gap-analysis.md           ← detailed gap analysis with options
│   └── erb-to-j2-architecture.md ← ERB→Jinja2 translation design
├── examples/
│   ├── puppet-simple/            ← source: 1 manifest, 1 ERB, 8 resources
│   ├── ansible-simple/           ← target: translated, verified on live agent
│   ├── puppet-complex/           ← source: 10 manifests, 14 ERB, Hiera, custom type
│   └── ansible-complex/          ← target: translated, syntax-checked
└── infra/
    └── puppet/                   ← AWS infrastructure provisioning
```

## 10. Next Steps

1. **Re-provision AWS sandbox** and deploy both `ansible-simple` and `ansible-complex` for live verification
2. **Build automated fact mapping table** (`fact-map.yml`, ~100 entries) for the ERB plugin
3. **Build Hiera hierarchy mapper** tool for enterprise-scale codebases
4. **Test on a real-world Puppet codebase** (e.g., theforeman modules) to validate at scale
5. **Upstream ERB plugin** — address any remaining PR feedback on [sshaaf/rgctl#101](https://github.com/sshaaf/rgctl/pull/101)
6. **Automate end-to-end** — script that runs `rgctl discover` → extracts graph → generates Ansible role scaffolding
