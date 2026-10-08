"""
    DynamicNetworks.jl - Dynamic Network Data Structures

Provides data structures for representing and manipulating dynamic (time-varying)
networks, including vertex/edge activity spells and time-varying attributes.

Port of the R networkDynamic package from the StatNet collection.
"""
module DynamicNetworks

using Dates
using Graphs
using NetworkCore
using NetworkCore: ConversionReport, record_drop!, require_observed
using PrecompileTools: @setup_workload, @compile_workload

public spell_active_at, elapsed_seconds, merge_spell_vector, unbounded_spell

# Core types
export DynamicNetwork, Spell, TimeVaryingAttribute

# Spell operations
export add_spell!, remove_spell!, get_spells, merge_spells!
export is_active, get_activity_range, spell_overlap, spell_duration
export activate!, deactivate!, activate_vertices!, activate_edges!

# Network extraction
export network_extract, network_collapse, network_slice
export get_timing_info, get_network_attribute, get_change_times

# Time-varying attributes
export get_vertex_attribute_active, set_vertex_attribute_active!
export get_edge_attribute_active, set_edge_attribute_active!
export list_vertex_attributes_active, list_edge_attributes_active

# Query functions
export when_vertex, when_edge
export get_vertex_activity, get_edge_activity
export active_vertices, active_edges

# Utility
export as_dynamic_network, reconcile_activity!
export get_observation_period, set_observation_period!

"""
    Spell{T}

An activity spell: the half-open time interval `[onset, terminus)` during
which a vertex or edge is active. A point spell `[t, t)` (`onset ==
terminus`) is an instantaneous event, active exactly at `t` (R
networkDynamic's convention).

# Fields
- `onset::T`: Start time (inclusive)
- `terminus::T`: End time (exclusive)
- `onset_censored::Bool`: True if the spell may have started earlier
- `terminus_censored::Bool`: True if the spell may continue beyond terminus

Equality and hashing look at `onset` and `terminus` only.

# Example
```julia
using DynamicNetworks
s = Spell(0.0, 5.0)
p = Spell(3.0, 3.0)                          # instantaneous event at t = 3
c = Spell(0.0, 5.0; onset_censored=true)     # began before observation
spell_duration(s)                            # 5.0
c == s                                       # true: flags are not compared
```
"""
struct Spell{T}
    onset::T
    terminus::T
    onset_censored::Bool
    terminus_censored::Bool

    function Spell(onset::T, terminus::T;
                   onset_censored::Bool=false,
                   terminus_censored::Bool=false) where T
        onset <= terminus || throw(ArgumentError("onset must be <= terminus"))
        new{T}(onset, terminus, onset_censored, terminus_censored)
    end
end

# Convenience constructor for mixed numeric types
Spell(onset::S, terminus::T; kwargs...) where {S, T} =
    (P = promote_type(S, T); Spell(P(onset), P(terminus); kwargs...))

# Spell utilities
Base.:(==)(a::Spell, b::Spell) = a.onset == b.onset && a.terminus == b.terminus
Base.isless(a::Spell, b::Spell) = a.onset < b.onset || (a.onset == b.onset && a.terminus < b.terminus)
Base.hash(s::Spell, h::UInt) = hash((s.onset, s.terminus), h)

function Base.show(io::IO, s::Spell)
    cens_l = s.onset_censored ? "(" : "["
    cens_r = s.terminus_censored ? ")*" : ")"
    print(io, "Spell", cens_l, s.onset, ", ", s.terminus, cens_r)
end

_is_point(s::Spell) = s.onset == s.terminus

"""
    DynamicNetworks.spell_active_at(s::Spell, at) -> Bool

Test a half-open activity spell at one instant. A point spell `[t,t)` is
active exactly at `t`. This public, qualified helper is shared with TSNA.

# Example
```julia
using DynamicNetworks
DynamicNetworks.spell_active_at(Spell(0.0, 5.0), 5.0)   # false: terminus excluded
DynamicNetworks.spell_active_at(Spell(5.0, 5.0), 5.0)   # true: point spell
```
"""
spell_active_at(s::Spell, at) =
    (s.onset <= at < s.terminus) || (s.onset == s.terminus == at)

"""
    DynamicNetworks.elapsed_seconds(duration) -> Float64

Convert a fixed Dates duration to seconds, preserving sub-millisecond units.
Numeric durations retain their native time unit. Calendar months and years
need an origin date and are rejected; subtract two dates or timestamps first.

# Example
```julia
using DynamicNetworks, Dates
DynamicNetworks.elapsed_seconds(Hour(1))   # 3600.0
DynamicNetworks.elapsed_seconds(2.5)       # 2.5 (numeric axes keep their unit)
```
"""
elapsed_seconds(d::Real) = Float64(d)
elapsed_seconds(d::Nanosecond) = Float64(Dates.value(d)) / 1e9
elapsed_seconds(d::Microsecond) = Float64(Dates.value(d)) / 1e6
elapsed_seconds(d::Millisecond) = Float64(Dates.value(d)) / 1e3
elapsed_seconds(d::Second) = Float64(Dates.value(d))
elapsed_seconds(d::Minute) = Float64(Dates.value(d)) * 60
elapsed_seconds(d::Hour) = Float64(Dates.value(d)) * 3600
elapsed_seconds(d::Day) = Float64(Dates.value(d)) * 86400
elapsed_seconds(d::Week) = Float64(Dates.value(d)) * 604800
elapsed_seconds(d::Dates.Period) = throw(ArgumentError(
    "$(typeof(d)) has no fixed duration in seconds; subtract two dates first"))
elapsed_seconds(d::Dates.CompoundPeriod) = sum(elapsed_seconds, Dates.periods(d); init=0.0)

"""
    spell_overlap(s1::Spell, s2::Spell) -> Bool

Check if two spells overlap. Half-open interval semantics: touching spells
`[0,10)` and `[10,20)` do not overlap. Point (zero-duration) spells `[t,t)`
are instantaneous events: they overlap an interval containing `t` and
another point spell only at the identical time.

# Example
```julia
using DynamicNetworks
spell_overlap(Spell(0.0, 10.0), Spell(5.0, 15.0))    # true
spell_overlap(Spell(0.0, 10.0), Spell(10.0, 20.0))   # false: half-open
spell_overlap(Spell(3.0, 3.0), Spell(0.0, 10.0))     # true: point inside
```
"""
function spell_overlap(s1::Spell{T}, s2::Spell{T}) where T
    p1 = s1.onset == s1.terminus
    p2 = s2.onset == s2.terminus
    if p1 && p2
        return s1.onset == s2.onset
    elseif p1
        return s2.onset <= s1.onset < s2.terminus
    elseif p2
        return s1.onset <= s2.onset < s1.terminus
    end
    return s1.onset < s2.terminus && s2.onset < s1.terminus
end

# The unbounded spell (-Inf, Inf) on a time axis: what an element with no
# spell record is equivalent to under `active_default=true` (R's
# active.default). Axes without infinities use their extreme values.
_time_neginf(::Type{T}) where T<:AbstractFloat = T(-Inf)
_time_posinf(::Type{T}) where T<:AbstractFloat = T(Inf)
_time_neginf(::Type{T}) where T = typemin(T)
_time_posinf(::Type{T}) where T = typemax(T)
_always(::Type{Time}) where Time = Spell(_time_neginf(Time), _time_posinf(Time))

"""
    DynamicNetworks.unbounded_spell(Time) -> Spell{Time}

The spell covering the whole time axis, `(-Inf, Inf)`. Axes without
infinities use their extreme values instead: `typemin(Time)`/`typemax(Time)`
on integer axes and on `DateTime`/`Date`. An element with no spell record is
equivalent to this spell under R's `active.default = TRUE`
([`get_vertex_activity`](@ref) reports it), and a bound equal to one of its
bounds means "unbounded" ([`spell_duration`](@ref) treats it so). Public so
that consumers (TSNA.jl, NDTV.jl) share one convention.

# Example
```julia
using DynamicNetworks, Dates
DynamicNetworks.unbounded_spell(Float64)    # Spell[-Inf, Inf)
DynamicNetworks.unbounded_spell(Int).terminus == typemax(Int)   # true
```
"""
unbounded_spell(::Type{Time}) where Time = _always(Time)

# Is either bound of `s` the axis extreme that stands for -Inf/Inf?
_unbounded(s::Spell{T}) where T =
    s.onset == _time_neginf(T) || s.terminus == _time_posinf(T)

"""
    spell_duration(s::Spell) -> duration

The length `terminus - onset` of a spell: zero for a point spell, a `Period`
on a `DateTime`/`Date` axis.

A spell with an **unbounded** side — onset `-Inf` or terminus `Inf`, or, on
axes without infinities, the extreme value that stands for them
(`typemin`/`typemax`; see [`DynamicNetworks.unbounded_spell`](@ref)) — has
unbounded duration, and no subtraction is done (subtracting the integer or
calendar extremes would overflow and wrap around):

| Time axis | Duration of an unbounded spell |
|:--|:--|
| floating point | `Inf` |
| other `Real` (integers, rationals) | `typemax(Time)` |
| `DateTime` | `Millisecond(typemax(Int64))` |
| `Date` | `Day(typemax(Int64))` |
| anything else | `ArgumentError` |

An element with no spell record is active over the unbounded spell
([`get_edge_activity`](@ref)), so its duration is unbounded too.

# Example
```julia
using DynamicNetworks
spell_duration(Spell(2.0, 7.5))      # 5.5
spell_duration(Spell(3.0, 3.0))      # 0.0
spell_duration(Spell(2.0, Inf))      # Inf
spell_duration(Spell(typemin(Int), 5))   # typemax(Int): unbounded, no overflow
```
"""
function spell_duration(s::Spell{T}) where T
    _is_point(s) && return _point_duration(s)
    _unbounded(s) && return _unbounded_duration(T)
    return s.terminus - s.onset
