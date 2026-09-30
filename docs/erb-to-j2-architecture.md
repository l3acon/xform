# ERB → Jinja2 Translation Architecture

> **Context:** Designing a scalable approach for translating Puppet ERB templates to
> Ansible Jinja2 templates. Must work for the simple example now and scale to
> arbitrary complexity for future projects.

## How Puppet Engineers Use ERB in Practice

ERB templates in Puppet are **configuration file generators**. Every `.erb` file
is referenced by a Puppet manifest via `template('module/path.erb')` and receives
its variables from:

1. **Class parameters** — `@port` in ERB maps to `$port` in the calling Puppet class
2. **Facter facts** — `@fqdn`, `@operatingsystem`, or `@facts['os']['family']`
3. **Scope lookups** — `scope['other::class::variable']` for cross-class access
4. **Iterator variables** — `|item|` from `.each` blocks (local to the template)

### Complexity Tiers (from analysis of real-world patterns)

| Tier | Frequency | Pattern | Translation Strategy |
|---|---|---|---|
| **T1** | ~40% | `<%= @var %>`, `end`, `else` | Regex substitution |
| **T2** | ~40% | `if @x == 'y'`, `.each do \|i\|`, `scope['x']`, hash access | Rule-based rewrite |
| **T3** | ~15% | Method chains (`.join`, `.split.first`), complex conditionals (`&&`, `.nil?`) | Rules + Jinja2 filters |
| **T4** | ~5% | `.select { }`, `.map { }`, Ruby stdlib, complex lambdas | LLM-assisted with graph context |

Key insight: **T1+T2 cover ~80% of blocks and are fully deterministic.** T3 adds
another ~15% with Jinja2 filter mappings. Only ~5% needs LLM assistance, and even
those benefit enormously from graph context.

## Architecture: Two-Layer Design

```
                    ┌─────────────────────────────────────────┐
                    │           rgctl knowledge graph          │
                    │                                          │
                    │  PuppetClass ──param──→ @variable        │
                    │       │                    │              │
                    │    template()          used in            │
                    │       │                    │              │
                    │  *.erb file ◄──────── ERB block          │
                    │       │                    │              │
                    │  PuppetFact ←────── @facts[...] ref      │
                    └──────────┬──────────────────┬────────────┘
                               │                  │
                    ┌──────────▼──────────────────▼────────────┐
                    │          erb2j2 translator                │
                    │                                           │
                    │  1. Parse ERB (tree-sitter-embedded-tmpl) │
                    │  2. Classify each block by tier            │
                    │  3. Query graph for variable provenance    │
                    │  4. Apply tier-appropriate translation     │
                    │  5. Emit .j2 file + mapping report         │
                    └───────────────────────────────────────────┘
```

### Layer 1: Graph (rgctl — variable provenance)

The graph answers: **"Where does each ERB variable come from, and what's the
Ansible equivalent?"**

For every ERB template, the graph provides:

- **Which Puppet class calls this template** — from the `template()` function call
  captured by the Puppet plugin as a `Calls` relation
- **What parameters that class has** — from the `PuppetClass` symbol's parameter list
- **What facts are referenced** — from `UsesFact` relations in the manifest
- **Cross-class scope lookups** — from `scope['other::class::param']` which traces
  through the class dependency graph

This context is critical for T3/T4 blocks where the translator needs to know
**what type of data** a variable holds to pick the right Jinja2 filter or construct.

#### Can we use rgctl ad-hoc for this?

**Yes.** Two approaches:

**A. Query rgctl's existing Puppet graph at translation time:**
```bash
# Get all resources and their relationships for a manifest
rgctl -f json gql 'MATCH (n:PuppetResource) RETURN n'

# Get the template() call edge to know which class feeds which template
rgctl -f json gql 'MATCH (c:PuppetClass)-[:CALLS]->(f) WHERE f.name = "template" RETURN c'

# Get class parameters (the variables available to the template)
rgctl -f json gql 'MATCH (c:PuppetClass) RETURN c.name, c.parameters'
```

**B. Build an ERB extraction plugin for rgctl** that adds the templates to the
same graph as the manifests. This is the more scalable approach:

### Layer 1b: ERB Graph Plugin (proposed rgctl enhancement)

A lightweight plugin registered for `.erb` files that:

1. Uses `tree-sitter-embedded-template` to parse the ERB structure
2. For each `<%= %>` / `<% %>` block, extracts:
   - Variable references (`@var`) → `PuppetVariable` nodes
   - Fact references (`@facts[...]`) → `PuppetFact` nodes
   - Scope lookups (`scope['x::y']`) → `References` edges to other classes
   - Iterator variables (local) → `PuppetVariable` with `scope: local` metadata
3. Emits `RendersTemplate` edges connecting the ERB file to its variables

This means `rgctl discover` on a Puppet module would produce a **unified graph**:

```
PuppetClass[profile::nginx]
  ├── param: $port (Integer, default: 80)
  ├── param: $vhosts (Array)
  ├── calls: template('profile/nginx.conf.erb')
  │     └── RendersTemplate → nginx.conf.erb
  │           ├── uses: @port (→ param $port)
  │           ├── uses: @vhosts (→ param $vhosts)
  │           ├── uses: @fqdn (→ fact fqdn)
  │           └── uses: scope['profile::backend::host'] (→ other class)
  └── resource: package[nginx]
```

