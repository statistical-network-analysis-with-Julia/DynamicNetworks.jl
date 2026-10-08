# Time Queries

This guide covers how to query activity status, extract network snapshots, and work with time-varying attributes in DynamicNetworks.jl.

## Activity Queries

### Point-in-Time Queries

The most basic query checks whether a vertex or edge is active at a specific time:

```julia
using DynamicNetworks

dnet = DynamicNetwork(5; observation_start=0.0, observation_end=50.0)
activate!(dnet, 0.0, 30.0; vertex=1)
activate!(dnet, 10.0, 50.0; vertex=2)
activate!(dnet, 5.0, 25.0; edge=(1, 2))

# Point queries
is_active(dnet, 10.0; vertex=1)   # true  (0 <= 10 < 30)
is_active(dnet, 35.0; vertex=1)   # false (30 <= 35)
is_active(dnet, 10.0; edge=(1, 2)) # true  (5 <= 10 < 25)
```

The spell is half-open: `onset <= t < terminus`. This means an element becomes inactive exactly at its terminus time.

Vertices 3, 4 and 5 have no spells, so they are **active at all times** (R's `active.default = TRUE`). Every query and extraction takes `active_default=false` to treat elements without a spell record as inactive:

```julia
is_active(dnet, 10.0; vertex=3)                        # true: no spells
is_active(dnet, 10.0; vertex=3, active_default=false)  # false
```

### Interval Queries

Check activity over a time interval with two rules:

```julia
# Rule :any -- active at ANY point during [10, 35]
is_active(dnet, 10.0, 35.0; vertex=1, rule=:any)  # true (overlaps with [0, 30))

# Rule :all -- active THROUGHOUT [10, 35]
is_active(dnet, 10.0, 35.0; vertex=1, rule=:all)  # false (not active at t=30)

# Active throughout [10, 25]
is_active(dnet, 10.0, 25.0; vertex=1, rule=:all)  # true (contained in [0, 30))
```

| Rule | Meaning | Condition |
|------|---------|-----------|
| `:any` | Active at any point in the interval | Any spell overlaps with `[onset, terminus)` |
| `:all` | Active throughout the entire interval | The union of the spells covers `[onset, terminus)` (adjacent spells count) |

### Listing Active Elements

Get all active vertices or edges at a time:

```julia
# All vertices active at t=15
verts = active_vertices(dnet, 15.0)
println("Active vertices: ", verts)

# All edges active at t=15
edgs = active_edges(dnet, 15.0)
println("Active edges: ", edgs)
```

These functions are useful for computing cross-sectional network statistics at specific time points.

### Complete Activity History

Retrieve all spells for an element:

```julia
# All spells for vertex 1
spells = when_vertex(dnet, 1)
for s in spells
    println("Active from $(s.onset) to $(s.terminus), duration: $(spell_duration(s))")
end

# All spells for edge (1, 2)
spells = when_edge(dnet, 1, 2)

# Activity range (earliest onset to latest terminus)
range = get_activity_range(dnet; vertex=1)
println("First active: $(range[1]), Last active: $(range[2])")
```

## Network Extraction

### Point Extraction

Extract a static `Network` representing the state at a single time:

```julia
using NetworkCore   # nv, ne
using Graphs        # connected_components (Graphs.jl, a separate package)

# Snapshot at t=15
snapshot = network_extract(dnet, 15.0)

# Use with standard network functions
println("Vertices: ", nv(snapshot))
println("Edges: ", ne(snapshot))

# Use with Graphs.jl algorithms
cc = connected_components(snapshot)
println("Components: ", length(cc))
```

### Vertex Re-indexing

When extracting a snapshot, only active vertices are included (here vertices 3, 4 and 5 count, since they have no spells), and they are re-indexed starting from 1; each keeps its original ID in the `:vertex_pid` attribute. An edge is included only when both endpoints are active. Static vertex attributes from the underlying network are carried over; `retain_all_vertices=true` keeps every vertex and stable IDs.

```julia
# If vertices 2, 5, 8 are active at t=10
# They become vertices 1, 2, 3 in the extracted network
snapshot = network_extract(dnet, 10.0)
# nv(snapshot) == 3
```

### Interval Extraction

Extract a network representing activity over a time range:

```julia
# Any activity during [10, 30]: includes elements active at any point
snapshot_any = network_extract(dnet, 10.0, 30.0; rule=:any)

# Active throughout [10, 30]: only elements continuously active
snapshot_all = network_extract(dnet, 10.0, 30.0; rule=:all)
```

Use cases:

- `:any` -- aggregate view of "who interacted during this period"
- `:all` -- stable ties that persisted throughout the period

### Time Series of Snapshots

Extract snapshots at regular intervals for temporal analysis:

```julia
# Snapshots every 10 time units
times = collect(0.0:10.0:100.0)
snapshots = network_slice(dnet, times)

# Compute density time series
densities = Float64[]
for snap in snapshots
    n = nv(snap)
    if n > 1
        max_e = is_directed(snap) ? n * (n - 1) : n * (n - 1) / 2
        push!(densities, ne(snap) / max_e)
    else
        push!(densities, 0.0)
    end
end

for (t, d) in zip(times, densities)
    println("t=$t: density = $(round(d, digits=3))")
end
```

### Collapsing to Static

Collapse the entire dynamic network to a single static network:

```julia
# Ties ever active between ever-active vertices; every vertex is kept
static = network_collapse(dnet)
println("Ever-active edges: ", ne(static))
```

`network_collapse(dnet; onset, terminus, rule)` restricts this to an interval
and equals `network_extract(dnet, onset, terminus; rule, retain_all_vertices=true)`.

## Time-Varying Attributes

Time-varying attributes (TEAs) are attributes whose values change over time. Each value is associated with a spell during which it is valid.

### Setting Vertex TEAs

```julia
# Disease status changes over time
set_vertex_attribute_active!(dnet, 1, :status, "susceptible", 0.0, 10.0)
set_vertex_attribute_active!(dnet, 1, :status, "infected", 10.0, 25.0)
set_vertex_attribute_active!(dnet, 1, :status, "recovered", 25.0, 100.0)

# Numeric attribute
set_vertex_attribute_active!(dnet, 1, :risk_score, 0.1, 0.0, 10.0)
set_vertex_attribute_active!(dnet, 1, :risk_score, 0.9, 10.0, 25.0)
set_vertex_attribute_active!(dnet, 1, :risk_score, 0.05, 25.0, 100.0)
```

### Getting Vertex TEAs

```julia
# Query at a specific time
status = get_vertex_attribute_active(dnet, 1, :status, 5.0)
println(status)  # "susceptible"

status = get_vertex_attribute_active(dnet, 1, :status, 15.0)
println(status)  # "infected"

status = get_vertex_attribute_active(dnet, 1, :status, 50.0)
println(status)  # "recovered"

# Returns nothing if no value is defined at that time
val = get_vertex_attribute_active(dnet, 1, :unknown, 5.0)
println(val)  # nothing
```

### Edge TEAs

```julia
# Set time-varying edge weight
set_edge_attribute_active!(dnet, 1, 2, :weight, 1.0, 5.0, 15.0)
set_edge_attribute_active!(dnet, 1, 2, :weight, 3.5, 15.0, 25.0)

# Query
w = get_edge_attribute_active(dnet, 1, 2, :weight, 10.0)
println(w)  # 1.0

w = get_edge_attribute_active(dnet, 1, 2, :weight, 20.0)
println(w)  # 3.5
```

### Listing TEAs

```julia
# All time-varying vertex attribute names
vertex_teas = list_vertex_attributes_active(dnet)
println("Vertex TEAs: ", vertex_teas)  # [:status, :risk_score]

# All time-varying edge attribute names
edge_teas = list_edge_attributes_active(dnet)
println("Edge TEAs: ", edge_teas)  # [:weight]
```

## Practical Examples

### Tracking Network Evolution

```julia
using DynamicNetworks

# Create a growing network
dnet = DynamicNetwork(10; observation_start=0.0, observation_end=100.0)
activate_vertices!(dnet, collect(1:10), 0.0, 100.0)

# Edges form progressively
activate!(dnet, 0.0, 100.0; edge=(1, 2))
activate!(dnet, 10.0, 100.0; edge=(2, 3))
activate!(dnet, 20.0, 100.0; edge=(3, 4))
activate!(dnet, 30.0, 100.0; edge=(4, 5))
activate!(dnet, 40.0, 100.0; edge=(5, 6))
activate!(dnet, 50.0, 80.0; edge=(6, 7))   # Temporary edge
activate!(dnet, 60.0, 100.0; edge=(7, 8))
activate!(dnet, 70.0, 100.0; edge=(8, 9))
activate!(dnet, 80.0, 100.0; edge=(9, 10))

# Track growth over time
for t in 0.0:10.0:100.0
    edgs = active_edges(dnet, t)
    println("t=$t: $(length(edgs)) active edges")
end
```

### Epidemic Simulation Data

```julia
# SIR model data
dnet = DynamicNetwork(20; observation_start=0.0, observation_end=50.0)
activate_vertices!(dnet, collect(1:20), 0.0, 50.0)

# Set initial states
for v in 1:20
    set_vertex_attribute_active!(dnet, v, :state, "S", 0.0, 50.0)
end

# Patient zero infected at t=0
set_vertex_attribute_active!(dnet, 1, :state, "I", 0.0, 10.0)
set_vertex_attribute_active!(dnet, 1, :state, "R", 10.0, 50.0)

# Check state at any time
for v in [1, 5, 10]
    state = get_vertex_attribute_active(dnet, v, :state, 5.0)
    println("Vertex $v at t=5: $state")
end
```

### Window-Based Analysis

```julia
# Analyze the network in non-overlapping windows of the observation period
# (`nothing` when none was set; fall back to the range of the data)
window_size = 10.0
period = get_observation_period(dnet)
start, stop = isnothing(period) ? extrema(get_change_times(dnet)) : period

for t in start:window_size:(stop - window_size)
    snap = network_extract(dnet, t, t + window_size; rule=:any)
    println("Window [$t, $(t + window_size)): $(nv(snap)) vertices, $(ne(snap)) edges")
end
```

## Summary of Query Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `is_active(dnet, t; vertex=v)` | `Bool` | Is vertex active at time t? |
| `is_active(dnet, t; edge=(i,j))` | `Bool` | Is edge active at time t? |
| `is_active(dnet, t1, t2; vertex=v, rule=r)` | `Bool` | Is vertex active during interval? |
| `active_vertices(dnet, t)` | `Vector{T}` | All active vertices at time t |
| `active_edges(dnet, t)` | `Vector{Tuple}` | All active edges at time t |
| `get_spells(dnet; vertex=v)` | `Vector{Spell}` | Stored spells for a vertex |
| `get_vertex_activity(dnet, v)` | `Vector{Spell}` | R view: `(-Inf, Inf)` when no record |
| `get_change_times(dnet)` | `Vector{Time}` | Sorted onsets and termini |
| `get_observation_period(dnet)` | `Tuple` or `nothing` | The given window; `nothing` when none was set |
| `when_vertex(dnet, v)` | `Vector{Spell}` | Alias for get_spells vertex |
| `when_edge(dnet, i, j)` | `Vector{Spell}` | Alias for get_spells edge |
| `get_activity_range(dnet; vertex=v)` | `Tuple` | Earliest onset to latest terminus |
| `network_extract(dnet, t)` | `Network` | Static snapshot at time t |
| `network_extract(dnet, t1, t2)` | `Network` | Static snapshot over interval |
| `network_slice(dnet, times)` | `Vector{Network}` | Multiple snapshots |
| `network_collapse(dnet)` | `Network` | Ever-active ties, all vertices kept |

All activity queries and extractions accept `active_default` (default `true`).