end

# A point spell lasts zero time (Inf - Inf would be NaN on a float axis).
_point_duration(s::Spell{T}) where T<:AbstractFloat = zero(T)
_point_duration(s::Spell) = s.terminus - s.onset

_unbounded_duration(::Type{T}) where T<:Real = typemax(T)
_unbounded_duration(::Type{DateTime}) = Millisecond(typemax(Int64))
_unbounded_duration(::Type{Date}) = Day(typemax(Int64))
_unbounded_duration(::Type{T}) where T = throw(ArgumentError(
    "the duration of an unbounded spell has no representation on a $T time axis"))

"""
    TimeVaryingAttribute{Time, V}

An attribute that changes over time (a TEA, after networkDynamic's
"temporally extended attribute"): parallel vectors of values and of the
spells during which each value holds. Created by
[`set_vertex_attribute_active!`](@ref) / [`set_edge_attribute_active!`](@ref);
read with [`get_vertex_attribute_active`](@ref) /
[`get_edge_attribute_active`](@ref).

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
set_vertex_attribute_active!(dnet, 1, :status, "S", 0.0, 4.0)
tea = dnet.vertex_tea[(1, :status)]
tea isa TimeVaryingAttribute       # true
tea.values, tea.spells             # (["S"], [Spell[0.0, 4.0)])
```
"""
struct TimeVaryingAttribute{Time, V}
    values::Vector{V}
    spells::Vector{Spell{Time}}

    function TimeVaryingAttribute{Time, V}() where {Time, V}
        new{Time, V}(V[], Spell{Time}[])
    end
end

"""
    DynamicNetwork{T, Time, D}

A network whose vertices and edges are active during spells of time.

# Type Parameters
- `T`: Vertex ID type
- `Time`: Time type (`Float64`, `Int`, `DateTime`, `Date`, ...)
- `D::Bool`: directedness, as in `Network{T,D}` (so the wrapped network is
  concretely typed)

# Constructors

    DynamicNetwork(n=0; directed=true, observation_start=nothing, observation_end=nothing)
    DynamicNetwork{T,Time}(n=0; directed=true, observation_start=nothing, observation_end=nothing)
    DynamicNetwork(networks::AbstractVector{<:Network}; onsets, termini, start)

The last builds a dynamic network from a panel of static networks, as R's
`networkDynamic(network.list = ...)` does; see
[`as_dynamic_network`](@ref) (its panel method).

# Activity semantics (R networkDynamic)
- Spells are half-open `[onset, terminus)`; a point spell `[t,t)` is active
  exactly at `t`.
- **An element with no spell record is active** (R's `active.default =
  TRUE`). Every query and extraction takes `active_default=true`; pass
  `active_default=false` to treat such elements as inactive. An element
  whose spells were all removed (by [`deactivate!`](@ref) or
  [`remove_spell!`](@ref)) has an *empty* record and is inactive.
- [`activate!`](@ref) and [`add_spell!`](@ref) merge overlapping and adjacent
  spells on insertion, as R's `activate.*` do.
- The observation window is the one given at construction or by
  [`set_observation_period!`](@ref); when none was given,
  [`get_observation_period`](@ref) returns `nothing` (see there for what
  TSNA.jl and NDTV.jl do then). A window has two ends, as R's
  `net.obs.period` does: give both `observation_start` and
  `observation_end`, or neither. Giving only one raises an `ArgumentError`
  rather than inventing the other end; for an open-ended window pass the
  axis extreme explicitly (`Inf`, or the bounds of
  [`DynamicNetworks.unbounded_spell`](@ref) on axes without infinities).

# Fields
- `network::Network{T,D}`: Base network structure (maximum set of vertices/edges)
- `vertex_spells::Dict{T, Vector{Spell{Time}}}`: Activity periods for vertices
- `edge_spells::Dict{Tuple{T,T}, Vector{Spell{Time}}}`: Activity periods for edges
- `vertex_tea`, `edge_tea`: Time-varying vertex and edge attributes
- `observation_period::Tuple{Time, Time}`: the stored observation window;
  meaningless when `observation_period_set` is false (read the window with
  [`get_observation_period`](@ref), which returns `nothing` then)
- `observation_period_set::Bool`: whether a window was given explicitly
- `mutation_count::Int`: Bumped on every spell/observation-window mutation
  (lets downstream packages memoize derived indexes safely)

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; edge=(1, 2))
is_active(dnet, 2.0; vertex=3)    # true: no vertex spells, active by default
is_active(dnet, 6.0; edge=(1, 2)) # false
```
"""
mutable struct DynamicNetwork{T<:Integer, Time, D}
    network::Network{T, D}
    vertex_spells::Dict{T, Vector{Spell{Time}}}
    edge_spells::Dict{Tuple{T,T}, Vector{Spell{Time}}}
    vertex_tea::Dict{Tuple{T,Symbol}, TimeVaryingAttribute{Time}}
    edge_tea::Dict{Tuple{Tuple{T,T},Symbol}, TimeVaryingAttribute{Time}}
    observation_period::Tuple{Time, Time}
    net_obs_period::Spell{Time}
    observation_period_set::Bool
    mutation_count::Int

    function DynamicNetwork{T, Time, D}(n::Integer=0;
                                        observation_start=nothing,
                                        observation_end=nothing) where {T<:Integer, Time, D}
        D isa Bool || throw(ArgumentError(
            "the directedness parameter D of DynamicNetwork{T,Time,D} must be a Bool"))
        explicit = !isnothing(observation_start) || !isnothing(observation_end)
        if explicit && (isnothing(observation_start) || isnothing(observation_end))
            given, other = isnothing(observation_start) ?
                ("observation_end", "observation_start") : ("observation_start", "observation_end")
            throw(ArgumentError(
                "an observation window needs both ends: $given was given without " *
                "$other. Pass both (for an open end, the axis extreme, e.g. " *
                "DynamicNetworks.unbounded_spell($Time)), or neither for no window"))
        end
        start = isnothing(observation_start) ? _default_obs_start(Time) :
                convert(Time, observation_start)
        stop = isnothing(observation_end) ? _default_obs_end(Time) :
               convert(Time, observation_end)
        explicit && _check_window(start, stop)
        net = Network{T, D}(; n=Int(n))
        new{T, Time, D}(
            net,
            Dict{T, Vector{Spell{Time}}}(),
            Dict{Tuple{T,T}, Vector{Spell{Time}}}(),
            Dict{Tuple{T,Symbol}, TimeVaryingAttribute{Time}}(),
            Dict{Tuple{Tuple{T,T},Symbol}, TimeVaryingAttribute{Time}}(),
            (start, stop),
            Spell(start, stop),
            explicit,
            0
        )
    end
end

DynamicNetwork{T, Time}(n::Integer=0; directed::Bool=true, kwargs...) where {T<:Integer, Time} =
    DynamicNetwork{T, Time, directed}(n; kwargs...)

DynamicNetwork(n::Integer=0; kwargs...) = DynamicNetwork{Int, Float64}(n; kwargs...)

# Record a structural mutation. Downstream memoized indexes (e.g. TSNA's
# contact index) compare this counter to detect staleness.
_touch!(dnet::DynamicNetwork) = (dnet.mutation_count += 1; dnet)

_check_window(start, stop) = start <= stop || throw(ArgumentError(
    "the observation window must have start <= end; got ($start, $stop)"))

# Filler for the stored `observation_period` field when no window was given.
# It is never read as a window (`get_observation_period` returns `nothing`
# then); DateTime/Date have no zero/one, hence the calendar values.
_default_obs_start(::Type{Time}) where Time<:Number = zero(Time)
_default_obs_end(::Type{Time}) where Time<:Number = one(Time)
_default_obs_start(::Type{DateTime}) = DateTime(0)
_default_obs_end(::Type{DateTime}) = DateTime(1)
_default_obs_start(::Type{Date}) = Date(0)
_default_obs_end(::Type{Date}) = Date(1)

function Base.show(io::IO, dnet::DynamicNetwork{T, Time}) where {T, Time}
    dir_str = is_directed(dnet) ? "directed" : "undirected"
    println(io, "DynamicNetwork{$T, $Time}: $dir_str dynamic network")
    println(io, "  Vertices: $(nv(dnet))")
    println(io, "  Edges (base): $(ne(dnet))")
    window = get_observation_period(dnet)
    println(io, "  Observation period: ", isnothing(window) ? "none set" : window)
    n_vs = sum(length(v) for v in values(dnet.vertex_spells); init=0)
    n_es = sum(length(v) for v in values(dnet.edge_spells); init=0)
    print(io, "  Spells: $n_vs vertex, $n_es edge")
end

# Forward Graphs.jl interface to underlying network
Graphs.nv(dnet::DynamicNetwork) = nv(dnet.network)
Graphs.ne(dnet::DynamicNetwork) = ne(dnet.network)
Graphs.vertices(dnet::DynamicNetwork) = vertices(dnet.network)
Graphs.is_directed(::DynamicNetwork{T, Time, D}) where {T, Time, D} = D
Graphs.is_directed(::Type{<:DynamicNetwork{T, Time, D}}) where {T, Time, D} = D

# Storage key of an edge: undirected edges are stored (min, max).
_edge_key(dnet::DynamicNetwork, edge) =
    is_directed(dnet) ? (edge[1], edge[2]) : (min(edge[1], edge[2]), max(edge[1], edge[2]))