**The translator then gets complete provenance for every variable in every template.**

### Layer 2: Translator (erb2j2 — the actual conversion)

The translator is a Python tool that:

1. **Parses** the ERB file with `tree-sitter-embedded-template`
2. **Classifies** each block by complexity tier
3. **Queries** the rgctl graph (JSON API or pre-exported JSON) for variable context
4. **Translates** each block using the appropriate strategy:

#### Tier 1: Direct regex substitution
```
<%= @var %>           →  {{ var }}
<% end %>             →  {% endif %} / {% endfor %}  (from block-tracking state)
<% else %>            →  {% else %}
<%# comment %>        →  {# comment #}
```

#### Tier 2: Rule-based structural rewrite
```
<% if @x == 'y' %>               →  {% if x == 'y' %}
<% elsif @x == 'z' %>            →  {% elif x == 'z' %}
<% unless @x %>                  →  {% if not x %}
<% @arr.each do |item| %>        →  {% for item in arr %}
<% @hash.each do |k, v| %>       →  {% for k, v in hash.items() %}
<%= scope['mod::class::var'] %>   →  {{ hostvars[inventory_hostname]['var'] }}
                                     OR {{ var }}  (if graph shows it's a role default)
<%= vhost['key'] %>               →  {{ vhost.key }}  (Jinja2 dot notation)
```

#### Tier 3: Rule-based with Jinja2 filter mapping
```ruby
# Ruby method          →  Jinja2 filter
@arr.join(', ')        →  {{ arr | join(', ') }}
@str.downcase          →  {{ str | lower }}
@str.upcase            →  {{ str | upper }}
@str.strip             →  {{ str | trim }}
@str.split('.').first  →  {{ str.split('.') | first }}
@arr.length            →  {{ arr | length }}
@var.nil?              →  {{ var is none }}    (in conditions)
@var.empty?            →  {{ var | length == 0 }}  (in conditions)
@str.include?('x')     →  {{ 'x' in str }}    (in conditions)
@int.to_s              →  {{ int | string }}
@str.to_i              →  {{ str | int }}

# Complex conditionals
unless @x.nil? || @x.empty?  →  {% if x is defined and x %}

# Fact references (with fact-map.yml lookup)
@facts['os']['family']       →  {{ ansible_os_family }}
@facts['networking']['ip']   →  {{ ansible_default_ipv4.address }}
```

#### Tier 4: LLM-assisted with graph context
For blocks containing `.select { }`, `.map { }`, complex lambdas, or Ruby stdlib:

1. Extract the Ruby expression from the ERB block
2. Query the graph for variable types and context
3. Build a structured LLM prompt:
   ```
   Translate this Ruby ERB expression to Jinja2.
   Expression: @allowed_networks.select { |n| n.include?('/') }
   Variable context from graph:
     - @allowed_networks: Array[String] (Puppet class param, contains CIDR ranges)
   Target: Jinja2 template for Ansible
   ```
4. Validate the LLM output against Jinja2 syntax
5. Flag for human review

### Block-Tracking State Machine

ERB uses `end` to close blocks, but Jinja2 uses `endif`/`endfor`/`endunless`.
The translator maintains a **block stack** to correctly close blocks:

```python
block_stack = []

# <% if ... %>  → push('if')
# <% @x.each do |i| %> → push('for')
# <% unless ... %> → push('if')  (unless → if not)
# <% end %> → pop() → emit {% endif %} or {% endfor %}
```

This is critical for correctness — a simple regex can't know whether `end`
closes an `if` or a `for`.

## Why This Architecture Scales

1. **Graph guarantees completeness** — every variable in every template is traced
   to its source. Missing translations are detectable.

2. **Tiered translation avoids unnecessary LLM calls** — 80%+ is deterministic,
   keeping the output reproducible and fast.

3. **The graph provides type context** — knowing that `@vhosts` is `Array[Hash]`
   lets the translator pick `.items()` vs regular iteration without guessing.

4. **Scope lookups resolve through the graph** — `scope['profile::backend::host']`
   becomes `{{ backend_host }}` only if the graph shows that variable is available
   as a role default. Otherwise it becomes `{{ hostvars[...] }}`.

5. **The mapping report enables verification** — for each template, emit a report
   showing every block, its tier, the translation applied, and the graph context
   used. Human reviewers can audit T3/T4 blocks efficiently.

## Implementation Plan

| Phase | Deliverable | Effort |
|---|---|---|
| **Phase 1** | `erb2j2` Python tool with T1+T2 rules, block stack, fact-map | 1 day |
| **Phase 2** | T3 Jinja2 filter mapping rules | 0.5 day |
| **Phase 3** | rgctl graph query integration for variable provenance | 0.5 day |
| **Phase 4** | ERB extraction plugin for rgctl (optional, for unified graph) | 1-2 days |
| **Phase 5** | T4 LLM fallback with graph context prompts | 0.5 day |

Phase 1-2 is sufficient for puppet-simple and most real-world templates.
Phase 3-5 handles enterprise-scale modules with hundreds of templates.
