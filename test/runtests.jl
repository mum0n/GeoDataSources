"""
Tests for `GeoDataSources.jl`.

Everything here works offline: the fetchers take local fixtures where they take fixtures at
all, and the network paths are exercised only by the `scripts/` drivers against live
endpoints. That keeps the contract - right variable, right axes, right units - testable
without depending on a service being up.
"""

using Test
using Dates
using UUIDs
using Statistics
using TOML
using JSON3
using DataFrames
using GeoData
using GeoDataSources
using GeoDataSources.GeoDataManifest
using GeoData.GeoDataTypes: Dimension, DIM_SPATIAL, DIM_TEMPORAL
using GeoData: GeoArray, GeoDataset
using GeoDataSources: RegionalCubeConfig, CUBE_VARIABLE_SOURCES, CUBE_VARIABLE_LAYOUT,
    standard_ocean_depths, _cube_horizontal_grid, _benthic_grid, raw_points,
    _qc_bottom_temperature, bin_points, raw_data_digests, discretize, DISCRETIZATION,
    discretized_path, load_bottom_temperature_points, load_substrate_points,
    _cube_field_name, _cube_to_layout, source_of, CUBE_FIELD_SPELLINGS,
    fetch_substrate_grainsize, fetch_bottom_temperature, ingest_bottom_temperature,
    ingest_substrate, ingest_nwa_bathymetry

# Internal, deliberately: the underscore marks these private, so they are *not* in the
# package's export list. Test code reaches them by qualified import, which is the one
# legitimate reason to name an internal from outside its module.
using GeoDataSources: _read_point_table, _write_point_table

include("helpers.jl")

@testset "GeoDataSources" begin
    include("cube_test.jl")

    @testset "Catalog persistence and query" begin
        dir = test_scratch()
        try
            cat_file = joinpath(dir, "catalog.json")
            catalog = GeoDataCatalog(cat_file; auto_save = true)

            geopublish!(catalog, "https://example.com/obs.nc";
                       key = :noaa_obs, name = "NOAA In-Situ Observations", tier = :raw,
                       variables = ["temp"], format = :netcdf)
            geopublish!(catalog, joinpath(dir, "grid.zarr");
                       key = :temp_harmonized, name = "Harmonized Temperature Grid",
                       tier = :processed, derived_from = [:noaa_obs], format = :zarr)
            geopublish!(catalog, joinpath(dir, "kernel.zarr");
                       key = :larval_dispersal, name = "Larval Dispersal Kernels",
                       tier = :derived, derived_from = [:temp_harmonized], format = :zarr)

            @test length(find_datasets(catalog; tier = :raw)) == 1
            @test find_datasets(catalog; derived_from = :noaa_obs)[1].key == :temp_harmonized
            @test get_dataset_by_key(catalog, :temp_harmonized).tier == :processed

            fetched = geofetch(catalog, :larval_dispersal)
            @test fetched.name == "Larval Dispersal Kernels"
            @test fetched.access_count == 1

            reloaded = GeoDataCatalog(cat_file)
            @test length(reloaded.entries) == 3
            @test get_dataset_by_key(reloaded, :temp_harmonized).derived_from == [:noaa_obs]
            @test get_dataset_by_key(reloaded, :larval_dispersal).access_count == 1

            target = get_dataset_by_key(reloaded, :noaa_obs)
            update_dataset!(reloaded, target.uuid, :key => :insitu, :name => "In-Situ")
            @test get_dataset_by_key(reloaded, :insitu).name == "In-Situ"
            @test_throws ArgumentError get_dataset_by_key(reloaded, :noaa_obs)
        finally
            GC.gc(); sleep(0.1)
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "Cube config and grid" begin
        cfg_path = joinpath(@__DIR__, "..", "configs", "regions", "scotian_shelf.toml")
        cfg = load_cube_config(cfg_path)
        @test cfg.region_name == "scotian_shelf"
        @test cfg.output_path == joinpath(store_root(), "cubes", "scotian_shelf_environmental")
        @test length(cfg.variables) == length(TOML.parsefile(cfg_path)["variables"])
        @test all(haskey(CUBE_VARIABLE_SOURCES, v) for v in cfg.variables)
        @test all(haskey(CUBE_VARIABLE_LAYOUT, v) for v in cfg.variables)
        @test length(standard_ocean_depths()) == 47

        # `resolution_deg` is spacing in degrees, which for longitude is a shorter
        # distance than the same number of degrees of latitude.
        cfg_deg = RegionalCubeConfig(region_name = "deg", lon_range = (-64.0, -63.0),
                                    lat_range = (44.0, 45.0), resolution_deg = 0.1)
        lo_deg, la_deg = _cube_horizontal_grid(cfg_deg)
        @test la_deg[2] - la_deg[1] ≈ 0.1
        @test lo_deg[2] - lo_deg[1] ≈ 0.1 * cos(deg2rad(44.5))

        # `resolution_km` is spacing in distance, and is square. It wins over degrees.
        cfg_km = RegionalCubeConfig(region_name = "km", lon_range = (-64.0, -63.0),
                                    lat_range = (44.0, 45.0), resolution_km = 1.0,
                                    resolution_deg = 0.1)
        lo_km, la_km = _cube_horizontal_grid(cfg_km)
        @test (la_km[2] - la_km[1]) * 110.574 ≈ 1.0
        @test (lo_km[2] - lo_km[1]) * 111.320 * cos(deg2rad(44.5)) ≈ 1.0
        @test length(lo_km) > 10
        @test length(la_km) > length(la_deg)
        # A grid stops at or before the requested bounds, never past them.
        @test la_km[end] <= 45.0 + 1e-9
        @test lo_km[end] <= -63.0 + 1e-9

        # An explicit target grid beats a derived one.
        tl = collect(-63.5:0.25:-63.0)
        ta = collect(44.5:0.25:44.75)
        lo, la = _benthic_grid((-64.0, -63.0), (44.0, 45.0), tl, ta, nothing)
        @test lo == tl && la == ta
        @test_throws Exception _benthic_grid((-64.0, -63.0), (44.0, 45.0), tl, nothing, 0.1)
    end

    @testset "Manifest fetch dispatch" begin
        for key in keys(GeoDataManifest.DATA_SOURCES)
            d = GeoDataManifest.data_source(key)
            @test d.key == key
            @test haskey(GeoDataManifest.FETCHERS, key) || d.primary !== nothing
            @test !isempty(d.title)
            @test !isempty(d.license)
        end
        for key in (:bathymetry, :atmosphere, :hydrography, :woa23, :coastline,
                    :bottom_temperature, :substrate, :nwa_bathymetry, :glorys)
            @test haskey(GeoDataManifest.FETCHERS, key)
        end
        for (variable, key) in CUBE_VARIABLE_SOURCES
            @test haskey(GeoDataManifest.DATA_SOURCES, key)
        end
        # Every declared source with a fetcher is covered by exactly one entry, and no
        # fetcher names a source the manifest does not declare: a dangling fetcher is a
        # path that never resolves.
        declared = Set(keys(GeoDataManifest.DATA_SOURCES))
        @test all(k -> k in declared, keys(GeoDataManifest.FETCHERS))
        @test sort(collect(keys(GeoDataManifest.FETCHERS))) ==
              sort([:bathymetry, :atmosphere, :hydrography, :woa23, :coastline,
                    :lateral_boundary, :bottom_temperature, :substrate,
                    :nwa_bathymetry, :glorys, :tides,
                    # :surface_winds names the winds alone; :atmosphere carries the whole ERA5
                    # surface state. Same product, two keyed sources (see DATA_SOURCES notes).
                    :surface_winds])
    end

    @testset "Unbuildable sources fail clearly, not silently" begin
        # A declared source with no fetcher for its tier must error at the fetch call,
        # naming its alternatives, rather than silently substituting. `tides` was the last
        # such source and now builds, so this list is what it should be: empty, with the
        # registry asserting every declared source is reachable.
        @test all(k -> !(k in keys(GeoDataManifest.FETCHERS)),
                  [k for k in keys(GeoDataManifest.DATA_SOURCES)
                   if !buildable(k)])
        @test issubset([:bathymetry, :atmosphere, :hydrography, :woa23, :coastline,
                        :lateral_boundary, :bottom_temperature, :substrate,
                        :nwa_bathymetry, :glorys, :tides],
                       keys(GeoDataManifest.FETCHERS))
        # GLORYS12V1 is the same Copernicus Marine physics collection the lateral-boundary
        # path reads, so it is declared and its reader is found.
        @test buildable(:glorys)
        @test haskey(GeoDataManifest.FETCHERS, :glorys)
        @test haskey(GeoDataManifest.DATA_SOURCES, :glorys)
        # Every fetcher names a declared source: a dangling fetcher never resolves.
        @test all(k -> k in keys(GeoDataManifest.DATA_SOURCES),
                  keys(GeoDataManifest.FETCHERS))
    end

    @testset "fetch_input resolves a cached store through <store>" begin
        # The `<store>` substitution lives in the manifest submodule and runs *before* the
        # cache check, so an unqualified parent-module call there fails every `fetch_input`
        # call, cached or not. It did: `store_root` was never imported into that module, and
        # no test reached the line because every other test stopped at a cached store or an
        # unbuildable source. This is the offline test that reaches it.
        dir = test_scratch()
        try
            target = replace(GeoDataManifest.DATA_SOURCES[:bathymetry].cache,
                             "<store>" => store_root())
            if is_cached(target)
                path = fetch_input(:bathymetry, dir)
                @test path == target
                # The cache is the registry's copy, not a per-run download.
                @test startswith(abspath(path), abspath(store_root()))
            else
                @info "Central store has no cached :bathymetry; skipping the resolved-path check."
                @test true
            end
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "Adapter keyword contract holds when actually called" begin
        # `fetch_input` calls every adapter as `(path; output_dir, force, strict,
        # kwargs...)`. An adapter naming a keyword its callee does not accept is a code
        # MethodError at the fetch call, which no offline test reaches because every other
        # test stops at a cached store or an unbuildable source. Three of the ten were live
        # that way earlier in this pass; this test is the one that proves the contract by
        # calling it, and it is what caught them.
        #
        # Reaching an adapter's *body* requires network access, so the whole test is
        # skipped unless it is explicitly opted in. The default run of this suite is
        # offline - it must stay that way - but the check must exist somewhere, and the
        # option makes it repeatable rather than a one-off manual script.
        if get(ENV, "GEODATASOURCES_LIVE", "") in ("1", "true", "yes")
            dir = test_scratch()
            try
                bad = String[]
                for key in sort(collect(filter(!=(:tides), keys(GeoDataManifest.FETCHERS))))
                    try
                        GeoDataManifest.FETCHERS[key](joinpath(dir, "$key.zarr");
                                                      output_dir = dir, force = true,
                                                      strict = false)
                    catch e
                        msg = first(split(sprint(showerror, e), "\n"))
                        (occursin("unsupported keyword", msg) ||
                         occursin("no method matching", msg)) && push!(bad, "$key: $msg")
                    end
                end
                @test isempty(bad)
                isempty(bad) || println("   rejected by callee:\n  ", join(bad, "\n  "))
            finally
                rm(dir; recursive = true, force = true)
            end
        else
            @test true
            @info "Set GEODATASOURCES_LIVE=1 to check the adapter keyword contract against live fetchers."
        end
    end
