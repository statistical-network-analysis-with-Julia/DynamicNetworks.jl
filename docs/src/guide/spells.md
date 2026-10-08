# Spells and Activity

This guide covers the `Spell` type and all operations for managing activity spells on vertices and edges in a dynamic network.

## The Spell Type

A `Spell{Time}` represents a time interval during which a network element is active. The interval is half-open: `[onset, terminus)` -- the onset is inclusive and the terminus is exclusive.

### Creating Spells

```julia
using DynamicNetworks

# Basic spell
s = Spell(0.0, 10.0)

# With censoring information
s = Spell(0.0, 10.0;
    onset_censored=true,     # Activity may have started before onset
    terminus_censored=false   # Terminus is known
)
```

### Censoring

Censoring indicates that a spell boundary may not represent the true start or end of activity:

| Flag | Meaning |
|------|---------|
| `onset_censored=true` | Activity may have started before the observed onset |
| `terminus_censored=true` | Activity may continue beyond the observed terminus |
| Both `false` (default) | Both boundaries are observed precisely |

Censoring is metadata -- it does not change how spells are processed in queries or extraction. Downstream packages read it: TSNA.jl does not count a left-censored onset as a tie formation. When spells merge, each flag travels with the bound it describes.

### Point Spells

A spell with `onset == terminus` is an instantaneous event, active exactly at that instant (R networkDynamic's convention):

```julia
p = Spell(5.0, 5.0)
DynamicNetworks.spell_active_at(p, 5.0)   # true
spell_overlap(p, Spell(0.0, 10.0))       # true: 5 lies in [0, 10)
spell_overlap(p, Spell(0.0, 5.0))        # false: the terminus is excluded
```

```julia
# Left-censored: we started observing at t=0, but the tie may predate observation
s = Spell(0.0, 50.0; onset_censored=true)

# Right-censored: observation ended at t=100, but the tie may persist
s = Spell(30.0, 100.0; terminus_censored=true)

# Interval-censored: both boundaries are uncertain
s = Spell(0.0, 100.0; onset_censored=true, terminus_censored=true)
```

### Spell Properties

```julia
s = Spell(5.0, 15.0)

s.onset            # 5.0
s.terminus         # 15.0
s.onset_censored   # false
s.terminus_censored # false
```

### Spell Utilities

```julia
# Duration of a spell
d = spell_duration(s)  # 10.0

# Check if two spells overlap
s1 = Spell(0.0, 10.0)
s2 = Spell(5.0, 15.0)
spell_overlap(s1, s2)  # true

s3 = Spell(10.0, 20.0)
spell_overlap(s1, s3)  # false (s1 ends exactly when s3 starts)

# Comparison (by onset, then terminus)
s1 < s2  # true (onset 0 < 5)
s1 == Spell(0.0, 10.0)  # true
```

### Spell Ordering

Spells are ordered first by onset, then by terminus:

```julia
spells = [Spell(5.0, 15.0), Spell(0.0, 10.0), Spell(5.0, 10.0)]
sort!(spells)
# Result: [Spell(0.0, 10.0), Spell(5.0, 10.0), Spell(5.0, 15.0)]
```

## Adding Spells

### Using activate!

The most common way to add spells is the `activate!` function:

```julia
dnet = DynamicNetwork(5; observation_start=0.0, observation_end=100.0)

# Activate a vertex
activate!(dnet, 0.0, 50.0; vertex=1)

# Activate an edge
activate!(dnet, 10.0, 30.0; edge=(1, 2))
```

`activate!` is a convenience wrapper that creates a `Spell` and calls `add_spell!`. Both **merge** the new spell with the element's stored spells, as R's `activate.*` do (see [Merging Spells](@ref)).

Vertex IDs must exist (`1:nv(dnet)`), and an edge spell must name an edge the base network can hold; anything else is an `ArgumentError` (for example a self-loop on a network created with `loops=false`).

### Using add_spell!

For more control, use `add_spell!` with a `Spell` object:

```julia
# With censoring
add_spell!(dnet, Spell(0.0, 50.0; onset_censored=true); vertex=1)

# Edge spell
add_spell!(dnet, Spell(10.0, 30.0); edge=(2, 3))
```

### Batch Activation

Activate multiple elements at once:

```julia
# Activate vertices 1 through 5 from time 0 to 100 (every vertex must
# exist: activating vertex 6 of this 5-vertex network is an ArgumentError)
activate_vertices!(dnet, collect(1:5), 0.0, 100.0)

# Activate several edges simultaneously
edges = [(1, 2), (2, 3), (3, 4), (4, 5)]
activate_edges!(dnet, edges, 5.0, 50.0)
```

### Edge Auto-Creation

When you add a spell to an edge that does not exist in the underlying static network, the edge is automatically created:

```julia
dnet = DynamicNetwork(5; observation_start=0.0, observation_end=10.0)
# No edges exist yet

activate!(dnet, 1.0, 5.0; edge=(1, 2))
# Edge (1,2) is now in the base network and has one spell
```

## Removing Spells

### Deactivating an Interval

`deactivate!` removes activity in `[onset, terminus)`, truncating or splitting stored spells (R's `deactivate.vertices`/`deactivate.edges`):

```julia
dd = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dd, 0.0, 10.0; vertex=1)
deactivate!(dd, 3.0, 6.0; vertex=1)
get_spells(dd; vertex=1)        # [Spell[0.0, 3.0), Spell[6.0, 10.0)]

# Vertex 2 has no spells, so it is active on (-Inf, Inf): deactivation cuts it
deactivate!(dd, 2.0, 4.0; vertex=2)
get_spells(dd; vertex=2)        # [Spell[-Inf, 2.0), Spell[4.0, Inf)]

# R's idiom for "never active"
deactivate!(dd, -Inf, Inf; vertex=3)
is_active(dd, 5.0; vertex=3)    # false
```

On `DateTime`/`Date` axes, which have no infinities, the axis extremes `typemin`/`typemax` stand in for `-Inf`/`Inf`.

### Removing a Stored Spell

Remove a specific stored spell from a vertex or edge:

```julia
# Remove a specific spell
remove_spell!(dnet, Spell(10.0, 30.0); edge=(1, 2))

# The spell must match exactly (onset and terminus)
s = Spell(10.0, 30.0)
remove_spell!(dnet, s; vertex=1)
```

If the specified spell does not exist, the function silently does nothing. Because spells are merged on insertion, a stored spell may be the union of several activations; use `deactivate!` to cut activity out of it. An element whose last spell is removed is inactive (an empty record).

## Retrieving Spells

### Get All Spells

```julia
# Get spells for a vertex
spells = get_spells(dnet; vertex=1)
println("Vertex 1 has $(length(spells)) spells")
for s in spells
    println("  [$(s.onset), $(s.terminus))")
end

# Get spells for an edge
spells = get_spells(dnet; edge=(1, 2))
```

### Convenience Aliases

```julia
# Equivalent to get_spells(dnet; vertex=v)
when_vertex(dnet, 1)

# Equivalent to get_spells(dnet; edge=(i, j))
when_edge(dnet, 1, 2)
```

`get_spells`, `when_vertex` and `when_edge` return the *stored* spells: an element with no record gives an empty vector even though it is active by default. `get_vertex_activity`/`get_edge_activity` follow R's `get.vertex.activity`/`get.edge.activity` and report such an element as `(-Inf, Inf)` (pass `active_default=false` for an empty vector):

```julia
get_vertex_activity(dnet, 5)    # [Spell[-Inf, Inf)] if vertex 5 has no spells
```

### Activity Range

Get the earliest and latest times for an element:

```julia
range = get_activity_range(dnet; vertex=1)
if !isnothing(range)
    println("Vertex 1 active from $(range[1]) to $(range[2])")
end

range = get_activity_range(dnet; edge=(1, 2))
```

## Merging Spells

Spells are kept in R networkDynamic's canonical, merged form: `activate!` and `add_spell!` merge a new spell with the stored ones on insertion, as R's `activate.*` do. A tie activated wave by wave (`[1,2)`, `[2,3)`, ...) is therefore stored as one spell -- one lifetime -- not as a sequence of dissolutions and re-formations.

```julia
dm = DynamicNetwork(4; observation_start=0.0, observation_end=100.0)
activate!(dm, 0.0, 20.0; vertex=1)
activate!(dm, 15.0, 40.0; vertex=1)
activate!(dm, 35.0, 60.0; vertex=1)
get_spells(dm; vertex=1)        # [Spell[0.0, 60.0)]: one contiguous spell
```

To keep spells as given, pass `merge=false` to `add_spell!`; `merge_spells!` then puts them in canonical form (for one element, or for every element when called without `vertex`/`edge`):

```julia
add_spell!(dm, Spell(0.0, 10.0); vertex=2, merge=false)
add_spell!(dm, Spell(10.0, 20.0); vertex=2, merge=false)
get_spells(dm; vertex=2)        # [Spell[0.0, 10.0), Spell[10.0, 20.0)]
merge_spells!(dm; vertex=2)
get_spells(dm; vertex=2)        # [Spell[0.0, 20.0)]
merge_spells!(dm)               # every vertex and edge
```

### Merge Rules

These are R networkDynamic's rules (pinned against R by the package's golden fixture):

- **Overlapping** intervals (s1.terminus > s2.onset) are merged
- **Adjacent** intervals (s1.terminus == s2.onset) are merged
- **Disjoint** intervals (gap between them) remain separate
- A **point spell** `[t,t)` is absorbed by an interval with `onset <= t < terminus` and by an identical point spell; otherwise it is kept. So `[0,5)` and `[5,5)` stay two spells: the point spell is the activity at `t = 5`, which `[0,5)` excludes.

```julia
activate!(dm, 0.0, 5.0; edge=(1, 2))
activate!(dm, 5.0, 5.0; edge=(1, 2))
get_spells(dm; edge=(1, 2))     # [Spell[0.0, 5.0), Spell[5.0, 5.0)]
activate!(dm, 2.0, 2.0; edge=(1, 2))
get_spells(dm; edge=(1, 2))     # unchanged: t = 2 lies in [0, 5)
```

`DynamicNetworks.merge_spell_vector(spells)` returns the canonical form of a spell vector without touching a network.

## Spell Patterns

### Continuous Activity

A vertex or edge active for the entire observation period:

```julia
activate!(dnet, 0.0, 100.0; vertex=1)
```

### Intermittent Activity

Active in separate periods with gaps:

```julia
activate!(dnet, 0.0, 20.0; vertex=1)    # First period
activate!(dnet, 40.0, 60.0; vertex=1)    # Second period
activate!(dnet, 80.0, 100.0; vertex=1)   # Third period
```

### Progressive Formation

Edges form over time:

```julia
activate!(dnet, 0.0, 100.0; edge=(1, 2))   # Exists from start
activate!(dnet, 20.0, 100.0; edge=(2, 3))   # Forms at t=20
activate!(dnet, 50.0, 100.0; edge=(3, 4))   # Forms at t=50
```

### Temporal Ordering

Events with short duration, representing interactions:

```julia
# Each "interaction" lasts a brief period
activate!(dnet, 1.0, 1.1; edge=(1, 2))
activate!(dnet, 3.5, 3.6; edge=(2, 3))
activate!(dnet, 5.0, 5.1; edge=(1, 3))
activate!(dnet, 7.2, 7.3; edge=(3, 2))
```

## Working with Different Time Types

### Float64 (Default)

```julia
dnet = DynamicNetwork(5; observation_start=0.0, observation_end=100.0)
activate!(dnet, 0.0, 50.0; vertex=1)
spell_duration(Spell(0.0, 50.0))  # 50.0
spell_duration(Spell(0.0, Inf))   # Inf
```

### Integer time

Integer axes have no infinities, so `typemin`/`typemax` stand for `-Inf`/`Inf`
(an element with no spell record is active over `(typemin, typemax)`). A spell
reaching either extreme has unbounded duration, reported as `typemax` rather
than computed (the subtraction would overflow):

```julia
using NetworkCore                                    # add_edge!
dnet = DynamicNetwork{Int, Int}(3; observation_start=0, observation_end=10)
add_edge!(dnet.network, 1, 2)                       # no spell record: always active
only(get_edge_activity(dnet, 1, 2))                 # Spell[typemin, typemax)
spell_duration(only(get_edge_activity(dnet, 1, 2))) # typemax(Int)
DynamicNetworks.unbounded_spell(Int) == Spell(typemin(Int), typemax(Int))   # true
```

### DateTime

```julia
using Dates

dnet = DynamicNetwork{Int, DateTime}(5;
    observation_start=DateTime(2024, 1, 1),
    observation_end=DateTime(2024, 12, 31)
)

activate!(dnet, DateTime(2024, 1, 1), DateTime(2024, 6, 30); vertex=1)

s = Spell(DateTime(2024, 1, 1), DateTime(2024, 6, 30))
d = spell_duration(s)  # Millisecond duration
```

### Date

```julia
using Dates

dnet = DynamicNetwork{Int, Date}(5;
    observation_start=Date(2024, 1, 1),
    observation_end=Date(2024, 12, 31)
)

activate!(dnet, Date(2024, 1, 1), Date(2024, 6, 30); vertex=1)

s = Spell(Date(2024, 1, 1), Date(2024, 6, 30))
d = spell_duration(s)  # Day duration
```

## Best Practices

### Spell Management

1. **Merging is automatic**: `activate!` keeps spells merged; `merge_spells!` is needed only after `add_spell!(...; merge=false)`
2. **Check for gaps**: Use `get_activity_range` to verify elements are active when expected
3. **Consistent time types**: All spells in a network must use the same `Time` type
4. **Order matters**: Spells are automatically sorted by onset when added

### Data Quality

1. **Mark censoring**: Use `onset_censored` and `terminus_censored` to document observation boundaries
2. **Validate constraints**: An edge should only be active when both endpoints are active -- use `reconcile_activity!`
3. **Check onset <= terminus**: The `Spell` constructor enforces this, throwing `ArgumentError` otherwise

### Performance

1. **Batch operations**: Use `activate_vertices!` and `activate_edges!` instead of loops
2. **Minimize spell count**: Spells are merged on insertion, which keeps storage and query time down
3. **Use `get_spells` sparingly**: For frequent queries, cache the result rather than calling repeatedly
