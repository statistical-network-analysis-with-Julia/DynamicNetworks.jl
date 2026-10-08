# Changelog

All notable changes to DynamicNetworks.jl are documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the package adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - Unreleased

First public release. Activity semantics follow R networkDynamic 0.12 and are
checked against it by a golden fixture.

### Renamed

- **The package and module are now `DynamicNetworks`** (directory and
  repository `DynamicNetworks.jl`); the package was previously developed as
  `NetworkDynamic.jl`. That name is one letter from `NetworkDynamics`, an
  unrelated package in Julia's General registry, which invited confusion and
  misinstalls. Write `using DynamicNetworks` where code said
  `using NetworkDynamic`. The UUID is unchanged, and so are the type and
  function names (`DynamicNetwork`, `activate!`, `network_extract`, …). Its
  dependency `Networks` is likewise renamed `NetworkCore`.

### Breaking

- **Elements with no spells are active by default**, as in R
  (`active.default = TRUE`). A network built from edge spells alone now
  extracts its vertices and edges instead of an empty network. Queries and
  extractions take `active_default=false` for the old behaviour. An element
  whose spells were all removed is inactive.
- **Activation merges spells**, as R's `activate.*` do: overlapping and
  adjacent spells coalesce, and a point spell inside an interval is absorbed.
  A tie activated wave by wave is one spell. `add_spell!(...; merge=false)`
  keeps spells as given.
- `deactivate!` on an element with no spells cuts the interval out of
  `(-Inf, Inf)` (axis extremes on calendar axes) instead of doing nothing.
- `network_collapse` is R's `network.collapse`: an edge needs both endpoints
  active, and `rule=:all` accepts coverage by adjacent spells. All vertices
  are still kept.
- `DynamicNetwork` gains a directedness parameter, `DynamicNetwork{T,Time,D}`,
  and wraps a concrete `Network{T,D}`. `DynamicNetwork{T,Time}(n; directed)`
  still constructs one.
- **`get_observation_period` returns `nothing` when no window was given**, as
  R's `net.obs.period` is `NULL`, instead of the placeholder `(0, 1)`.
  Nothing is derived from the data: R's packages use different ranges for a
  network without a window, and TSNA.jl and NDTV.jl now apply them. `show`
  prints "none set", `get_timing_info(dnet).observation_period` is `nothing`,
  and an extraction's report no longer names a window that was never given.
- `spell_duration` of a spell with an unbounded side (`±Inf`, or
  `typemin`/`typemax` on integer and calendar axes) is unbounded — `Inf`,
  `typemax`, `Millisecond(typemax(Int64))` or `Day(typemax(Int64))` — instead
  of an overflowed subtraction (`-1` on an `Int` axis for an element with no
  spell record).
- Unknown vertices, and edges the base network cannot hold (a self-loop with
  `loops=false`, a within-mode tie of a two-mode network), are an
  `ArgumentError` instead of being stored.
- Point (zero-duration) spells `[t, t)` are instantaneous events active
  exactly at `t`.

### Added

- **Panel constructor**: `DynamicNetwork(networks; onsets, termini, start)`
  and `as_dynamic_network(networks; ..., report)` build a dynamic network from
  a vector of static networks, as R's `networkDynamic(network.list = ...)`
  does, with its discrete spells (each panel one time step long by default),
  merged per element. A golden fixture of 40 random panels pins it against
  networkDynamic.
- Public `DynamicNetworks.unbounded_spell(Time)`: the spell covering the whole
  axis, which TSNA.jl and NDTV.jl share.
- A PrecompileTools workload: the time to the first result drops from
  about 3.3 s to 0.6 s.
- `active_default` keyword on `is_active`, `active_vertices`, `active_edges`,
  `network_extract`, `network_slice`, `network_collapse`,
  `get_vertex_activity` and `get_edge_activity`.
- `get_change_times` (R's `get.change.times`).
- `merge_spells!(dnet)` merges every element; public
  `DynamicNetworks.merge_spell_vector`.
- `deactivate!`, `get_vertex_activity`, `get_edge_activity`.
- `retain_all_vertices` on extraction; renumbered snapshots record original
  IDs in the `:vertex_pid` vertex attribute.
- Interval filtering (`onset`, `terminus`, `rule`) for `network_collapse`.
- Conversion reports: `as_dynamic_network`, `network_extract` and
  `network_collapse` accept `report=true` and name what they could not carry.
- Public `spell_active_at` and `elapsed_seconds` helpers for temporal
  consumers.
- `mutation_count`, so downstream packages can cache derived indexes.
- A golden fixture from R networkDynamic (80 random cases: stored spells,
  extraction, collapse, reconciliation), runnable docstring examples for every
  export, and Aqua checks.

### Fixed

- `merge_spells!` dropped a point spell at an adjacent spell's terminus.
- `reconcile_activity!` dropped point spells and censoring flags, and clipped
  edges of vertices without spells to the observation window.
- `network_collapse(rule=:all)` required a single spell to cover the interval.
- `get_timing_info` failed on a network with edge spells but no vertex spells.
- `as_dynamic_network` dropped attributes, the `loops` and two-mode flags and
  the missing-dyad mask; extraction and collapse dropped the mask, network
  attributes and the `loops` flag.
- `rule=:all` queries consider the union of adjacent or overlapping spells;
  a point query at a terminus is inactive.
- An observation window given by one end only is refused with an
  `ArgumentError`. It used to take the other end from the placeholder
  `(0, 1)`: `observation_end=10` gave the window `(0, 10)`, and
  `observation_start=5` failed with "onset must be <= terminus". For an
  open-ended window, pass the axis extreme (`Inf`) explicitly. An inverted
  window is refused by name, and a refused `set_observation_period!` no longer
  leaves the stored window half-changed.
- The `vertex=` and `edge=` keywords (`activate!`, `deactivate!`,
  `add_spell!`, `remove_spell!`, `get_spells`, `merge_spells!`, `is_active`,
  `get_activity_range`) take ids of any `Integer` type. On a
  `DynamicNetwork{Int32}` a literal `vertex=1` or `edge=(1, 2)` threw a
  `TypeError`.

### Known limitations

Kept in sync with the README "Not implemented" section:

- No time-varying network attributes and no attribute deactivation.
- No `network.collapse` attribute aggregation (`activity.count`,
  `activity.duration`, TEA summaries); no `earliest`/`latest` rules.
- No `trim.spells`, `reconcile.edge.activity(mode="match.to.vertices")` or
  `reconcile.vertex.activity`.
- No spell data-frame import/export (`networkDynamic(edge.spells=)`,
  `as.data.frame.networkDynamic`) and no `read.son`.
- No persistent IDs beyond the `:vertex_pid` attribute, so panels with
  different vertex sets cannot be matched.
- One observation window; no multi-spell `net.obs.period` or time-unit
  metadata.
- No active-subset helpers (`get.neighborhood.active`, `is.adjacent.active`,
  `network.dyadcount.active`, `add.vertices.active`, ...), age functions,
  `adjust.activity`, `delete.edge.activity`/`delete.vertex.activity`,
  `when.edge.attrs.match`, `activate.edge.value`, `search.spell`,
  `spells.hit` or `%t%`/`%k%`.
- No hyperedges or multiplex edges.