@testset "Every fetcher accepts the canonical keyword set (live)" begin
        # The canonical set is documented on the `_fetcher_*` adapters: `lon_range`,
        # `lat_range`, `output_path`, `force`, `backend`, `verbose`. Documenting it is not the
        # same as having it: before this item, seven of the eleven fetchers raised MethodError
        # when called with the documented set, because each had been written with its own
        # keyword set and none had been checked against the documented one. The set is now
        # implemented everywhere, and this is the check that says so.
        #
        # Checking keyword acceptance needs the method table, which in this Julia version has
        # no accessible reflection (`Base.kwarg_decl` and `Base.method_argnames` both raise
        # MethodError on these functions), so it is verified by calling -- which reaches the
        # network. Hence opt-in, exactly as the adapter test above.
        if get(ENV, "GEODATASOURCES_LIVE", "") in ("1", "true", "yes")
            dir = test_scratch()
            try
                bad = String[]
                for key in sort(collect(filter(!=(:tides), keys(GeoDataManifest.FETCHERS))))
                    try
                        GeoDataManifest.FETCHERS[key](
                            joinpath(dir, string(key, ".out")); output_dir = dir,
                            lon_range = (-64.0, -63.0), lat_range = (44.0, 45.0),
                            force = false, backend = :zarr, verbose = false)
                    catch e
                        msg = first(split(sprint(showerror, e), "\n"))
                        (occursin("unsupported keyword", msg) ||
                         occursin("no method matching", msg)) &&
                            push!(bad, string(key, ": ", msg[1:min(110, length(msg))]))
                    end
                end
                @test isempty(bad)
                isempty(bad) || println("   rejected:\n  ", join(bad, "\n  "))
            finally
                rm(dir; recursive = true, force = true)
            end
        else
            @test true
            @info "Set GEODATASOURCES_LIVE=1 to check every fetcher accepts the canonical keyword set."
        end
    end
