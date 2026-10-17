using Test
using Dates
using UUIDs
using GeoData
using GeoDataSources
using GeoDataSources: wind_speed_to_kinematic_stress, wind_speed_from_stress,
    load_wind_stress_geodata

include("helpers.jl")

@testset "Atmosphere & Wind Stress Dynamics" begin
    # Stress conversions
    @test wind_speed_to_kinematic_stress(0.0, 0.0) == (0.0, 0.0)

    tx, ty = wind_speed_to_kinematic_stress(3.0, 4.0)
    @test tx > 0 && ty > 0
    @test ty / tx ≈ 4.0 / 3.0

    slow_tx, = wind_speed_to_kinematic_stress(10.0, 0.0)
    fast_tx, = wind_speed_to_kinematic_stress(20.0, 0.0)
    @test slow_tx > 0 && fast_tx > slow_tx

    u5, v5 = wind_speed_to_kinematic_stress(5.0, -5.0)
    @test v5 < 0
    @test u5 > 0
    @test abs(v5) ≈ abs(u5)
    tx_low, = wind_speed_to_kinematic_stress(9.0, 0.0)
    tx_high, = wind_speed_to_kinematic_stress(12.0, 0.0)
    @test tx_high / 12.0 > tx_low / 9.0

    for s in (2.0, 8.0, 11.0, 15.0, 25.0, 60.0)
        t, = wind_speed_to_kinematic_stress(s, 0.0)
        @test wind_speed_from_stress(t) ≈ s rtol = 1e-6
    end
    @test wind_speed_from_stress(0.0) == 0.0
    @test wind_speed_from_stress(-0.5) == wind_speed_from_stress(0.5)
    @test wind_speed_from_stress(-0.5) > 0.0

    d1, = wind_speed_to_kinematic_stress(8.0, 0.0; ρ_air = 1.0)
    d2, = wind_speed_to_kinematic_stress(8.0, 0.0; ρ_air = 2.0)
    @test d2 ≈ 2 * d1

    # Wind stress store read
    dir = test_scratch()
    try
        lon = collect(-64.0:1.0:-61.0); lat = collect(44.0:1.0:45.0)
        tx_mat = [0.05 * (lon[i] + 64.0) for i in 1:4, j in 1:2]
        ty_mat = [0.02 * (lat[j] - 44.0) for i in 1:4, j in 1:2]
        d_lon = Dimension(name = :lon, size = 4, coords = lon,
                          dim_type = GeoData.DIM_SPATIAL)
        d_lat = Dimension(name = :lat, size = 2, coords = lat,
                          dim_type = GeoData.DIM_SPATIAL)
        crs = CoordinateSystem(crs = "EPSG:4326")
        ds = GeoDataset(
            Dict("tau_x" => GeoArray(tx_mat, (d_lon, d_lat,), crs, Dict{String, Any}()),
                 "tau_y" => GeoArray(ty_mat, (d_lon, d_lat,), crs, Dict{String, Any}())),
            Dict(:lon => GeoArray(lon, (d_lon,), crs, Dict{String, Any}()),
                 :lat => GeoArray(lat, (d_lat,), crs, Dict{String, Any}())),
            Dict(:lon => d_lon, :lat => d_lat), crs, Dict{String, Any}(), nothing, "w")
        p = joinpath(dir, "winds.zarr")
        geosave(p, ds; backend = :zarr)

        w = load_wind_stress_geodata(p)
        @test w.tau_x ≈ sum(tx_mat) / prod(size(tx_mat))
        @test w.tau_y ≈ sum(ty_mat) / prod(size(ty_mat))
        @test w.tau_max ≈ maximum(hypot.(tx_mat, ty_mat))
        @test w.speed10_rms ≈ wind_speed_from_stress(hypot(w.tau_x, w.tau_y))
    finally
        rm(dir; recursive = true, force = true)
    end
end
