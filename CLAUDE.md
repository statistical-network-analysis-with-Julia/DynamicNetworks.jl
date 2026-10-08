# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DynamicNetworks.jl is a Julia port of the R `networkDynamic` package from the StatNet collection. It provides data structures for representing and manipulating dynamic (time-varying) networks with activity spells, time-varying attributes, and network snapshot extraction.

## Development Commands

- **Run tests:** `julia --project -e 'using Pkg; Pkg.test()'` (includes the golden-fixture replay, the docstring-example testset and `Aqua.test_all`)
- **Regenerate the golden fixtures:** `Rscript test/fixtures/r/spell_semantics.R > test/fixtures/spell_semantics.toml` and `Rscript test/fixtures/r/panel_semantics.R > test/fixtures/panel_semantics.toml` (need R with networkDynamic)
- **Build docs:** `julia --project=docs docs/make.jl`
- **Load package in REPL:** `julia --project -e 'using DynamicNetworks'`
- **Instantiate dependencies:** `julia --project -e 'using Pkg; Pkg.instantiate()'`

## Architecture

The entire package lives in a single file: `src/DynamicNetworks.jl`.

### Core Types

- **`Spell{T}`** -- Immutable struct representing a time interval `[onset, terminus)` with optional censoring flags. Supports ordering and overlap checks.
- **`TimeVaryingAttribute{Time, V}`** -- Parallel vectors of values and spells for attributes that change over time (called TEAs, after the R package convention).
- **`DynamicNetwork{T, Time, D}`** -- Mutable struct wrapping a concrete `Network{T, D}` with dictionaries for vertex spells, edge spells, vertex TEAs, and edge TEAs. `T` is the vertex ID type (must be `<:Integer`), `Time` is the timestamp type (typically `Float64` or `DateTime`), `D::Bool` is directedness (so `dnet.network` is concretely typed; `is_directed(dnet)` returns `D`). `DynamicNetwork{T,Time}(n; directed=true, ...)` and `DynamicNetwork(n; ...)` fill in `D`. Fields `observation_period_set::Bool` (was a window given?) and `mutation_count::Int` (bumped on every mutation; TSNA keys its contact cache on it).

### Functional Organization (within the single module)

1. **Spell operations** -- `add_spell!`, `remove_spell!`, `merge_spells!`, `activate!`, `activate_vertices!`, `activate_edges!`
2. **Activity queries** -- `is_active` (point and interval variants with `:any`/`:all` rules), `active_vertices`, `active_edges`, `when_vertex`, `when_edge`
3. **Network extraction** -- `network_extract` (point and interval), `network_slice`, `network_collapse`, `get_timing_info`
4. **Time-varying attributes** -- `set_vertex_attribute_active!`, `get_vertex_attribute_active!`, and edge equivalents
5. **Conversion/reconciliation** -- `as_dynamic_network` (a static network, or a panel: `as_dynamic_network(networks; onsets, termini, start, report)`, which `DynamicNetwork(networks; ...)` calls -- R's `networkDynamic(network.list=)`: panel k active `[onsets[k], termini[k])`, default `start .+ (0:K-1)` of length 1, every vertex active in every panel, spells merged, window `(min onset, max terminus)`, vertices matched by position, base network from panel 1's static attributes, a mask only when all panels share it), `reconcile_activity!`

### Conversion invariants

Both directions between `Network` and `DynamicNetwork` honour the **ecosystem conversion contract** (NetworkCore.jl `src/conversion.jl`): preserve what the target can represent, reject or policy-gate what it cannot, report what was dropped. The full per-path table for the whole ecosystem is `NetworkCore.jl/docs/src/guide/conversion_invariants.md`.