"""
    get_observation_period(dnet::DynamicNetwork) -> Union{Tuple, Nothing}

The observation window `(start, end)` (R's `net.obs.period`), or `nothing`
when none was given.

A window is given by the `observation_start`/`observation_end` constructor
keywords, by [`set_observation_period!`](@ref), by
[`as_dynamic_network`](@ref) and by the panel constructor. Without one,
nothing is derived from the data, just as R's `nd %n% "net.obs.period"` is
`NULL`: each consumer applies R's own rule for that case. TSNA.jl follows
tsna (lifetimes over the whole time axis, with `Inf` durations for open
spells; event series over the closed range of [`get_change_times`](@ref)), and
NDTV.jl animates the closed range of the change times, as ndtv does. A
consumer that needs a finite range and finds none raises an `ArgumentError`
that asks for a window; no placeholder range is ever used.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3)
activate!(dnet, 2.0, 7.0; edge=(1, 2))
get_observation_period(dnet)        # nothing: no window was given
extrema(get_change_times(dnet))     # (2.0, 7.0): the range of the data
set_observation_period!(dnet, 0.0, 10.0)
get_observation_period(dnet)        # (0.0, 10.0)
```
"""
function get_observation_period(dnet::DynamicNetwork{T, Time}) where {T, Time}
    return dnet.observation_period_set ? dnet.observation_period : nothing
end

"""
    set_observation_period!(dnet::DynamicNetwork, start, stop) -> dnet

Set the observation window (R's `net.obs.period`). Activity outside it is not
clipped; the window is what duration and censoring computations (TSNA.jl) and
default animation ranges (NDTV.jl) use.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3)
set_observation_period!(dnet, 0.0, 52.0)
get_observation_period(dnet)        # (0.0, 52.0)
```
"""
function set_observation_period!(dnet::DynamicNetwork{T, Time}, start, stop) where {T, Time}
    start, stop = convert(Time, start), convert(Time, stop)
    _check_window(start, stop)      # before any field changes
    dnet.observation_period = (start, stop)
    dnet.net_obs_period = Spell(start, stop)
    dnet.observation_period_set = true
    _touch!(dnet)
    return dnet
end

"""
    get_change_times(dnet::DynamicNetwork; vertex_activity=true, edge_activity=true,
                     vertex_attribute_activity=true, edge_attribute_activity=true,
                     ignore_inf=true) -> Vector

The sorted, unique onsets and termini of the network's spells (R
networkDynamic's `get.change.times`). The keywords choose which spells are
included; `ignore_inf=true` drops infinite bounds.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3)
activate!(dnet, 0.0, 4.0; vertex=1)
activate!(dnet, 2.0, 6.0; edge=(1, 2))
get_change_times(dnet)              # [0.0, 2.0, 4.0, 6.0]
```
"""
function get_change_times(dnet::DynamicNetwork{T, Time};
                          vertex_activity::Bool=true, edge_activity::Bool=true,
                          vertex_attribute_activity::Bool=true,
                          edge_attribute_activity::Bool=true,
                          ignore_inf::Bool=true) where {T, Time}
    times = Time[]
    function add!(spells)
        for s in spells
            push!(times, s.onset, s.terminus)
        end
    end
    vertex_activity && foreach(add!, values(dnet.vertex_spells))
    edge_activity && foreach(add!, values(dnet.edge_spells))
    vertex_attribute_activity && foreach(t -> add!(t.spells), values(dnet.vertex_tea))
    edge_attribute_activity && foreach(t -> add!(t.spells), values(dnet.edge_tea))
    if ignore_inf
        lo, hi = _time_neginf(Time), _time_posinf(Time)
        filter!(t -> t != lo && t != hi, times)
    end
    return sort!(unique!(times))
end

# =============================================================================
# Spell Operations
# =============================================================================

# `vertex=`/`edge=` keywords accept ids of any Integer type and are converted
# to the network's id type T (so literal ids work on a DynamicNetwork{Int32}).
# An id that T cannot represent is not a vertex of the network.
_as_vertex(::DynamicNetwork, ::Nothing) = nothing
function _as_vertex(dnet::DynamicNetwork{T}, v::Integer) where T
    typemin(T) <= v <= typemax(T) || throw(ArgumentError(
        "vertex $v is not in the network (it has $(nv(dnet)) vertices)"))
    return T(v)
end
_as_edge(::DynamicNetwork, ::Nothing) = nothing
_as_edge(dnet::DynamicNetwork, e::Tuple{Integer, Integer}) =
    (_as_vertex(dnet, e[1]), _as_vertex(dnet, e[2]))

function _check_vertex(dnet::DynamicNetwork, v)
    1 <= v <= nv(dnet) || throw(ArgumentError(
        "vertex $v is not in the network (it has $(nv(dnet)) vertices)"))
    return v
end

# Validate an edge and make sure it exists in the base network. A self-loop
# on a loop-less network or a within-mode tie on a two-mode network cannot be
# added, and used to leave spells recorded for an edge that does not exist.
function _ensure_edge!(dnet::DynamicNetwork, edge)
    i, j = edge
    _check_vertex(dnet, i); _check_vertex(dnet, j)
    if !has_edge(dnet.network, i, j)
        add_edge!(dnet.network, i, j) || throw(ArgumentError(
            "edge ($i, $j) cannot be added to the base network " *
            (i == j ? "(it has loops=false)" : "(two-mode networks only admit cross-mode edges)")))
    end
    return _edge_key(dnet, edge)
end

"""
    add_spell!(dnet::DynamicNetwork, spell::Spell; vertex=nothing, edge=nothing,
               merge=true) -> dnet

Add an activity spell to a vertex or edge (an edge is added to the base
network if needed). With `merge=true` (default) the element's spells are
merged on insertion as R networkDynamic's `activate.*` do: overlapping and
adjacent intervals coalesce, and a point spell inside an interval (or
duplicating another point spell) is absorbed; see
[`merge_spells!`](@ref). `merge=false` stores the spell as given (the spell
vector is still kept sorted).

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
add_spell!(dnet, Spell(0.0, 5.0); edge=(1, 2))
add_spell!(dnet, Spell(5.0, 8.0); edge=(1, 2))
get_spells(dnet; edge=(1, 2))       # [Spell[0.0, 8.0)]: merged, as in R
```
"""
function add_spell!(dnet::DynamicNetwork{T, Time}, spell::Spell{Time};
                    vertex::Union{Nothing, Integer}=nothing,
                    edge::Union{Nothing, Tuple{Integer,Integer}}=nothing,
                    merge::Bool=true) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    if !isnothing(vertex)
        _check_vertex(dnet, vertex)
        spells = get!(dnet.vertex_spells, vertex, Spell{Time}[])
        push!(spells, spell)
        dnet.vertex_spells[vertex] = merge ? merge_spell_vector(spells) : sort!(spells)
    elseif !isnothing(edge)
        e = _ensure_edge!(dnet, edge)
        spells = get!(dnet.edge_spells, e, Spell{Time}[])
        push!(spells, spell)
        dnet.edge_spells[e] = merge ? merge_spell_vector(spells) : sort!(spells)
    else
        throw(ArgumentError("Must specify either vertex or edge"))
    end
    _touch!(dnet)
    return dnet
end

"""
    activate!(dnet::DynamicNetwork, onset, terminus; vertex=nothing, edge=nothing) -> dnet

Make a vertex or edge active during `[onset, terminus)` (R's
`activate.vertices`/`activate.edges`); `onset == terminus` records an
instantaneous event. Spells are merged on insertion, as in R.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; vertex=1)
activate!(dnet, 1.0, 4.0; edge=(1, 2))
activate!(dnet, 7.0, 7.0; edge=(2, 3))      # point spell (contact at t = 7)
is_active(dnet, 7.0; edge=(2, 3))           # true
```
"""
function activate!(dnet::DynamicNetwork{T, Time}, onset, terminus;
                   vertex::Union{Nothing, Integer}=nothing,
                   edge::Union{Nothing, Tuple{Integer,Integer}}=nothing) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    add_spell!(dnet, Spell(convert(Time, onset), convert(Time, terminus));
               vertex=vertex, edge=edge)
end

"""
    deactivate!(dnet::DynamicNetwork, onset, terminus; vertex=nothing, edge=nothing) -> dnet

Remove activity in `[onset, terminus)` from a vertex or edge (R's
`deactivate.vertices`/`deactivate.edges`). Existing spells are truncated or
split so that no remaining spell overlaps the interval; spells entirely
inside it are removed. Censoring flags are preserved on the surviving spell
fragments. A point (zero-duration) interval `[t, t)` removes only point
spells at exactly `t` (half-open interval spells are unaffected).

An element with no spell record is active by default, i.e. equivalent to the
spell `(-Inf, Inf)` (the extreme values on axes without infinities), and is
cut the same way: deactivating `[2, 4)` leaves `[-Inf, 2)` and `[4, Inf)`, as
in R. An element whose last spell is removed is inactive (an empty record).
An edge that is not in the base network has nothing to deactivate.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 10.0; vertex=1)
deactivate!(dnet, 3.0, 6.0; vertex=1)
get_spells(dnet; vertex=1)          # [Spell[0.0, 3.0), Spell[6.0, 10.0)]
deactivate!(dnet, 2.0, 4.0; vertex=2)
get_spells(dnet; vertex=2)          # [Spell[-Inf, 2.0), Spell[4.0, Inf)]
```
"""
function deactivate!(dnet::DynamicNetwork{T, Time}, onset, terminus;
                     vertex::Union{Nothing, Integer}=nothing,
                     edge::Union{Nothing, Tuple{Integer,Integer}}=nothing) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    onset, terminus = convert(Time, onset), convert(Time, terminus)
    query = Spell(onset, terminus)
    if !isnothing(vertex)
        _check_vertex(dnet, vertex)
        spells = get(dnet.vertex_spells, vertex, nothing)
    elseif !isnothing(edge)
        e = _edge_key(dnet, edge)
        has_edge(dnet.network, e[1], e[2]) || return dnet
        spells = get(dnet.edge_spells, e, nothing)
    else
        throw(ArgumentError("Must specify either vertex or edge"))
    end
    # No record: active by default, i.e. one unbounded spell
    spells = isnothing(spells) ? [_always(Time)] : spells

    new_spells = Spell{Time}[]
    for s in spells
        if !spell_overlap(s, query) || (onset == terminus && s.onset < s.terminus)
            push!(new_spells, s)
            continue
        end
        # Keep the fragments outside the deactivation window
        if s.onset < onset
            push!(new_spells, Spell(s.onset, onset;
                                    onset_censored=s.onset_censored))
        end
        if s.terminus > terminus
            push!(new_spells, Spell(terminus, s.terminus;
                                    terminus_censored=s.terminus_censored))
        end
    end

    if !isnothing(vertex)
        dnet.vertex_spells[vertex] = new_spells
    else
        dnet.edge_spells[_edge_key(dnet, edge)] = new_spells
    end

    _touch!(dnet)
    return dnet
