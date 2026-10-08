# Getting Started

Create activity spells, query their boundaries, and extract snapshots with a clear actor-indexing policy. Later sections add time-varying attributes and explain conversions between static networks and temporal observations.

!!! note "Before you begin"

    Activity intervals are half-open: an ordinary spell includes its onset and excludes its terminus. Zero-duration spells represent activity at one instant. This package stores temporal observations; it does not estimate a network evolution model. Snapshot extraction can lose timing information, which conversion reports make explicit.

## Installation

```@raw html
<p>Use Julia <strong>1.12 or newer</strong> and the <a href="/getting-started/">shared workspace installation guide</a>. These development packages are not yet registered; the guide prepares the required sibling checkouts and a Julia environment for the examples.</p>
```

Run the blocks below in order in that environment. They build on variables from earlier steps; stochastic examples use seeded random number generators where shown.

## Basic Workflow

The typical DynamicNetworks.jl workflow consists of four steps:

1. **Create a dynamic network** - Define the base structure and observation period
2. **Add activity spells** - Specify when vertices and edges are active
3. **Query activity** - Check what is active at given times
4. **Extract snapshots** - Obtain static networks at specific time points

## Step 1: Create a Dynamic Network

A dynamic network wraps a static `Network` with temporal information:

```julia
using DynamicNetworks

# Create a directed dynamic network with 5 vertices
dnet = DynamicNetwork{Int, Float64}(5;
    observation_start=0.0,
    observation_end=100.0
)

# Simplified constructor (defaults to Int vertices, Float64 time)
dnet = DynamicNetwork(5;
    observation_start=0.0,
    observation_end=100.0
)
```

### Type Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `T` | Vertex ID type (`Int`, `Int32`) | `Int` |
| `Time` | Timestamp type (`Float64`, `DateTime`) | `Float64` |
| `D` | Directedness (`true`/`false`), set by the `directed` keyword | `true` |

The full type is `DynamicNetwork{T, Time, D}`, so the wrapped static network is
the concrete `Network{T, D}`; `DynamicNetwork{Int, Float64}(5)` and
`DynamicNetwork(5)` fill in `D` from `directed`.

### Constructor Options

| Option | Description | Default |
|--------|-------------|---------|
| `observation_start` | Start of observation window | unset |
| `observation_end` | End of observation window | unset |
| `directed` | Whether the network is directed | `true` |

Give both ends of the window or neither: a window with one end only raises an
`ArgumentError`. For an open-ended window, pass the axis extreme (`Inf`) as
that end.

When no window is given, `get_observation_period` returns `nothing`, as R's
`net.obs.period` is `NULL`; nothing is derived from the data. TSNA.jl and
NDTV.jl then follow tsna's and ndtv's rules for a network without a window,
which read the range of `get_change_times(dnet)` where they need one.

```julia
# Undirected dynamic network
dnet = DynamicNetwork(10;
    observation_start=0.0,
    observation_end=50.0,
    directed=false
)
```

### Using DateTime

For calendar-based timestamps:

```julia
using Dates

dnet_dt = DynamicNetwork{Int, DateTime}(10;
    observation_start=DateTime(2024, 1, 1),
    observation_end=DateTime(2024, 12, 31)
)
```

## Step 2: Add Activity Spells

Activity spells define when vertices and edges are active.

### Activating Vertices

```julia
# Activate vertex 1 from time 0.0 to 50.0
activate!(dnet, 0.0, 50.0; vertex=1)

# Activate vertex 2 from time 0.0 to 100.0
activate!(dnet, 0.0, 100.0; vertex=2)

# Activate multiple vertices at once
activate_vertices!(dnet, [3, 4, 5], 0.0, 100.0)
```

### Activating Edges

```julia
# Activate edge from vertex 1 to vertex 2
activate!(dnet, 5.0, 30.0; edge=(1, 2))

# Activate edge from vertex 2 to vertex 3
activate!(dnet, 10.0, 50.0; edge=(2, 3))

# Activate multiple edges at once
activate_edges!(dnet, [(3, 4), (4, 5)], 20.0, 80.0)
```

### Multiple Spells

A vertex or edge can have multiple activity spells (e.g., intermittent activity).
As in R's `activate.vertices`/`activate.edges`, `activate!` **merges** a new
spell with the overlapping or adjacent spells already stored:

```julia
# Vertex 1 already has [0, 50): [0, 30) adds nothing, [50, 80) is adjacent
activate!(dnet, 0.0, 30.0; vertex=1)
activate!(dnet, 50.0, 80.0; vertex=1)
get_spells(dnet; vertex=1)        # [Spell[0.0, 80.0)]

# Edge (1,2) already has [5, 30): it is now active on [5, 30) and [40, 60)
activate!(dnet, 5.0, 20.0; edge=(1, 2))
activate!(dnet, 40.0, 60.0; edge=(1, 2))
get_spells(dnet; edge=(1, 2))     # [Spell[5.0, 30.0), Spell[40.0, 60.0)]
```