- **`as_dynamic_network` is lossless.** A `DynamicNetwork` *wraps* a `Network`, so the whole static object is carried in by `copy` — directedness, the `loops` flag, two-mode metadata, vertex/edge/network attributes, and the **missing-dyad mask**. It used to rebuild a bare `Network` from `nv(net)`, which silently discarded all of them (a masked network round-tripped to zero masked dyads) and, with `loops=true`, left a self-loop recorded as an edge *spell* while `add_edge!` refused it on the loop-less base network.
- **`network_extract` / `network_collapse` preserve everything a static network can hold**: directedness, `loops`, static vertex/edge/network attributes, and the missing-dyad mask (an unobserved dyad of the base network is unobserved in every snapshot of it — it must not become an absent tie). Two-mode metadata survives only under `retain_all_vertices=true`; renumbering to `1:k` destroys the "vertices `1:k` are mode 1" invariant that the flag encodes.
- What a static network *cannot* hold — spells, TEAs, the observation window, plus mask entries whose endpoints an extraction drops — is named in a `NetworkCore.ConversionReport`: pass `report=true` to get `(net, rep)` and inspect `dropped_fields(rep)` / `is_lossless(rep)`.
- Pinned by the six "Conversion invariants: ..." testsets in `test/runtests.jl`, which cover directed and undirected, with/without attributes, masked dyads with a **present** face value *and* an **absent** one, self-loops, isolates, two-mode networks, overlapping spells, point spells, and observation-window boundaries.

### Activity semantics (R networkDynamic 0.12; pinned by the golden fixture)

