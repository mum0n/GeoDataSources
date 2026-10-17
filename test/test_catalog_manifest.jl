using Test
using Dates
using UUIDs
using GeoData
using GeoDataSources
using GeoDataSources.GeoDataManifest

include("helpers.jl")

@testset "Catalog, Manifest & Medallion Invariants" begin
    # Catalog persistence and query
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

    # Manifest fetch dispatch
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
    declared = Set(keys(GeoDataManifest.DATA_SOURCES))
    @test all(k -> k in declared, keys(GeoDataManifest.FETCHERS))

    # Unbuildable sources fail clearly
    @test all(k -> !(k in keys(GeoDataManifest.FETCHERS)),
              [k for k in keys(GeoDataManifest.DATA_SOURCES) if !buildable(k)])
    @test buildable(:glorys)
    @test haskey(GeoDataManifest.FETCHERS, :glorys)

    # Medallion tier placement
    root = GeoDataSources.store_root()
    short(p) = replace(p, root => "<store>")
    for (key, dname) in ((:bathymetry, "discretized"),
                         (:coastline, "discretized"),
                         (:substrate, "discretized"),
                         (:nwa_bathymetry, "discretized"),
                         (:glorys, "modelled"),
                         (:atmosphere, "modelled"),
                         (:surface_winds, "modelled"),
                         (:lateral_boundary, "modelled"),
                         (:tides, "modelled"),
                         (:bottom_temperature, "raw"))
        p = short(GeoDataSources.resolved_cache_path(key, "."))
        @test occursin("/$(dname)/", p)
    end

    # Tier label preserves fetcher dispatch
    m = GeoDataSources.GeoDataManifest
    for key in keys(m.FETCHERS)
        @test haskey(m.FETCHERS, key)
    end
    @test m.data_source(:tides).tier === :modelled
end