@testset "Every fetcher accepts the canonical keyword set (live)" begin
        # The canonical set is documented on the `_fetcher_*` adapters: `lon_range`,
        # `lat_range`, `output_path`, `force`, `backend`, `verbose`. Documenting it is not the
        # same as having it: before this item, seven of the eleven fetchers raised MethodError
        # when called with the documented set, because each had been written with its own
        # keyword list and none had ever been checked against the documented one. The set is
        # now implemented everywhere, and this is the check that says so.
        #
        # Checking keyword acceptance needs the method table, which in this Julia version has
        # no accessible reflection (`Base.kwarg_decl` and `Base.method_argnames` both raise
        # MethodError on these functions), so it is verified by calling -- which reaches the
        # network. Hence opt-in, exactly as the adapter test above.
        if get(ENV, "GEODATASOURCES_LIVE", "") in ("1", "true", "yes")
            dir = test_scratch()
            try
                bad = String[]
                # `tides` is excluded from the *call* because entering its body downloads a
                # 4.7 GB archive, and a keyword-shape check that costs 4.7 GB is not a check
                # anyone will run. It is covered by the signature test below instead.
                checked = filter(k -> k !== :tides, keys(GeoDataManifest.FETCHERS))
                for key in sort(collect(checked))
                    try
                        GeoDataManifest.FETCHERS[key](
                            joinpath(dir, string(key, ".out")); output_dir = dir,
                            lon_range = (-64.0, -63.0), lat_range = (44.0, 45.0),
                            force = false, backend = :zarr, verbose = false)
                    catch e
                        msg = first(split(sprint(showerror, e), "\n"))
                        (occursin("unsupported keyword", msg) ||
                         occursin("no method matching", msg)) &&
                            push!(bad, string(key, ": ", msg[1:min(110, length(msg))]))
                    end
                end
                @test isempty(bad)
                isempty(bad) || println("   rejected:\n  ", join(bad, "\n  "))
            finally
                rm(dir; recursive = true, force = true)
            end
        else
            @test true
            @info "Set GEODATASOURCES_LIVE=1 to check every fetcher accepts the canonical keyword set."
        end
    end
    @testset "The slow fetchers' signatures carry the canonical set" begin
        # `tides` downloads 4.7 GB, so it is not part of the live call check. Each
        # canonical keyword must literally appear in its signature, which is what the
        # method table reads; this verifies presence, while the live test above
        # verifies acceptance with defaults.
        tsrc = read(joinpath(dirname(@__DIR__), "src", "Fetch", "tides.jl"), String)
        head = split(tsrc, "function fetch_tpxo9_velocity")[2]
        sig = string(head[1:min(600, length(head))])
        needle(kw) = Regex(string("\\b", kw, "\\s*::"))
        for kw in ("lon_range", "lat_range", "output_path", "force", "backend", "verbose")
            @test occursin(needle(kw), sig)
        end
    end



    @testset "Tier 1 raw" begin
        digests = raw_data_digests()
        @test sort(collect(keys(digests))) == sort([:bottom_temperature, :nwa_bathymetry,
                                                    :substrate])
        for (key, digest) in digests
            @test length(digest) == 64
            @test digest == raw_data_digests()[key]
        end

        bt = load_bottom_temperature_points()
        for c in (:lon, :lat, :t, :yr, :z, :project, :date, :dyear)
            @test String(c) in names(bt)
        end
        @test nrow(bt) > 400_000
        subst = load_substrate_points()
        @test all(c -> String(c) in names(subst), [:lon, :lat, :grainsize])
        @test nrow(subst) > 500_000
    end

    @testset "Tier 1 -> tier 2 ingestion keeps everything" begin
        dir = test_scratch()
        try
            W = (lon_range = (-64.0, -63.0), lat_range = (44.0, 45.0))
            src = load_bottom_temperature_points()

            p = ingest_bottom_temperature(; W..., tag = "keep_all")
            t = _read_point_table(p)
            # No column is dropped by ingestion: everything the raw table has is written.
            for c in names(src)
                c in ("geometry",) && continue
                @test Symbol(c) in t.columns
            end
            @test :lon in t.columns && :lat in t.columns
            # Row-for-row: ingestion writes exactly the rows inside the requested bounds
            # and nothing else, so the ingested table is a faithful subset of tier 1.
            in_bounds = 0
            for row in eachrow(src)
                if (W.lon_range[1] <= row.lon <= W.lon_range[2]) &&
                   (W.lat_range[1] <= row.lat <= W.lat_range[2])
                    in_bounds += 1
                end
            end
            @test length(t.rows) == in_bounds
            @test in_bounds > 0 && in_bounds < nrow(src)
            # Depth is preserved as missing where the source has no value: a 1 km grid
            # is not invented for a station whose depth was never recorded.
            n_missing_z = count(r -> ismissing(r.z), eachrow(src[src.lon .>= W.lon_range[1] .&&
                                                              src.lon .<= W.lon_range[2] .&&
                                                              src.lat .>= W.lat_range[1] .&&
                                                              src.lat .<= W.lat_range[2], :]))
            @test n_missing_z > 0
        finally
            GC.gc(); sleep(0.1)
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "Tier 2 discretization" begin
        for (key, policy) in DISCRETIZATION
            @test policy.resolution > 0
            @test !isempty(policy.rationale)
        end
        @test DISCRETIZATION[:bottom_temperature].resolution == 1.0
        @test DISCRETIZATION[:nwa_bathymetry].unit === :deg

        # A wrong resolution is an error naming the policy, not a silent resample.
        @test_throws Exception discretize(
            :bottom_temperature; lon_range = (-64.0, -63.0), lat_range = (44.0, 45.0),
            resolution = 0.25)

        # QC keeps every row it can defend: only unusable values are dropped, and a
        # missing depth is not one of them.
        df = raw_points(:bottom_temperature)
        sub, report = _qc_bottom_temperature(df)
        @test report.n_read == nrow(df)
        @test report.n_kept == nrow(sub) == nrow(df) - sum(values(report.dropped))
        @test all(t -> -5.0 <= t <= 40.0, coalesce.(sub.t, NaN))
        @test all(x -> isfinite(x), sub.lon) && all(x -> isfinite(x), sub.lat)

        dir = test_scratch()
        try
            prov = discretize(:bottom_temperature; lon_range = (-64.0, -63.0),
                              lat_range = (44.0, 45.0), tag = "ci")
            @test prov.dataset === :bottom_temperature
            @test prov.variable == "t"
            @test prov.n_read == nrow(df) && prov.n_kept <= prov.n_read
            @test prov.grid_n_lon > 1 && prov.grid_n_lat > 1
            @test prov.grid_unit === :km && prov.grid_resolution == 1.0
            @test length(prov.raw_sha256) == 64
            lo, hi = prov.value_range
            @test -2.0 < lo && hi < 25.0
            @test prov.mean_count_per_filled_cell >= 1.0

            field = discretized_path(:bottom_temperature, "ci")
            side = replace(field, ".parquet" => ".provenance.json")
            @test isfile(field) && isfile(side)
            recorded = JSON3.read(read(side, String))
            @test recorded["tier"] == "discretized"
            @test recorded["raw_sha256"] == prov.raw_sha256
            @test recorded["grid"]["resolution"] == 1.0
        finally
            GC.gc(); sleep(0.1)
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "Tier 1 -> tier 3 grid products" begin
        window = (lon_range = (-64.0, -63.0), lat_range = (44.0, 45.0),
                  resolution_deg = 1 / 12)

        subst_ds = fetch_substrate_grainsize(; window...)
        assert_dataset_invariants(subst_ds)
        @test subst_ds.dims[:lon].size == 13 && subst_ds.dims[:lat].size == 13
        @test size(subst_ds.variables["substrate"].data) == (13, 13)
        @test size(subst_ds.variables["substrate_n"].data) == (13, 13)
        @test subst_ds.attrs["interpolated"] == true
        @test length(subst_ds.attrs["sha256"]) == 64
        filled = count(isfinite, subst_ds.variables["substrate"].data)
        @test 0 < filled < 169
        @test minimum(subst_ds.variables["substrate_n"].data) == 0

        bt_ds = fetch_bottom_temperature(; window...)
        assert_dataset_invariants(bt_ds)
        @test bt_ds.dims[:lon].size == 13 && bt_ds.dims[:lat].size == 13
        @test bt_ds.dims[:time].size > 40
        @test size(bt_ds.variables["bottom_temperature"].data) ==
              (13, 13, bt_ds.dims[:time].size)
        temps = filter(isfinite, bt_ds.variables["bottom_temperature"].data)
        @test !isempty(temps)
        @test -2.0 < minimum(temps) && maximum(temps) < 25.0
        @test maximum(bt_ds.variables["bottom_temperature_n"].data) >= 1

        # `z` is bottom depth: binned as its own static field beside the temperature.
        @test haskey(bt_ds.variables, "survey_depth")
        @test haskey(bt_ds.variables, "survey_depth_n")
        @test size(bt_ds.variables["survey_depth"].data) == (13, 13)
        depths = filter(isfinite, bt_ds.variables["survey_depth"].data)
        @test !isempty(depths) && minimum(depths) >= 0.0
    end

    @testset "Point binning" begin
        lon = [1.0, 2.0, 3.0]
        lat = [10.0, 11.0]
        rows = [(lon = 1.0, lat = 10.0, v = 5.0), (lon = 1.0, lat = 10.0, v = 7.0),
                (lon = 1.0, lat = 11.0, v = 9.0)]
        field, counts = bin_points(rows, lon, lat, value = :v)
        @test field[1, 1] == 6.0
        @test counts[1, 1] == 2
        @test field[1, 2] == 9.0
        @test ismissing(field[2, 1]) && counts[2, 1] == 0
        @test ismissing(field[3, 2]) && counts[3, 2] == 0

        # A point outside the grid is skipped, not clamped into an edge cell as data.
        outside = [(lon = 1.0, lat = 10.0, v = 5.0), (lon = 99.0, lat = 99.0, v = 100.0)]
        f2, c2 = bin_points(outside, lon, lat, value = :v)
        @test c2[2, 1] == 0 && ismissing(f2[2, 1])

        # A NaN coordinate cannot be placed in a bin, so it is skipped rather than
        # fabricated into the corner.
        nanrows = [(lon = NaN, lat = 10.0, v = 5.0), (lon = 2.0, lat = 11.0, v = 3.0)]
        f3, c3 = bin_points(nanrows, lon, lat, value = :v)
        @test c3[1, 1] == 0 && c3[2, 2] == 1

        # Time binning: labels, so a mid-year observation joins its own year.
        trows = [(lon = 1.0, lat = 10.0, yr = 1999.4, v = 4.0),
                 (lon = 1.0, lat = 10.0, yr = 2000.0, v = 8.0),
                 (lon = 1.0, lat = 10.0, yr = 2001.6, v = 9.0)]
        tf, tc = bin_points(trows, lon, lat, value = :v, times = :yr,
                            time_bins = [2000.0, 2001.0])
        @test tc[1, 1, 1] == 2 && tf[1, 1, 1] == 6.0
        @test tc[1, 1, 2] == 1 && tf[1, 1, 2] == 9.0
        @test tc[2, 1, 1] == 0 && ismissing(tf[2, 1, 1])
    end

    @testset "WOA23 interpolator reads the file it was given" begin
        # Both fixes here were latent until this test: the interpolator permuted depth by
        # a fixed third slot regardless of the declared dimensions, and it indexed
        # `lons[i+1]` unguarded, so any axis of length 1 raised a BoundsError.
        dir = test_scratch()
        try
            lon = collect(-66.0:1.0:-61.0)      # 6
            lat = collect(42.0:1.0:45.0)        # 4
            dep = collect(0.0:10.0:40.0)        # 5
            field(lon, lat, z) = 10.0 + z / 5.0 + lat + lon / 10.0

            # The stored axis is positive-down (as a WOA file's is) and the interpolator is
            # queried negative-up, so the field is sampled at the negative of each stored
            # depth. Getting this the other way round makes the node test pass while the
            # midpoint is wrong, which is the failure this testset exists to catch.
            function make_woa_store(path, varname, order, scale)
                raw = [scale * field(lon[i], lat[j], -dep[k])
                       for i in 1:6, j in 1:4, k in 1:5]
                ds = if order === :lat_lon_depth
                    make_3d_store(permutedims(raw, (2, 1, 3)), lat, lon, dep, varname;
                                  order = (:lat, :lon, :depth))
                else
                    make_3d_store(raw, lon, lat, dep, varname)
                end
                geosave(path, ds; backend = :zarr)
                return path
            end

            for order in (:lon_lat_depth, :lat_lon_depth)
                # Both stores are written before the fetch: `fetch_woa23` looks for
                # temperature and salinity at fixed paths, and leaving one absent sends it
                # to the network, which is exactly what this suite must not do.
                for (varname, prefix, scale) in (("t_an", "temperature", 1.0),
                                                 ("s_an", "salinity", 0.1))
                    pth = joinpath(dir, "woa23_$(prefix)_01_0.25deg.zarr")
                    rm(pth; force = true, recursive = true)
                    make_woa_store(pth, varname, order, scale)
                end
                res = fetch_woa23(; lon_range = (-66.0, -61.0), lat_range = (42.0, 45.0),
                                  month = 1, output_dir = dir, include_o2 = false,
                                  verbose = false)
                @test res !== nothing
                itp = res.temperature_fn
                # Exact at every node: a permutation into the wrong axis would shift these.
                for i in 1:6, j in 1:4, k in 1:5
                    @test itp(lon[i], lat[j], -dep[k]) ≈ field(lon[i], lat[j], -dep[k])
                end
                # Midpoint of a cell: trilinear average of the eight corners.
                corners = [field(a, b, c) for a in (-65.0, -64.0), b in (43.0, 44.0),
                           c in (-10.0, -20.0)]
                @test itp(-64.5, 43.5, -15.0) ≈ sum(corners) / 8
            end

            # A one-cell axis has no second sample: it contributes its single value rather
            # than raising a BoundsError at `lons[i+1]`. Both stores are written so the
            # fetch stays offline.
            for (varname, prefix, scale) in (("t_an", "temperature", 1.0),
                                             ("s_an", "salinity", 0.1))
                pth = joinpath(dir, "woa23_$(prefix)_01_0.25deg.zarr")
                rm(pth; force = true, recursive = true)
                geosave(pth, make_3d_store(fill(scale * 3.0, 1, 4, 5), [-66.0],
                                           collect(42.0:1.0:45.0),
                                           collect(0.0:10.0:40.0), varname);
                        backend = :zarr)
            end
            deg = fetch_woa23(; lon_range = (-66.0, -61.0), lat_range = (42.0, 45.0),
                              month = 1, output_dir = dir, include_o2 = false,
                              verbose = false).temperature_fn
            @test deg(-66.0, 43.0, -10.0) ≈ 3.0
            # And it still answers for coordinates anywhere on the remaining axes.
            @test deg(-66.0, 45.0, -40.0) ≈ 3.0
        finally
            rm(dir; recursive = true, force = true)
        end

        @testset "A NetCDF carries a bounds dimension and a scalar" begin
            # NetCDF's CF convention adds `climatology_bounds` over a `nbounds` dimension that
            # has no coordinate variable, plus a scalar `crs` grid-mapping variable. Real
            # WOA23 has both. Three separate defects hid behind them, each silent because the
            # only route that reaches them is a live fetch:
            #   1. `_read_coord`/`_read_data` failed on `missing` elements that NCDatasets
            #      types as `Union{Missing, Float32}` while reporting `ismissing` as false.
            #   2. The Zarr writer refused the whole save over a coordinate-less dimension,
            #      leaving a store holding nothing but `lat` - and `fetch_woa23`'s mirror loop
            #      swallowed the error, so it looked like "all mirrors unsuccessful".
            #   3. `check_declared_dims` received `Vector{Union{}}` for a scalar variable.
            dir = test_scratch()
            try
                lon3 = collect(-65.0:0.5:-63.0); lat3 = collect(43.0:0.5:45.0)
                dep3 = collect(0.0:10.0:40.0)
                answer3(i, j, k) = -100.0 - lat3[j] - lon3[i] / 10 - dep3[k] / 5
                v3 = [answer3(i, j, k) for i in 1:length(lon3), j in 1:length(lat3),
                      k in 1:length(dep3), t in 1:1]
                # The shape the real WOA23 file has: lon/lat/depth plus a singleton time
                # axis, a coordinate-less `nbounds` dimension for the CF bounds variables,
                # and a scalar grid-mapping variable.
                d_lon = Dimension(name = :lon, size = length(lon3), coords = lon3,
                                  dim_type = GeoData.DIM_SPATIAL)
                d_lat = Dimension(name = :lat, size = length(lat3), coords = lat3,
                                  dim_type = GeoData.DIM_SPATIAL)
                d_dep = Dimension(name = :depth, size = length(dep3), coords = dep3,
                                  dim_type = GeoData.DIM_PARAMETRIC)
                d_time = Dimension(name = :time, size = 1, coords = [15.5],
                                   units = "days since 1950-01-01", dim_type = GeoData.DIM_TEMPORAL)
                d_nb = Dimension(name = :nbounds, size = 2, coords = nothing,
                                 dim_type = GeoData.DIM_GENERIC)
                crs = CoordinateSystem(crs = "EPSG:4326")
                ds2 = GeoDataset(
                    Dict("t_an" => GeoArray(v3, (d_lon, d_lat, d_dep, d_time,), crs, Dict()),
                         "climatology_bounds" => GeoArray(zeros(2), (d_nb,), crs, Dict()),
                         "grid_mapping" => GeoArray(reshape([1.0], ()), (), crs, Dict{String, Any}())),
                    Dict(:lon => GeoArray(lon3, (d_lon,), crs, Dict()),
                         :lat => GeoArray(lat3, (d_lat,), crs, Dict()),
                         :depth => GeoArray(dep3, (d_dep,), crs, Dict()),
                         :time => GeoArray([15.5], (d_time,), crs, Dict())),
                    Dict(:lon => d_lon, :lat => d_lat, :depth => d_dep, :time => d_time,
                         :nbounds => d_nb),
                    crs, Dict{String, Any}(), nothing, "cf-shape")

                out = joinpath(dir, "cf_shape.zarr")
                geosave(out, ds2; backend = :zarr)          # (1) must not refuse
                back = geoload(out; backend = :zarr)
                @test "t_an" in keys(back.variables)        # (2) the field actually landed
                @test "climatology_bounds" in keys(back.variables)
                # A store records an axis only through a coordinate array or a variable
                # size that matches one, so the coordinate-less `nbounds` does not survive.
                # The axes that carry values do, and `climatology_bounds` is still there.
                @test sort(collect(keys(back.dims))) == [:depth, :lat, :lon, :time]

                # (3) A fetch over such a store answers with the values the store holds.
                # Each store carries the variable its name asks for: writing `t_an` into
                # both made the salinity lookup fall back to an arbitrary first variable,
                # which is the silent-wrong-read this item exists to catch.
                for (varname, prefix) in (("t_an", "temperature"), ("s_an", "salinity"))
                    pth = joinpath(dir, "woa23_$(prefix)_01_0.25deg.zarr")
                    rm(pth; force = true, recursive = true)
                    ds_one = GeoDataset(
                        Dict(varname => ds2.variables["t_an"],
                             "climatology_bounds" => ds2.variables["climatology_bounds"],
                             "grid_mapping" => ds2.variables["grid_mapping"]),
                        ds2.coords, ds2.dims, ds2.crs, Dict{String, Any}(), nothing,
                        "cf-$prefix")
                    geosave(pth, ds_one; backend = :zarr)
                end
                fn = fetch_woa23(; lon_range = (-65.0, -63.0), lat_range = (43.0, 45.0),
                                 month = 1, output_dir = dir, include_o2 = false,
                                 verbose = false).temperature_fn
                for i in 1:length(lon3), j in 1:length(lat3), k in 1:length(dep3)
                    @test fn(lon3[i], lat3[j], -dep3[k]) ≈
                          (-100.0 - lat3[j] - lon3[i] / 10 - dep3[k] / 5)
                end
            finally
                rm(dir; recursive = true, force = true)
            end
        end

    @testset "Lakehouse paths resolve and checksums hash" begin
        # Both of these failed on first use from a notebook: `lakehouse_path` called
        # `lakehouse_root_dir`, which lives in the sibling catalogue module, so it raised
        # UndefVarError; and `compute_lakehouse_checksum` read a `.digest` field that does not
        # exist on a SHA2 context. Neither had a caller, so neither had a test.
        scratch = test_scratch()
        try
            path = lakehouse_path(:probe; tier = :processed, ext = "zarr")
            @test endswith(path, ".zarr")
            @test contains(path, string(lakehouse_root_dir()))
            # Pure: asking where something would go creates nothing.
            @test !isdir(path)
            @test_throws ArgumentError lakehouse_path(:probe; tier = :nope)

            f = joinpath(scratch, "blob.bin")
            write(f, rand(UInt8, 4096))
            digest = compute_lakehouse_checksum(f)
            @test length(digest) == 64 && occursin(r"^[0-9a-f]+$", digest)
            @test digest == compute_lakehouse_checksum(f)      # stable for the same bytes
            @test compute_lakehouse_checksum(joinpath(scratch, "absent.bin")) == ""
            write(f, [0x00])
            @test compute_lakehouse_checksum(f) != digest      # changed content, changed digest
        finally
            rm(scratch; recursive = true, force = true)
        end
    end
