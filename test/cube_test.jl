using Test
using GeoData
using GeoDataSources
using Dates

@testset "Regional Data Cube & Bioenergetics" begin
    # 1. Configuration parsing
    cfg_path = joinpath(@__DIR__, "..", "configs", "regions", "scotian_shelf.toml")
    @test isfile(cfg_path)
    
    cfg = load_cube_config(cfg_path)
    @test cfg.region_name == "scotian_shelf"
    @test cfg.time_mode == :climatology
    @test length(cfg.depth_levels) == 47
    @test :dissolved_oxygen in cfg.variables
    @test :ph in cfg.variables

    # 2. Standard ocean depths
    depths = standard_ocean_depths()
    @test length(depths) == 47
    @test depths[1] == 0.0
    @test depths[end] == 4000.0

    # 3. Bioenergetic metabolic scope coupler
    # Optimal conditions (3.0°C, [O2]=300 μmol/kg, pH=8.1)
    scope_opt = evaluate_bioenergetic_scope(3.0, 300.0, 8.1)
    @test scope_opt > 0.70

    # Hypoxic conditions ([O2]=30 μmol/kg)
    scope_hypoxic = evaluate_bioenergetic_scope(3.0, 30.0, 8.1)
    @test scope_hypoxic < scope_opt
    @test scope_hypoxic > 0.0

    # Lethal thermal threshold (11.0°C)
    scope_lethal = evaluate_bioenergetic_scope(11.0, 300.0, 8.1)
    @test scope_lethal == 0.0
end