A tie observed in consecutive waves (`activate!(dnet, t, t + 1; edge=e)` per
wave) is therefore stored as one spell, one lifetime.

### Using Spell Objects Directly

For more control, create `Spell` objects:

```julia
# Create a spell with censoring information
s = Spell(0.0, 50.0; onset_censored=true)  # May have started earlier

# Add spell to vertex (merged into vertex 1's [0, 80), which keeps the
# onset-censoring flag)
add_spell!(dnet, s; vertex=1)

# Add spell to edge
add_spell!(dnet, Spell(10.0, 30.0); edge=(1, 2))
```

## Step 3: Query Activity

### Point Queries

Check if an element is active at a specific time:

```julia
# Is vertex 1 active at time 25?
is_active(dnet, 25.0; vertex=1)  # true

# Is edge (1,2) active at time 25?
is_active(dnet, 25.0; edge=(1, 2))  # depends on spells
```

### Elements Without Spells

As in R (`active.default = TRUE`), a vertex or edge with no spell record is
**active at all times**. Pass `active_default=false` to any query or
extraction to treat it as inactive instead:

```julia
dnet2 = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet2, 0.0, 10.0; edge=(1, 2))
is_active(dnet2, 5.0; vertex=3)                        # true: no record
is_active(dnet2, 5.0; vertex=3, active_default=false)  # false
active_vertices(dnet2, 5.0)                            # [1, 2, 3]
```

A record emptied by `deactivate!` or `remove_spell!` means "never active".

### Interval Queries

Check activity during a time interval:

```julia
# Is vertex 1 active at ANY point during [10, 40]?
is_active(dnet, 10.0, 40.0; vertex=1, rule=:any)  # true

# Is vertex 1 active THROUGHOUT [10, 40]?
is_active(dnet, 10.0, 40.0; vertex=1, rule=:all)  # depends on spells
```

### Listing Active Elements

```julia
# Get all vertices active at time 25
active_verts = active_vertices(dnet, 25.0)
println("Active vertices: ", active_verts)

# Get all edges active at time 25
active_edgs = active_edges(dnet, 25.0)
println("Active edges: ", active_edgs)
```

### Retrieving Spells

```julia
# Get all spells for vertex 1
spells = get_spells(dnet; vertex=1)
for s in spells
    println("Active from $(s.onset) to $(s.terminus)")
end

# Convenience aliases
spells = when_vertex(dnet, 1)
spells = when_edge(dnet, 1, 2)
```

## Step 4: Extract Network Snapshots

### At a Single Time Point

```julia
using NetworkCore   # for nv/ne on the extracted static network

# Extract static network at time 25
snapshot = network_extract(dnet, 25.0)

# The result is a standard Network{Int}
println("Vertices: ", nv(snapshot))
println("Edges: ", ne(snapshot))
```

### Over a Time Interval

```julia
# Extract network with any activity during [10, 30]
snapshot_any = network_extract(dnet, 10.0, 30.0; rule=:any)

# Extract network active throughout [10, 30]
snapshot_all = network_extract(dnet, 10.0, 30.0; rule=:all)
```

### Sequence of Snapshots

```julia
# Extract snapshots at regular intervals
times = collect(0.0:10.0:100.0)
snapshots = network_slice(dnet, times)

for (t, snap) in zip(times, snapshots)
    println("t=$t: $(nv(snap)) vertices, $(ne(snap)) edges")
end
```

### Collapse to Static

```julia
# A static network of the ties ever active (between ever-active vertices);
# every vertex is kept, so IDs are stable
static = network_collapse(dnet)
println("Total ever-active edges: ", ne(static))
```

## Working with Time-Varying Attributes

### Setting Attributes

```julia
# Set a time-varying vertex attribute
set_vertex_attribute_active!(dnet, 1, :status, "susceptible", 0.0, 10.0)
set_vertex_attribute_active!(dnet, 1, :status, "infected", 10.0, 30.0)
set_vertex_attribute_active!(dnet, 1, :status, "recovered", 30.0, 100.0)

# Set a time-varying edge attribute
set_edge_attribute_active!(dnet, 1, 2, :weight, 1.0, 5.0, 20.0)
set_edge_attribute_active!(dnet, 1, 2, :weight, 2.5, 20.0, 50.0)
```

### Getting Attributes