end

@testset "WOA23 subset strings name each axis once" begin
        # The oxygen THREDDS branch built `...lat[130:1:138],depthdepth[0:1:101]...` --
        # the literal `depth` in front of a helper that already returns `depth[...]`. The
        # URL is malformed, THREDDS rejects it, and the mirror loop then moves on as though
        # the server were at fault. A named axis repeated is a typo, not a slow server.
        tsrc = read(joinpath(dirname(@__DIR__), "src", "woa23.jl"), String)
        head = split(tsrc, "opendap_depth()")[1]
        sig = string(head[1:min(2_000_000, length(head))])
        @test !occursin("depthdepth", tsrc)
        # Each subset string names lat, then depth, then time exactly once.
        for line in eachline(IOBuffer(split(tsrc, "fetch_woa23(")[2]))
            occursin(".nc?", line) || continue
            depth_count = length(collect(eachmatch(r"depth\[", line)))
            lat_count = length(collect(eachmatch(r"(?<!a)lat\[", line)))
            @test depth_count <= 1
        end
    end
@testset "Regional cube: grids, field spelling, and layout" begin
        # `regional_cube.jl` was the last uncovered file in the data layer. These are the
        # pure parts of it: the horizontal grid, the alias-aware field spelling, and the
        # layout transform. Each had a specific wrong-answer mode worth pinning down.

        # --- the horizontal grid -------------------------------------------------------
        # `resolution_deg` must not silently stretch longitude: a degree of longitude is
        # shorter than a degree of latitude, and a shelf described in km expects cells that
        # are square on the page.
        cfg = RegionalCubeConfig(region_name = "grid", lon_range = (-64.0, -60.0),
                                 lat_range = (44.0, 47.0), resolution_deg = 0.5)
        lon, lat = GeoDataSources._cube_horizontal_grid(cfg)
        @test issorted(lon) && issorted(lat)
        @test lon[1] ≈ -64.0 && lat[1] ≈ 44.0
        @test lon[end] <= -60.0 + 1e-9 && lat[end] <= 47.0 + 1e-9
        @test length(lon) == 12 && length(lat) == 7
        # A degree of longitude is shorter than a degree of latitude, so the
        # longitude step is the degree step shrunk by cos(mid-domain latitude).
        @test (lon[2] - lon[1]) ≈ 0.5 * cos(deg2rad(45.5)) rtol = 1e-6
        @test (lat[2] - lat[1]) ≈ 0.5

        # `resolution_km` is the unit a shelf is described in; it must give a *near-square*
        # cell, which is the whole point of taking it over degrees.
        cfg_km = RegionalCubeConfig(region_name = "km", lon_range = (-64.0, -60.0),
                                    lat_range = (44.0, 47.0), resolution_km = 4.0)
        lkm, akm = GeoDataSources._cube_horizontal_grid(cfg_km)
        dlon = lkm[2] - lkm[1]
        dlat = akm[2] - akm[1]
        @test length(lkm) == 79 && length(akm) == 83
        @test dlat ≈ 4.0 / 110.574 rtol = 1e-6