end

"""
    activate_vertices!(dnet::DynamicNetwork, vertices, onset, terminus) -> dnet

Activate several vertices for the spell `[onset, terminus)`.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(4; observation_start=0.0, observation_end=10.0)
activate_vertices!(dnet, [1, 2, 3], 0.0, 5.0)
active_vertices(dnet, 7.0)          # [4]: vertex 4 has no spells (active by default)
```
"""
function activate_vertices!(dnet::DynamicNetwork{T, Time}, verts::AbstractVector{<:Integer},
                            onset, terminus) where {T, Time}
    spell = Spell(convert(Time, onset), convert(Time, terminus))
    for v in verts
        add_spell!(dnet, spell; vertex=T(v))
    end
    return dnet
end

"""
    activate_edges!(dnet::DynamicNetwork, edges, onset, terminus) -> dnet

Activate several edges (a vector of `(i, j)` tuples) for the spell
`[onset, terminus)`; edges missing from the base network are added.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate_edges!(dnet, [(1, 2), (2, 3)], 0.0, 5.0)
sort(active_edges(dnet, 1.0))       # [(1, 2), (2, 3)]
```
"""
function activate_edges!(dnet::DynamicNetwork{T, Time}, edges::AbstractVector{<:Tuple{Integer,Integer}},
                         onset, terminus) where {T, Time}
    spell = Spell(convert(Time, onset), convert(Time, terminus))
    for e in edges
        add_spell!(dnet, spell; edge=(T(e[1]), T(e[2])))
    end
    return dnet
end

"""
    remove_spell!(dnet::DynamicNetwork, spell::Spell; vertex=nothing, edge=nothing) -> dnet

Remove a stored spell (matched on onset and terminus) from a vertex or edge.
Because spells are merged on insertion, the stored spell may be a union of
several activations; to cut activity out of a spell use
[`deactivate!`](@ref). An element whose last spell is removed is inactive.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; vertex=1)
remove_spell!(dnet, Spell(0.0, 5.0); vertex=1)
is_active(dnet, 1.0; vertex=1)      # false: an empty record means inactive
```
"""
function remove_spell!(dnet::DynamicNetwork{T, Time}, spell::Spell{Time};
                       vertex::Union{Nothing, Integer}=nothing,
                       edge::Union{Nothing, Tuple{Integer,Integer}}=nothing) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    if !isnothing(vertex)
        if haskey(dnet.vertex_spells, vertex)
            filter!(s -> s != spell, dnet.vertex_spells[vertex])
        end
    elseif !isnothing(edge)
        e = _edge_key(dnet, edge)
        if haskey(dnet.edge_spells, e)
            filter!(s -> s != spell, dnet.edge_spells[e])
        end
    else
        throw(ArgumentError("Must specify either vertex or edge"))
    end
    _touch!(dnet)
    return dnet
end

"""
    get_spells(dnet::DynamicNetwork; vertex=nothing, edge=nothing) -> Vector{Spell}

The spells *stored* for a vertex or edge (sorted). An element with no spell
record returns an empty vector, although it is active by default; use
[`get_vertex_activity`](@ref)/[`get_edge_activity`](@ref) for R's
`active.default` view.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 1.0, 3.0; edge=(1, 2))
get_spells(dnet; edge=(1, 2))       # [Spell[1.0, 3.0)]
get_spells(dnet; vertex=1)          # Spell{Float64}[]: no record
```
"""
function get_spells(dnet::DynamicNetwork{T, Time};
                    vertex::Union{Nothing, Integer}=nothing,
                    edge::Union{Nothing, Tuple{Integer,Integer}}=nothing) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    if !isnothing(vertex)
        return get(dnet.vertex_spells, vertex, Spell{Time}[])
    elseif !isnothing(edge)
        return get(dnet.edge_spells, _edge_key(dnet, edge), Spell{Time}[])
    else
        throw(ArgumentError("Must specify either vertex or edge"))
    end
end

"""
    merge_spells!(dnet::DynamicNetwork; vertex=nothing, edge=nothing) -> dnet

Merge the stored spells of a vertex or edge — of every vertex and edge when
neither keyword is given — into R networkDynamic's canonical form:
overlapping or adjacent intervals coalesce; a point spell `[t,t)` is absorbed
by an interval with `onset <= t < terminus` and by an identical point spell,
and is kept otherwise (so `[0,5)` and `[5,5)` stay two spells: the point
spell is the activity at `t = 5`). Censoring flags are preserved: the merged
spell keeps the onset censoring of the spell supplying its onset and the
terminus censoring of the spell supplying its terminus.

Spells added through [`activate!`](@ref)/[`add_spell!`](@ref) are already
merged; this is needed only after `add_spell!(...; merge=false)`.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
add_spell!(dnet, Spell(0.0, 6.0); vertex=1, merge=false)
add_spell!(dnet, Spell(4.0, 10.0); vertex=1, merge=false)
merge_spells!(dnet; vertex=1)
get_spells(dnet; vertex=1)          # [Spell[0.0, 10.0)]
```
"""
function merge_spells!(dnet::DynamicNetwork{T, Time};
                       vertex::Union{Nothing, Integer}=nothing,
                       edge::Union{Nothing, Tuple{Integer,Integer}}=nothing) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    if isnothing(vertex) && isnothing(edge)
        for (k, s) in dnet.vertex_spells
            dnet.vertex_spells[k] = merge_spell_vector(s)
        end
        for (k, s) in dnet.edge_spells
            dnet.edge_spells[k] = merge_spell_vector(s)
        end
    elseif !isnothing(vertex)
        haskey(dnet.vertex_spells, vertex) &&
            (dnet.vertex_spells[vertex] = merge_spell_vector(dnet.vertex_spells[vertex]))
    else
        e = _edge_key(dnet, edge)
        haskey(dnet.edge_spells, e) &&
            (dnet.edge_spells[e] = merge_spell_vector(dnet.edge_spells[e]))
    end
    _touch!(dnet)
    return dnet
end

"""
    DynamicNetworks.merge_spell_vector(spells) -> Vector{Spell}

Return the canonical (merged, sorted) form of a spell vector without
mutating it, with the rules of [`merge_spells!`](@ref): overlapping or
adjacent intervals coalesce, a point spell inside an interval or duplicating
another point spell is absorbed, censoring flags travel with the bound they
describe. Public so that consumers (TSNA.jl) that need one lifetime per
contiguous activity can merge spells they did not create.

# Example
```julia
using DynamicNetworks
DynamicNetworks.merge_spell_vector([Spell(0.0, 5.0), Spell(5.0, 10.0), Spell(2.0, 2.0)])
# [Spell[0.0, 10.0)]
```
"""
function merge_spell_vector(spells::AbstractVector{Spell{Time}}) where Time
    isempty(spells) && return Spell{Time}[]
    intervals = sort!([s for s in spells if !_is_point(s)])
    merged = Spell{Time}[]
    if !isempty(intervals)
        current = intervals[1]
        for i in 2:length(intervals)
            s = intervals[i]
            if s.onset <= current.terminus
                # Overlap or adjacent — extend current, keeping the censoring
                # flag of whichever spell supplies each merged bound
                on_cens = current.onset_censored ||
                          (s.onset == current.onset && s.onset_censored)
                if s.terminus > current.terminus
                    term, term_cens = s.terminus, s.terminus_censored
                elseif s.terminus == current.terminus
                    term = current.terminus
                    term_cens = current.terminus_censored || s.terminus_censored
                else
                    term, term_cens = current.terminus, current.terminus_censored
                end
                current = Spell(current.onset, term;
                                onset_censored=on_cens, terminus_censored=term_cens)
            else
                push!(merged, current)
                current = s
            end
        end
        push!(merged, current)
    end
    # Point spells: absorbed when an interval is active at their instant, and
    # deduplicated; kept otherwise (R keeps [5,5) beside [0,5)).
    points = sort!([s for s in spells if _is_point(s)])
    last_point = nothing
    for p in points
        any(s -> s.onset <= p.onset < s.terminus, merged) && continue
        !isnothing(last_point) && last_point.onset == p.onset && continue
        push!(merged, p)
        last_point = p
    end
    return sort!(merged)
end

# =============================================================================
# Activity Queries
# =============================================================================

# Active-at test on a stored record; `nothing` means "no record".
_record_active_at(spells::Nothing, at, active_default::Bool) = active_default
_record_active_at(spells::AbstractVector, at, ::Bool) = any(s -> spell_active_at(s, at), spells)

function _record_active_in(spells::Nothing, onset, terminus, rule::Symbol, active_default::Bool)
    return active_default
end
function _record_active_in(spells::AbstractVector, onset, terminus, rule::Symbol, ::Bool)
    if rule == :any
        query = Spell(onset, terminus)
        return any(s -> spell_overlap(s, query), spells)
    else
        return _covers_interval(spells, onset, terminus)
    end
end

_vertex_record(dnet::DynamicNetwork, v) = get(dnet.vertex_spells, v, nothing)
_edge_record(dnet::DynamicNetwork, key) = get(dnet.edge_spells, key, nothing)

