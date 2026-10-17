using Test
using Dates
using UUIDs
using GeoData
using GeoDataSources
using GeoDataSources: fetch_woa23, _validate_tpxo9_velocity,
    build_boundary_tracer_interpolators_geodata,
    _central_glorys_subset, resolved_cache_path

include("helpers.jl")

@testset "Hydrodynamics, WOA23 & Tidal Verification" begin
    # Lakehouse paths & checksums
    scratch = test_scratch()
    try
        path = lakehouse_path(:probe; tier = :processed, ext = "zarr")
        @test endswith(path, ".zarr")
        @test contains(path, string(lakehouse_root_dir()))
        @test !isdir(path)

        f = joinpath(scratch, "blob.bin")
        write(f, rand(UInt8, 4096))
        digest = compute_lakehouse_checksum(f)
        @test length(digest) == 64 && occursin(r"^[0-9a-f]+$", digest)
        @test digest == compute_lakehouse_checksum(f)
    finally
        rm(scratch; recursive = true, force = true)
    end

    # WOA23 interpolator verification
    dir = test_scratch()
    try
        lon = collect(-66.0:1.0:-61.0)
        lat = collect(42.0:1.0:45.0)
        dep = collect(0.0:10.0:40.0)
        field_eval(lo, la, z) = 10.0 + z / 5.0 + la + lo / 10.0

        for order in (:lon_lat_depth, :lat_lon_depth)
            for (varname, prefix, scale) in (("t_an", "temperature", 1.0),
                                             ("s_an", "salinity", 0.1))
                pth = joinpath(dir, "woa23_$(prefix)_01_0.25deg.zarr")
                rm(pth; force = true, recursive = true)
                raw = [scale * field_eval(lon[i], lat[j], -dep[k])
                       for i in 1:6, j in 1:4, k in 1:5]
                ds = if order === :lat_lon_depth
                    make_3d_store(permutedims(raw, (2, 1, 3)), lon, lat, dep, varname;
                                  order = (:lat, :lon, :depth))
                else
                    make_3d_store(raw, lon, lat, dep, varname)
                end
                geosave(pth, ds; backend = :zarr)
            end
            res = fetch_woa23(; lon_range = (-66.0, -61.0), lat_range = (42.0, 45.0),
                              month = 1, output_dir = dir, include_o2 = false,
                              verbose = false)
            @test res !== nothing
            itp = res.temperature_fn
            for i in 1:6, j in 1:4, k in 1:5
                @test itp(lon[i], lat[j], -dep[k]) ≈ field_eval(lon[i], lat[j], -dep[k])
            end
        end

        # Boundary tracer interpolator
        lon_b = collect(-64.0:1.0:-60.0)
        lat_b = collect(42.0:1.0:46.0)
        dep_b = collect(0.0:5.0:25.0)
        crs = CoordinateSystem(crs = "EPSG:4326")
        dims = map(d -> Dimension(name = d, size = length(d == :lon ? lon_b :
                                                                d == :lat ? lat_b : dep_b),
                                  coords = d == :lon ? lon_b : d == :lat ? lat_b : dep_b,
                                  units = d == :lon ? "degrees_east" :
                                          d == :lat ? "degrees_north" : "m",
                                  dim_type = d == :lon || d == :lat ? GeoData.DIM_SPATIAL :
                                          GeoData.DIM_PARAMETRIC),
                    (:lon, :lat, :depth))
        temp = [Float64(i + j - k) for i in axes(lon_b, 1), j in axes(lat_b, 1), k in axes(dep_b, 1)]
        salt = fill(31.0, length(lon_b), length(lat_b), length(dep_b))
        for (varname, data) in (("thetao", temp), ("so", salt))
            vars = Dict{String, GeoArray}(varname => GeoArray(data, dims, crs, Dict()))
            ds_b = GeoDataset(vars,
                            Dict{Symbol, GeoArray}(:lon => GeoArray(lon_b, (dims[1],), crs, Dict()),
                                                   :lat => GeoArray(lat_b, (dims[2],), crs, Dict()),
                                                   :depth => GeoArray(dep_b, (dims[3],), crs, Dict())),
                            Dict{Symbol, Dimension}(:lon => dims[1], :lat => dims[2],
                                                    :depth => dims[3]), crs,
                            Dict{String, Any}(), nothing, "boundary-fixture")
            geosave(joinpath(dir, "$(varname).zarr"), ds_b; backend = :zarr)
        end
        res_b = build_boundary_tracer_interpolators_geodata(
            joinpath(dir, "thetao.zarr"), joinpath(dir, "so.zarr");
            T_name = "thetao", S_name = "so", months = [1])
        @test res_b.S(-62.0, 44.0, 10.0, 1) == 31.0
        @test res_b.T(-62.0, 44.0, 0.0, 1) == temp[3, 3, 1]

        # Tidal atlas verification
        global_lon = collect(0.0:1.0:359.0)
        full_lat = collect(-80.0:1.0:80.0)
        d_con = Dimension(name = :ncon, size = 2, coords = [1.0, 2.0],
                          dim_type = GeoData.DIM_GENERIC)
        function atlas_store(pth, lat_vals, vars)
            d_l = Dimension(name = :lon, size = length(global_lon),
                              coords = global_lon, dim_type = GeoData.DIM_SPATIAL)
            d_la = Dimension(name = :lat, size = length(lat_vals), coords = lat_vals,
                              dim_type = GeoData.DIM_SPATIAL)
            crs_a = CoordinateSystem(crs = "EPSG:4326")
            vars_out = Dict{String, GeoArray}(
                "con" => GeoArray([1.0, 2.0], (d_con,), crs_a, Dict{String, Any}()))
            for v in vars
                vars_out[v] = GeoArray(ones(length(global_lon), length(lat_vals)),
                                       (d_l, d_la,), crs_a, Dict{String, Any}())
            end
            coords_a = Dict{Symbol, GeoArray}(
                :lon => GeoArray(global_lon, (d_l,), crs_a, Dict{String, Any}()),
                :lat => GeoArray(lat_vals, (d_la,), crs_a, Dict{String, Any}()),
                :ncon => GeoArray([1.0, 2.0], (d_con,), crs_a, Dict{String, Any}()))
            geosave(pth, GeoDataset(
                vars_out, coords_a, Dict(:lon => d_l, :lat => d_la, :ncon => d_con),
                crs_a, Dict{String, Any}(), nothing, "atlas"); backend = :zarr)
        end

        good_atlas = joinpath(dir, "global_atlas.zarr")
        atlas_store(good_atlas, full_lat, ("ua", "up", "va", "vp"))
        @test GeoDataSources._validate_tpxo9_velocity(
            good_atlas; lat_range = (-71.0, -60.0), verbose = false) !== nothing
    finally
        rm(dir; recursive = true, force = true)
    end
end