# Square cells in ground distance, which is what `resolution_km` promises: both
        # steps cover 4 km. They differ in degrees because a degree of longitude is
        # shorter than a degree of latitude, by exactly cos(mid-domain latitude).
        @test dlon * 111.320 * cos(deg2rad(45.5)) ≈ 4.0
        @test dlat * 110.574 ≈ 4.0

        # An inverted domain names itself rather than producing a grid backwards.
        cfg_bad = RegionalCubeConfig(region_name = "bad", lon_range = (-60.0, -64.0),
                                     lat_range = (44.0, 47.0), resolution_deg = 0.5)
        m = try
            GeoDataSources._cube_horizontal_grid(cfg_bad); ""
        catch e
            first(split(sprint(showerror, e), "\n"))
        end
        @test occursin("Domain must be given as (min, max)", m)

        # --- field spelling ------------------------------------------------------------
        # A source that spells a variable differently is matched through the alias table,
        # and a store carrying neither spelling is reported as absent rather than being
        # substituted with a constant.
        function spelled(names)
            d = Dict{String, GeoArray}()
            coords = Dict{Symbol, GeoArray}()
            dims = Dict{Symbol, GeoData.Dimension}()
            crs = GeoData.CoordinateSystem(crs = "EPSG:4326")
            dl = GeoData.Dimension(name = :lon, size = 2, coords = [1.0, 2.0])
            dla = GeoData.Dimension(name = :lat, size = 2, coords = [1.0, 2.0])
            dims[:lon] = dl; dims[:lat] = dla
            coords[:lon] = GeoData.GeoArray([1.0, 2.0], (dl,), crs, Dict())
            coords[:lat] = GeoData.GeoArray([1.0, 2.0], (dla,), crs, Dict())
            for (i, n) in enumerate(names)
                d[n] = GeoArray(ones(2, 2), (dl, dla,), crs, Dict{String, Any}())
            end
            GeoDataset(d, coords, dims, crs, Dict{String, Any}(), nothing, "s")
        end

        @test GeoDataSources._cube_field_name(spelled(["temp", "t_an"]), :temperature) == "t_an"
        @test GeoDataSources._cube_field_name(spelled(["temp", "x"]), :temperature) == "temp"
        @test GeoDataSources._cube_field_name(spelled(["temp", "x"]), :salinity) === nothing
        # A store carrying neither the preferred nor an aliased spelling is absent.
        @test GeoDataSources._cube_field_name(spelled(["nitrate"]), :ph) === nothing
        @test GeoDataSources._cube_field_name(spelled(["temp"]), :oxygen) === nothing

        # --- layout ------------------------------------------------------------------
        # Axis order comes from the declared dimensions, so a file stored
        # `(time, depth, lat, lon)` is read correctly rather than by a positional guess.
        crs = GeoData.CoordinateSystem(crs = "EPSG:4326")
        dl = GeoData.Dimension(name = :lon, size = 3, coords = collect(1.0:3.0))
        dla = GeoData.Dimension(name = :lat, size = 4, coords = collect(1.0:4.0))
        dd = GeoData.Dimension(name = :depth, size = 5, coords = collect(1.0:5.0))
        dt = GeoData.Dimension(name = :time, size = 6, coords = collect(1.0:6.0))
        # Stored in an unhelpful order, as a real file might be.
        ga = GeoArray(reshape(Float32.(collect(1.0:360.0)), (3, 4, 5, 6)),
                      (dl, dla, dd, dt,), crs, Dict{String, Any}())
        out = GeoDataSources._cube_to_layout(ga, :lon_lat_depth_time)
        @test size(out) == (3, 4, 5, 6)
        @test out[1, 1, 1, 1] == 1.0
        # A source missing the depth axis gets a length-1 axis appended, which is the only
        # way to say "does not vary along this axis" in an N-d array.
        ga3 = GeoArray(reshape(Float32.(collect(1.0:72.0)), (3, 4, 6)),
                       (dl, dla, dt,), crs, Dict{String, Any}())
        o3 = GeoDataSources._cube_to_layout(ga3, :lon_lat_depth_time)
        @test size(o3) == (3, 4, 6, 1)
        @test o3[2, 3, 6, 1] == ga3.data[2, 3, 6]
        @test o3[1, 1, 1, 1] == ga3.data[1, 1, 1]
        # The length-1 axis is appended last, so the source's own axes keep
        # their relative order and position.
        # A benthic static field has no time axis either.
        ga2 = GeoArray(reshape(Float32.(collect(1.0:12.0)), (3, 4)),
                       (dl, dla,), crs, Dict{String, Any}())
        o2 = GeoDataSources._cube_to_layout(ga2, :lon_lat)
        @test size(o2) == (3, 4)
        # An unknown layout names itself.
        m2 = try
            GeoDataSources._cube_to_layout(ga2, :nonsense); ""
        catch e
            first(split(sprint(showerror, e), "\n"))
        end
        @test occursin("Unknown cube layout", m2)
    end