- **No spell record = active** (`active.default = TRUE`). A key absent from `vertex_spells`/`edge_spells` means "always active"; a key present with an *empty* vector means "never active" (what `deactivate!`/`remove_spell!` leave). Every query/extraction takes `active_default=true`; the helpers `_record_active_at`/`_record_active_in` dispatch on `nothing` vs a vector. The edge universe is the base network's edge set (`edges(dnet.network)`), never `keys(edge_spells)`; an edge not in the base network is never active.
- **Merge on activation**: `add_spell!` (hence `activate!`, `activate_*!`, `as_dynamic_network`) stores `merge_spell_vector(spells)` unless `merge=false`. Rules: intervals overlapping or adjacent coalesce; a point spell `[t,t)` is absorbed by an interval with `onset <= t < terminus` or an identical point, otherwise kept (`[0,5)` + `[5,5)` stay two). Censoring flags travel with the bound they describe. `merge_spell_vector` is `public` for TSNA.
- `deactivate!` on an element with no record cuts out of `_always(Time)` = `(-Inf, Inf)` (`typemin`/`typemax` on axes without infinities).
- `network_extract`: vertex active; edge active AND both endpoints active. `network_collapse` = the same over `(-Inf, Inf)` or `[onset, terminus)` with `retain_all_vertices=true` (R drops inactive vertices — the one documented divergence; no attribute aggregation).
- `reconcile_activity!` = R `reconcile.edge.activity(mode="reduce.to.vertices")`: intersect each edge's spells (or `(-Inf, Inf)` when it has no record) with both endpoints' (absent record = always active); keeps point spells and censoring.
- A window needs both ends: the constructor refuses `observation_start` or `observation_end` alone (an `ArgumentError`; no placeholder end), and `_check_window` refuses an inverted window before any field changes (also in `set_observation_period!`).
- The `vertex=`/`edge=` keywords of the nine spell/activity functions are `Union{Nothing, Integer}`/`Union{Nothing, Tuple{Integer,Integer}}`, normalised to `T` at entry by `_as_vertex`/`_as_edge`; never type them `T` (literal ids failed on `DynamicNetwork{Int32}`).
- `get_observation_period` returns the explicit window, or `nothing` when none was given (R's `net.obs.period` is `NULL`). Nothing is derived from the data: the derived `[first, last)` window and the `(0, 1)` placeholder it replaced made TSNA/NDTV drop ties at the range's edges. Consumers apply R's rule for the no-window case themselves (TSNA: lifetimes over `unbounded_spell`, tiedDuration/tEdgeDensity/series over the closed range of `get_change_times`; NDTV: closed frame grid) and raise an `ArgumentError` asking for `set_observation_period!` where R would use `(0, 1)`. Downstream code must call it, not read the `observation_period` field (meaningless when `observation_period_set` is false).
- `DynamicNetworks.unbounded_spell(Time)` (public) is `_always(Time)`: `(-Inf, Inf)`, or `(typemin, typemax)` on axes without infinities. `spell_duration` of a spell touching either bound returns `_unbounded_duration(Time)` (`Inf`/`typemax`/`Millisecond(typemax(Int64))`/`Day(typemax(Int64))`, `ArgumentError` otherwise) instead of subtracting the extremes (which overflowed to `-1`); a point spell lasts zero.
- `get_spells`/`when_*` return stored spells (empty when no record); `get_vertex_activity`/`get_edge_activity` are R's view (`(-Inf, Inf)` for no record).
- `add_spell!` validates: vertex in `1:nv`, edge addable to the base network (self-loop needs `loops=true`, two-mode needs cross-mode), else `ArgumentError`.

The golden fixture `test/fixtures/spell_semantics.toml` (80 random directed/undirected cases from `test/fixtures/r/spell_semantics.R`, loaded with `NetworkCore.load_golden`) must agree exactly on stored spells, extraction (instants; intervals under `any`/`all`), collapse edge sets and reconcile. `test/fixtures/panel_semantics.toml` (40 random samplk-style panels from `test/fixtures/r/panel_semantics.R`) pins the panel constructor's stored vertex/edge spells and window. The R-concordance table (every networkDynamic export has a row; check with `getNamespaceExports("networkDynamic")`) and "Not implemented" list live in `docs/src/guide/r_concordance.md`, the README and the CHANGELOG "Known limitations" — keep them in sync.

### Design Patterns

- Keyword dispatch: most functions take `vertex=` or `edge=` keyword arguments to select the target element, throwing `ArgumentError` if neither is provided.
- Undirected edge normalization: edges in undirected networks are stored with `(min, max)` ordering.
- Spells are kept sorted and merged after insertion (`merge_spell_vector`).
- `Graphs.jl` interface methods (`nv`, `ne`, `vertices`, `is_directed`) are forwarded to the underlying `Network`.

## Key Dependencies

- **PrecompileTools.jl** -- the `@compile_workload` at the end of the module (README path, both directedness flavours); keep it in step with the README examples.

- **NetworkCore.jl** -- Local/sibling package (via `[sources]` path dependency at `../NetworkCore.jl`); provides the static network type that `DynamicNetwork` wraps.
- **Graphs.jl** -- Julia standard graph interface; `DynamicNetwork` forwards core methods to it.
- **Dates** -- stdlib; supports `DateTime`/`Date` as timestamp types.

## Conventions

- Julia 1.12+ required (NetworkCore.jl cannot load on earlier versions).
- Mutating functions use `!` suffix (e.g., `activate!`, `reconcile_activity!`).
- All public API is exported at the top of the module file.
- Docstrings use the standard Julia triple-quote format with `# Fields` / `# Type Parameters` sections.
- Spells use half-open intervals: `[onset, terminus)`.
- The package uses parametric types throughout; generic over vertex ID type and time type.
- Behavioral tests live in `test/runtests.jl` (extraction, TEAs, point spells, censoring, DateTime time axes, the R golden fixture). The "Every exported docstring carries a runnable example" testset runs every ```` ```julia ```` block of every exported/public docstring in a fresh module that has only `using DynamicNetworks` (examples needing `nv`/`ne` add `using NetworkCore`); the "Aqua" testset runs `Aqua.test_all` and `detect_ambiguities`. Aqua and Test have `[compat]` entries.
- Point (zero-duration) spells `[t,t)` are instantaneous events, active exactly at `t`.
- `rule=:all` checks continuous coverage by the union of sorted spells, including
  adjacent spells. Point queries use the same half-open semantics.
- Qualified public `spell_active_at` and `elapsed_seconds` are shared with TSNA;
  Dates durations are seconds, numeric durations retain the native time unit.
- Read-only activity queries do not mutate any global cache.
- `network_extract` records original vertex IDs in the `:vertex_pid` vertex attribute when it renumbers; `retain_all_vertices=true` keeps IDs stable.
- TEA lookups return the most recently set matching value when attribute spells overlap.
