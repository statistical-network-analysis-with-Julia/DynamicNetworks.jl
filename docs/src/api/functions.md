# Functions API Reference

This page documents all functions available in DynamicNetworks.jl.

## Spell Operations

### Adding Spells

```@docs
add_spell!
activate!
activate_vertices!
activate_edges!
```

### Removing and Merging Spells

```@docs
remove_spell!
deactivate!
merge_spells!
DynamicNetworks.merge_spell_vector
```

### Retrieving Spells

```@docs
get_spells
when_vertex
when_edge
get_activity_range
```

## Activity Queries

The qualified helpers below are public for downstream packages:

```@docs
DynamicNetworks.spell_active_at
DynamicNetworks.elapsed_seconds
```

### Point and Interval Queries

```@docs
is_active
get_vertex_activity
get_edge_activity
```

### Active Element Listing

```@docs
active_vertices
active_edges
```

## Network Extraction

```@docs
network_extract
network_slice
network_collapse
```

## Time-Varying Attributes

### Vertex Attributes

```@docs
set_vertex_attribute_active!
get_vertex_attribute_active
list_vertex_attributes_active
```

### Edge Attributes

```@docs
set_edge_attribute_active!
get_edge_attribute_active
list_edge_attributes_active
```

## Observation Period

```@docs
get_observation_period
set_observation_period!
get_change_times
get_timing_info
```

## Conversion and Reconciliation

```@docs
as_dynamic_network
reconcile_activity!
```