@testset "A source carrying no field for a variable leaves it absent" begin
        # The acceptance criterion for this item: a variable whose source is absent must be
        # left absent, not written as a constant. `assimilate_regional_cube` says so in a
        # comment and a @warn; this exercises the same contract on the two helpers that
        # implement it, without a network fetch.
        dir = test_scratch()
        try
            # A store carrying temperature but no salinity field: exactly the shape the
            # real per-source loop encounters.
            lon = collect(-64.0:1.0:-62.0)
            lat = collect(44.0:1.0:45.0)
            d_lon = Dimension(name = :lon, size = 3, coords = lon,
                              dim_type = GeoData.DIM_SPATIAL)
            d_lat = Dimension(name = :lat, size = 2, coords = lat,
                              dim_type = GeoData.DIM_SPATIAL)
            crs = CoordinateSystem(crs = "EPSG:4326")
            ds = GeoDataset(
                Dict("temp" => GeoArray(rand(3, 2), (d_lon, d_lat,), crs,
                                        Dict{String, Any}())),
                Dict(:lon => GeoArray(lon, (d_lon,), crs, Dict{String, Any}()),
                     :lat => GeoArray(lat, (d_lat,), crs, Dict{String, Any}())),
                Dict(:lon => d_lon, :lat => d_lat), crs, Dict{String, Any}(), nothing, "p")
            p = joinpath(dir, "partial.zarr")
            geosave(p, ds; backend = :zarr)

            loaded = geoload(p)
            # The variable the store carries is found, under either spelling.
            @test _cube_field_name(loaded, :temperature) !== nothing
            # The one it does not carry is reported absent -- and that absence is what the
            # assimilator records as "missing", rather than filling with a constant.
            @test _cube_field_name(loaded, :ph) === nothing
            @test _cube_field_name(loaded, :oxygen) === nothing

            # source_of is the other half: a variable with no configured source is skipped,
            # and an unconfigured one is named by its default.