"""
    is_active(dnet::DynamicNetwork, at; vertex=nothing, edge=nothing, active_default=true) -> Bool
    is_active(dnet::DynamicNetwork, onset, terminus; vertex=nothing, edge=nothing,
              rule=:any, active_default=true) -> Bool

Is a vertex or edge active at the instant `at`, or during `[onset, terminus)`
(`rule=:any`: at any point; `rule=:all`: throughout, possibly across several
adjacent spells)? As in R's `is.active`, an element with no spell record is
active when `active_default=true`. An edge that is not in the base network is
never active.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; vertex=1)
is_active(dnet, 2.0; vertex=1)                       # true
is_active(dnet, 5.0; vertex=1)                       # false: terminus excluded
is_active(dnet, 2.0; vertex=2)                       # true: no record
is_active(dnet, 2.0; vertex=2, active_default=false) # false
is_active(dnet, 3.0, 8.0; vertex=1, rule=:all)       # false
```
"""
function is_active(dnet::DynamicNetwork{T, Time}, at;
                   vertex::Union{Nothing, Integer}=nothing,
                   edge::Union{Nothing, Tuple{Integer,Integer}}=nothing,
                   active_default::Bool=true) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    at = convert(Time, at)
    if !isnothing(vertex)
        return _record_active_at(_vertex_record(dnet, vertex), at, active_default)
    elseif !isnothing(edge)
        e = _edge_key(dnet, edge)
        has_edge(dnet.network, e[1], e[2]) || return false
        return _record_active_at(_edge_record(dnet, e), at, active_default)
    else
        throw(ArgumentError("Must specify either vertex or edge"))
    end
end

function is_active(dnet::DynamicNetwork{T, Time}, onset, terminus;
                   vertex::Union{Nothing, Integer}=nothing,
                   edge::Union{Nothing, Tuple{Integer,Integer}}=nothing,
                   rule::Symbol=:any,
                   active_default::Bool=true) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    onset, terminus = convert(Time, onset), convert(Time, terminus)
    rule in (:any, :all) || throw(ArgumentError("rule must be :any or :all"))
    onset <= terminus || throw(ArgumentError("onset must be <= terminus"))
    if !isnothing(vertex)
        rec = _vertex_record(dnet, vertex)
    elseif !isnothing(edge)
        e = _edge_key(dnet, edge)
        has_edge(dnet.network, e[1], e[2]) || return false
        rec = _edge_record(dnet, e)
    else
        throw(ArgumentError("Must specify either vertex or edge"))
    end
    return _record_active_in(rec, onset, terminus, rule, active_default)
end

# Spell vectors are sorted on insertion. The union may cover an interval
# even when no individual spell does; do not mutate or merge caller storage.
function _covers_interval(spells, onset, terminus)
    onset <= terminus || throw(ArgumentError("onset must be <= terminus"))
    onset == terminus && return any(s -> spell_active_at(s, onset), spells)
    covered = onset
    for s in spells
        s.terminus <= covered && continue
        s.onset > covered && return false
        covered = s.terminus
        covered >= terminus && return true
    end
    return false
end

"""
    active_vertices(dnet::DynamicNetwork, at; active_default=true) -> Vector

The vertices active at time `at` (vertices with no spell record count as
active when `active_default=true`).

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; vertex=1)
active_vertices(dnet, 6.0)          # [2, 3]
```
"""
function active_vertices(dnet::DynamicNetwork{T, Time}, at;
                         active_default::Bool=true) where {T, Time}
    at = convert(Time, at)
    return T[T(v) for v in 1:nv(dnet)
             if _record_active_at(_vertex_record(dnet, T(v)), at, active_default)]
end

"""
    active_edges(dnet::DynamicNetwork, at; active_default=true) -> Vector{Tuple}

The edges of the base network active at time `at`, as `(i, j)` tuples
(`(min, max)` on undirected networks); edges with no spell record count as
active when `active_default=true`. Edge activity does not look at the
endpoints' activity (as in R); [`network_extract`](@ref) does.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; edge=(1, 2))
activate!(dnet, 4.0, 8.0; edge=(2, 3))
sort(active_edges(dnet, 4.5))       # [(1, 2), (2, 3)]
```
"""
function active_edges(dnet::DynamicNetwork{T, Time}, at;
                      active_default::Bool=true) where {T, Time}
    at = convert(Time, at)
    result = Tuple{T,T}[]
    for e in edges(dnet.network)
        key = _edge_key(dnet, (T(src(e)), T(dst(e))))
        _record_active_at(_edge_record(dnet, key), at, active_default) && push!(result, key)
    end
    return result
end

"""
    get_activity_range(dnet::DynamicNetwork; vertex=nothing, edge=nothing) -> Union{Tuple, Nothing}

The earliest onset and latest terminus of an element's stored spells, or
`nothing` when it has none.

Note: censored spells report their *observed* bounds, so with
`onset_censored`/`terminus_censored` spells this is the observed, not the
true, activity range.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 1.0, 3.0; vertex=1)
activate!(dnet, 6.0, 9.0; vertex=1)
get_activity_range(dnet; vertex=1)  # (1.0, 9.0)
```
"""
function get_activity_range(dnet::DynamicNetwork{T, Time};
                            vertex::Union{Nothing, Integer}=nothing,
                            edge::Union{Nothing, Tuple{Integer,Integer}}=nothing) where {T, Time}
    vertex, edge = _as_vertex(dnet, vertex), _as_edge(dnet, edge)
    spells = get_spells(dnet; vertex=vertex, edge=edge)
    isempty(spells) && return nothing

    earliest = minimum(s.onset for s in spells)
    latest = maximum(s.terminus for s in spells)
    return (earliest, latest)
end

"""
    when_vertex(dnet::DynamicNetwork, v) -> Vector{Spell}

The stored activity spells of vertex `v` (same as `get_spells(dnet; vertex=v)`).

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 2.0, 4.0; vertex=1)
when_vertex(dnet, 1)                # [Spell[2.0, 4.0)]
```
"""
when_vertex(dnet::DynamicNetwork{T, Time}, v::Integer) where {T, Time} = get_spells(dnet; vertex=T(v))

"""
    when_edge(dnet::DynamicNetwork, i, j) -> Vector{Spell}

The stored activity spells of edge `(i, j)` (same as `get_spells(dnet; edge=(i, j))`).

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 2.0, 4.0; edge=(1, 2))
when_edge(dnet, 1, 2)               # [Spell[2.0, 4.0)]
```
"""
when_edge(dnet::DynamicNetwork{T, Time}, i::Integer, j::Integer) where {T, Time} =
    get_spells(dnet; edge=(T(i), T(j)))

"""
    get_vertex_activity(dnet::DynamicNetwork, v; active_default=true) -> Vector{Spell}

The activity spells of vertex `v`, after R networkDynamic's
`get.vertex.activity`: a vertex with no spell record is reported as the
unbounded spell `(-Inf, Inf)` when `active_default=true` (an empty vector
otherwise).

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; vertex=1)
get_vertex_activity(dnet, 1)        # [Spell[0.0, 5.0)]
get_vertex_activity(dnet, 2)        # [Spell[-Inf, Inf)]: active by default
```
"""
function get_vertex_activity(dnet::DynamicNetwork{T, Time}, v::Integer;
                             active_default::Bool=true) where {T, Time}
    rec = _vertex_record(dnet, T(v))
    isnothing(rec) && return active_default ? [_always(Time)] : Spell{Time}[]
    return rec
end

"""
    get_edge_activity(dnet::DynamicNetwork, i, j; active_default=true) -> Vector{Spell}

The activity spells of edge `(i, j)`, after R networkDynamic's
`get.edge.activity`: an edge of the base network with no spell record is
reported as `(-Inf, Inf)` when `active_default=true`. An edge that is not in
the base network has no spells.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 1.0, 4.0; edge=(1, 2))
get_edge_activity(dnet, 1, 2)       # [Spell[1.0, 4.0)]
```
"""
function get_edge_activity(dnet::DynamicNetwork{T, Time}, i::Integer, j::Integer;
                           active_default::Bool=true) where {T, Time}
    key = _edge_key(dnet, (T(i), T(j)))
    has_edge(dnet.network, key[1], key[2]) || return Spell{Time}[]
    rec = _edge_record(dnet, key)
    isnothing(rec) && return active_default ? [_always(Time)] : Spell{Time}[]
    return rec
end

# =============================================================================
# Network Extraction
# =============================================================================

"""
    network_extract(dnet::DynamicNetwork, at; retain_all_vertices=false,
                    active_default=true, report=false) -> Network
    network_extract(dnet::DynamicNetwork, onset, terminus; rule=:any,
                    retain_all_vertices=false, active_default=true, report=false) -> Network

Extract the static network active at the instant `at`, or during
`[onset, terminus)` (`rule=:any`: active at any point; `rule=:all`: active
throughout, across adjacent spells). A vertex is included when active; an
edge when it is active *and* both endpoints are (R's `network.extract`).
Elements with no spell record are active when `active_default=true` (R's
default).

With `retain_all_vertices=true`, all base vertices are kept (inactive ones
as isolates), so vertex IDs are stable across time slices. With the default
`retain_all_vertices=false`, inactive vertices are dropped and survivors
are renumbered densely to `1:k`; each extracted vertex's original ID is
recorded in the `:vertex_pid` vertex attribute (persistent ID, after R
networkDynamic's `vertex.pid`) so slices can still be aligned over time.

# Conversion invariants

Preserved either way: directedness, the `loops` flag, static vertex, edge and
network attributes, and the **missing-dyad mask** (an unobserved dyad of the
base network is unobserved in every snapshot of it — it does not silently
become an absent tie). Two-mode metadata survives only under
`retain_all_vertices=true`; renumbering destroys the mode partition.

Inherently dropped (a static network has no time axis): spells, time-varying
attributes, and the observation period. Pass `report=true` to get
`(net, ::NetworkCore.ConversionReport)` naming everything the extraction dropped.

# Example
```julia
using DynamicNetworks, NetworkCore   # NetworkCore for nv/ne
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; edge=(1, 2))
activate!(dnet, 4.0, 8.0; edge=(2, 3))
activate!(dnet, 0.0, 3.0; vertex=3)
snap = network_extract(dnet, 4.5)          # vertex 3 inactive, so (2,3) is dropped
nv(snap), ne(snap)                         # (2, 1)
ne(network_extract(dnet, 0.0, 10.0))       # 2: union over the interval
```
"""
function network_extract(dnet::DynamicNetwork{T, Time}, at;
                         retain_all_vertices::Bool=false,
                         active_default::Bool=true,
                         report::Bool=false) where {T, Time}
    at = convert(Time, at)
    edge_active = rec -> _record_active_at(rec, at, active_default)
    vert_active = rec -> _record_active_at(rec, at, active_default)
    net, rep = _extract(dnet, vert_active, edge_active, retain_all_vertices)
    return report ? (net, rep) : net
