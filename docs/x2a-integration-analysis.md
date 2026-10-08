# xform — Comparative Analysis: Graph-Backed vs LLM-First Migration

> **Date:** 2026-10-08
> **Authors:** Matt Fernandez
> **Status:** Analysis complete
> **Context:** Comparing xform's rgctl/migIQ methodology against x2ansible (x2a) and APME to identify integration paths

---

## 1. Purpose

This report compares three projects that touch the infrastructure migration
lifecycle, documents how their methodologies and expectations differ, and
proposes how xform's graph-backed approach could strengthen x2a's production
pipeline.

| Project | Repository | Role |
|---|---|---|
| **x2a** (x2ansible) | [x2ansible/x2a-convertor](https://github.com/x2ansible) | LLM-powered conversion of Chef/Puppet/PS/Salt to Ansible |
| **xform** | [l3acon/xform](https://github.com/l3acon/xform) | Graph-backed Puppet-to-Ansible translation (this repo) |
| **APME** | [ansible/apme](https://github.com/ansible/apme) | Multi-validator static analysis and remediation for Ansible content |

---

## 2. How Each Project Works

### 2.1 x2a — LLM-First Agent Pipeline

x2a is a production-grade CLI tool that converts legacy infrastructure code to
Ansible. It uses LangGraph with LLM-powered agents organized into three phases:

```
Init (scan repo, generate migration-plan.md)
  -> Analyze (deep-dive per module, produce migration-plan-<module>.md)
    -> Migrate (generate Ansible role, lint, validate, retry)
```

**Architecture highlights:**

- All agents inherit from `BaseAgent[S: BaseState]` which provides three
  invocation modes: `invoke_react()`, `invoke_structured()`, `invoke_llm()`
- Technology-specific input agents (`PuppetSubagent`, `ChefSubagent`, etc.)
  parse source code by sending each file to the LLM
- Technology-agnostic export agents (`PlanningAgent`, `WriteAgent`,
  `ValidationAgent`) consume migration plans and produce Ansible roles
- Middleware stack handles telemetry, conversation compaction, goal validation,
  and rules injection
- Validation uses ansible-lint with LLM retry (up to 5 attempts)
- Supports Chef, Puppet, PowerShell, and Salt as source technologies
- Publishes to AAP (Ansible Automation Platform) and generates Molecule tests

**Key design choice:** every analysis step sends source code to an LLM with
crafted prompts. The LLM returns Pydantic structured output
(`ManifestExecutionAnalysis`, `PuppetTemplateAnalysis`, `HieraDataAnalysis`,
etc.). There is no deterministic parse step — the LLM *is* the parser.

### 2.2 xform — Graph-First Translation

xform uses rgctl as a code knowledge graph to index the entire Puppet codebase
before any translation begins. The pipeline is:

```
rgctl discover (index codebase -> knowledge graph)
  -> Query graph (resource inventory, variable provenance, dependency chains)
    -> Tiered translation (T1-T4: regex -> rules -> filters -> LLM fallback)
      -> Verify (cross-reference graph nodes against output)
```

The LLM is invoked only for Tier 4 blocks (~5% of ERB constructs) where Ruby
expressions are too complex for deterministic rules. The graph provides
completeness guarantees: if a node exists in the source graph, it must appear
in the output.

See [experiment-report.md](experiment-report.md) and
[gap-analysis.md](gap-analysis.md) for full details.

### 2.3 APME — Parse-and-Validate Platform

APME is a multi-validator static analysis platform for Ansible content. It does
not convert from other technologies — it validates and remediates existing
Ansible code. Its architecture is relevant because it shares the "deterministic
first, LLM fallback" pattern:

- Parses Ansible YAML into a `ContentGraph` (plays, tasks, blocks, handlers
  as a DAG)
- Fans out validation to 6 parallel gRPC backends: Native (Python graph rules),
  OPA (Rego policy), Ansible (runtime checks), Gitleaks (secrets), Collection
  Health, and Dep Audit (Python CVEs)
- Tier 1 remediation applies deterministic transforms (FQCN fix,
  shell-to-command, key ordering) in a convergence loop with rescan
- Tier 2 remediation optionally invokes Abbenay (AI) for violations without
  deterministic transforms, with human approval
- 100+ rules across lint (L), modernize (M), risk (R), policy (P), and
  secrets (SEC) categories

APME sits **downstream** of both x2a and xform — it would validate the Ansible
output that either project produces.

---

## 3. Methodology Differences

### 3.1 Core Philosophy

| Dimension | **x2a** | **xform** | **APME** |
|---|---|---|---|
| **Source of truth** | LLM extracts structure via prompts | rgctl knowledge graph (deterministic) | ContentGraph from YAML parse |
| **Completeness signal** | GoalValidationMiddleware checks if LLM believes it finished | Graph node coverage verifies nothing was omitted | 6 parallel validators with rescan |
| **LLM role** | Central — analysis, translation, and generation | Fallback — ~5% of ERB blocks, Ruby-to-Python custom types | Optional — Tier 2 remediation only |
| **Determinism** | Non-deterministic (LLM generates fresh each run) | ~95% deterministic (tiered rule-based translation) | Tier 1 fully deterministic; Tier 2 non-deterministic |

### 3.2 The Tiered Pattern

xform and APME independently arrived at the same approach — deterministic
transforms first, LLM escalation only when necessary:

| Tier | **xform** (ERB translation) | **APME** (Ansible remediation) | **x2a** |
|---|---|---|---|
| **T1** | Regex substitution (~40%) | Deterministic transforms (FQCN, key order) | N/A — all LLM |
| **T2** | Rule-based structural rewrite (~40%) | AI-assisted via Abbenay | N/A — all LLM |
| **T3** | Jinja2 filter mapping (~15%) | Manual/cross-file | N/A — all LLM |
| **T4** | LLM fallback with graph context (~5%) | N/A | Everything |

### 3.3 How Each Project Analyzes Puppet Source Code

| Aspect | **x2a** | **xform** |
|---|---|---|
| **Manifests (`.pp`)** | LLM reads file, returns `ManifestExecutionAnalysis` Pydantic model (1 LLM call per file) | `tree-sitter-puppet` extracts AST into `PuppetResource`, `PuppetClass`, `PuppetVariable` graph nodes — zero LLM |
| **ERB templates** | LLM reads file, returns `PuppetTemplateAnalysis` (1 LLM call per file) | `tree-sitter-embedded-template` parses ERB structure; blocks classified into 4 tiers; variable provenance traced through graph |
| **Custom types/providers** | LLM reads Ruby file, returns `CustomTypeAnalysis` (1 LLM call per file) | rgctl Ruby plugin extracts full call graph; LLM assists only for Ruby-to-Python translation |
| **Hiera data** | `HieraAnalysisAgent` uses LLM with file-reading tools (1+ LLM calls) | Parse `hiera.yaml` deterministically; map hierarchy levels to Ansible inventory |
| **Dependency resolution** | LLM-driven discovery + `PuppetDependencyFetcher` for Forge modules | Graph edges (`DependsOnModule`, `IncludesClass`, `RequiresResource`) — dependency chain is a graph traversal |
| **Execution tree** | `PuppetExecutionTreeBuilder` assembles tree from LLM-extracted analysis | Graph traversal from entry class through `IncludesClass` edges |

### 3.4 What x2a Extracts vs What rgctl Provides

x2a's `ManifestAnalysisService` sends each `.pp` file to the LLM and asks it
to fill a `ManifestExecutionAnalysis` Pydantic schema. Every field in that
schema has a deterministic counterpart in the rgctl graph:

| x2a Pydantic Field | rgctl Graph Source |
|---|---|
| `class_name` | `PuppetClass` node `name` property |
| `class_parameters` | `PuppetClass` node `parameters` list |
| `class_inherits` | `InheritsClass` edge |
| `execution_order` (resources) | `PuppetResource` nodes ordered by line number |
| `execution_order` (class includes) | `IncludesClass` edges |
| `execution_order` (conditionals) | AST conditional nodes via tree-sitter |
| `execution_order` (iterations) | AST iteration nodes via tree-sitter |
| `relationship_chains` | `RequiresResource` edges + `->` / `~>` relation nodes |
| `fact_references` | `UsesFact` edges |
| `puppetdb_queries` | Function call nodes matching `puppetdb_query` |

Similarly for template analysis:

| x2a Pydantic Field | rgctl Graph Source |
|---|---|
| `PuppetTemplateAnalysis.variables_used` | `UsesVariable` edges from ERB plugin |
| `PuppetTemplateAnalysis.hiera_lookups` | Function call nodes matching `hiera`/`lookup` |
| `PuppetTemplateAnalysis.loops` | ERB block nodes with iteration classification |
| `PuppetTemplateAnalysis.ruby_logic` | ERB block tier metadata (T1-T4) |

### 3.5 Validation Strategy

| | **x2a** | **xform** | **APME** |
|---|---|---|---|
| **Syntactic** | ansible-lint with LLM retry loop (up to 5 attempts) | N/A (manual verification) | 6 parallel validators, convergence loop rescan |
| **Semantic** | `GoalValidationMiddleware` asks LLM if goal was met | Graph node coverage (every source node must map to output) | N/A (validates Ansible, not translation fidelity) |
| **Functional** | None | Deploy to live infrastructure (AWS sandbox) | None (static analysis only) |

---

## 4. Where x2a Spends Tokens on Structural Extraction

x2a's `PuppetSubagent` analysis pipeline makes one LLM call per source file:

```
PuppetSubagent._analyze_structure()
  |
  +-- _analyze_manifests()         # 1 LLM call per .pp file
  |     ManifestAnalysisService -> invoke_structured(ManifestExecutionAnalysis)
  |
  +-- _analyze_templates()         # 1 LLM call per .erb/.epp file
  |     TemplateAnalysisService -> invoke_structured(PuppetTemplateAnalysis)
  |
  +-- HieraAnalysisAgent           # 1+ LLM calls with tool use
  |     -> invoke_react() with file-reading tools
  |
  +-- _analyze_custom_types()      # 1 LLM call per Ruby file
  |     CustomTypeAnalysisService -> invoke_structured(CustomTypeAnalysis)
  |
  +-- _detect_credentials()        # 1 LLM call
        CredentialDetectionService -> invoke_structured(CredentialAnalysis)
```

For the puppet-complex example (10 manifests, 14 templates, 3 Ruby files,
5 Hiera data files):

| File Type | Count | LLM Calls | What the LLM Extracts |
|---|---|---|---|
| Manifests (`.pp`) | 10 | 10 | Class name, params, execution order, relations, facts |
| Templates (`.erb`) | 14 | 14 | Variables, loops, ruby logic blocks |
| Hiera data (`.yaml`) | 5 | 5+ | Variable mappings, merge strategies, overrides |
| Custom types (`.rb`) | 3 | 3 | Component type, params, behavior |
| Credentials | 1 | 1 | Secret detection |
| **Total** | **33** | **34+** | |

xform extracted the equivalent structural information from puppet-complex in
**0.3 seconds** (308 nodes, 755 edges) with zero LLM tokens (see
[experiment-report.md](experiment-report.md) section 4.3). The graph also
captured relationships the LLM sometimes misses: ordering arrows (`->`,
`~>`), inherited class parameters, and complete variable provenance through
Hiera hierarchy levels.

---

## 5. What xform's Approach Enables

### 5.1 Deterministic ERB Translation

The [ERB-to-J2 architecture](erb-to-j2-architecture.md) demonstrated that
~95% of ERB blocks translate deterministically:

| Tier | Frequency | Strategy | Example |
|---|---|---|---|
| **T1** | ~40% | Regex substitution | `<%= @var %>` to `{{ var }}` |
| **T2** | ~40% | Structural rewrite | `<% @arr.each do \|item\| %>` to `{% for item in arr %}` |
| **T3** | ~15% | Jinja2 filter mapping | `@str.downcase` to `{{ str \| lower }}` |
| **T4** | ~5% | LLM fallback with graph context | `.select { \|n\| n.include?('/') }` |

Of the 125 ERB blocks in puppet-complex, all fell into Tiers 1-3. Zero blocks
required LLM fallback.

**T1 rules** (direct regex):
```
<%= @var %>           ->  {{ var }}
<% end %>             ->  {% endif %} / {% endfor %}  (block stack determines which)
<% else %>            ->  {% else %}
<%# comment %>        ->  {# comment #}
```

**T2 rules** (structural):
```
<% if @x == 'y' %>               ->  {% if x == 'y' %}
<% elsif @x == 'z' %>            ->  {% elif x == 'z' %}
<% unless @x %>                  ->  {% if not x %}
<% @arr.each do |item| %>        ->  {% for item in arr %}
<% @hash.each do |k, v| %>       ->  {% for k, v in hash.items() %}
<%= scope['mod::class::var'] %>   ->  {{ var }}
```

**T3 rules** (filter mapping):
```
@arr.join(', ')        ->  {{ arr | join(', ') }}
@str.downcase          ->  {{ str | lower }}
@str.upcase            ->  {{ str | upper }}
@str.strip             ->  {{ str | trim }}
@arr.length            ->  {{ arr | length }}
@var.nil?              ->  {{ var is none }}
@str.include?('x')     ->  {{ 'x' in str }}
unless @x.nil? || @x.empty?  ->  {% if x is defined and x %}
```

### 5.2 Completeness Guarantee via Graph Coverage

After translation, xform cross-referenced every rgctl graph node against the
Ansible output. Missing translations are detectable — the graph knows what
should exist. This is the guarantee x2a's `GoalValidationMiddleware` cannot
provide: it checks if the LLM *believes* it finished, not whether every source
artifact has a corresponding output artifact.

### 5.3 Idiomatic Improvements from Graph Context

The dependency graph revealed patterns that translate to better Ansible idioms
than file-by-file LLM translation produces:

| Puppet Pattern | Typical LLM Output | Graph-Informed Output |
|---|---|---|
| `exec` + `unless` + `notify` (firewall-cmd) | `ansible.builtin.shell` with `when` | `ansible.posix.firewalld` with `immediate: true` |
| `exec` with `refreshonly: true` | Shell task with conditional | Eliminated (module handles state) |
| `subscribe => File[...]` | Often missed or incorrectly translated | `notify: restart httpd` handler |
| Puppet ordering arrows `->` / `~>` | Implicit task ordering | Explicit role ordering in play `roles:` list |
| `$vhosts.each \|$name, $vhost\|` | Varied loop constructs | `loop: "{{ vhosts \| dict2items }}"` with `loop_control` |

### 5.4 Deterministic Hiera Hierarchy Mapping

Hiera `hiera.yaml` (v5) is a structured YAML file that maps directly to
Ansible inventory:

| Hiera Level | Ansible Location |
|---|---|
| `nodes/%{certname}.yaml` | `host_vars/<hostname>.yml` |
| `roles/%{role}.yaml` | `group_vars/<role>.yml` |
| `os/%{os.family}.yaml` | `group_vars/<os_family>.yml` |
| `common.yaml` | `group_vars/all.yml` or role `defaults/main.yml` |

Namespace flattening (`profile::base::ntp_servers` to `ntp_servers`) is a
deterministic string operation. The xform puppet-complex example demonstrated
the full 4-level hierarchy mapping without any LLM involvement.

---

## 6. Proposed Integration with x2a

### 6.1 Design Principle

Use rgctl for **structural extraction** (what the code *is*) and reserve the
LLM for **semantic decisions** (what the code *should become* in Ansible).

### 6.2 Pipeline Change

```
Current x2a:
  fetch_deps -> discover_context -> [LLM per file] -> exec_tree -> report

With rgctl:
  fetch_deps -> rgctl_discover -> [graph queries] -> exec_tree -> report
                                       |
                              LLM only for semantic gaps
```

### 6.3 Integration Layers

#### Layer 1: Graph-Backed Manifest Analysis

Replace `ManifestAnalysisService` (LLM per `.pp` file) with graph queries
that populate the same `ManifestExecutionAnalysis` Pydantic model:

```python
class ManifestExecutionAnalysis(BaseModel):
    # ... existing fields ...

    @classmethod
    def from_graph(cls, graph_data: dict) -> "ManifestExecutionAnalysis":
        """Build from rgctl graph query results."""
        execution_order = [
            ExecutionItem(
                type="resource",
                resource_type=r["puppet_type"],
                title=r["title"],
                attributes=r.get("attributes", {}),
            )
            for r in sorted(graph_data["resources"], key=lambda r: r["line"])
        ]
        return cls(
            class_name=graph_data["classes"][0]["name"],
            class_parameters=cls._extract_params(graph_data["classes"]),
            execution_order=execution_order,
            relationship_chains=cls._extract_chains(graph_data["relations"]),
            fact_references=cls._extract_facts(graph_data["relations"]),
        )
```

All downstream code (`PuppetExecutionTreeBuilder`, `ReportWriterAgent`,
`ExportState`) is unchanged — they consume the same Pydantic models.

**Eliminates:** ~10 LLM calls for puppet-complex manifests.

#### Layer 2: Tiered ERB-to-Jinja2 Pre-Translation

New `ERBToJinja2Translator` tool that:

1. Parses ERB structure (tree-sitter-embedded-template or regex)
2. Classifies each block by tier using the rules from section 5.1
3. Applies deterministic T1-T3 rules with a block stack for correct
   `endif`/`endfor` emission
4. Delegates T4 blocks to the existing LLM-based `TemplateAnalysisService`
5. Emits `.j2` files that the `WriteAgent` receives instead of raw `.erb`

The block stack is critical — ERB uses `end` for everything, but Jinja2
requires `endif`/`endfor`/`endblock`. The translator maintains a stack:

```
<% if ... %>     -> push('if')     -> {% if ... %}
<% @x.each %>   -> push('for')    -> {% for ... %}
<% end %>        -> pop() = 'for'  -> {% endfor %}
<% end %>        -> pop() = 'if'   -> {% endif %}
```

**Eliminates:** ~14 LLM calls for puppet-complex templates.

#### Layer 3: Graph-Backed Execution Tree

x2a's `PuppetExecutionTreeBuilder` assembles a class execution tree from
LLM-extracted `ManifestExecutionAnalysis` results. With rgctl, the tree is
built from graph dependency edges:

```python
class GraphBackedExecutionTreeBuilder:
    def build_tree(self, entry_class: str) -> ExecutionTreeNode:
        chain = self.graph.traverse_classes(entry_class)
        # Graph traversal gives the complete, verified class chain
        # e.g. role::webserver -> profile::base -> profile::security
        #   -> profile::web -> profile::app -> profile::monitoring
        for cls in chain:
            resources = self.graph.resources_for_class(cls.name)
            # Build nodes from graph data (no LLM)
```

The tree is provably complete — every `include`/`require` is a graph edge.
No silent omissions from LLM inattention.

#### Layer 4: Deterministic Hiera Mapping

Replace `HieraAnalysisAgent` (LLM with file-reading tools) with a
deterministic parser for the common case:

1. Parse `hiera.yaml` to extract hierarchy structure
2. Walk each level, read the data files
3. Flatten Puppet namespaces (`profile::base::ntp_servers` to `ntp_servers`)
4. Map hierarchy levels to Ansible inventory locations
5. Produce `HieraDataAnalysisResult` objects matching x2a's existing interface

The LLM-based agent remains as fallback for unusual Hiera configurations
(custom backends, complex interpolation, hiera-eyaml patterns).

**Eliminates:** ~5 LLM calls for Hiera analysis.

#### Layer 5: Fact Mapping Table

Static YAML mapping (~100 entries) for Puppet-to-Ansible fact substitution:

```yaml
fqdn: ansible_fqdn
hostname: ansible_hostname
operatingsystem: ansible_distribution
operatingsystemrelease: ansible_distribution_version
osfamily: ansible_os_family
ipaddress: ansible_default_ipv4.address
memorysize: ansible_memtotal_mb
processorcount: ansible_processor_count
kernel: ansible_kernel
```

Used by the ERB translator for automatic `<%= @fqdn %>` to
`{{ ansible_fqdn }}` substitution. Eliminates a common source of LLM
inconsistency — the LLM sometimes maps `@operatingsystem` to
`ansible_os_family` instead of `ansible_distribution`.

#### Layer 6: Graph Coverage Validation

New validation step after the export pipeline generates Ansible code:

```python
class GraphCoverageValidator:
    def validate(self, graph, output_dir: Path) -> CoverageReport:
        uncovered = []
        # Every PuppetResource must map to an Ansible task
        for resource in graph.nodes(type="PuppetResource"):
            if not self._find_matching_task(resource, output_dir):
                uncovered.append(resource)
        # Every ERB template must have a .j2 counterpart
        for erb in graph.nodes(type="ERBTemplate"):
            j2_name = erb.name.replace(".erb", ".j2")
            if not (output_dir / "templates" / j2_name).exists():
                uncovered.append(erb)
        # Every Hiera variable must appear in inventory or defaults
        for var in graph.nodes(type="PuppetVariable"):
            if not self._find_variable_in_ansible(var, output_dir):
                uncovered.append(var)
        return CoverageReport(total=graph.node_count(), uncovered=uncovered)
```

Uncovered nodes are reported back to the `WriteAgent` for targeted generation.

---

## 7. Token Impact

Using puppet-complex as the benchmark:

| Analysis Phase | x2a Current | With rgctl | Calls Saved |
|---|---|---|---|
| Manifest analysis | ~10 LLM calls | 0 (graph queries) | 10 |
| Template analysis | ~14 LLM calls | 0-1 (T4 fallback only) | 13-14 |
| Hiera analysis | ~5 LLM calls + tool use | 0 (deterministic parse) | 5 |
| Custom types | ~3 LLM calls | ~3 (Ruby needs LLM) | 0 |
| Credential detection | ~1 LLM call | ~1 (semantic task) | 0 |
| Report writing | 1 LLM call | 1 (richer graph context) | 0 |
| **Analysis total** | **~34 LLM calls** | **~5 LLM calls** | **~29 (~85%)** |

The export pipeline (Planning, Write, Molecule, Review, Validation) remains
LLM-driven but benefits from:

- Pre-translated `.j2` templates — `WriteAgent` receives Jinja2, not raw ERB
- Graph-derived variable provenance included in prompt context
- Fact mapping table for consistent substitutions
- Coverage validation as a completeness check after generation

---

## 8. APME as a Downstream Quality Gate

APME sits downstream of both x2a and xform. It validates and remediates the
Ansible output before it reaches production:

```
Legacy Code (Puppet, Chef, etc.)
        |
        v
  +------------------+
  |  xform / x2a     |  <- GENERATE Ansible
  |  (conversion)    |
  +--------+---------+
           |
           v
  +------------------+
  |     APME         |  <- VALIDATE + REMEDIATE Ansible
  |  (quality gate)  |
  +--------+---------+
           |
           v
      AAP / Git repo
```

### What APME adds beyond ansible-lint

| Capability | ansible-lint (x2a current) | APME |
|---|---|---|
| Rule count | ~30 categories | 100+ rules (L/M/R/P/SEC) |
| Secrets scanning | No | 800+ patterns via Gitleaks |
| Collection health | No | Installed collection checks |
| Python CVE audit | No | pip-audit integration |
| Argspec validation | No | Validates against installed ansible-core version |
| Remediation | Flags only | Tier 1 deterministic transforms in convergence loop |
| AI remediation | LLM retry in WriteAgent | Tier 2 via Abbenay with ContentGraph context |

### Tiered remediation for x2a output

```
x2a WriteAgent output
        |
        v
  APME Tier 1 (deterministic transforms)
        |  auto-fixes: FQCN, key ordering, shell->command, etc.
        v
  APME Validators (rescan dirty nodes)
        |
        v
  Remaining violations?
        |
   +----+----+
   |         |
   No        Yes -> x2a ValidationAgent (LLM) or APME Tier 2 (AI)
   |
   v
  Done
```

APME's Tier 1 deterministic transforms would fix mechanical issues that x2a's
`ValidationAgent` currently sends back to the LLM for retry. This reduces the
LLM retry loop (up to `MAX_VALIDATION_ATTEMPTS=5`) by handling the
deterministic fixes before the LLM sees any errors.

---

## 9. Implementation Estimate

### Phase 1: Foundation (~4 days)

| Task | Effort | Description |
|---|---|---|
| rgctl Python wrapper | 2 days | Run `rgctl discover`, parse JSON graph, expose query API |
| Fact mapping table (`fact_map.yml`) | 1 day | ~100 Puppet-to-Ansible fact mappings |
| Feature flag + wiring | 1 day | `X2A_USE_RGCTL` setting, conditional service injection in `PuppetSubagent` |

### Phase 2: Structural Analysis (~4 days)

| Task | Effort | Description |
|---|---|---|
| `ManifestExecutionAnalysis.from_graph()` | 2 days | Classmethod mapping graph nodes/edges to existing Pydantic models |
| `RgctlManifestAnalysisService` | 1 day | Drop-in replacement for `ManifestAnalysisService` |
| `GraphBackedExecutionTreeBuilder` | 1 day | Build tree from graph edges instead of LLM output |

### Phase 3: Template Translation (~3 days)

| Task | Effort | Description |
|---|---|---|
| `ERBToJinja2Translator` (T1-T3) | 2 days | Deterministic translation rules with block stack state machine |
| T4 LLM fallback integration | 1 day | Delegate complex blocks to existing `TemplateAnalysisService` |

### Phase 4: Hiera + Coverage (~3 days)

| Task | Effort | Description |
|---|---|---|
| `DeterministicHieraMapper` | 2 days | Parse `hiera.yaml`, map hierarchy, flatten namespaces |
| `GraphCoverageValidator` | 1 day | Post-export node coverage check in export workflow |

**Total: ~14 days**

The implementation is additive — the graph layer feeds data into x2a's
existing agent pipeline through the same Pydantic interfaces. All downstream
code (`ReportWriterAgent`, `ExportState`, `ToAnsibleSubagent`) is unchanged.
A feature flag controls whether the graph-backed or LLM-backed analysis
services are used, so there is no regression risk.

---

## 10. Risks and Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| **rgctl binary dependency** — Rust binary complicates Docker/CI | Medium | Subprocess wrapper (same pattern as ansible-lint). Optional: `X2A_USE_RGCTL=false` (default) requires no rgctl install |
| **Puppet plugin coverage** — may not handle all Puppet constructs (virtual resources, collectors, complex metaparameters) | Medium | Per-file fallback to LLM-based `ManifestAnalysisService` when graph data is incomplete. Not all-or-nothing |
| **ERB edge cases** — enterprise codebases may have Ruby patterns beyond T1-T3 (custom methods, inline requires) | Low | Conservative tier classification — anything not confidently T1-T3 falls to T4 (existing LLM pipeline). xform saw 0% T4 in puppet-complex, but the path exists |
| **Graph staleness** — source files change between discover and export | Low | `rgctl discover` runs at analysis start (<2s even for large corpora). Source dir is read-only during analysis |
| **Scope to other technologies** — this covers Puppet only | Low | Modular: each technology's `*SubAgent` independently chooses analysis backend. Other technologies continue using LLM unchanged |

---

## 11. Summary

xform's experiment demonstrated that the structural extraction x2a performs via
LLM calls — parsing manifests, classifying ERB blocks, tracing Hiera
hierarchies, building execution trees — is work a deterministic parser handles
with better accuracy, zero token cost, and provable completeness.

The integration path is not a rewrite. It is a **pre-analysis layer** that
feeds verified structural data into x2a's existing agent pipeline through the
same Pydantic interfaces. The LLM remains essential for what it does well:
semantic translation decisions, Ansible code generation, complex Ruby-to-Python
conversion, and creative problem-solving. The graph handles what the LLM does
poorly: exhaustive enumeration, guaranteed completeness, and deterministic
pattern matching.

---

## References

- [xform experiment report](experiment-report.md)
- [xform gap analysis](gap-analysis.md)
- [xform ERB-to-J2 architecture](erb-to-j2-architecture.md)
- [xform rgctl benchmark](final_benchmarc_report_rgctl_vs_baseline.md)
- [APME architecture](https://github.com/ansible/apme/tree/main/docs/architecture)
- [APME README](https://github.com/ansible/apme)
- [rgctl ERB plugin PR](https://github.com/sshaaf/rgctl/pull/101)