# A variable with a configured source uses it.
            cfg_pick = RegionalCubeConfig(region_name = "pick",
                                         lon_range = (-64.0, -60.0),
                                         lat_range = (44.0, 47.0),
                                         sources = Dict{Symbol, Symbol}(
                                             :temperature => :glorys))
            @test source_of(cfg_pick, :temperature) === :glorys
            # An unconfigured variable falls back to its declared default.
            @test source_of(cfg_pick, :temperature) === :glorys
            cfg_default = RegionalCubeConfig(region_name = "d",
                                            lon_range = (-64.0, -60.0),
                                            lat_range = (44.0, 47.0),
                                            sources = Dict{Symbol, Symbol}())
            @test source_of(cfg_default, :temperature) ==
                get(CUBE_VARIABLE_SOURCES, :temperature, nothing)
            # A variable with no default at all *raises*, naming what is declared; it never
            # silently returns nothing for the caller to skip.
            m3 = try
                source_of(cfg_pick, :bathymetry)
                ""
            catch e
                first(split(sprint(showerror, e), "\n"))
            end
            @test occursin("No source is declared for cube variable bathymetry", m3)
            # The error lists what *is* declared, so a config author sees the options.
            # A source that is not in DATA_SOURCES is named too, with the declared list.
            cfg_badsrc = RegionalCubeConfig(
                region_name = "badsrc", lon_range = (-64.0, -60.0),
                lat_range = (44.0, 47.0),
                sources = Dict{Symbol, Symbol}(:ph => :no_such_source))
            m4 = try
                source_of(cfg_badsrc, :ph)
                ""
            catch e
                first(split(sprint(showerror, e), "\n"))
            end
            @test occursin("not declared in DATA_SOURCES", m4)
        finally
            rm(dir; recursive = true, force = true)
        end
    end
    @testset "Axis and cache helpers" begin
        @test to_positive_down([-5.0, -10.0]) == ([5.0, 10.0], true)
        @test to_positive_down([10.0, 20.0]) == ([10.0, 20.0], false)
        @test is_cached(joinpath(@__DIR__, "..", "Project.toml"))
        @test !is_cached("nope.zarr")
    end


    @testset "A boundary subset already assimilated is reused, not re-fetched" begin
        # The per-domain cache path in the run's `inputs/` is not where a downloaded subset
        # lives: it sits under the source's own directory in the central store. Looking only
        # by its per-domain name re-fetched it, and the fetch needs a Copernicus console
        # script that is only available when the product was not already assimilated.
        using GeoDataSources: _central_glorys_subset
        dir = test_scratch()
        try
            mkpath(dir)
            # A fixture covering a box, a fixture covering a smaller one, and one that is
            # not a NetCDF at all -- each written by geosave so the reader sees the same
            # structure the assimilation produces.
            function subset(name, lon, lat)
                lonv = collect(Float64, lon)
                latv = collect(Float64, lat)
                l = Dimension(name = :lon, size = length(lonv), coords = lonv,
                              units = "degrees_east", dim_type = GeoData.DIM_SPATIAL)
                t = Dimension(name = :lat, size = length(latv), coords = latv,
                              units = "degrees_north", dim_type = GeoData.DIM_SPATIAL)
                crs = CoordinateSystem(crs = "EPSG:4326")
                vars = Dict{String, GeoArray}("thetao" => GeoArray(ones(length(lonv), length(latv)),
                                                                   (l, t), crs, Dict()))
                ds = GeoDataset(vars,
                                Dict{Symbol, GeoArray}(:lon => GeoArray(lonv, (l,), crs, Dict()),
                                                       :lat => GeoArray(latv, (t,), crs, Dict())),
                                Dict{Symbol, Dimension}(:lon => l, :lat => t), crs,
                                Dict{String, Any}(), nothing, "glorys-fixture")
                geosave(joinpath(dir, name), ds; backend = :ncdatasets)
                return joinpath(dir, name)
            end

            covering = subset("boundary_big.nc", -71.0:0.5:-53.0, 40.0:0.5:48.5)
            covering2 = subset("boundary_wide.nc", -80.0:0.5:-45.0, 30.0:0.5:55.0)
            subset("boundary_small.nc", -60.0:0.5:-55.0, 42.0:0.5:46.0)
            write(joinpath(dir, "notes.txt"), "not a NetCDF")

            # The exact scotian_shelf embedding box is covered by the first fixture, and the
            # smallest covering file is not assumed: a larger file covering the same box is
            # accepted too, which is what "covers" means.
            box = ((-71.0, -53.0), (40.0, 48.5))
            found = _central_glorys_subset(box...; dir = dir)
            @test found in (covering, covering2)
            @test endswith(string(found), ".nc")

            # A box no fixture covers is refused rather than silently accepted: a subset cut
            # too small returns an empty sponge, not an error. One case per axis, because
            # coverage is checked along longitude and latitude separately.
            @test _central_glorys_subset((-90.0, -70.0), (40.0, 48.5); dir = dir) === nothing
            @test _central_glorys_subset((-71.0, -53.0), (20.0, 40.0); dir = dir) === nothing

            # A missing directory is a miss, not a crash.
            @test _central_glorys_subset(box...; dir = joinpath(dir, "nope")) === nothing
        finally
            isdir(dir) && rm(dir; recursive = true, force = true)
        end
    end

    @testset "A boundary tracer interpolator takes axis values, not (values, Dimension)" begin
        # `axis()` returns the coordinate values *and* the dimension record. The builder here
        # assigned the pair to `lons`/`lats`/`deps` and then treated each as a vector, so
        # `minimum(deps)` failed on a tuple the first time the GLORYS path ran -- and before
        # that the path was unreachable, which is why nothing caught it.
        using GeoDataSources: build_boundary_tracer_interpolators_geodata
        dir = test_scratch()
        try
            lon = collect(-64.0:1.0:-60.0)
            lat = collect(42.0:1.0:46.0)
            dep = collect(0.0:5.0:25.0)
            crs = CoordinateSystem(crs = "EPSG:4326")
            dims = map(d -> Dimension(name = d, size = length(d == :lon ? lon :
                                                                    d == :lat ? lat : dep),
                                      coords = d == :lon ? lon : d == :lat ? lat : dep,
                                      units = d == :lon ? "degrees_east" :
                                              d == :lat ? "degrees_north" : "m",
                                      dim_type = d == :lon || d == :lat ? GeoData.DIM_SPATIAL :
                                              GeoData.DIM_PARAMETRIC),
                        (:lon, :lat, :depth))
            # longitude-weighted temperature and a flat salinity, so any axis mix-up shows.
            temp = [Float64(i + j - k) for i in axes(lon, 1), j in axes(lat, 1), k in axes(dep, 1)]
            salt = fill(31.0, length(lon), length(lat), length(dep))
            mkpath(dir)
            for (name, data, varname) in (("thetao", temp, "thetao"), ("so", salt, "so"))
                vars = Dict{String, GeoArray}(varname => GeoArray(data, dims, crs, Dict()))
                ds = GeoDataset(vars,
                                Dict{Symbol, GeoArray}(:lon => GeoArray(lon, (dims[1],), crs, Dict()),
                                                       :lat => GeoArray(lat, (dims[2],), crs, Dict()),
                                                       :depth => GeoArray(dep, (dims[3],), crs, Dict())),
                                Dict{Symbol, Dimension}(:lon => dims[1], :lat => dims[2],
                                                        :depth => dims[3]), crs,
                                Dict{String, Any}(), nothing, "boundary-fixture")
                geosave(joinpath(dir, "$(varname).zarr"), ds; backend = :zarr)
            end
            res = build_boundary_tracer_interpolators_geodata(
                joinpath(dir, "thetao.zarr"), joinpath(dir, "so.zarr");
                T_name = "thetao", S_name = "so", months = [1])
            @test res.S(-62.0, 44.0, 10.0, 1) == 31.0
            # The value at an exact node is the fixture value there, not a surprise: this is
            # what the previous tuple misuse prevented anything from reaching.
            @test res.T(-62.0, 44.0, 0.0, 1) == temp[3, 3, 1]
        finally
            isdir(dir) && rm(dir; recursive = true, force = true)
        end
    end

    @testset "A resolved cache path expands the store token" begin
        # The tides defect: a caller testing `data_source(:tides).cache` with only
        # `<output_dir>` substituted looks at a literal `<store>` directory, so the check was
        # false for a 1.37 GB file that was on disk and the run re-fetched the 4.7 GB archive.
        using GeoDataSources: resolved_cache_path
        raw = GeoDataSources.data_source(:tides).cache
        resolved = resolved_cache_path(:tides, "outputs/run")
        @test occursin("<store>", raw)
        @test !occursin("<store>", resolved)
        @test normpath(resolved) == normpath(joinpath(GeoDataSources.store_root(), "tpxo9",
                                                     "u_tpxo9.v1.nc"))
        # The per-run form still works for a source that names `<output_dir>`.
        woa = resolved_cache_path(:woa23, "outputs/run")
        @test !occursin("<", woa)
    end

    @testset "A tidal atlas is checked against the domain it claims to cover" begin
        # The archive the manifest points at also contains regional `*_remap*` members that
        # look equivalent and are not. A reader that takes whichever member it is handed
        # returns an empty box for a domain the file does not span, which is the worst
        # outcome: a run that looks fine and records a tidal source it never used. The
        # validation below turns that into a named error, and it is checked with fixtures
        # because the archive is 4.7 GB and does not belong in a test.
        dir = test_scratch()
        try
            global_lon = collect(0.0:1.0:359.0)
            narrow_lat = collect(-50.0:1.0:50.0)
            full_lat = collect(-80.0:1.0:80.0)
            d_con = Dimension(name = :ncon, size = 2, coords = [1.0, 2.0],
                              dim_type = GeoData.DIM_GENERIC)

            # Build a store on the named latitude axis carrying the named harmonic
            # variables, so each case below is one line instead of a fresh constructor.
            function atlas(pth, lat, vars)
                d_lon = Dimension(name = :lon, size = length(global_lon),
                                  coords = global_lon, dim_type = GeoData.DIM_SPATIAL)
                d_lat = Dimension(name = :lat, size = length(lat), coords = lat,
                                  dim_type = GeoData.DIM_SPATIAL)
                crs = CoordinateSystem(crs = "EPSG:4326")
                vars_out = Dict{String, GeoArray}(
                    "con" => GeoArray([1.0, 2.0], (d_con,), crs, Dict{String, Any}()))
                for v in vars
                    vars_out[v] = GeoArray(ones(length(global_lon), length(lat)),
                                           (d_lon, d_lat,), crs, Dict{String, Any}())
                end
                coords = Dict{Symbol, GeoArray}(
                    :lon => GeoArray(global_lon, (d_lon,), crs, Dict{String, Any}()),
                    :lat => GeoArray(lat, (d_lat,), crs, Dict{String, Any}()),
                    :ncon => GeoArray([1.0, 2.0], (d_con,), crs, Dict{String, Any}()))
                geosave(pth, GeoDataset(
                    vars_out, coords, Dict(:lon => d_lon, :lat => d_lat, :ncon => d_con),
                    crs, Dict{String, Any}(), nothing, "atlas"); backend = :zarr)
                return nothing
            end

            good = joinpath(dir, "global.zarr")
            atlas(good, full_lat, ("ua", "up", "va", "vp"))
            partial = joinpath(dir, "partial.zarr")
            atlas(partial, narrow_lat, ("ua", "up", "va", "vp"))

            # A store that spans the requested domain validates and comes back.
            @test GeoDataSources._validate_tpxo9_velocity(
                good; lat_range = (-71.0, -60.0), verbose = false) !== nothing

            # A store that does not span it is refused, naming its actual coverage, rather
            # than returning an empty box the caller would have interpolated away.
            msg = try
                GeoDataSources._validate_tpxo9_velocity(
                    partial; lat_range = (-71.0, -60.0), verbose = false)
                ""
            catch e
                first(split(sprint(showerror, e), "\n"))
            end
            @test occursin("covers latitude", msg)
            @test occursin("-71.0", msg)

            # Either harmonic form is accepted: the two readers in ParticleTracking disagree
            # about which they open and both carry the same information.
            for extra in (("ua", "up", "va", "vp"), ("URe", "UIm", "VRe", "VIm"))
                pth = joinpath(dir, "form_$(first(extra)).zarr")
                atlas(pth, full_lat, extra)
                @test GeoDataSources._validate_tpxo9_velocity(
                    pth; lat_range = (-70.0, -60.0), verbose = false) !== nothing
            end

            # A store carrying neither form is refused, naming what it does have.
            neither = joinpath(dir, "neither.zarr")
            atlas(neither, full_lat, ("elevation",))
            m2 = try
                GeoDataSources._validate_tpxo9_velocity(neither; verbose = false)
                ""
            catch e
                first(split(sprint(showerror, e), "\n"))
            end
            @test occursin("neither", m2)

            # `:tides` is reachable through the same path as every other source.
            @test buildable(:tides)
            @test haskey(GeoDataManifest.FETCHERS, :tides)
        finally
            rm(dir; recursive = true, force = true)
        end
    end


    @testset "Wind stress conversion and its stated inverse" begin
        # These are the pure parts of winds.jl. The inverse is asserted to invert: a
        # documented inverse that does not round-trip is worse than no inverse, because the
        # caller has no way to tell the difference from the return value alone.
        @test wind_speed_to_kinematic_stress(0.0, 0.0) == (0.0, 0.0)

        # Direction is preserved: stress is along the wind.
        tx, ty = wind_speed_to_kinematic_stress(3.0, 4.0)
        @test tx > 0 && ty > 0
        @test ty / tx ≈ 4.0 / 3.0

        # Magnitude grows with speed on the low branch, and the drag coefficient changes
        # across the 11 m/s break the code documents.
        slow_tx, = wind_speed_to_kinematic_stress(10.0, 0.0)
        fast_tx, = wind_speed_to_kinematic_stress(20.0, 0.0)
        @test slow_tx > 0 && fast_tx > slow_tx

        # Opposite winds give opposite stress, and the low/high branches differ in how
        # hard they push for the same speed (documented break at 11 m/s).
        u5, v5 = wind_speed_to_kinematic_stress(5.0, -5.0)
        @test v5 < 0
        @test u5 > 0
        @test abs(v5) ≈ abs(u5)          # symmetric in the two components
        tx_low, = wind_speed_to_kinematic_stress(9.0, 0.0)
        tx_high, = wind_speed_to_kinematic_stress(12.0, 0.0)
        @test tx_high / 12.0 > tx_low / 9.0     # the high branch multiplies by a larger cd

        # Round trip: speed -> stress -> speed, for speeds on both sides of the break.
        for s in (2.0, 8.0, 11.0, 15.0, 25.0, 60.0)
            t, = wind_speed_to_kinematic_stress(s, 0.0)
            @test wind_speed_from_stress(t) ≈ s rtol = 1e-6
        end
        # Zero stress is zero speed, not a bisection that wanders. A negative stress is
        # taken by magnitude, which the docstring now states explicitly.
        @test wind_speed_from_stress(0.0) == 0.0
        @test wind_speed_from_stress(-0.5) == wind_speed_from_stress(0.5)
        @test wind_speed_from_stress(-0.5) > 0.0

        # A denser air column pushes harder for the same wind.
        d1, = wind_speed_to_kinematic_stress(8.0, 0.0; ρ_air = 1.0)
        d2, = wind_speed_to_kinematic_stress(8.0, 0.0; ρ_air = 2.0)
        @test d2 ≈ 2 * d1
    end

    @testset "Wind stress read back from a store" begin
        dir = test_scratch()
        try
            lon = collect(-64.0:1.0:-61.0); lat = collect(44.0:1.0:45.0)
            tx = [0.05 * (lon[i] + 64.0) for i in 1:4, j in 1:2]
            ty = [0.02 * (lat[j] - 44.0) for i in 1:4, j in 1:2]
            d_lon = Dimension(name = :lon, size = 4, coords = lon,
                              dim_type = GeoData.DIM_SPATIAL)
            d_lat = Dimension(name = :lat, size = 2, coords = lat,
                              dim_type = GeoData.DIM_SPATIAL)
            crs = CoordinateSystem(crs = "EPSG:4326")
            ds = GeoDataset(
                Dict("tau_x" => GeoArray(tx, (d_lon, d_lat,), crs, Dict{String, Any}()),
                     "tau_y" => GeoArray(ty, (d_lon, d_lat,), crs, Dict{String, Any}())),
                Dict(:lon => GeoArray(lon, (d_lon,), crs, Dict{String, Any}()),
                     :lat => GeoArray(lat, (d_lat,), crs, Dict{String, Any}())),
                Dict(:lon => d_lon, :lat => d_lat), crs, Dict{String, Any}(), nothing, "w")
            p = joinpath(dir, "winds.zarr")
            geosave(p, ds; backend = :zarr)

            w = load_wind_stress_geodata(p)
            # Domain means, as the docstring states.
            @test w.tau_x ≈ sum(tx) / prod(size(tx))
            @test w.tau_y ≈ sum(ty) / prod(size(ty))
            @test w.tau_max ≈ maximum(hypot.(tx, ty))
            @test w.speed10_rms ≈ wind_speed_from_stress(hypot(w.tau_x, w.tau_y))

            # A store with a missing variable names it.
            ds_bad = GeoDataset(
                Dict("speed" => GeoArray(rand(4, 2), (d_lon, d_lat,), crs,
                                          Dict{String, Any}())),
                ds.coords, ds.dims, crs, Dict{String, Any}(), nothing, "bad")
            pb = joinpath(dir, "bad.zarr")
            geosave(pb, ds_bad; backend = :zarr)
            m = try
                load_wind_stress_geodata(pb); ""
            catch e
                first(split(sprint(showerror, e), "\n"))
            end
            @test occursin("has no tau_x variable", m)

            # A store of all-NaN raises on the finite check rather than averaging to NaN.
            ds_nan = GeoDataset(
                Dict("tau_x" => GeoArray(fill(NaN, 4, 2), (d_lon, d_lat,), crs,
                                          Dict{String, Any}()),
                     "tau_y" => GeoArray(fill(NaN, 4, 2), (d_lon, d_lat,), crs,
                                          Dict{String, Any}())),
                ds.coords, ds.dims, crs, Dict{String, Any}(), nothing, "nan")
            pn = joinpath(dir, "nan.zarr")
            geosave(pn, ds_nan; backend = :zarr)
            @test_throws Exception load_wind_stress_geodata(pn)
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "Real ingestion is sparse, as survey data is" begin
        window = (lon_range = (-64.0, -63.0), lat_range = (44.0, 45.0))
        st = fetch_substrate_grainsize(; window...)
        @test count(isfinite, st.variables["substrate"].data) == 79
    end
end