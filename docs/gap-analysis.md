# xform — Gap Analysis: Puppet → Ansible Translation Pipeline

> **Date:** 2026-09-29
> **Status:** Planning
> **Context:** Using rgctl as the completeness backbone for translating Puppet to Ansible

## Executive Summary

rgctl's plugin API already defines Puppet and Ansible symbol types (`PuppetModule`, `PuppetClass`, `PuppetResource`, `PuppetVariable`, `PuppetFact`, `AnsiblePlaybook`, `AnsibleTask`, `AnsibleRole`, etc.) and the corresponding edge types (`IncludesRole`, `ExecutesTask`, `NotifiesHandler`, `UsesVariable`, `RendersTemplate`). The GQL parser, graph schema, and graph builder all wire these types through. However, **no language plugins exist yet to populate them**. The graph plumbing is ready; the extractors are the gap.

Five gaps must be closed before the pipeline can guarantee full translation coverage.

---

## Gap 1: Puppet Manifest (`.pp`) Parsing

### Problem

Puppet manifests use a custom DSL (not Ruby). rgctl's Ruby plugin ignores `.pp` files. The manifests contain resource declarations, class definitions, node definitions, include/require statements, and variable references — the primary surface to translate.

### What Exists

- **tree-sitter-puppet** (crates.io v1.3.0, MIT) — full grammar with rich AST:
  - `resource_declaration` (with type, title, attributes, virtual/exported markers)
  - `class_definition` (with parameters, inheritance, block body)
  - `defined_resource_type`
  - `node_definition` (with node\_name patterns)
  - `include_statement` / `require_statement`
  - `variable` (with class\_identifier scoping)
  - `function_call` (lookup, template, hiera, etc.)
  - `relation` (ordering arrows `->` and `~>`)
  - `resource_reference`, `resource_collector`, `resource_default`

- rgctl plugin API already has: `PuppetModule`, `PuppetClass`, `PuppetDefinedType`, `PuppetResource`, `PuppetVariable`, `PuppetFact` symbol types

### Options

#### A. Add Puppet Plugin to rgctl *(Recommended)*

**Effort:** ~2–3 days for core extraction

- Create `crates/rgctl-lang-puppet` with `tree-sitter-puppet`
- Implement `LanguagePlugin` trait: `extract_symbols` + `extract_relations`
- Map AST nodes to existing rgctl symbol types:

  | tree-sitter AST Node | rgctl Symbol / Edge |
  |---|---|
  | `resource_declaration` | `PuppetResource` |
  | `class_definition` | `PuppetClass` |
  | `defined_resource_type` | `PuppetDefinedType` |
  | `node_definition` | `PuppetModule` (or new `PuppetNode` type) |
  | `variable` | `PuppetVariable` |
  | `include_statement` | `IncludesRole` relation |
  | `require_statement` | `DependsOn` relation |
  | `function_call(template)` | `RendersTemplate` relation |
  | `relation` (`->` / `~>`) | `NotifiesHandler` / `DependsOn` edges |

- Register in `crates/rgctl-languages/src/lib.rs`
- Add to `languages.toml`: `extensions = ["pp"]`, `handler = "custom"`

**Pro:** Full graph integration — blast radius, migration planner, GQL queries all work natively on Puppet manifests. Single `discover` indexes everything.

**Con:** Requires Rust development, contributing upstream to rgctl.

#### B. Standalone Python Parser *(Alternative)*

**Effort:** ~1–2 days

- Use tree-sitter Python bindings + `tree-sitter-puppet` grammar
- Write a Python script that parses `.pp` files and emits a JSON graph
- Import the JSON into the xform pipeline alongside rgctl output

**Pro:** Faster to prototype, doesn't require modifying rgctl.

**Con:** Two separate graphs; no unified blast radius or migration planner. Loses the "single source of truth" property.

#### C. Use SousChef MCP Tools *(Supplement)*