```julia
# Get attribute at a specific time
status = get_vertex_attribute_active(dnet, 1, :status, 15.0)
println(status)  # "infected"

status = get_vertex_attribute_active(dnet, 1, :status, 35.0)
println(status)  # "recovered"

# Get edge attribute at a time
w = get_edge_attribute_active(dnet, 1, 2, :weight, 10.0)
println(w)  # 1.0
```

### Listing Available Attributes

```julia
# What time-varying vertex attributes exist?
attrs = list_vertex_attributes_active(dnet)
println("Vertex TEAs: ", attrs)

# What time-varying edge attributes exist?
edge_attrs = list_edge_attributes_active(dnet)
println("Edge TEAs: ", edge_attrs)
```

## Complete Example

```julia
using DynamicNetworks, NetworkCore   # NetworkCore for nv/ne

# Create a small dynamic network representing a classroom
dnet = DynamicNetwork(5;
    observation_start=0.0,
    observation_end=60.0  # 60-minute class
)

# All students present for the full class
activate_vertices!(dnet, [1, 2, 3, 4, 5], 0.0, 60.0)

# Communication edges (who talks to whom and when)
activate!(dnet, 0.0, 15.0; edge=(1, 2))    # 1 talks to 2 early
activate!(dnet, 10.0, 30.0; edge=(2, 3))   # 2 talks to 3 mid-early
activate!(dnet, 20.0, 45.0; edge=(1, 3))   # 1 talks to 3 middle
activate!(dnet, 30.0, 55.0; edge=(3, 4))   # 3 talks to 4 mid-late
activate!(dnet, 40.0, 60.0; edge=(4, 5))   # 4 talks to 5 late
activate!(dnet, 5.0, 50.0; edge=(2, 1))    # 2 reciprocates 1

# Track discussion topic as a time-varying vertex attribute
for v in 1:5
    set_vertex_attribute_active!(dnet, v, :topic, "intro", 0.0, 20.0)
    set_vertex_attribute_active!(dnet, v, :topic, "main", 20.0, 45.0)
    set_vertex_attribute_active!(dnet, v, :topic, "conclusion", 45.0, 60.0)
end

# Extract snapshots at different points in the class
println("=== Beginning of class (t=5) ===")
snap1 = network_extract(dnet, 5.0)
println("Edges: ", ne(snap1))

println("\n=== Middle of class (t=30) ===")
snap2 = network_extract(dnet, 30.0)
println("Edges: ", ne(snap2))

println("\n=== End of class (t=55) ===")
snap3 = network_extract(dnet, 55.0)
println("Edges: ", ne(snap3))

# Summary information
info = get_timing_info(dnet)
println("\n=== Summary ===")
println("Observation period: ", info.observation_period)
println("Data range: $(info.data_start) to $(info.data_end)")
println("Vertex spells: ", info.n_vertex_spells)
println("Edge spells: ", info.n_edge_spells)
```

## Converting Between Static and Dynamic

### Static to Dynamic

```julia
using NetworkCore

# Create a static network
net = network(4; directed=true)
add_edge!(net, 1, 2)
add_edge!(net, 2, 3)
add_edge!(net, 3, 4)

# Convert to dynamic with all elements active from 0 to 100
dnet = as_dynamic_network(net; onset=0.0, terminus=100.0)
```

### Dynamic to Static

```julia
# Collapse to static (all ever-active elements)
static = network_collapse(dnet)

# Or extract at a specific time
static_at_50 = network_extract(dnet, 50.0)
```

## Ensuring Consistency

Edge activity should be consistent with vertex activity -- an edge can only be active when both endpoints are active. `reconcile_activity!` trims edge spells to their endpoints' activity (R's `reconcile.edge.activity(mode = "reduce.to.vertices")`):

```julia
# After modifying vertex spells, reconcile edge activity
reconcile_activity!(dnet)
```

## Best Practices

1. **Set the observation period**: Specify `observation_start` and `observation_end` when you know the observation design (otherwise there is no window, and downstream packages follow R's rules for that case)
2. **Remember the default**: Vertices and edges with no spells are active at all times; give every vertex spells, or pass `active_default=false`, when absence matters
3. **Use `reconcile_activity!`**: After modifying vertex spells, ensure edge consistency
4. **Merging is automatic**: `activate!` merges spells; `merge_spells!` is needed only after `add_spell!(...; merge=false)`
5. **Use appropriate time types**: `Float64` for abstract time, `DateTime` for calendar time
6. **Extract snapshots for analysis**: Use `network_extract` to get static networks for SNA functions

## Next Steps

- Learn about [Dynamic Networks](guide/dynamic_networks.md) in detail
- Understand [Spells and Activity](guide/spells.md) operations
- Master [Time Queries](guide/queries.md) for extracting and querying temporal data