end

function network_extract(dnet::DynamicNetwork{T, Time}, onset, terminus;
                         rule::Symbol=:any,
                         retain_all_vertices::Bool=false,
                         active_default::Bool=true,
                         report::Bool=false) where {T, Time}
    onset, terminus = convert(Time, onset), convert(Time, terminus)
    rule in (:any, :all) || throw(ArgumentError("rule must be :any or :all"))
    onset <= terminus || throw(ArgumentError("onset must be <= terminus"))
    active = rec -> _record_active_in(rec, onset, terminus, rule, active_default)
    net, rep = _extract(dnet, active, active, retain_all_vertices)
    return report ? (net, rep) : net
end

# Shared extraction machinery: `vert_active(record)` and `edge_active(record)`
# decide inclusion from an element's spell record (`nothing` = no record).
# Everything the static target can hold is carried across — directedness,
# loops, two-mode metadata (when IDs are stable), vertex/edge/network
# attributes, and the missing-dyad mask; what a static network cannot hold is
# named in the returned ConversionReport. Original vertex IDs are preserved
# (retain_all_vertices) or recorded as :vertex_pid.
function _extract(dnet::DynamicNetwork{T, Time, D}, vert_active, edge_active,
                  retain_all_vertices::Bool) where {T, Time, D}
    base = dnet.network
    n = nv(base)
    is_on = falses(n)
    for v in 1:n
        is_on[v] = vert_active(_vertex_record(dnet, T(v)))
    end
    active_verts = T[T(v) for v in 1:n if is_on[v]]
    rep = ConversionReport(:DynamicNetwork, :Network)

    new_id = zeros(T, n)
    if retain_all_vertices
        new_id .= T.(1:n)
        extracted = Network{T, D}(; n=n, loops=base.loops, bipartite=base.bipartite)
    else
        for (i, v) in enumerate(active_verts)
            new_id[v] = T(i)
        end
        # Renumbering to 1:k destroys the "vertices 1:k are mode 1" invariant
        # that the two-mode flag encodes, so it cannot be carried.
        if !isnothing(base.bipartite)
            record_drop!(rep, :bipartite,
                         "two-mode metadata cannot survive vertex renumbering; " *
                         "pass retain_all_vertices=true to keep it")
        end
        extracted = Network{T, D}(; n=length(active_verts), loops=base.loops)
        # Persistent IDs: map extracted vertices back to base-network IDs
        for v in active_verts
            set_vertex_attribute!(extracted, :vertex_pid, new_id[v], v)
        end
    end

    # Add active edges (only between active endpoints) with attributes. The
    # universe is the base network's edge set: an edge with no spell record is
    # decided by `edge_active(nothing)` (the active_default).
    for e in edges(base)
        i, j = T(src(e)), T(dst(e))
        key = _edge_key(dnet, (i, j))
        (is_on[i] && is_on[j]) || continue
        edge_active(_edge_record(dnet, key)) || continue
        ni, nj = new_id[i], new_id[j]
        add_edge!(extracted, ni, nj)
        for (attr_name, attr_dict) in base.edge_attrs
            akey = D ? (i, j) : minmax(i, j)
            if haskey(attr_dict, akey)
                set_edge_attribute!(extracted, attr_name, ni, nj, attr_dict[akey])
            end
        end
    end

    # Copy static vertex attributes of surviving vertices (all vertices
    # survive when retain_all_vertices is set)
    for v in (retain_all_vertices ? T.(1:n) : active_verts)
        nid = new_id[v]
        for (attr_name, attr_dict) in base.vertex_attrs
            if haskey(attr_dict, v)
                set_vertex_attribute!(extracted, attr_name, nid, attr_dict[v])
            end
        end
    end

    # Network-level attributes are representable and therefore copied.
    for (attr_name, val) in base.network_attrs
        set_network_attribute!(extracted, attr_name, val)
    end

    # The missing-dyad mask: an unobserved dyad of the base network stays
    # unobserved in the snapshot. Entries whose endpoints did not survive the
    # extraction cannot be represented and are reported, never silently lost.
    n_mask_dropped = 0
    for (i, j) in missing_dyads(base)
        if retain_all_vertices || (is_on[i] && is_on[j])
            set_missing_dyad!(extracted, new_id[i], new_id[j])
        else
            n_mask_dropped += 1
        end
    end
    if n_mask_dropped > 0
        record_drop!(rep, :missing_dyads,
                     "$n_mask_dropped masked dyad(s) have an endpoint that is " *
                     "inactive in this extraction and were not carried; pass " *
                     "retain_all_vertices=true to keep the whole mask")
    end

    record_drop!(rep, :spells,
                 "a static network has no time axis; vertex and edge activity " *
                 "spells are collapsed to presence/absence")
    if !isempty(dnet.vertex_tea) || !isempty(dnet.edge_tea)
        record_drop!(rep, :time_varying_attributes,
                     "time-varying (TEA) attribute values are not copied; read " *
                     "them with get_vertex_attribute_active/get_edge_attribute_active")
    end
    window = get_observation_period(dnet)
    isnothing(window) || record_drop!(rep, :observation_period,
                                      "the observation window $window has no static " *
                                      "counterpart")

    return extracted, rep
end

"""
    network_slice(dnet::DynamicNetwork, times::AbstractVector; kwargs...) -> Vector{Network}

Extract a sequence of static networks at the given instants. Keyword
arguments (`retain_all_vertices`, `active_default`) are forwarded to
[`network_extract`](@ref); `report=true` is not meaningful here and is
rejected.

# Example
```julia
using DynamicNetworks, NetworkCore   # NetworkCore for nv/ne
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 5.0; edge=(1, 2))
ne.(network_slice(dnet, [1.0, 6.0]))       # [1, 0]
```
"""
function network_slice(dnet::DynamicNetwork{T, Time}, times::AbstractVector;
                       report::Bool=false, kwargs...) where {T, Time}
    report && throw(ArgumentError(
        "network_slice returns a vector of networks; call network_extract " *
        "directly for a per-slice ConversionReport"))
    return [network_extract(dnet, t; kwargs...) for t in times]
end

"""
    network_collapse(dnet::DynamicNetwork; onset=nothing, terminus=nothing,
                     rule=:any, active_default=true, report=false) -> Network

Collapse the dynamic network to a static one: R's `network.collapse`, which
is `network.extract` over `[onset, terminus)` (the whole time axis when they
are not given) under `rule` (`:any`: active at some point; `:all`:
throughout, possibly across adjacent spells). An edge is included when it
and both its endpoints are active under that rule; elements with no spell
record are active when `active_default=true`.

One deliberate difference from R: **all base vertices are kept** (vertex IDs
are stable, inactive vertices are isolates), so the result equals
`network_extract(dnet, onset, terminus; rule, retain_all_vertices=true)`.
R's attribute aggregation (`activity.count`, `activity.duration`, TEA
summaries) is not implemented.

Because vertex IDs are stable, everything the static target can hold survives:
directedness, `loops`, two-mode metadata, static vertex/edge/network
attributes, and the full missing-dyad mask. Spells, time-varying attributes
and the observation window are dropped by nature; pass `report=true` for
`(net, ::NetworkCore.ConversionReport)` naming them.

# Example
```julia
using DynamicNetworks, NetworkCore   # NetworkCore for nv/ne
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=20.0)
activate!(dnet, 0.0, 5.0; edge=(1, 2))
activate!(dnet, 5.0, 10.0; edge=(1, 2))      # adjacent: merged to [0, 10)
activate!(dnet, 12.0, 15.0; edge=(2, 3))
ne(network_collapse(dnet))                                         # 2
ne(network_collapse(dnet; onset=2.0, terminus=8.0, rule=:all))     # 1
```
"""
function network_collapse(dnet::DynamicNetwork{T, Time};
                          onset=nothing, terminus=nothing,
                          rule::Symbol=:any, active_default::Bool=true,
                          report::Bool=false) where {T, Time}
    rule in (:any, :all) || throw(ArgumentError("rule must be :any or :all"))
    (isnothing(onset) == isnothing(terminus)) || throw(ArgumentError(
        "give both onset and terminus, or neither (the whole time axis)"))
    active = if isnothing(onset)
        # The whole axis (-Inf, Inf): rule=:any is "ever active"; rule=:all
        # "always active" (R's onset = -Inf, terminus = Inf)
        lo, hi = _time_neginf(Time), _time_posinf(Time)
        rec -> _record_active_in(rec, lo, hi, rule, active_default)
    else
        lo, hi = convert(Time, onset), convert(Time, terminus)
        lo <= hi || throw(ArgumentError("onset must be <= terminus"))
        rec -> _record_active_in(rec, lo, hi, rule, active_default)
    end

    net, rep = _extract(dnet, active, active, true)
    return report ? (net, rep) : net
end

