using DynamicNetworks
using NetworkCore
using Test
using Graphs
using Dates
using Aqua

@testset "DynamicNetworks.jl" begin
    @testset "Module loading" begin
        @test @isdefined(DynamicNetworks)
    end

    @testset "Spell construction" begin
        s = Spell(0.0, 1.0)
        @test s isa Spell{Float64}
        @test s.onset == 0.0
        @test s.terminus == 1.0
        @test s.onset_censored == false
        @test s.terminus_censored == false

        s2 = Spell(0.0, 1.0; onset_censored=true)
        @test s2.onset_censored == true

        @test_throws ArgumentError Spell(1.0, 0.0)
    end

    @testset "Spell utilities" begin
        s1 = Spell(0.0, 2.0)
        s2 = Spell(1.0, 3.0)
        s3 = Spell(3.0, 4.0)

        @test spell_overlap(s1, s2) == true
        @test spell_overlap(s1, s3) == false
        @test spell_duration(s1) == 2.0
    end

    @testset "DynamicNetwork construction" begin
        dnet = DynamicNetwork(5)
        @test dnet isa DynamicNetwork{Int, Float64}
        @test Graphs.nv(dnet) == 5
        @test Graphs.ne(dnet) == 0

        dnet2 = DynamicNetwork{Int, Float64}(3;
            observation_start=0.0, observation_end=10.0, directed=false)
        @test get_observation_period(dnet2) == (0.0, 10.0)
    end

    @testset "Spell operations" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)

        activate!(dnet, 0.0, 5.0; vertex=1)
        activate!(dnet, 3.0, 8.0; vertex=1)
        spells = get_spells(dnet; vertex=1)
        # Activation merges overlapping spells, as R's activate.vertices does
        @test spells == [Spell(0.0, 8.0)]
        # merge=false keeps them as given
        add_spell!(dnet, Spell(6.0, 9.0); vertex=2, merge=false)
        add_spell!(dnet, Spell(0.0, 7.0); vertex=2, merge=false)
        @test get_spells(dnet; vertex=2) == [Spell(0.0, 7.0), Spell(6.0, 9.0)]
        merge_spells!(dnet)                       # every element at once
        @test get_spells(dnet; vertex=2) == [Spell(0.0, 9.0)]
        # Out-of-range vertices and impossible edges are refused, not stored
        @test_throws ArgumentError activate!(dnet, 0.0, 1.0; vertex=4)
        @test_throws ArgumentError activate!(dnet, 0.0, 1.0; edge=(1, 5))
        @test_throws ArgumentError activate!(dnet, 0.0, 1.0; edge=(2, 2))   # loops=false
        @test !haskey(dnet.edge_spells, (2, 2))

        activate!(dnet, 1.0, 4.0; edge=(1, 2))
        @test is_active(dnet, 2.0; edge=(1, 2)) == true
        @test is_active(dnet, 5.0; edge=(1, 2)) == false
    end

    @testset "deactivate!" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        activate!(dnet, 0.0, 10.0; vertex=1)

        # Punch a hole: [0,10) minus [3,6) leaves [0,3) and [6,10)
        deactivate!(dnet, 3.0, 6.0; vertex=1)
        @test get_spells(dnet; vertex=1) == [Spell(0.0, 3.0), Spell(6.0, 10.0)]
        @test is_active(dnet, 2.0; vertex=1)
        @test !is_active(dnet, 4.0; vertex=1)
        @test is_active(dnet, 7.0; vertex=1)

        # Truncation at the boundaries and full removal
        activate!(dnet, 0.0, 5.0; edge=(1, 2))
        deactivate!(dnet, 0.0, 2.0; edge=(1, 2))
        @test get_spells(dnet; edge=(1, 2)) == [Spell(2.0, 5.0)]
        deactivate!(dnet, 0.0, 10.0; edge=(1, 2))
        @test isempty(get_spells(dnet; edge=(1, 2)))

        # Non-overlapping deactivation is a no-op
        activate!(dnet, 0.0, 2.0; vertex=2)
        deactivate!(dnet, 5.0, 8.0; vertex=2)
        @test get_spells(dnet; vertex=2) == [Spell(0.0, 2.0)]
        # No recorded spells: active by default, i.e. (-Inf, Inf), so the
        # deactivation cuts a hole in it (R deactivate.vertices)
        deactivate!(dnet, 0.0, 5.0; vertex=3)
        @test get_spells(dnet; vertex=3) == [Spell(-Inf, 0.0), Spell(5.0, Inf)]
        @test !is_active(dnet, 2.0; vertex=3) && is_active(dnet, 6.0; vertex=3)

        # Censoring flags survive on the fragments
        dnet2 = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
        add_spell!(dnet2, Spell(0.0, 10.0; onset_censored=true,
                                terminus_censored=true); vertex=1)
        deactivate!(dnet2, 4.0, 6.0; vertex=1)
        s = get_spells(dnet2; vertex=1)
        @test s[1].onset_censored && !s[1].terminus_censored
        @test !s[2].onset_censored && s[2].terminus_censored

        # Point deactivation removes point spells only
        dnet3 = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
        activate!(dnet3, 5.0, 5.0; edge=(1, 2))   # instantaneous event
        activate!(dnet3, 0.0, 10.0; vertex=1)
        deactivate!(dnet3, 5.0, 5.0; edge=(1, 2))
        deactivate!(dnet3, 5.0, 5.0; vertex=1)
        @test isempty(get_spells(dnet3; edge=(1, 2)))
        @test get_spells(dnet3; vertex=1) == [Spell(0.0, 10.0)]

        # DateTime time axis
        dnet4 = DynamicNetwork{Int, DateTime}(2;
            observation_start=DateTime(2024, 1, 1),
            observation_end=DateTime(2024, 12, 31))
        activate!(dnet4, DateTime(2024, 1, 1), DateTime(2024, 12, 31); vertex=1)
        deactivate!(dnet4, DateTime(2024, 3, 1), DateTime(2024, 6, 1); vertex=1)
        @test is_active(dnet4, DateTime(2024, 2, 1); vertex=1)
        @test !is_active(dnet4, DateTime(2024, 4, 1); vertex=1)
        @test is_active(dnet4, DateTime(2024, 7, 1); vertex=1)

        @test_throws ArgumentError deactivate!(dnet, 0.0, 1.0)
    end

    @testset "Mutation counter" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        c0 = dnet.mutation_count
        activate!(dnet, 0.0, 5.0; vertex=1)
        @test dnet.mutation_count > c0

        c1 = dnet.mutation_count
        deactivate!(dnet, 1.0, 2.0; vertex=1)
        @test dnet.mutation_count > c1

        c2 = dnet.mutation_count
        activate!(dnet, 0.0, 5.0; edge=(1, 2))
        remove_spell!(dnet, Spell(0.0, 5.0); edge=(1, 2))
        merge_spells!(dnet; vertex=1)
        reconcile_activity!(dnet)
        set_observation_period!(dnet, 0.0, 20.0)
        @test dnet.mutation_count >= c2 + 5

        # Queries do not bump the counter
        c3 = dnet.mutation_count
        is_active(dnet, 1.5; vertex=1)
        get_spells(dnet; vertex=1)
        network_extract(dnet, 1.5)
        @test dnet.mutation_count == c3
    end

    @testset "Activity queries" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        activate!(dnet, 0.0, 5.0; vertex=1)
        activate!(dnet, 2.0, 8.0; vertex=2)

        @test is_active(dnet, 1.0; vertex=1) == true
        @test is_active(dnet, 6.0; vertex=1) == false
        @test is_active(dnet, 3.0; vertex=2) == true

        # Exported spell accessors (R get.vertex.activity/get.edge.activity)
        @test get_vertex_activity(dnet, 1) == [Spell(0.0, 5.0)]
        @test get_vertex_activity(dnet, 1) == when_vertex(dnet, 1)
        activate!(dnet, 1.0, 4.0; edge=(1, 2))
        @test get_edge_activity(dnet, 1, 2) == [Spell(1.0, 4.0)]
        @test get_edge_activity(dnet, 1, 2) == when_edge(dnet, 1, 2)
    end

    @testset "Continuous activity across adjacent spells" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=6.0)
        for v in 1:2
            activate!(dnet, 0.0, 2.0; vertex=v)
            activate!(dnet, 2.0, 4.0; vertex=v)
        end
        activate!(dnet, 0.0, 2.0; edge=(1, 2))
        activate!(dnet, 2.0, 4.0; edge=(1, 2))
        @test is_active(dnet, 0.0, 4.0; vertex=1, rule=:all)
        @test is_active(dnet, 1.0, 3.0; edge=(1, 2), rule=:all)
        @test !is_active(dnet, 0.0, 5.0; vertex=1, rule=:all)
        @test !is_active(dnet, 4.0, 4.0; vertex=1, rule=:all)
        @test is_active(dnet, 2.0, 2.0; vertex=1, rule=:all)
        @test_throws ArgumentError is_active(dnet, 4.0, 1.0; vertex=1, rule=:all)
        @test ne(network_extract(dnet, 0.0, 4.0; rule=:all)) == 1
        deactivate!(dnet, 1.0, 2.0; edge=(1, 2))
        @test !is_active(dnet, 0.0, 4.0; edge=(1, 2), rule=:all)
        @test ne(network_extract(dnet, 0.0, 4.0; rule=:all)) == 0

        # Concurrent read-only queries need no mutable global default cache.
        answers = Vector{Bool}(undef, 256)
        Threads.@threads for i in eachindex(answers)
            answers[i] = is_active(dnet, 0.5; vertex=1) &&
                         !is_active(dnet, 0.5; vertex=3, active_default=false)
        end
        @test all(answers)
    end

    @testset "Shared public time helpers" begin
        @test Base.ispublic(DynamicNetworks, :spell_active_at)
        @test Base.ispublic(DynamicNetworks, :elapsed_seconds)
        @test DynamicNetworks.spell_active_at(Spell(2.0, 2.0), 2.0)
        @test !DynamicNetworks.spell_active_at(Spell(1.0, 2.0), 2.0)
        seconds = DynamicNetworks.elapsed_seconds
        @test seconds(3.5) == 3.5
        @test seconds(DateTime(2026, 1, 2) - DateTime(2026, 1, 1)) == 86400
        @test seconds(Date(2026, 1, 2) - Date(2026, 1, 1)) == 86400
        @test seconds(Microsecond(1)) == 1e-6
        @test seconds(Nanosecond(1)) == 1e-9
        @test seconds(Hour(1) + Minute(1)) == 3660
        @test_throws ArgumentError seconds(Month(1))
    end

    @testset "Point (zero-duration) spells" begin
        s = Spell(5.0, 5.0)
        @test spell_duration(s) == 0.0

        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        activate!(dnet, 5.0, 5.0; edge=(1, 2))

        # Instantaneous event: active exactly at t, nowhere else
        @test is_active(dnet, 5.0; edge=(1, 2))
        @test !is_active(dnet, 4.99; edge=(1, 2))
        @test !is_active(dnet, 5.01; edge=(1, 2))

        # Interval queries see the event when the interval covers t
        @test is_active(dnet, 4.0, 6.0; edge=(1, 2))
        @test !is_active(dnet, 6.0, 8.0; edge=(1, 2))

        # Point-vs-point overlap only when identical
        @test spell_overlap(Spell(5.0, 5.0), Spell(5.0, 5.0))
        @test !spell_overlap(Spell(5.0, 5.0), Spell(6.0, 6.0))
        @test spell_overlap(Spell(5.0, 5.0), Spell(0.0, 10.0))
    end

    @testset "Int time arguments on Float64 networks" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        activate!(dnet, 1, 4; vertex=1)      # Int onset/terminus
        @test is_active(dnet, 2; vertex=1)   # Int query
        @test !is_active(dnet, 5; vertex=1)
        @test active_vertices(dnet, 2; active_default=false) == [1]
        @test active_vertices(dnet, 2) == [1, 2, 3]   # 2, 3 have no spells
    end

    @testset "Network extraction" begin
        dnet = DynamicNetwork(4; observation_start=0.0, observation_end=10.0)
        set_vertex_attribute!(dnet.network, :name,
                              Dict(1 => "A", 2 => "B", 3 => "C", 4 => "D"))
        # Vertex 1 is never active (R idiom: deactivate the whole axis)
        deactivate!(dnet, -Inf, Inf; vertex=1)

        activate!(dnet, 0.0, 10.0; vertex=2)
        activate!(dnet, 0.0, 10.0; vertex=3)
        activate!(dnet, 0.0, 4.0; vertex=4)
        activate!(dnet, 1.0, 5.0; edge=(2, 3))
        set_edge_attribute!(dnet.network, :w, 2, 3, 7.0)
        activate!(dnet, 1.0, 3.0; edge=(3, 4))

        # At t=2: vertices 2,3,4 active; edges (2,3) and (3,4) active
        snap = network_extract(dnet, 2.0)
        @test nv(snap) == 3
        @test ne(snap) == 2

        # Renumbered, but original IDs recorded as :vertex_pid
        pids = get_vertex_attribute(snap, :vertex_pid)
        @test sort(collect(values(pids))) == [2, 3, 4]

        # Static vertex attributes survive extraction (this used to throw)
        names = get_vertex_attribute(snap, :name)
        new_of = Dict(old => new for (new, old) in pids)
        @test names[new_of[2]] == "B"
        @test names[new_of[4]] == "D"
        # Edge attributes survive too
        @test get_edge_attribute(snap, :w, new_of[2], new_of[3]) == 7.0

        # Stable IDs with retain_all_vertices
        snap_stable = network_extract(dnet, 2.0; retain_all_vertices=true)
        @test nv(snap_stable) == 4
        @test has_edge(snap_stable, 2, 3)
        @test has_edge(snap_stable, 3, 4)
        @test get_vertex_attribute(snap_stable, :name, 2) == "B"

        # At t=6: vertex 4 and both edges inactive
        snap6 = network_extract(dnet, 6.0; retain_all_vertices=true)
        @test ne(snap6) == 0

        # Interval extraction with rules
        any_net = network_extract(dnet, 4.5, 6.0; rule=:any,
                                  retain_all_vertices=true)
        @test has_edge(any_net, 2, 3)      # (2,3) active until 5
        @test !has_edge(any_net, 3, 4)     # (3,4) ended at 3
        all_net = network_extract(dnet, 1.0, 5.0; rule=:all,
                                  retain_all_vertices=true)
        @test has_edge(all_net, 2, 3)
        @test !has_edge(all_net, 3, 4)

        # Slices
        slices = network_slice(dnet, [0.5, 2.0, 6.0]; retain_all_vertices=true)
        @test length(slices) == 3
        @test ne(slices[2]) == 2
        @test ne(slices[3]) == 0
    end

    @testset "Network collapse" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        set_vertex_attribute!(dnet.network, :name, Dict(1 => "A", 2 => "B", 3 => "C"))
        activate!(dnet, 0.0, 2.0; edge=(1, 2))
        activate!(dnet, 8.0, 9.0; edge=(2, 3))

        col = network_collapse(dnet)
        @test nv(col) == 3
        @test has_edge(col, 1, 2) && has_edge(col, 2, 3)
        @test get_vertex_attribute(col, :name, 1) == "A"

        # Interval-restricted collapse
        col_early = network_collapse(dnet; onset=0.0, terminus=5.0)
        @test has_edge(col_early, 1, 2)
        @test !has_edge(col_early, 2, 3)
    end

    @testset "Time-varying attributes" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)

        set_vertex_attribute_active!(dnet, 1, :status, "healthy", 0.0, 5.0)
        set_vertex_attribute_active!(dnet, 1, :status, "sick", 5.0, 10.0)

        @test get_vertex_attribute_active(dnet, 1, :status, 2.0) == "healthy"
        @test get_vertex_attribute_active(dnet, 1, :status, 5.0) == "sick"
        @test get_vertex_attribute_active(dnet, 1, :status, 10.0) === nothing
        @test get_vertex_attribute_active(dnet, 2, :status, 2.0) === nothing

        # Overlapping spells: the most recently set value wins
        set_vertex_attribute_active!(dnet, 1, :status, "recovered", 4.0, 6.0)
        @test get_vertex_attribute_active(dnet, 1, :status, 4.5) == "recovered"

        set_edge_attribute_active!(dnet, 1, 2, :strength, 0.5, 0.0, 5.0)
        @test get_edge_attribute_active(dnet, 1, 2, :strength, 1.0) == 0.5
        @test get_edge_attribute_active(dnet, 1, 2, :strength, 7.0) === nothing

        @test :status in list_vertex_attributes_active(dnet)
        @test :strength in list_edge_attributes_active(dnet)
    end

    @testset "Spell merging preserves censoring" begin
        dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
        add_spell!(dnet, Spell(0.0, 3.0; onset_censored=true); vertex=1)
        add_spell!(dnet, Spell(2.0, 6.0); vertex=1)
        add_spell!(dnet, Spell(6.0, 8.0; terminus_censored=true); vertex=1)
        add_spell!(dnet, Spell(9.0, 10.0); vertex=1)

        merge_spells!(dnet; vertex=1)
        spells = get_spells(dnet; vertex=1)

        @test length(spells) == 2
        @test spells[1].onset == 0.0 && spells[1].terminus == 8.0
        @test spells[1].onset_censored          # from the left-censored spell
        @test spells[1].terminus_censored       # from the right-censored spell
        @test spells[2] == Spell(9.0, 10.0)
    end

    @testset "Conversion utilities" begin
        net = network(3; directed=false)
        add_edge!(net, 1, 2)
        add_edge!(net, 2, 3)

        # Bare call works; mixed Int/Float64 promotes
        dnet = as_dynamic_network(net)
        @test dnet isa DynamicNetwork{Int, Float64}
        @test is_active(dnet, 0.5; vertex=1)
        @test is_active(dnet, 0.5; edge=(1, 2))

        dnet2 = as_dynamic_network(net; onset=0, terminus=10.0)
        @test dnet2 isa DynamicNetwork{Int, Float64}
        @test get_observation_period(dnet2) == (0.0, 10.0)

        @test !is_directed(dnet)
    end

    @testset "DateTime time axis" begin
        # Default construction no longer requires observation kwargs
        dnet = DynamicNetwork{Int, DateTime}(3)
        @test dnet isa DynamicNetwork{Int, DateTime}

        t0 = DateTime(2024, 1, 1)
        t1 = DateTime(2024, 6, 1)
        t2 = DateTime(2024, 12, 31)
        set_observation_period!(dnet, t0, t2)

        activate!(dnet, t0, t1; vertex=1)
        @test is_active(dnet, DateTime(2024, 3, 1); vertex=1)
        @test !is_active(dnet, DateTime(2024, 7, 1); vertex=1)

        snap = network_extract(dnet, DateTime(2024, 3, 1))
        @test nv(snap) == 3          # vertices 2, 3 have no spells: active
        @test nv(network_extract(dnet, DateTime(2024, 3, 1); active_default=false)) == 1
        # Deactivating a default-active vertex on a calendar axis uses the
        # axis extremes in place of infinities
        deactivate!(dnet, t0, t1; vertex=2)
        @test get_spells(dnet; vertex=2) ==
              [Spell(typemin(DateTime), t0), Spell(t1, typemax(DateTime))]

        # Static network conversion with DateTime bounds
        net = network(2)
        add_edge!(net, 1, 2)
        ddnet = as_dynamic_network(net; onset=t0, terminus=t2)
        @test ddnet isa DynamicNetwork{Int, DateTime}
        @test is_active(ddnet, t1; edge=(1, 2))
    end

    @testset "Reconcile activity" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        activate!(dnet, 0.0, 4.0; vertex=1)
        activate!(dnet, 6.0, 10.0; vertex=1)  # gap [4, 6)
        activate!(dnet, 2.0, 8.0; vertex=2)
        activate!(dnet, 0.0, 10.0; edge=(1, 2))

        reconcile_activity!(dnet)
        spells = get_spells(dnet; edge=(1, 2))

        # Edge restricted to when both endpoints are active: [2,4) and [6,8)
        @test spells == [Spell(2.0, 4.0), Spell(6.0, 8.0)]
        @test issorted(spells)
    end

    @testset "Observation period" begin
        dnet = DynamicNetwork(2; observation_start=0.0, observation_end=5.0)
        @test get_observation_period(dnet) == (0.0, 5.0)
        set_observation_period!(dnet, 1.0, 10.0)
        @test get_observation_period(dnet) == (1.0, 10.0)
    end

    # =========================================================================
    # Conversion invariants (see docs/src/guide/conversion_invariants.md)
    #
    # The contract: everything the target representation can hold survives;
    # what it cannot hold is rejected or reported, never silently dropped.
    # The missing-dyad mask is the field that used to vanish — a masked dyad
    # round-tripped to zero masked dyads, which is the exact failure mode the
    # ecosystem missing-data contract exists to prevent.
    # =========================================================================

    # A network exercising every field the contract names: directedness,
    # loops + a self-loop, isolates, vertex/edge/network attributes, and both
    # flavours of masked dyad (one with a PRESENT face value, one ABSENT).
    function _kitchen_sink(; directed::Bool)
        net = network(6; directed=directed, loops=true)
        add_edge!(net, 1, 2)
        add_edge!(net, 2, 3)
        add_edge!(net, 3, 3)             # self-loop
        # vertices 5, 6 are isolates
        set_vertex_attribute!(net, :grp, 1, "a")
        set_vertex_attribute!(net, :grp, 5, "b")   # isolate carries an attribute
        set_edge_attribute!(net, :weight, 1, 2, 2.5)
        set_network_attribute!(net, :title, "kitchen sink")
        set_missing_dyad!(net, 2, 3)     # masked, PRESENT face value
        set_missing_dyad!(net, 4, 5)     # masked, ABSENT face value
        return net
    end

    @testset "Conversion invariants: Network → DynamicNetwork is lossless" begin
        for directed in (true, false)
            net = _kitchen_sink(; directed=directed)
            dnet, rep = as_dynamic_network(net; onset=0.0, terminus=10.0,
                                           report=true)

            @test is_lossless(rep)
            @test isempty(dropped_fields(rep))

            base = dnet.network
            @test is_directed(base) == directed
            @test base.loops
            @test nv(base) == 6
            @test has_edge(base, 3, 3)                     # self-loop survived
            @test get_vertex_attribute(base, :grp, 1) == "a"
            @test get_vertex_attribute(base, :grp, 5) == "b"
            @test get_edge_attribute(base, :weight, 1, 2) == 2.5
            @test get_network_attribute(base, :title) == "kitchen sink"

            # The mask survives — both the present-face and the absent-face
            # masked dyad, and neither turned into a tie or a non-tie.
            @test n_missing_dyads(base) == 2
            @test is_missing_dyad(base, 2, 3)
            @test is_missing_dyad(base, 4, 5)
            @test has_edge(base, 2, 3)                     # present face value
            @test !has_edge(base, 4, 5)                    # absent face value

            # Every vertex and edge active for the whole observation window
            @test get_observation_period(dnet) == (0.0, 10.0)
            @test all(is_active(dnet, 5.0; vertex=v) for v in 1:6)
            @test is_active(dnet, 5.0; edge=(3, 3))
        end
    end

    @testset "Conversion invariants: Network → DynamicNetwork → Network round-trip" begin
        for directed in (true, false)
            net = _kitchen_sink(; directed=directed)
            back = network_collapse(as_dynamic_network(net; onset=0.0, terminus=10.0))

            @test is_directed(back) == directed
            @test back.loops
            @test nv(back) == nv(net)
            @test ne(back) == ne(net)
            @test Set((src(e), dst(e)) for e in edges(back)) ==
                  Set((src(e), dst(e)) for e in edges(net))
            @test has_edge(back, 3, 3)
            @test get_vertex_attribute(back, :grp, 1) == "a"
            @test get_vertex_attribute(back, :grp, 5) == "b"
            @test get_edge_attribute(back, :weight, 1, 2) == 2.5
            @test get_network_attribute(back, :title) == "kitchen sink"

            # THE regression: the mask must not round-trip to zero.
            @test n_missing_dyads(back) == 2
            @test is_missing_dyad(back, 2, 3)
            @test is_missing_dyad(back, 4, 5)
            @test has_edge(back, 2, 3) && !has_edge(back, 4, 5)
        end
    end

    @testset "Conversion invariants: two-mode metadata" begin
        bp = network(5; bipartite=2)
        add_edge!(bp, 1, 3)
        add_edge!(bp, 2, 5)
        set_missing_dyad!(bp, 1, 4)
        dnet = as_dynamic_network(bp; onset=0.0, terminus=10.0)

        @test dnet.network.bipartite == 2
        @test is_two_mode(dnet.network)

        # Stable IDs: the mode partition is meaningful and is preserved.
        collapsed, rep = network_collapse(dnet; report=true)
        @test collapsed.bipartite == 2
        @test n_missing_dyads(collapsed) == 1
        @test !(:bipartite in dropped_fields(rep))

        keep, rep_keep = network_extract(dnet, 5.0; retain_all_vertices=true,
                                         report=true)
        @test keep.bipartite == 2
        @test !(:bipartite in dropped_fields(rep_keep))

        # Renumbering destroys "vertices 1:k are mode 1" — dropped, and SAID so.
        renum, rep_renum = network_extract(dnet, 5.0; retain_all_vertices=false,
                                           report=true)
        @test isnothing(renum.bipartite)
        @test :bipartite in dropped_fields(rep_renum)
    end

    @testset "Conversion invariants: network_extract preserves what it can" begin
        for directed in (true, false)
            net = _kitchen_sink(; directed=directed)
            dnet = as_dynamic_network(net; onset=0.0, terminus=10.0)

            snap, rep = network_extract(dnet, 5.0; retain_all_vertices=true,
                                        report=true)
            @test is_directed(snap) == directed
            @test snap.loops
            @test has_edge(snap, 3, 3)
            @test get_vertex_attribute(snap, :grp, 1) == "a"
            @test get_edge_attribute(snap, :weight, 1, 2) == 2.5
            @test get_network_attribute(snap, :title) == "kitchen sink"
            @test n_missing_dyads(snap) == 2
            @test is_missing_dyad(snap, 2, 3) && is_missing_dyad(snap, 4, 5)

            # A snapshot has no time axis: that IS lossy, and the report says so.
            @test !is_lossless(rep)
            @test :spells in dropped_fields(rep)
            @test :observation_period in dropped_fields(rep)
            @test !(:missing_dyads in dropped_fields(rep))   # nothing lost here
        end
    end

    @testset "Conversion invariants: mask entries on inactive vertices are reported" begin
        dnet = DynamicNetwork(4; observation_start=0.0, observation_end=10.0)
        activate!(dnet, 0.0, 10.0; vertex=1)
        activate!(dnet, 0.0, 10.0; vertex=2)
        activate!(dnet, 0.0, 10.0; edge=(1, 2))
        # Vertices 3 and 4 are never active
        deactivate!(dnet, -Inf, Inf; vertex=3)
        deactivate!(dnet, -Inf, Inf; vertex=4)
        set_missing_dyad!(dnet.network, 3, 4)
        set_missing_dyad!(dnet.network, 1, 2)

        # Renumbering drops vertices 3, 4 — so their masked dyad cannot be
        # carried. It is not silently forgotten.
        renum, rep = network_extract(dnet, 5.0; retain_all_vertices=false,
                                     report=true)
        @test nv(renum) == 2
        @test n_missing_dyads(renum) == 1              # (1,2) survives, remapped
        @test is_missing_dyad(renum, 1, 2)
        @test :missing_dyads in dropped_fields(rep)

        # Keeping all vertices keeps the whole mask.
        keep, rep_keep = network_extract(dnet, 5.0; retain_all_vertices=true,
                                         report=true)
        @test n_missing_dyads(keep) == 2
        @test !(:missing_dyads in dropped_fields(rep_keep))
    end

    @testset "Conversion invariants: TEA drop is reported only when TEAs exist" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        activate_vertices!(dnet, [1, 2, 3], 0.0, 10.0)
        activate!(dnet, 0.0, 10.0; edge=(1, 2))

        _, rep = network_extract(dnet, 5.0; retain_all_vertices=true, report=true)
        @test !(:time_varying_attributes in dropped_fields(rep))

        set_vertex_attribute_active!(dnet, 1, :mood, "up", 0.0, 5.0)
        _, rep2 = network_extract(dnet, 2.0; retain_all_vertices=true, report=true)
        @test :time_varying_attributes in dropped_fields(rep2)
    end

    @testset "Conversion invariants: temporal edge cases" begin
        dnet = DynamicNetwork(5; observation_start=0.0, observation_end=10.0)
        activate_vertices!(dnet, [1, 2, 3, 4, 5], 0.0, 10.0)
        # Overlapping spells on one edge
        activate!(dnet, 0.0, 6.0; edge=(1, 2))
        activate!(dnet, 4.0, 10.0; edge=(1, 2))
        # Point spell: an instantaneous contact at t = 7
        activate!(dnet, 7.0, 7.0; edge=(2, 3))
        # A spell flush with the observation-window edges
        activate!(dnet, 0.0, 10.0; edge=(3, 4))
        # Vertex 5 is an isolate throughout

        # Overlapping spells: the edge is active across the union, including
        # the overlap, and collapsing it yields exactly one edge.
        @test has_edge(network_extract(dnet, 5.0; retain_all_vertices=true), 1, 2)
        @test has_edge(network_extract(dnet, 8.0; retain_all_vertices=true), 1, 2)
        collapsed = network_collapse(dnet)
        @test ne(collapsed) == 3
        @test nv(collapsed) == 5                       # the isolate survives

        # Point spell: present exactly at its instant, nowhere else.
        @test has_edge(network_extract(dnet, 7.0; retain_all_vertices=true), 2, 3)
        @test !has_edge(network_extract(dnet, 6.99; retain_all_vertices=true), 2, 3)
        @test !has_edge(network_extract(dnet, 7.01; retain_all_vertices=true), 2, 3)

        # Observation-window edges: [0,10) is half-open at the terminus.
        @test has_edge(network_extract(dnet, 0.0; retain_all_vertices=true), 3, 4)
        @test !has_edge(network_extract(dnet, 10.0; retain_all_vertices=true), 3, 4)

        # network_slice is a vector of networks, so it has no single report.
        @test length(network_slice(dnet, [0.0, 5.0, 7.0])) == 3
        @test_throws ArgumentError network_slice(dnet, [0.0]; report=true)
    end

    # =========================================================================
    # R networkDynamic semantics: activity defaults, merging, collapse, reconcile
    # =========================================================================

    @testset "Elements with no spells are active by default (R active.default)" begin
        # Edges activated, no vertex spells at all. R extracts 3 vertices and
        # 2 edges; this used to extract nothing.
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        activate!(dnet, 0.0, 10.0; edge=(1, 2))
        activate!(dnet, 0.0, 10.0; edge=(2, 3))
        snap = network_extract(dnet, 5.0)
        @test (nv(snap), ne(snap)) == (3, 2)
        @test active_vertices(dnet, 5.0) == [1, 2, 3]
        @test is_active(dnet, 5.0, 6.0; vertex=1, rule=:all)
        @test get_vertex_activity(dnet, 1) == [Spell(-Inf, Inf)]
        # The old behaviour is available on request
        none = network_extract(dnet, 5.0; active_default=false)
        @test (nv(none), ne(none)) == (0, 0)
        @test isempty(active_vertices(dnet, 5.0; active_default=false))
        @test isempty(get_vertex_activity(dnet, 1; active_default=false))

        # A base-network edge with no spell record is active too
        add_edge!(dnet.network, 3, 1)
        @test is_active(dnet, 50.0; edge=(3, 1))
        @test (3, 1) in active_edges(dnet, 50.0)
        @test !((3, 1) in active_edges(dnet, 50.0; active_default=false))
        @test get_edge_activity(dnet, 3, 1) == [Spell(-Inf, Inf)]
        @test has_edge(network_extract(dnet, 50.0), 3, 1)
        @test has_edge(network_collapse(dnet), 3, 1)
        # ... while an edge that is not in the base network never is
        @test !is_active(dnet, 5.0; edge=(1, 3))
        @test isempty(get_edge_activity(dnet, 1, 3))

        # A record emptied by deactivation means "never active"
        deactivate!(dnet, -Inf, Inf; vertex=2)
        @test !is_active(dnet, 5.0; vertex=2)
        @test isempty(get_vertex_activity(dnet, 2))
        @test ne(network_extract(dnet, 5.0)) == 1      # only (3,1) remains
    end

    @testset "Activation merges spells as R activate.* does" begin
        # Expected values are R networkDynamic 0.12 output (see the golden
        # fixture below for the randomised version of the same check).
        cases = [
            ([(0, 5), (5, 10)], [(0, 10)]),             # adjacent
            ([(0, 6), (4, 10)], [(0, 10)]),             # overlapping
            ([(0, 5), (5, 5)], [(0, 5), (5, 5)]),       # point at the terminus is kept
            ([(0, 5), (2, 2)], [(0, 5)]),               # point inside is absorbed
            ([(5, 5), (5, 10)], [(5, 10)]),             # point at the onset is absorbed
            ([(5, 5), (5, 5)], [(5, 5)]),               # duplicate point
            ([(3, 3), (5, 5)], [(3, 3), (5, 5)]),
            ([(0, 2), (4, 6), (1, 5)], [(0, 6)]),       # bridging spell
            ([(0, 2), (4, 6), (2, 4)], [(0, 6)]),       # adjacent on both sides
        ]
        for (acts, expected) in cases
            dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
            for (a, b) in acts
                activate!(dnet, a, b; edge=(1, 2))
            end
            @test get_spells(dnet; edge=(1, 2)) == [Spell(Float64(a), Float64(b)) for (a, b) in expected]
        end
        # Censoring flags travel with the bound they describe
        dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
        add_spell!(dnet, Spell(0.0, 4.0; onset_censored=true); vertex=1)
        add_spell!(dnet, Spell(3.0, 10.0; terminus_censored=true); vertex=1)
        s = only(get_spells(dnet; vertex=1))
        @test s == Spell(0.0, 10.0) && s.onset_censored && s.terminus_censored
    end

    @testset "merge_spells! keeps a point spell at an adjacent terminus" begin
        dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
        add_spell!(dnet, Spell(0.0, 5.0); edge=(1, 2), merge=false)
        add_spell!(dnet, Spell(5.0, 5.0); edge=(1, 2), merge=false)
        @test is_active(dnet, 5.0; edge=(1, 2))
        merge_spells!(dnet; edge=(1, 2))
        @test is_active(dnet, 5.0; edge=(1, 2))           # used to be lost
        @test get_spells(dnet; edge=(1, 2)) == [Spell(0.0, 5.0), Spell(5.0, 5.0)]
        # The public non-mutating form
        @test DynamicNetworks.merge_spell_vector([Spell(2.0, 2.0), Spell(0.0, 5.0)]) ==
              [Spell(0.0, 5.0)]
        @test isempty(DynamicNetworks.merge_spell_vector(Spell{Float64}[]))
    end

    @testset "network_collapse(rule=:all) honours coverage by adjacent spells" begin
        dnet = DynamicNetwork(2; observation_start=0.0, observation_end=10.0)
        add_spell!(dnet, Spell(0.0, 5.0); edge=(1, 2), merge=false)
        add_spell!(dnet, Spell(5.0, 10.0); edge=(1, 2), merge=false)
        @test ne(network_extract(dnet, 2.0, 8.0; rule=:all)) == 1
        @test ne(network_collapse(dnet; onset=2.0, terminus=8.0, rule=:all)) == 1   # was 0
        @test ne(network_collapse(dnet; onset=2.0, terminus=12.0, rule=:all)) == 0
        # Collapse is extract with stable IDs: an edge whose endpoint is
        # inactive throughout is not collapsed into the network (R)
        deactivate!(dnet, -Inf, Inf; vertex=2)
        col = network_collapse(dnet)
        @test nv(col) == 2 && ne(col) == 0
        @test_throws ArgumentError network_collapse(dnet; onset=1.0)
        for rule in (:any, :all), (a, b) in ((0.0, 3.0), (4.0, 6.0), (9.0, 12.0))
            dn = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
            activate!(dn, 0.0, 5.0; edge=(1, 2)); activate!(dn, 5.0, 9.0; edge=(2, 3))
            activate!(dn, 4.0, 8.0; vertex=3)
            c = network_collapse(dn; onset=a, terminus=b, rule=rule)
            x = network_extract(dn, a, b; rule=rule, retain_all_vertices=true)
            @test Set((src(e), dst(e)) for e in edges(c)) == Set((src(e), dst(e)) for e in edges(x))
        end
    end

    @testset "reconcile_activity! keeps point spells and censoring" begin
        dnet = DynamicNetwork(3; observation_start=0.0, observation_end=10.0)
        activate!(dnet, 0.0, 10.0; vertex=1)
        activate!(dnet, 0.0, 10.0; vertex=2)
        activate!(dnet, 3.0, 3.0; edge=(1, 2))                       # point spell
        add_spell!(dnet, Spell(1.0, 4.0; terminus_censored=true); edge=(2, 1))
        reconcile_activity!(dnet)
        sp = get_spells(dnet; edge=(1, 2))
        @test sp == [Spell(3.0, 3.0)]                                 # used to vanish
        sp21 = get_spells(dnet; edge=(2, 1))
        @test sp21 == [Spell(1.0, 4.0)] && sp21[1].terminus_censored  # used to be lost

        # A vertex with no record is always active, whatever the window says;
        # an edge with no record takes its endpoints' activity; a vertex that
        # is never active silences its edges (R reduce.to.vertices).
        d2 = DynamicNetwork(4; observation_start=0.0, observation_end=10.0)
        for (i, j) in ((1, 2), (2, 3), (3, 4))
            add_edge!(d2.network, i, j)
        end
        activate!(d2, 0.0, 5.0; vertex=1)
        activate!(d2, 2.0, 8.0; vertex=2)
        activate!(d2, 0.0, 10.0; edge=(1, 2))
        activate!(d2, 1.0, 12.0; edge=(2, 3))                         # vertex 3: no record
        deactivate!(d2, -Inf, Inf; vertex=4)
        reconcile_activity!(d2)
        @test get_spells(d2; edge=(1, 2)) == [Spell(2.0, 5.0)]
        @test get_spells(d2; edge=(2, 3)) == [Spell(2.0, 8.0)]       # not clipped to the window
        @test isempty(get_spells(d2; edge=(3, 4)))
        @test !is_active(d2, 5.0; edge=(3, 4))
    end

    @testset "DynamicNetwork wraps a concretely typed Network" begin
        for directed in (true, false)
            dnet = DynamicNetwork(4; directed=directed, observation_start=0.0,
                                  observation_end=10.0)
            @test dnet isa DynamicNetwork{Int, Float64, directed}
            @test isconcretetype(fieldtype(typeof(dnet), :network))
            @test is_directed(typeof(dnet)) == directed
            activate!(dnet, 0.0, 5.0; edge=(1, 2))
            @test (@inferred network_extract(dnet, 1.0)) isa Network{Int, directed}
            @test (@inferred network_collapse(dnet)) isa Network{Int, directed}
            @test (@inferred active_edges(dnet, 1.0)) isa Vector{Tuple{Int,Int}}
        end
        @test DynamicNetwork{Int32, Float64}(3) isa DynamicNetwork{Int32, Float64, true}
        @test as_dynamic_network(network(3; directed=false)) isa DynamicNetwork{Int, Float64, false}
    end

    @testset "Observation period: given, or nothing" begin
        # Without a window nothing is derived from the data (R's net.obs.period
        # is NULL); a derived [first, last) window used to make consumers drop
        # ties that form at the last change time, and the (0, 1) placeholder
        # stood in when there was no finite spell bound.
        dnet = DynamicNetwork(3)
        @test !dnet.observation_period_set
        @test get_observation_period(dnet) === nothing
        activate!(dnet, 2.0, 7.0; edge=(1, 2))
        activate!(dnet, -Inf, 4.0; vertex=3)                          # infinite bound ignored
        @test get_observation_period(dnet) === nothing                # still nothing
        @test get_change_times(dnet) == [2.0, 4.0, 7.0]
        @test get_change_times(dnet; ignore_inf=false) == [-Inf, 2.0, 4.0, 7.0]
        @test get_change_times(dnet; edge_activity=false) == [4.0]
        @test occursin("none set", sprint(show, dnet))
        @test get_timing_info(dnet).observation_period === nothing
        # No window, so an extraction has no window to report as dropped
        _, rep = network_extract(dnet, 3.0; report=true)
        @test !(:observation_period in dropped_fields(rep))
        set_observation_period!(dnet, 0.0, 10.0)
        @test dnet.observation_period_set
        @test get_observation_period(dnet) == (0.0, 10.0)
        @test !occursin("none set", sprint(show, dnet))
        @test get_timing_info(dnet).observation_period == (0.0, 10.0)
        _, rep = network_extract(dnet, 3.0; report=true)
        @test :observation_period in dropped_fields(rep)
        @test get_observation_period(DynamicNetwork{Int, DateTime}(2)) === nothing
        @test_throws ArgumentError set_observation_period!(DynamicNetwork(2), 5.0, 1.0)
    end

    @testset "Observation period: both ends or neither" begin
        # A window given by one end only used to take the other end from the
        # (0, 1) placeholder: observation_end=10 gave (0, 10), and
        # observation_start=5 failed with "onset must be <= terminus".
        for (kw, given) in (((; observation_end=10.0), "observation_end"),
                            ((; observation_start=5.0), "observation_start"))
            err = try DynamicNetwork(3; kw...); nothing catch e; e end
            @test err isa ArgumentError
            @test occursin(given, err.msg) && occursin("both ends", err.msg)
        end
        @test_throws ArgumentError DynamicNetwork{Int, Int}(2; observation_start=3)
        @test_throws ArgumentError DynamicNetwork{Int32, DateTime}(2; observation_end=DateTime(2024))
        # An open-ended window is asked for explicitly
        @test get_observation_period(DynamicNetwork(3; observation_start=5.0,
                                                    observation_end=Inf)) == (5.0, Inf)
        u = DynamicNetworks.unbounded_spell(Int)
        @test get_observation_period(DynamicNetwork{Int, Int}(3; observation_start=5,
                                                              observation_end=u.terminus)) ==
              (5, typemax(Int))
        # An inverted window is refused by name, at construction and when set,
        # and a refused set_observation_period! leaves the network unchanged
        err = try DynamicNetwork(3; observation_start=5.0, observation_end=2.0); nothing catch e; e end
        @test err isa ArgumentError && occursin("start <= end", err.msg)
        d = DynamicNetwork(3; observation_start=0.0, observation_end=4.0)
        n0 = d.mutation_count
        @test_throws ArgumentError set_observation_period!(d, 10.0, 5.0)
        @test get_observation_period(d) == (0.0, 4.0)
        @test d.net_obs_period == Spell(0.0, 4.0) && d.mutation_count == n0
    end

    @testset "vertex= and edge= take ids of any Integer type" begin
        # The keywords were typed by the network's id type, so on a
        # DynamicNetwork{Int32} a literal `vertex=1` or `edge=(1, 2)` threw a
        # TypeError. Every keyword method must give the Int answers.
        function run(T)
            d = DynamicNetwork{T, Float64}(4)
            add_spell!(d, Spell(0.0, 2.0); vertex=1)
            add_spell!(d, Spell(1.0, 3.0); edge=(1, 2))
            activate!(d, 0.0, 5.0; vertex=2)
            activate!(d, 4.0, 6.0; edge=(1, 2))
            activate!(d, 2.0, 8.0; edge=(3, 4))
            deactivate!(d, 1.0, 2.0; vertex=2)
            deactivate!(d, 3.0, 4.0; edge=(3, 4))
            remove_spell!(d, Spell(4.0, 8.0); edge=(3, 4))
            add_spell!(d, Spell(9.0, 9.5); edge=(3, 4), merge=false)
            add_spell!(d, Spell(9.5, 10.0); edge=(3, 4), merge=false)
            merge_spells!(d; edge=(3, 4)); merge_spells!(d; vertex=1)
            (get_spells(d; vertex=1), get_spells(d; vertex=2), get_spells(d; edge=(1, 2)),
             get_spells(d; edge=(4, 3)) == get_spells(d; edge=(3, 4)),
             get_spells(d; edge=(3, 4)),
             is_active(d, 1.5; vertex=2), is_active(d, 1.5; edge=(1, 2)),
             is_active(d, 0.0, 10.0; vertex=2, rule=:all), is_active(d, 5.0, 6.0; edge=(1, 2)),
             get_activity_range(d; vertex=2), get_activity_range(d; edge=(1, 2)))
        end
        @test run(Int32) == run(Int)
        d = DynamicNetwork{Int32, Float64}(3; directed=false)
        activate!(d, 0.0, 1.0; edge=(UInt8(2), big(1)))
        @test only(keys(d.edge_spells)) === (Int32(1), Int32(2))
        @test is_active(d, 0.5; edge=(Int16(1), 2))
        # Ids the id type cannot hold are not vertices: refused by name, not
        # by an InexactError from the conversion
        for bad in (typemax(Int64), -1, 0, 4)
            @test_throws ArgumentError activate!(d, 0.0, 1.0; vertex=bad)
            @test_throws ArgumentError activate!(d, 0.0, 1.0; edge=(1, bad))
        end
        @test_throws ArgumentError is_active(d, 0.5; vertex=typemax(Int64))
    end

    @testset "spell_duration of unbounded spells does not overflow" begin
        # On axes without infinities the unbounded spell is (typemin, typemax):
        # subtracting them wrapped around to -1 on Int, and gave a meaningless
        # period on DateTime.
        @test spell_duration(Spell(2.0, Inf)) == Inf
        @test spell_duration(Spell(-Inf, 3.0)) == Inf
        @test spell_duration(Spell(-Inf, Inf)) == Inf
        @test spell_duration(Spell(Inf, Inf)) == 0.0                  # a point spell, not NaN
        @test spell_duration(Spell(4, 9)) == 5
        @test spell_duration(Spell(typemin(Int), typemax(Int))) == typemax(Int)
        @test spell_duration(Spell(typemin(Int), 5)) == typemax(Int)
        @test spell_duration(Spell(5, typemax(Int))) == typemax(Int)
        @test spell_duration(Spell(typemax(Int), typemax(Int))) == 0
        @test spell_duration(Spell(Int32(1), typemax(Int32))) === typemax(Int32)
        d = DynamicNetwork{Int, Int}(3; observation_start=0, observation_end=10)
        add_edge!(d.network, 1, 2)                                     # no record
        @test spell_duration(only(get_edge_activity(d, 1, 2))) == typemax(Int)   # was -1
        @test DynamicNetworks.unbounded_spell(Int) == Spell(typemin(Int), typemax(Int))
        @test DynamicNetworks.unbounded_spell(Float32) == Spell(-Inf32, Inf32)
        t0 = DateTime(2024)
        @test spell_duration(Spell(t0, t0 + Day(2))) == Millisecond(Day(2))
        @test spell_duration(Spell(t0, typemax(DateTime))) == Millisecond(typemax(Int64))
        @test spell_duration(Spell(typemin(Date), Date(2024))) == Day(typemax(Int64))
        @test spell_duration(only(get_vertex_activity(DynamicNetwork{Int, DateTime}(1), 1))) ==
              Millisecond(typemax(Int64))
    end

    @testset "activate_edges!, get_activity_range and TimeVaryingAttribute" begin
        dnet = DynamicNetwork(4; directed=false, observation_start=0.0, observation_end=10.0)
        activate_edges!(dnet, [(1, 2), (3, 2)], 1.0, 4.0)
        activate_edges!(dnet, [(1, 2)], 4.0, 6.0)                     # adjacent: merged
        activate_edges!(dnet, [(Int32(3), Int32(4))], 7.0, 7.0)       # any integer type
        @test ne(dnet.network) == 3                                   # missing edges added
        @test get_spells(dnet; edge=(2, 1)) == [Spell(1.0, 6.0)]
        @test get_spells(dnet; edge=(2, 3)) == [Spell(1.0, 4.0)]
        @test get_spells(dnet; edge=(3, 4)) == [Spell(7.0, 7.0)]
        @test_throws ArgumentError activate_edges!(dnet, [(1, 5)], 0.0, 1.0)
        # Vertices added to the base network have no record: active by default
        add_vertices!(dnet.network, 1)
        @test nv(dnet) == 5 && is_active(dnet, 3.0; vertex=5)
        activate_edges!(dnet, [(1, 5)], 0.0, 1.0)
        @test get_spells(dnet; edge=(5, 1)) == [Spell(0.0, 1.0)]

        @test get_activity_range(dnet; edge=(1, 2)) == (1.0, 6.0)
        activate!(dnet, 2.0, 3.0; vertex=1); activate!(dnet, 8.0, Inf; vertex=1)
        @test get_activity_range(dnet; vertex=1) == (2.0, Inf)
        @test get_activity_range(dnet; vertex=2) === nothing          # no record
        @test get_activity_range(dnet; edge=(1, 4)) === nothing       # not an edge
        @test_throws ArgumentError get_activity_range(dnet)

        set_vertex_attribute_active!(dnet, 2, :status, "S", 0.0, 4.0)
        set_vertex_attribute_active!(dnet, 2, :status, "I", 3.0, 10.0)
        tea = dnet.vertex_tea[(2, :status)]
        @test tea isa TimeVaryingAttribute{Float64, String}
        @test tea.values == ["S", "I"]
        @test tea.spells == [Spell(0.0, 4.0), Spell(3.0, 10.0)]
        @test get_vertex_attribute_active(dnet, 2, :status, 3.5) == "I"   # latest wins
        @test get_vertex_attribute_active(dnet, 2, :status, 1.0) == "S"
        @test get_vertex_attribute_active(dnet, 2, :status, 10.0) === nothing
        empty_tea = TimeVaryingAttribute{Float64, Int}()
        @test isempty(empty_tea.values) && isempty(empty_tea.spells)
        set_edge_attribute_active!(dnet, 2, 1, :w, 1.5, 0.0, 2.0)
        @test dnet.edge_tea[((1, 2), :w)] isa TimeVaryingAttribute{Float64, Float64}
        @test get_change_times(dnet; vertex_activity=false, edge_activity=false) ==
              [0.0, 2.0, 3.0, 4.0, 10.0]                               # TEA spells
    end

    @testset "Panel constructor: networkDynamic(network.list =)" begin
        w1 = network(4); add_edge!(w1, 1, 2); add_edge!(w1, 3, 4)
        w2 = network(4); add_edge!(w2, 1, 2); add_edge!(w2, 2, 3)
        w3 = network(4); add_edge!(w3, 3, 4)
        set_vertex_attribute!(w1, :grp, 1, "a")
        set_edge_attribute!(w2, :w, 1, 2, 2.0)
        d = DynamicNetwork([w1, w2, w3])
        @test d isa DynamicNetwork{Int, Float64, true}
        @test get_observation_period(d) == (0.0, 3.0)
        @test get_spells(d; edge=(1, 2)) == [Spell(0.0, 2.0)]
        @test get_spells(d; edge=(3, 4)) == [Spell(0.0, 1.0), Spell(2.0, 3.0)]
        @test get_spells(d; edge=(2, 3)) == [Spell(1.0, 2.0)]
        @test all(get_spells(d; vertex=v) == [Spell(0.0, 3.0)] for v in 1:4)
        @test get_vertex_attribute(d.network, :grp, 1) == "a"
        d2, rep = as_dynamic_network([w1, w2, w3]; report=true)
        @test :edge_attributes in dropped_fields(rep)
        @test :panel_attributes in dropped_fields(rep)                # w1's :grp differs
        @test !is_lossless(rep)
        @test is_lossless(last(as_dynamic_network([w3, w3]; report=true)))
        # Shifted default and explicit spells with a gap
        @test get_observation_period(DynamicNetwork([w1, w2]; start=10)) == (10, 12)
        d3 = DynamicNetwork([w1, w2, w3]; onsets=[0.0, 5.0, 7.0], termini=[5.0, 7.0, 7.5])
        @test get_spells(d3; edge=(1, 2)) == [Spell(0.0, 7.0)]
        @test get_observation_period(d3) == (0.0, 7.5)
        # Undirected, Int32 ids, a shared mask
        u1 = Network{Int32}(; n=3, directed=false); add_edge!(u1, 2, 1)
        u2 = Network{Int32}(; n=3, directed=false); add_edge!(u2, 1, 2)
        set_missing_dyad!(u1, 2, 3); set_missing_dyad!(u2, 3, 2)
        du = DynamicNetwork([u1, u2])
        @test du isa DynamicNetwork{Int32, Float64, false}
        @test get_spells(du; edge=(Int32(2), Int32(1))) == [Spell(0.0, 2.0)]
        @test is_missing_dyad(du.network, 2, 3)
        # Refusals
        @test_throws ArgumentError DynamicNetwork(Network{Int, true}[])
        @test_throws ArgumentError DynamicNetwork([w1, network(5)])
        @test_throws ArgumentError DynamicNetwork([w1, network(4; directed=false)])
        @test_throws ArgumentError DynamicNetwork([w1, network(4; loops=true)])
        @test_throws ArgumentError DynamicNetwork([w1, w2]; onsets=[0.0, 1.0])
        @test_throws ArgumentError DynamicNetwork([w1, w2]; onsets=[0.0], termini=[1.0])
        @test_throws ArgumentError DynamicNetwork([w1, w2]; onsets=[0.0, 2.0], termini=[1.0, 1.0])
        @test_throws ArgumentError DynamicNetwork([w1, w2]; start=1.0, onsets=[0.0, 1.0],
                                                  termini=[1.0, 2.0])
        m2 = copy(w2); set_missing_dyad!(m2, 1, 4)
        @test_throws ArgumentError DynamicNetwork([w1, m2])
    end

    @testset "Golden fixture: panel constructor vs R networkDynamic(network.list =)" begin
        fx = NetworkCore.load_golden(joinpath(@__DIR__, "fixtures", "panel_semantics.toml"))
        V = fx.values
        fmt(x) = isinf(x) ? (x > 0 ? "Inf" : "-Inf") :
                 (isinteger(x) ? string(Int(x)) : string(x))
        fmtsp(sp) = isempty(sp) ? "NULL" : join(["$(fmt(s.onset)) $(fmt(s.terminus))" for s in sp], ";")
        n_edges = 0
        for g in 1:V["n_cases"]
            c = V["case_$g"]
            directed, n = c["directed"], c["n"]
            nets = map(1:c["n_waves"]) do k
                w = network(n; directed=directed)
                for e in c["wave_$k"]
                    add_edge!(w, parse.(Int, split(e))...)
                end
                w
            end
            d = if c["kind"] == "default"
                DynamicNetwork(nets)
            elseif c["kind"] == "start"
                DynamicNetwork(nets; start=Float64(c["start"]))
            else
                DynamicNetwork(nets; onsets=Float64.(c["onsets"]), termini=Float64.(c["termini"]))
            end
            @test collect(get_observation_period(d)) == Float64.(c["observation_period"])
            @test [fmtsp(get_vertex_activity(d, v)) for v in 1:n] == c["vertex_activity"]
            r_edges = Dict(split(x, "|")[1] => split(x, "|")[2] for x in c["edge_activity"])
            lab(i, j) = directed ? "$i $j" : "$(min(i, j)) $(max(i, j))"
            r_lab = Dict(lab(parse.(Int, split(k))...) => v for (k, v) in r_edges)
            jl_lab = Dict(lab(src(e), dst(e)) => fmtsp(get_edge_activity(d, src(e), dst(e)))
                          for e in edges(d.network))
            @test jl_lab == r_lab
            n_edges += length(r_lab)
        end
        @test n_edges > 500
    end

    @testset "Golden fixture: spell semantics vs R networkDynamic" begin
        fx = NetworkCore.load_golden(joinpath(@__DIR__, "fixtures", "spell_semantics.toml"))
        V = fx.values
        num(x) = parse(Float64, x)
        fmt(x) = isinf(x) ? (x > 0 ? "Inf" : "-Inf") :
                 (isinteger(x) ? string(Int(x)) : string(x))
        fmtsp(sp) = isempty(sp) ? "NULL" : join(["$(fmt(s.onset)) $(fmt(s.terminus))" for s in sp], ";")
        n_checked = 0
        for g in 1:V["n_cases"]
            c = V["case_$g"]
            directed = c["directed"]
            dnet = DynamicNetwork(5; directed=directed)
            pairs = [Tuple(parse.(Int, split(e))) for e in c["edges"]]
            for (i, j) in pairs
                add_edge!(dnet.network, i, j)
            end
            for op in c["ops"]
                k, a, b, on, te = split(op)
                a, b, on, te = parse(Int, a), parse(Int, b), num(on), num(te)
                k == "av" && activate!(dnet, on, te; vertex=a)
                k == "dv" && deactivate!(dnet, on, te; vertex=a)
                k == "ae" && activate!(dnet, on, te; edge=(a, b))
                k == "de" && deactivate!(dnet, on, te; edge=(a, b))
            end
            # Stored spells (activation merges, deactivation of defaults)
            @test [fmtsp(get_vertex_activity(dnet, v)) for v in 1:5] == c["vertex_spells"]
            @test [fmtsp(get_edge_activity(dnet, i, j)) for (i, j) in pairs] == c["edge_spells"]
            lab(i, j) = directed ? "$i-$j" : "$(min(i, j))-$(max(i, j))"
            function edge_labels(x)
                pid = nv(x) == 0 ? Int[] : [get_vertex_attribute(x, :vertex_pid, v) for v in 1:nv(x)]
                join(sort([lab(pid[src(e)], pid[dst(e)]) for e in edges(x)]), ",")
            end
            for (qq, ans) in zip(c["queries"], c["answers"])
                parts = split(qq)
                if parts[1] == "at"
                    t = num(parts[2])
                    x = network_extract(dnet, t)
                    va = [v for v in 1:5 if is_active(dnet, t; vertex=v)]
                else
                    rule = Symbol(parts[1]); a, b = num(parts[2]), num(parts[3])
                    x = network_extract(dnet, a, b; rule=rule)
                    va = [v for v in 1:5 if is_active(dnet, a, b; vertex=v, rule=rule)]
                end
                @test "V=$(join(va, ",")) E=$(edge_labels(x))" == ans
                n_checked += 1
            end
            for (qq, ans) in zip(c["collapse_queries"], c["collapse_answers"])
                rule, a, b = Symbol(split(qq)[1]), num(split(qq)[2]), num(split(qq)[3])
                col = network_collapse(dnet; onset=a, terminus=b, rule=rule)
                @test join(sort([lab(src(e), dst(e)) for e in edges(col)]), ",") == ans
                n_checked += 1
            end
            reconcile_activity!(dnet)
            @test [fmtsp(get_edge_activity(dnet, i, j)) for (i, j) in pairs] ==
                  c["reconciled_edge_spells"]
        end
        @test n_checked == 12 * V["n_cases"]
    end

    @testset "Every exported docstring carries a runnable example" begin
        # Mirrors ERGM.jl's testset: every DynamicNetworks-owned docstring of an
        # exported or public binding contains a ```julia block, and every block
        # runs in a fresh module (an example that needs another package says so).
        meta = Base.Docs.meta(DynamicNetworks)
        documented_elsewhere(b) = any(haskey(Base.Docs.meta(m), b) for m in (NetworkCore, Graphs))
        undocumented = String[]; missing_example = String[]
        blocks = Tuple{String,String}[]
        for nm in names(DynamicNetworks)
            nm === :DynamicNetworks && continue
            b = Base.Docs.Binding(DynamicNetworks, nm)
            if !haskey(meta, b)
                documented_elsewhere(b) || push!(undocumented, string(nm))
                continue
            end
            has_example = false
            for (_, ds) in meta[b].docs
                txt = ds.text isa AbstractString ? ds.text : join(string.(ds.text), "\n")
                for m in eachmatch(r"```julia\n(.*?)```"s, txt)
                    has_example = true
                    push!(blocks, (string(nm), String(m.captures[1])))
                end
            end
            has_example || push!(missing_example, string(nm))
        end
        @test isempty(undocumented)
        @test isempty(missing_example)
        @test length(blocks) >= 38
        for (nm, code) in blocks
            m = Module(Symbol("DocExample_", nm))
            ok = try
                Core.eval(m, :(using DynamicNetworks))
                Core.eval(m, Meta.parseall(code; filename="docstring:$nm"))
                true
            catch err
                println(stderr, "docstring example of $nm failed: ", sprint(showerror, err))
                false
            end
            @test ok
        end
    end

    @testset "Aqua" begin
        Aqua.test_all(DynamicNetworks)
        @test isempty(Test.detect_ambiguities(DynamicNetworks))
    end
end
