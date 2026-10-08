# DynamicNetworks.jl

Represent when actors and ties are active, attach attributes that change over time, and extract network snapshots. DynamicNetworks.jl is the data layer for analyses and visualizations built from activity spells.

| First analysis | Learn the model or data | Reference and detail |
|:--|:--|:--|
| [Create spells and snapshots](getting_started.md) | [Understand activity intervals](guide/spells.md) | [Browse temporal operations](api/functions.md) |

!!! note "Supported scope"

    Activity intervals are half-open: an ordinary spell includes its onset and excludes its terminus. Zero-duration spells represent activity at one instant. As in R networkDynamic, a vertex or edge with no spells is active at all times, and activation merges overlapping or adjacent spells. This package stores temporal observations; it does not estimate a network evolution model. Snapshot extraction can lose timing information, which conversion reports make explicit.

## Installation

```@raw html
<p>Use Julia <strong>1.12 or newer</strong> and the <a href="/getting-started/">shared workspace installation guide</a>. These development packages are not yet registered; the guide prepares the required sibling checkouts and a Julia environment for the examples.</p>
```

## Quick Start

Create two overlapping contacts and extract the ties observed at time 3:

```julia
using NetworkCore, DynamicNetworks

dnet = DynamicNetwork(4; observation_start=0.0, observation_end=10.0)
activate_vertices!(dnet, collect(1:4), 0.0, 10.0)
activate!(dnet, 1.0, 4.0; edge=(1, 2))
activate!(dnet, 3.0, 8.0; edge=(2, 3))
snapshot, report = network_extract(dnet, 3.0; retain_all_vertices=true, report=true)
println((actors=nv(snapshot), ties=ne(snapshot)))
println(dropped_fields(report))
@assert !is_active(dnet, 4.0; edge=(1, 2))
```

Both ties are active at time 3. The first is inactive at its terminus, time 4. Keeping all vertices preserves actor indexing; the report records temporal information that a static snapshot cannot retain.

## Relationship to Other Packages

| Package | Role |
|---------|------|
| **NetworkCore.jl** | Static network data structure (dependency) |
| **DynamicNetworks.jl** | Dynamic network data structure (this package) |
| [TERGM.jl](https://statistical-network-analysis-with-Julia.github.io/TERGM.jl/dev/) | Models discrete panels of static snapshots; it does not require a DynamicNetwork |
| **TSNA.jl** | Temporal SNA descriptive analysis (uses DynamicNetworks for data) |
| **NDTV.jl** | Network visualization and animation |

## Documentation

```@contents
Pages = [
    "getting_started.md",
    "guide/dynamic_networks.md",
    "guide/spells.md",
    "guide/queries.md",
    "guide/r_concordance.md",
    "api/types.md",
    "api/functions.md",
]
Depth = 2
```

## Theoretical Background

### Discrete vs. Continuous Time

Dynamic networks can be modeled in two paradigms:

- **Discrete time**: Network changes at fixed time steps $t = 1, 2, 3, \ldots$ (panel data)
- **Continuous time**: Changes can occur at any time, represented by spells $[t_{\text{onset}}, t_{\text{terminus}})$

DynamicNetworks.jl supports continuous-time representation, which subsumes discrete time as a special case. Continuous-time spells can represent any pattern of activity, including instantaneous events and long-duration ties.

### Activity Algebra

Spells follow interval algebra rules:

- **Overlap**: Two spells overlap if $s_1.\text{onset} < s_2.\text{terminus}$ and $s_2.\text{onset} < s_1.\text{terminus}$
- **Containment**: Spell $s_1$ contains $s_2$ if $s_1.\text{onset} \leq s_2.\text{onset}$ and $s_1.\text{terminus} \geq s_2.\text{terminus}$
- **Duration**: $d(s) = s.\text{terminus} - s.\text{onset}$
- **Merging**: Overlapping or adjacent spells are merged into a single contiguous spell when they are activated, as in R networkDynamic

## References

1. Butts, C.T. (2008). `network`: A package for managing relational data in R. *Journal of Statistical Software*, 24(2), 1-36.

2. Almquist, Z.W., Butts, C.T. (2014). Logistic network regression for scalable analysis of networks with joint edge/vertex dynamics. *Sociological Methodology*, 44(1), 273-321.

3. Bender-deMoll, S., Morris, M. (2012). `networkDynamic`: Dynamic extensions for network objects. R package.

4. Holme, P., Saramaki, J. (2012). Temporal networks. *Physics Reports*, 519(3), 97-125.


## Citation

If you use DynamicNetworks.jl in your work, please cite it using the entry in
[`CITATION.bib`](https://github.com/statistical-network-analysis-with-Julia/DynamicNetworks.jl/blob/main/CITATION.bib):

```biblatex
@misc{SNWJDynamicNetworksJL,
  author = {Santoni, Simone},
  title = {DynamicNetworks.jl: Dynamic Network Data Structures for Julia},
  year = {2026},
  url = {https://github.com/statistical-network-analysis-with-Julia/DynamicNetworks.jl},
  note = {Homepage: https://statistical-network-analysis-with-Julia.github.io/DynamicNetworks.jl; GitHub: https://github.com/statistical-network-analysis-with-Julia}
}
```

## Module

```@docs
DynamicNetworks
```
