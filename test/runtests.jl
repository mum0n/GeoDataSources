# ==============================================================================
# GeoDataSources Comprehensive Test Suite Orchestrator
# ==============================================================================

import Pkg

const RUNNING_UNDER_PKG_TEST = basename(dirname(Base.active_project())) == "test"
if !RUNNING_UNDER_PKG_TEST
    Pkg.activate(joinpath(@__DIR__, ".."); io = devnull)
    Pkg.instantiate(; io = devnull)
end

# Usage:
#   julia --project=. test/runtests.jl                # Run every segment
#   julia --project=. test/runtests.jl cube           # Run regional cube & bioenergetics
#   julia --project=. test/runtests.jl catalog        # Run catalog & manifest checks
#   julia --project=. test/runtests.jl ingestion      # Run ingestion & discretization
#   julia --project=. test/runtests.jl hydro          # Run hydrodynamics, WOA23 & tides
#   julia --project=. test/runtests.jl winds          # Run winds & atmospheric forcing
#
# Under `Pkg.test()` the whole suite runs; pass segments as test_args:
#   Pkg.test(test_args = ["cube", "catalog"])
# ==============================================================================

using Test
using Dates
using UUIDs
using Statistics
using TOML
using JSON3
using DataFrames
using GeoData
using GeoDataSources

include(joinpath(@__DIR__, "helpers.jl"))

const AVAILABLE_SEGMENTS = Dict{Symbol, @NamedTuple{file::String, desc::String}}(
    :cube => (
        file = "test_cube.jl",
        desc = "Regional Environmental Data Cube & Metabolic Bioenergetics"
    ),
    :catalog => (
        file = "test_catalog_manifest.jl",
        desc = "Data Catalog, Manifest Registry & Medallion Invariants"
    ),
    :ingestion => (
        file = "test_ingestion.jl",
        desc = "Raw Observations Ingestion, Discretization & Benthic Grids"
    ),
    :hydro => (
        file = "test_hydrodynamics.jl",
        desc = "Hydrodynamics Assimilation, WOA23 Tracers & TPXO9 Tidal Verification"
    ),
    :winds => (
        file = "test_winds.jl",
        desc = "Atmospheric Wind Stress Conversions & Central Lakehouse Persistence"
    )
)

"""
    parse_requested_segments(args::Vector{String}) -> Vector{Symbol}

Resolves CLI segment arguments to segment keys.
"""
function parse_requested_segments(args::Vector{String})::Vector{Symbol}
    if isempty(args)
        return collect(keys(AVAILABLE_SEGMENTS))
    end

    selected = Symbol[]
    for a in args
        key = Symbol(lowercase(strip(a)))
        if haskey(AVAILABLE_SEGMENTS, key)
            push!(selected, key)
        else
            avail = sort(string.(collect(keys(AVAILABLE_SEGMENTS))))
            @warn "Unrecognized test segment: '$a'. Available segments: $(join(avail, ", "))"
        end
    end

    return isempty(selected) ? sort!(collect(keys(AVAILABLE_SEGMENTS))) : unique(selected)
end

requested_segments = parse_requested_segments(ARGS)

@testset "GeoDataSources Comprehensive Suite" begin
    for seg_key in requested_segments
        info = AVAILABLE_SEGMENTS[seg_key]
        println("\n" * "="^80)
        println(">>> Running Segment: $(info.desc) ($(info.file))")
        println("="^80)
        include(joinpath(@__DIR__, info.file))
    end
end