"""
    get_timing_info(dnet::DynamicNetwork) -> NamedTuple

Summary timing information: the observation window
([`get_observation_period`](@ref); `nothing` when none was given), the
earliest onset and latest terminus of
the stored spells (`nothing` when there are none), and the stored vertex and
edge spell counts.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 2.0, 6.0; edge=(1, 2))
info = get_timing_info(dnet)
info.data_start, info.data_end, info.n_edge_spells   # (2.0, 6.0, 1)
```
"""
function get_timing_info(dnet::DynamicNetwork{T, Time}) where {T, Time}
    all_onsets = Time[]
    all_termini = Time[]

    for spells in values(dnet.vertex_spells)
        for s in spells
            push!(all_onsets, s.onset)
            push!(all_termini, s.terminus)
        end
    end
    for spells in values(dnet.edge_spells)
        for s in spells
            push!(all_onsets, s.onset)
            push!(all_termini, s.terminus)
        end
    end

    if isempty(all_onsets)
        return (
            observation_period=get_observation_period(dnet),
            data_start=nothing,
            data_end=nothing,
            n_vertex_spells=0,
            n_edge_spells=0
        )
    end

    return (
        observation_period=get_observation_period(dnet),
        data_start=minimum(all_onsets),
        data_end=maximum(all_termini),
        n_vertex_spells=sum(length(v) for v in values(dnet.vertex_spells); init=0),
        n_edge_spells=sum(length(v) for v in values(dnet.edge_spells); init=0)
    )
end

# =============================================================================
# Time-Varying Attributes
# =============================================================================

"""
    set_vertex_attribute_active!(dnet, v, attr, value, onset, terminus) -> dnet

Set a time-varying vertex attribute: `attr` of vertex `v` takes `value`
during `[onset, terminus)` (R's `activate.vertex.attribute`).

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
set_vertex_attribute_active!(dnet, 1, :status, "S", 0.0, 4.0)
set_vertex_attribute_active!(dnet, 1, :status, "I", 4.0, 10.0)
get_vertex_attribute_active(dnet, 1, :status, 5.0)   # "I"
```
"""
function set_vertex_attribute_active!(dnet::DynamicNetwork{T, Time}, v::Integer,
                                      attr::Symbol, value, onset, terminus) where {T, Time}
    key = (T(v), attr)
    if !haskey(dnet.vertex_tea, key)
        dnet.vertex_tea[key] = TimeVaryingAttribute{Time, typeof(value)}()
    end
    tea = dnet.vertex_tea[key]
    push!(tea.values, value)
    push!(tea.spells, Spell(convert(Time, onset), convert(Time, terminus)))
    return dnet
end

"""
    get_vertex_attribute_active(dnet, v, attr, at) -> value

The value of a time-varying vertex attribute at time `at`, or `nothing`
(R's `get.vertex.attribute.active`). When several attribute spells cover
`at`, the most recently set value wins.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
set_vertex_attribute_active!(dnet, 1, :age, 30, 0.0, 5.0)
get_vertex_attribute_active(dnet, 1, :age, 2.0)      # 30
get_vertex_attribute_active(dnet, 1, :age, 7.0)      # nothing
```
"""
function get_vertex_attribute_active(dnet::DynamicNetwork{T, Time}, v::Integer,
                                     attr::Symbol, at) where {T, Time}
    at = convert(Time, at)
    key = (T(v), attr)
    !haskey(dnet.vertex_tea, key) && return nothing

    tea = dnet.vertex_tea[key]
    for i in reverse(eachindex(tea.spells))
        if spell_active_at(tea.spells[i], at)
            return tea.values[i]
        end
    end
    return nothing
end

"""
    set_edge_attribute_active!(dnet, i, j, attr, value, onset, terminus) -> dnet

Set a time-varying edge attribute: `attr` of edge `(i, j)` takes `value`
during `[onset, terminus)` (R's `activate.edge.attribute`).

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 10.0; edge=(1, 2))
set_edge_attribute_active!(dnet, 1, 2, :weight, 0.5, 0.0, 5.0)
get_edge_attribute_active(dnet, 1, 2, :weight, 1.0)  # 0.5
```
"""
function set_edge_attribute_active!(dnet::DynamicNetwork{T, Time}, i::Integer, j::Integer,
                                    attr::Symbol, value, onset, terminus) where {T, Time}
    key = (_edge_key(dnet, (T(i), T(j))), attr)
    if !haskey(dnet.edge_tea, key)
        dnet.edge_tea[key] = TimeVaryingAttribute{Time, typeof(value)}()
    end
    tea = dnet.edge_tea[key]
    push!(tea.values, value)
    push!(tea.spells, Spell(convert(Time, onset), convert(Time, terminus)))
    return dnet
end

"""
    get_edge_attribute_active(dnet, i, j, attr, at) -> value

The value of a time-varying edge attribute at time `at`, or `nothing`
(R's `get.edge.attribute.active`). When several attribute spells cover `at`,
the most recently set value wins.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; directed=false, observation_start=0.0, observation_end=10.0)
set_edge_attribute_active!(dnet, 1, 2, :weight, 2.0, 0.0, 5.0)
get_edge_attribute_active(dnet, 2, 1, :weight, 3.0)  # 2.0 (undirected)
```
"""
function get_edge_attribute_active(dnet::DynamicNetwork{T, Time}, i::Integer, j::Integer,
                                   attr::Symbol, at) where {T, Time}
    at = convert(Time, at)
    key = (_edge_key(dnet, (T(i), T(j))), attr)
    !haskey(dnet.edge_tea, key) && return nothing

    tea = dnet.edge_tea[key]
    for idx in reverse(eachindex(tea.spells))
        if spell_active_at(tea.spells[idx], at)
            return tea.values[idx]
        end
    end
    return nothing
end

"""
    list_vertex_attributes_active(dnet::DynamicNetwork) -> Vector{Symbol}

The names of all time-varying vertex attributes.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
set_vertex_attribute_active!(dnet, 1, :status, "S", 0.0, 4.0)
list_vertex_attributes_active(dnet)  # [:status]
```
"""
function list_vertex_attributes_active(dnet::DynamicNetwork)
    return unique([key[2] for key in keys(dnet.vertex_tea)])
end

"""
    list_edge_attributes_active(dnet::DynamicNetwork) -> Vector{Symbol}

The names of all time-varying edge attributes.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
set_edge_attribute_active!(dnet, 1, 2, :weight, 1.0, 0.0, 4.0)
list_edge_attributes_active(dnet)    # [:weight]
```
"""
function list_edge_attributes_active(dnet::DynamicNetwork)
    return unique([key[2] for key in keys(dnet.edge_tea)])
end

# =============================================================================
# Conversion and Reconciliation
# =============================================================================

"""
    as_dynamic_network(net::Network; onset=0.0, terminus=1.0, report=false) -> DynamicNetwork

Convert a static network to a dynamic network with all elements active
during the specified period. Mixed numeric `onset`/`terminus` types are
promoted (e.g. `onset=0, terminus=10.0` gives a `Float64` time axis);
`DateTime`/`Date` values give a calendar time axis.

# Conversion invariants

This direction is **lossless**: a `DynamicNetwork` wraps a `Network`, so the
whole source object is carried into it by `copy` — directedness, the `loops`
flag, two-mode metadata, vertex, edge and network attributes, and the
missing-dyad mask (a dyad that was unobserved statically is unobserved for the
whole observation window). Every vertex and every edge gets the single spell
`[onset, terminus)`, and the observation window is set to it, so
`network_collapse(as_dynamic_network(net))` reproduces `net`.

`report=true` returns `(dnet, ::NetworkCore.ConversionReport)`; the report is
lossless.

# Example
```julia
using DynamicNetworks, NetworkCore
net = network(3; directed=false)
add_edge!(net, 1, 2)
dnet = as_dynamic_network(net; onset=0.0, terminus=10.0)
is_active(dnet, 5.0; edge=(2, 1))    # true
```
"""
function as_dynamic_network(net::Network{T, D}; onset=0.0, terminus=1.0,
                            report::Bool=false) where {T, D}
    Time = promote_type(typeof(onset), typeof(terminus))
    onset, terminus = convert(Time, onset), convert(Time, terminus)
    dnet = DynamicNetwork{T, Time, D}(Int(nv(net));
                                      observation_start=onset,
                                      observation_end=terminus)

    # Carry the *whole* static object into the base network: attributes, the
    # loops/two-mode flags, and the missing-dyad mask. Rebuilding a bare
    # Network from the vertex count (as this used to) silently discarded all
    # of them, and dropped self-loops outright when `loops=true`.
    dnet.network = copy(net)

    spell = Spell(onset, terminus)

    # Activate all vertices
    for v in 1:nv(net)
        add_spell!(dnet, spell; vertex=T(v))
    end

    # Activate all edges
    for e in edges(net)
        add_spell!(dnet, spell; edge=(T(src(e)), T(dst(e))))
    end

    rep = ConversionReport(:Network, :DynamicNetwork)
    return report ? (dnet, rep) : dnet
end