[SousChef](https://github.com/kpeacocke/souschef) provides 95 MCP tools including puppet manifest analysis and conversion. It recognizes 14 Puppet resource types and maps 10 to `ansible.builtin` modules.

**Pro:** Already built, AI-assisted for complex constructs.

**Con:** No graph integration; task-by-task approach (the problem we're solving).

#### D. Use p2a CLI *(Supplement)*

[puppet-to-ansible](https://pypi.org/project/puppet-to-ansible/) (PyPI v0.1.2) converts modules, Hiera data, manifests. Maps 20+ resource types. Handles ERB→Jinja2, notify→handlers, `params.pp`→defaults.

**Pro:** Most complete standalone converter.

**Con:** Same as SousChef — no graph, no coverage guarantee.

### Recommendation

Option A (rgctl plugin) as the primary approach. Options C/D as reference implementations and validation — run them in parallel and diff against our graph-based output to catch anything we miss.

---

## Gap 2: ERB → Jinja2 Template Translation

### Problem

Puppet templates use ERB (Embedded Ruby). Ansible uses Jinja2. Both are well-defined template languages with programmatic constructs. The translation is structural:

| ERB | Jinja2 |
|---|---|
| `<%= @variable %>` | `{{ variable }}` |
| `<%= scope['var'] %>` | `{{ var }}` |
| `<% if @condition %>` | `{% if condition %}` |
| `<% end %>` | `{% endif %}` |
| `<% @array.each do \|item\| %>` | `{% for item in array %}` |
| `<% end %>` | `{% endfor %}` |
| `<%# comment %>` | `{# comment #}` |
| `<%= @facts['os']['name'] %>` | `{{ ansible_os_family }}` |

### What Exists

- **tree-sitter-embedded-template** (crates.io v0.25.0) — parses ERB/EJS structure, identifies code blocks (`<% %>`), output blocks (`<%= %>`), comments (`<%# %>`)
- No standalone ERB→Jinja2 tool exists as a library

### Options

#### A. Build a Dedicated ERB→Jinja2 Transformer *(Recommended)*

**Effort:** ~2 days

- Python tool (`erb2j2`) using `tree-sitter-embedded-template` bindings
- Parse ERB: identify expression blocks, code blocks, comments
- For each block, apply regex-based Ruby→Jinja2 translation rules:

  | Ruby (ERB) | Jinja2 |
  |---|---|
  | `@variable` | `variable` (strip `@`) |
  | `scope['x::y']` | `hostvars[x_y]` or var lookup |
  | `.each do \|x\| / end` | `for x in / endfor` |
  | `if/elsif/else/end` | `if/elif/else/endif` |
  | `unless` | `if not` |
  | `.nil?` | `is none` |
  | `.empty?` | `\| length == 0` |
  | `.include?(x)` | `x in var` |
  | `.downcase` / `.upcase` | `\| lower` / `\| upper` |
  | `.strip` | `\| trim` |
  | `.length` / `.size` | `\| length` |

- Handles facts mapping: `@fqdn` → `ansible_fqdn`, etc.
- Emits Jinja2 file + a mapping report (what changed and why)

**Pro:** Deterministic, testable, no LLM needed for mechanical transforms. Can be run as a pre-processing step before the graph analysis.

**Con:** Complex Ruby expressions inside ERB may need LLM fallback.

#### B. Add ERB Extraction to rgctl *(Supplement)*

- Register `.erb` files with `tree-sitter-embedded-template`
- Extract variable references as `PuppetVariable` → `RendersTemplate` edges
- This gives graph coverage but NOT translation — use alongside Option A

**Pro:** Templates appear in the dependency graph.

**Con:** Doesn't do the actual ERB→Jinja2 conversion.

#### C. LLM-Only Translation *(Fallback)*

Feed each ERB template to an LLM with the conversion rules.

**Pro:** Handles arbitrary Ruby expressions.

**Con:** Non-deterministic, hard to validate at scale.

### Recommendation

Option A (`erb2j2` tool) for the mechanical transformation, combined with Option B (ERB in rgctl graph) for coverage tracking. LLM fallback for complex Ruby expressions that the regex rules can't handle.

---

## Gap 3: Hiera Data → Ansible Variable Hierarchy

### Problem

Puppet uses Hiera for hierarchical data lookup. Hiera has a configured hierarchy (e.g., per-node, per-OS, per-environment, common) with merge strategies (first, deep, hash). Ansible has `group_vars`, `host_vars`, role defaults, and variable precedence — conceptually similar but structurally different.

**Key complexity:**

- Hiera hierarchy is defined in `hiera.yaml` (v3 or v5 format)
- Lookups can use merge strategies: first, unique, hash, deep
- Data files are YAML, organized by hierarchy level
- Variable interpolation in hierarchy paths: `%{facts.os.family}`
- Ansible has 22 levels of variable precedence (not hierarchical merge)

### What Exists

- rgctl already has a YAML config format plugin that extracts key paths
- p2a (puppet-to-ansible) has `convert-hiera` subcommand
- `community.general.hiera` Ansible lookup plugin exists but is v3-only and stale
- Direct blog post evidence: *"the least bad way is to load YAML data files directly as Ansible variable files and forget about the fancy hierarchies"*

### Options

#### A. Build a Hiera Hierarchy Mapper *(Recommended)*

**Effort:** ~3–4 days

- Parse `hiera.yaml` to understand the hierarchy structure
- For each hierarchy level, map to Ansible equivalent:

  | Hiera Level | Ansible Equivalent |
  |---|---|
  | `nodes/%{certname}.yaml` | `host_vars/<hostname>.yml` |
  | `os/%{os.family}.yaml` | `group_vars/<os_group>.yml` |
  | `common.yaml` | `group_vars/all.yml` or role `defaults/main.yml` |

- Handle variable interpolation in paths:
  - `%{facts.os.family}` → mapped to Ansible inventory groups
  - `%{environment}` → mapped to Ansible inventory or env var
- Handle merge strategies:
  - **first** (default) → Ansible native precedence (no special handling)
  - **deep/hash merge** → Generate `ansible.cfg` `hash_behaviour=merge`, OR use `combine` filter in templates, OR flatten into single vars file with comment

- Output: inventory structure + variable files + mapping report

**Pro:** Systematic, handles the hierarchy faithfully.

**Con:** Deep merge semantics have no perfect Ansible equivalent.

#### B. Extend rgctl with a Hiera Config Plugin *(Supplement)*

- Parse `hiera.yaml` as a config format plugin
- Create graph nodes for each hierarchy level and data file
- Add edges: `PuppetVariable` → data source file
- Track which variables are looked up from which hierarchy level

**Pro:** Variables appear in the dependency graph with provenance.

**Con:** Doesn't do the actual data migration.

#### C. Simple Flat Copy *(Minimal viable)*

- Copy Hiera YAML data files directly into `group_vars/all.yml`
- Puppet-style keys (`class::param`) → flattened Ansible vars
- Ignore hierarchy; document what was lost

**Pro:** Fast, works for simple cases.

**Con:** Loses the hierarchy semantics entirely.

### Recommendation

Option A (hierarchy mapper) for the data migration, combined with Option B (Hiera in rgctl graph) so every variable lookup in every manifest can be traced to its data source.

---

## Gap 4: Facter Facts → Ansible Facts Mapping

### Problem

Puppet uses Facter for system facts. Ansible uses the setup module (`gather_facts`). The fact namespaces differ significantly:

| Puppet Facter | Ansible Fact |
|---|---|
| `$facts['os']['family']` | `ansible_os_family` |
| `$facts['networking']['ip']` | `ansible_default_ipv4.address` |
| `$facts['kernel']` | `ansible_kernel` |
| `$::fqdn` | `ansible_fqdn` |
| `$::hostname` | `ansible_hostname` |
| `$::osfamily` | `ansible_os_family` |
| `$::operatingsystem` | `ansible_distribution` |
| `$::memorysize` | `ansible_memtotal_mb` |

Additionally, Puppet modules define **custom facts** in `lib/facter/*.rb` — Ruby code that gathers system data. These have no Ansible equivalent and must be rewritten as either:

- Ansible custom facts (executable scripts in `/etc/ansible/facts.d/`)
- Ansible `set_fact` tasks using command/shell modules
- Ansible custom fact modules (Python)

### What Exists

- rgctl Ruby plugin successfully parses `lib/facter/*.rb` files, BUT: `Facter.add` blocks are not methods — they appear as file-level code. The plugin sees the file but extracts limited structure from the blocks.
- No comprehensive Puppet→Ansible fact mapping table exists as a tool

### Options

#### A. Build a Fact Mapping Table + Custom Fact Translator *(Recommended)*

**Effort:** ~2 days (two parts)

**Part 1: Static fact mapping table**

- Comprehensive YAML/JSON table mapping Puppet fact paths to Ansible facts
- Used by the manifest translator to rewrite `$facts['x']` → `ansible_x`
- ~100 common mappings covers 95%+ of real-world usage
- Edge cases flagged for manual review

**Part 2: Custom fact translator** (`lib/facter/*.rb` → `facts.d/`)

- Parse each `.rb` file with rgctl's Ruby plugin
- For each `Facter.add` block:
  - If `setcode` contains a simple command → shell script in `facts.d/`
  - If `setcode` contains file parsing → Python script in `facts.d/`
  - If `setcode` is complex Ruby logic → Python module + flag for review
- Generate the `facts.d` executable with the equivalent logic

**Pro:** Covers both built-in and custom facts systematically.

**Con:** Complex Ruby fact logic needs manual review or LLM assist.

#### B. Enhance rgctl Ruby Plugin for Facter Patterns *(Supplement)*

- Add Facter-specific AST pattern recognition to the Ruby plugin
- Detect `Facter.add(:name)` blocks and extract: fact name, confine conditions, setcode body
- Emit `PuppetFact` symbol type with metadata
- Create edges: `PuppetFact` → `PuppetResource` (where facts are used)

**Pro:** Facts appear in the dependency graph.

**Con:** Ruby plugin changes need to go upstream.

#### C. Treat as Atomic Manual Units *(Minimal)*

- List all files in `lib/facter/`
- For each, generate a TODO task in the migration plan
- Human rewrites each custom fact

**Pro:** Zero tooling effort.

**Con:** Doesn't scale; misses the graph integration.

### Recommendation

Option A (mapping table + translator) for the conversion, combined with Option B (enhanced Ruby plugin) for graph coverage. The mapping table is the highest-value deliverable — it's used everywhere facts appear.

---

## Gap 5: Resource Type/Provider Ruby Code → Ansible Modules

### Problem

Puppet custom types (`lib/puppet/type/*.rb`) and providers (`lib/puppet/provider/*/*.rb`) are Ruby classes that define resources beyond Puppet's built-in set. They are the deepest Ruby code in a Puppet module. The Ansible equivalent is a custom Python module in `library/` or a collection plugin.

This is fundamentally a **Ruby→Python code translation** problem. rgctl's Ruby plugin already extracts the full call graph from these files (tested: 9 functions, 18 nodes, 28 edges from a realistic provider).

### What Exists

- **rgctl Ruby Tier 1 plugin:** full extraction of types, providers, functions
  - Methods: `create`, `destroy`, `exists?`, plus private helpers
  - Call graph: which methods call which
  - Imports: `puppet/type`, `puppet/provider`, external libs
  - External references: `ERB`, `FileUtils`, etc.
- No automated Ruby→Python translator exists for Puppet-specific patterns

### Options

#### A. rgctl Graph + LLM-Assisted Translation *(Recommended)*

**Effort:** ~1–2 days for pipeline; translation is per-module

- Use rgctl as-is: discover the Ruby code, get the full graph
- For each type/provider pair, use the graph to build a translation context:
  - Blast-radius of each method (what depends on it)
  - Call graph (which helpers are used by `create`/`destroy`/`exists?`)
  - Imports (what external Ruby libs need Python equivalents)
- Feed this context + the source to an LLM with a structured prompt:

  > *"Translate this Puppet type+provider to an Ansible module. Here is the call graph: \[JSON\]. Here are the dependencies: \[JSON\]. The module must implement: \[argument\_spec from type params\]"*

- Validate: the Ansible module must handle all methods the provider had

**Pro:** Leverages rgctl's existing Ruby analysis. LLM gets architectural context, not just raw code. Graph ensures nothing is missed.

**Con:** LLM translation needs human review for correctness.

#### B. Template-Based Scaffolding *(Supplement)*

- For each Puppet type, auto-generate an Ansible module skeleton:
  - Type params → `argument_spec`
  - `ensure => present/absent` → `state` parameter
  - Provider methods → module logic placeholders
- Human or LLM fills in the implementation

**Pro:** Consistent structure, less LLM variance.

**Con:** Still needs implementation for the actual logic.

#### C. Keep as Puppet *(Escape hatch)*

- Some custom types/providers may not need translation if the functionality exists in an Ansible collection already
- Map known Puppet Forge modules to Ansible Galaxy equivalents:

  | Puppet Forge Module | Ansible Galaxy Equivalent |
  |---|---|
  | `puppetlabs/apache` | `ansible.builtin` + `geerlingguy.apache` |
  | `puppetlabs/mysql` | `community.mysql` |
  | `puppetlabs/firewall` | `ansible.posix.firewalld` |

**Pro:** No translation needed for well-known modules.

**Con:** Custom in-house types still need translation.

### Recommendation

Option A (graph-assisted LLM translation) for custom types/providers, combined with Option C (Forge→Galaxy mapping) to avoid translating what already has an Ansible equivalent.

---

## Implementation Priority

| Priority | Gap | Effort | Impact |
|---|---|---|---|
| **1 (HIGH)** | Gap 1: Puppet `.pp` plugin | 2–3d | Unlocks the entire pipeline |
| **2 (HIGH)** | Gap 4: Fact mapping table | 2d | Used by every other gap |
| **3 (MED)** | Gap 2: ERB→Jinja2 tool | 2d | Deterministic, high coverage |
| **4 (MED)** | Gap 3: Hiera mapper | 3–4d | Complex but well-scoped |
| **5 (LOW)** | Gap 5: Type/provider translation | 1–2d+ | Per-module LLM-assisted work |

**Total estimated effort for tooling: ~10–13 days**
*(Gap 5 effort is per-module and depends on module complexity)*

---

## Tool Inventory

| Tool | Type | Purpose |
|---|---|---|
| `rgctl` | Existing | Ruby analysis, graph, migration planner |
| `rgctl-lang-puppet` | New plugin | Puppet `.pp` manifest extraction |
| `erb2j2` | New tool | ERB→Jinja2 deterministic transformer |
| `hiera2ansible` | New tool | Hiera hierarchy → Ansible vars mapper |
| `fact-map.yml` | New data | Puppet→Ansible built-in fact mapping |
| `facter2facts` | New tool | Custom fact Ruby → `facts.d` translator |
| `souschef` / `p2a` | 3rd party | Validation/reference for `.pp` translation |
