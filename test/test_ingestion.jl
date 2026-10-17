using Test
using Dates
using UUIDs
using DataFrames
using GeoData
using GeoDataSources
using JSON3
using GeoDataSources: raw_points, _qc_bottom_temperature, bin_points,
    raw_data_digests, discretize, DISCRETIZATION, discretized_path,
    load_bottom_temperature_points, load_substrate_points,
    fetch_substrate_grainsize, fetch_bottom_temperature,
    ingest_bottom_temperature, _read_point_table

include("helpers.jl")

@testset "Discretization, Ingestion & Observations" begin
    # Tier 1 raw digests
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

    # Ingestion retains all rows and columns
    dir = test_scratch()
    try
        W = (lon_range = (-64.0, -63.0), lat_range = (44.0, 45.0))
        src = load_bottom_temperature_points()

        p = ingest_bottom_temperature(; W..., tag = "keep_all")
        t = _read_point_table(p)
        for c in names(src)
            c in ("geometry",) && continue
            @test Symbol(c) in t.columns
        end
        @test :lon in t.columns && :lat in t.columns

        in_bounds = 0
        for row in eachrow(src)
            if (W.lon_range[1] <= row.lon <= W.lon_range[2]) &&
               (W.lat_range[1] <= row.lat <= W.lat_range[2])
                in_bounds += 1
            end
        end
        @test length(t.rows) == in_bounds
        @test in_bounds > 0 && in_bounds < nrow(src)

        # Discretization policy & QC
        for (k_pol, policy) in DISCRETIZATION
            @test policy.resolution > 0
            @test !isempty(policy.rationale)
        end
        @test DISCRETIZATION[:bottom_temperature].resolution == 1.0

        sub, report = _qc_bottom_temperature(src)
        @test report.n_read == nrow(src)
        @test report.n_kept == nrow(sub) == nrow(src) - sum(values(report.dropped))
        @test all(t_val -> -5.0 <= t_val <= 40.0, coalesce.(sub.t, NaN))

        prov = discretize(:bottom_temperature; lon_range = (-64.0, -63.0),
                          lat_range = (44.0, 45.0), tag = "ci")
        @test prov.dataset === :bottom_temperature
        @test prov.variable == "t"
        @test prov.n_read == nrow(src) && prov.n_kept <= prov.n_read

        field = discretized_path(:bottom_temperature, "ci")
        side = replace(field, ".parquet" => ".provenance.json")
        @test isfile(field) && isfile(side)
    finally
        GC.gc(); sleep(0.1)
        rm(dir; recursive = true, force = true)
    end

    # Point binning
    lon = [1.0, 2.0, 3.0]
    lat = [10.0, 11.0]
    rows = [(lon = 1.0, lat = 10.0, v = 5.0), (lon = 1.0, lat = 10.0, v = 7.0),
            (lon = 1.0, lat = 11.0, v = 9.0)]
    field_bin, counts_bin = bin_points(rows, lon, lat, value = :v)
    @test field_bin[1, 1] == 6.0
    @test counts_bin[1, 1] == 2
    @test field_bin[1, 2] == 9.0
    @test ismissing(field_bin[2, 1]) && counts_bin[2, 1] == 0

    outside = [(lon = 1.0, lat = 10.0, v = 5.0), (lon = 99.0, lat = 99.0, v = 100.0)]
    f2, c2 = bin_points(outside, lon, lat, value = :v)
    @test c2[2, 1] == 0 && ismissing(f2[2, 1])

    # Grid products fetch
    window = (lon_range = (-64.0, -63.0), lat_range = (44.0, 45.0),
              resolution_deg = 1 / 12)
    subst_ds = fetch_substrate_grainsize(; window...)
    assert_dataset_invariants(subst_ds)
    @test subst_ds.dims[:lon].size == 13 && subst_ds.dims[:lat].size == 13
    @test size(subst_ds.variables["substrate"].data) == (13, 13)

    bt_ds = fetch_bottom_temperature(; window...)
    assert_dataset_invariants(bt_ds)
    @test bt_ds.dims[:lon].size == 13 && bt_ds.dims[:lat].size == 13
    @test haskey(bt_ds.variables, "survey_depth")
end
