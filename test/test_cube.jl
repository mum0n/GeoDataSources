using Test
using GeoData
using GeoDataSources
using Dates
using TOML
using GeoDataSources: RegionalCubeConfig, CUBE_VARIABLE_SOURCES, CUBE_VARIABLE_LAYOUT,
    standard_ocean_depths, _cube_horizontal_grid, _benthic_grid,
    _cube_field_name, _cube_to_layout, source_of, CUBE_FIELD_SPELLINGS

include("helpers.jl")

@testset "Regional Environmental Cube & Bioenergetics" begin
    # Bioenergetics scope & configuration
    cfg_path = joinpath(@__DIR__, "..", "configs", "regions", "scotian_shelf.toml")
    @test isfile(cfg_path)

    cfg = load_cube_config(cfg_path)
    @test cfg.region_name == "scotian_shelf"
    @test cfg.time_mode == :climatology
    @test length(cfg.depth_levels) == 47
    @test :dissolved_oxygen in cfg.variables
    @test :ph in cfg.variables

    depths = standard_ocean_depths()
    @test length(depths) == 47
    @test depths[1] == 0.0
    @test depths[end] == 4000.0

    scope_opt = evaluate_bioenergetic_scope(3.0, 300.0, 8.1)
    @test scope_opt > 0.70

    scope_hypoxic = evaluate_bioenergetic_scope(3.0, 30.0, 8.1)
    @test scope_hypoxic < scope_opt
    @test scope_hypoxic > 0.0

    scope_lethal = evaluate_bioenergetic_scope(11.0, 300.0, 8.1)
    @test scope_lethal == 0.0

    # Grid generation and spacing
    @test cfg.output_path == joinpath(store_root(), "cubes", "scotian_shelf_environmental")
    @test length(cfg.variables) == length(TOML.parsefile(cfg_path)["variables"])
    @test all(haskey(CUBE_VARIABLE_SOURCES, v) for v in cfg.variables)
    @test all(haskey(CUBE_VARIABLE_LAYOUT, v) for v in cfg.variables)

    cfg_deg = RegionalCubeConfig(region_name = "deg", lon_range = (-64.0, -63.0),
                                lat_range = (44.0, 45.0), resolution_deg = 0.1)
    lo_deg, la_deg = _cube_horizontal_grid(cfg_deg)
    @test la_deg[2] - la_deg[1] ≈ 0.1
    @test lo_deg[2] - lo_deg[1] ≈ 0.1 * cos(deg2rad(44.5))

    cfg_km = RegionalCubeConfig(region_name = "km", lon_range = (-64.0, -63.0),
                                lat_range = (44.0, 45.0), resolution_km = 1.0,
                                resolution_deg = 0.1)
    lo_km, la_km = _cube_horizontal_grid(cfg_km)
    @test (la_km[2] - la_km[1]) * 110.574 ≈ 1.0
    @test (lo_km[2] - lo_km[1]) * 111.320 * cos(deg2rad(44.5)) ≈ 1.0
    @test length(lo_km) > 10
    @test length(la_km) > length(la_deg)
    @test la_km[end] <= 45.0 + 1e-9
    @test lo_km[end] <= -63.0 + 1e-9

    tl = collect(-63.5:0.25:-63.0)
    ta = collect(44.5:0.25:44.75)
    lo, la = _benthic_grid((-64.0, -63.0), (44.0, 45.0), tl, ta, nothing)
    @test lo == tl && la == ta
    @test_throws Exception _benthic_grid((-64.0, -63.0), (44.0, 45.0), tl, nothing, 0.1)
end