"""
    as_dynamic_network(networks::AbstractVector{<:Network}; onsets=nothing,
                       termini=nothing, start=nothing, report=false) -> DynamicNetwork
    DynamicNetwork(networks::AbstractVector{<:Network}; onsets=nothing,
                   termini=nothing, start=nothing) -> DynamicNetwork

Build a dynamic network from a panel of static networks observed one after
another: R networkDynamic's `networkDynamic(network.list = networks)`, with
its discrete-spell semantics.

- Network `k` holds during `[onsets[k], termini[k])`. By default each panel
  is one time step long: `onsets = start .+ (0:K-1)` and `termini = onsets .+ 1`,
  with `start = 0` (R's "each network in network.list should have a discrete
  spell of length 1").
- Every vertex is active in every panel's spell, and every tie present in
  panel `k` is active during that panel's spell. Spells are merged, so a tie
  present in consecutive panels has one spell (it forms once), as in R.
- The observation window is `(minimum(onsets), maximum(termini))`. R records
  each panel's spell in `net.obs.period`; a `DynamicNetwork` holds one
  window, so gaps between non-contiguous panels are not recorded (tsna uses
  only the outer range of `net.obs.period` either way).
- Vertices are matched by position: every panel must have the same number of
  vertices, directedness, `loops` flag and two-mode partition (R's
  `vertex.pid` matching of panels with different vertex sets is not
  implemented, and is refused with an `ArgumentError`).

# Conversion invariants

The base network takes the static vertex and network attributes of the
**first** panel (R's `base.net` default). A missing-dyad mask is carried when
every panel has the same one; panels with different masks are refused,
because a `DynamicNetwork` has no time-varying mask. Edge attributes, and
vertex or network attributes that differ in later panels, have no slot (R
would need `create.TEAs = TRUE`) and are named in the
`NetworkCore.ConversionReport` that `report=true` returns as `(dnet, rep)`.

# Example
```julia
using DynamicNetworks, NetworkCore
w1 = network(3); add_edge!(w1, 1, 2)
w2 = network(3); add_edge!(w2, 1, 2); add_edge!(w2, 2, 3)
w3 = network(3); add_edge!(w3, 2, 3)
dnet = DynamicNetwork([w1, w2, w3])
get_spells(dnet; edge=(1, 2))       # [Spell[0.0, 2.0)]: waves 1 and 2, one spell
get_spells(dnet; edge=(2, 3))       # [Spell[1.0, 3.0)]
get_observation_period(dnet)        # (0.0, 3.0)
```
"""
function as_dynamic_network(networks::AbstractVector{<:Network};
                            onsets=nothing, termini=nothing, start=nothing,
                            report::Bool=false)
    K = length(networks)
    K >= 1 || throw(ArgumentError("a panel needs at least one network"))
    net1 = first(networks)
    T, D = _vertex_type(net1), is_directed(net1)
    n = Int(nv(net1))
    for (k, net) in enumerate(networks)
        Int(nv(net)) == n || throw(ArgumentError(
            "network $k of the panel has $(nv(net)) vertices and network 1 has $n; " *
            "panels are matched by vertex position, so they must share one vertex " *
            "set (R's vertex.pid matching is not implemented)"))
        is_directed(net) == D || throw(ArgumentError(
            "network $k of the panel differs from network 1 in directedness"))
        net.loops == net1.loops || throw(ArgumentError(
            "network $k of the panel differs from network 1 in its loops flag"))
        net.bipartite == net1.bipartite || throw(ArgumentError(
            "network $k of the panel differs from network 1 in its two-mode partition"))
    end

    # Spells of the panels: R's defaults, or the caller's.
    if isnothing(onsets) && isnothing(termini)
        s0 = isnothing(start) ? 0.0 : start
        onsets = [s0 + (k - 1) for k in 1:K]
        termini = [o + 1 for o in onsets]
    elseif isnothing(onsets) || isnothing(termini)
        throw(ArgumentError("give both onsets and termini, or neither"))
    else
        isnothing(start) || throw(ArgumentError(
            "start sets the default onsets; it cannot be combined with onsets/termini"))
    end
    length(onsets) == K && length(termini) == K || throw(ArgumentError(
        "onsets and termini need one entry per network ($K)"))
    Time = promote_type(eltype(onsets), eltype(termini))
    ons = Time[convert(Time, o) for o in onsets]
    ters = Time[convert(Time, t) for t in termini]
    for k in 1:K
        ons[k] <= ters[k] || throw(ArgumentError(
            "the spell of network $k has onset $(ons[k]) after terminus $(ters[k])"))
    end

    rep = ConversionReport(:NetworkPanel, :DynamicNetwork)

    # The missing-dyad mask is static in a DynamicNetwork: carry it only when
    # every panel shares it.
    mask1 = Set(missing_dyads(net1))
    for (k, net) in enumerate(networks)
        Set(missing_dyads(net)) == mask1 || throw(ArgumentError(
            "network $k of the panel has a different missing-dyad mask from network 1; " *
            "a DynamicNetwork holds one static mask, so a mask that changes over " *
            "time cannot be represented"))
    end

    base = Network{T, D}(; n=n, loops=net1.loops, bipartite=net1.bipartite)
    for (attr_name, attr_dict) in net1.vertex_attrs, (v, val) in attr_dict
        set_vertex_attribute!(base, attr_name, T(v), val)
    end
    for (attr_name, val) in net1.network_attrs
        set_network_attribute!(base, attr_name, val)
    end
    for (i, j) in mask1
        set_missing_dyad!(base, T(i), T(j))
    end
    any(net -> !isempty(net.edge_attrs), networks) &&
        record_drop!(rep, :edge_attributes,
                     "edge attributes of the panels are not carried (a time-varying " *
                     "edge attribute would be a TEA; set them with " *
                     "set_edge_attribute_active!)")
    if any(net -> net.vertex_attrs != net1.vertex_attrs ||
                  net.network_attrs != net1.network_attrs, networks)
        record_drop!(rep, :panel_attributes,
                     "vertex or network attributes that differ from the first panel " *
                     "are not carried; the base network takes the first panel's")
    end

    dnet = DynamicNetwork{T, Time, D}(n; observation_start=minimum(ons),
                                      observation_end=maximum(ters))
    dnet.network = base
    for (k, net) in enumerate(networks)
        spell = Spell(ons[k], ters[k])
        for v in 1:n
            add_spell!(dnet, spell; vertex=T(v))
        end
        for e in edges(net)
            add_spell!(dnet, spell; edge=(T(src(e)), T(dst(e))))
        end
    end
    return report ? (dnet, rep) : dnet
end

_vertex_type(::Network{T}) where T = T

DynamicNetwork(networks::AbstractVector{<:Network}; onsets=nothing, termini=nothing,
               start=nothing) =
    as_dynamic_network(networks; onsets=onsets, termini=termini, start=start)

# Intersection of two spells (point spells included); censoring flags travel
# with the bound that survives. Returns `nothing` when they do not meet.
function _intersect(a::Spell{Time}, b::Spell{Time}) where Time
    if _is_point(a) || _is_point(b)
        p, q = _is_point(a) ? (a, b) : (b, a)
        spell_active_at(q, p.onset) || return nothing
        return Spell(p.onset, p.onset;
                     onset_censored=p.onset_censored, terminus_censored=p.terminus_censored)
    end
    lo, hi = max(a.onset, b.onset), min(a.terminus, b.terminus)
    lo < hi || return nothing
    on_c = (lo == a.onset && a.onset_censored) || (lo == b.onset && b.onset_censored)
    te_c = (hi == a.terminus && a.terminus_censored) || (hi == b.terminus && b.terminus_censored)
    return Spell(lo, hi; onset_censored=on_c, terminus_censored=te_c)
end

function _intersect_sets(A, B, ::Type{Time}) where Time
    out = Spell{Time}[]
    for a in A, b in B
        s = _intersect(a, b)
        isnothing(s) || push!(out, s)
    end
    return out
end

"""
    reconcile_activity!(dnet::DynamicNetwork) -> dnet

Make edge activity consistent with vertex activity: an edge is kept active
only while both endpoints are active (R networkDynamic's
`reconcile.edge.activity(mode = "reduce.to.vertices")`). Elements with no
spell record are active by default, so

- an edge whose endpoints both have no vertex record is left unchanged;
- an edge with no record of its own becomes the intersection of its
  endpoints' activity;
- an endpoint whose spells were all removed (never active) leaves the edge
  inactive.

Point spells survive (an instantaneous edge event inside vertex activity is
kept), and censoring flags travel with the bound that survives.

# Example
```julia
using DynamicNetworks
dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
activate!(dnet, 0.0, 4.0; vertex=1)
activate!(dnet, 2.0, 8.0; vertex=2)
activate!(dnet, 0.0, 10.0; edge=(1, 2))
reconcile_activity!(dnet)
get_spells(dnet; edge=(1, 2))        # [Spell[2.0, 4.0)]
```
"""
function reconcile_activity!(dnet::DynamicNetwork{T, Time}) where {T, Time}
    full = [_always(Time)]
    for e in edges(dnet.network)
        i, j = T(src(e)), T(dst(e))
        key = _edge_key(dnet, (i, j))
        vi, vj = _vertex_record(dnet, i), _vertex_record(dnet, j)
        # Both endpoints active by default: nothing constrains the edge
        isnothing(vi) && isnothing(vj) && continue
        es = _edge_record(dnet, key)
        E = isnothing(es) ? full : es
        reduced = _intersect_sets(_intersect_sets(E, isnothing(vi) ? full : vi, Time),
                                  isnothing(vj) ? full : vj, Time)
        dnet.edge_spells[key] = merge_spell_vector(reduced)
    end

    _touch!(dnet)
    return dnet
end

# Time-to-first-extract: compile the README path (activation, queries,
# extraction, collapse, reconciliation) for both directedness flavours.
@setup_workload begin
    @compile_workload begin
        for directed in (true, false)
            d = DynamicNetwork(4; directed=directed, observation_start=0.0,
                               observation_end=10.0)
            activate!(d, 0.0, 5.0; edge=(1, 2))
            activate!(d, 5.0, 8.0; edge=(1, 2))
            activate!(d, 3.0, 3.0; edge=(2, 3))
            activate!(d, 2.0, 9.0; vertex=3)
            deactivate!(d, 6.0, 7.0; vertex=4)
            is_active(d, 1.0; vertex=1); is_active(d, 0.0, 4.0; edge=(1, 2), rule=:all)
            active_vertices(d, 1.0); active_edges(d, 1.0)
            network_extract(d, 1.0); network_extract(d, 0.0, 5.0; rule=:all)
            network_extract(d, 1.0; retain_all_vertices=true)
            network_collapse(d); network_collapse(d; onset=0.0, terminus=4.0)
            get_observation_period(d); get_change_times(d)
            reconcile_activity!(d)
        end
    end
end

end # module
