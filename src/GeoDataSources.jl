"""
    GeoDataSources.jl

Dataset acquisition, provenance, and cataloguing for `GeoData.jl`.

This package holds everything that touches the network, the filesystem, or the catalog;
`GeoData` itself holds the containers, backends, and coordinate operations. The split is
deliberate: a consumer that needs `GeoDataset` and `Zarr` can depend on `GeoData` alone
and never load a downloader, and the fetching layer can never quietly become part of the
data model's API.

# Layout

| Module | Responsibility |
|:---|:---|
| `Fetch/Download` | the single downloader: scratch files, atomic replace, retries |
| `Access/Axis` | the single place that finds a coordinate axis or a variable by name |
| `coastline`, `bathymetry`, `winds`, `woa23`, `boundary` | one file per data source |
| `Fetch/Copernicus` | CMEMS / CDS access |
| `GeoDataManifest` | declared sources, verified URLs, provenance records |
| `CatalogModule` | `GeoDataCatalog`: registration, lineage, query |
| `LakehouseModule` | medallion tier paths and checksums |
| `regional_cube` | regional data-cube assimilation |

# Substitution policy

A dataset that is unavailable is an error, not a silently invented value. Nothing in this
package fabricates a field, and every fallback path has to be opted into by the caller
(see `GeoDataManifest.fetch_input(strict=true)`). This rule is why the cache check tests a
directory with `ispath`, not `isfile`, and why a missing variable is reported instead of
being filled with a default.
"""

module GeoDataSources

using Reexport

@reexport using GeoData
using GeoData: GeoDataset, GeoArray, Dimension, CoordinateSystem, GeoBackend,
    BackendCapabilities, GeoStorage, strip_scheme, standardize_dimension_name,
    find_coord_indices, slice_indices, is_regular_grid, grid_spacing, dimension_name
using GeoData.GeoDataTypes: DIM_SPATIAL, DIM_TEMPORAL, DIM_PARAMETRIC, DIM_GENERIC
using Base64, CodecZlib, DataFrames, Dates, Downloads, GeoInterface, GeoParquet, HTTP,
    Interpolations, JSON3, LinearAlgebra, NCDatasets, Random, SHA, Statistics, TOML,
    TranscodingStreams, UUIDs

# Local helpers: one downloader, one coordinate accessor. Everything else below uses them.
include("Access/Axis.jl")
include("Fetch/Download.jl")
# Assimilated-data storage: the central, user-configurable registry. Included before the
# sources because they (bathymetry, the manifest) resolve their cache through store_root().
include("storage.jl")

# Data sources
include("coastline.jl")
include("bathymetry.jl")
include("biodata.jl")

# The coastline rings that ship with the package. Bundled data, not acquisition, and here rather
# than in GeoData because GeoData is the generic data layer and must not carry this project's
# study region. Applied as a default by the application layers, never by the data layer.
include("bundled_coastline.jl")
include("winds.jl")
include("woa23.jl")
include("boundary.jl")
include("regrid_utils.jl")
include("Fetch/tides.jl")
    include("Fetch/copernicus.jl")
using .Copernicus

# Provenance: the declared registry of verified physical inputs.
include("manifest.jl")
using .GeoDataManifest

# Regional data cube
include("regional_cube.jl")

# Catalog and lakehouse tiers
include("catalog.jl")
using .CatalogModule
include("lakehouse.jl")
using .LakehouseModule

export
    # coordinate access (shared)
    axis,
    require_coord,
    to_positive_down,
    # downloading (shared)
    download_to_path,
    cache_path,
    parse_time_units,
    # assimilated-data storage (central, user-configurable registry)
    storage_config,
    store_root,
    store_path,
    storage_file_path,
    # coastline
    # the bundled regional coastline rings. Exported so a caller that wants a regional
    # default passes it explicitly, rather than the generic layer defaulting to it.
    SCOTIAN_SHELF_COASTLINE,
    load_coastline_geodata,
    # bathymetry
    load_bathymetry_geodata,
    save_bathymetry_geodata,
    regrid_bathymetry_from_etopo,
    etopo_bathymetry_field,
    bathymetry,
    bathymetry_dataset,
    bathymetry_field,
    bathymetry_arrays,
    bathymetry_artefact,
    preferred_bathymetry_source,
    BATHYMETRY_SOURCES,
    BATHYMETRY_SOURCE_ALIASES,
    BATHYMETRY_COVERAGE,
    # winds
    load_wind_stress_geodata,
    build_bulk_surface_flux_geodata,
    wind_speed_to_kinematic_stress,
    wind_speed_from_stress,
    # tier-1 raw benthic data held inside this package
    BIODATA_RAW,
    INGESTED_DATA_DIR,
    ingested_path,
    ingest_bottom_temperature,
    discretize,
    DISCRETIZATION,
    ingest_substrate,
    ingest_nwa_bathymetry,
    RAW_DATA_DIR,
    raw_path,
    raw_data_digests,
    load_bottom_temperature_points,
    load_substrate_points,
    benthic_dataset,
    # WOA23
    load_woa23_interpolators,
    # boundary hydrography
    fetch_boundary_hydrography_geodata,
    build_boundary_tracer_interpolators_geodata,
    # regridding
    slice_bathymetry_geodata,
    slice_wind_geodata,
    extract_grid_coordinates_geodata,
    # bathymetry processing
    sample_marine_cells,
    # geospatial utilities
    # Copernicus
    copernicusmarine_executable,
    project_python,
    copernicus_credentials,
    copernicus_login_reminder,
    # manifest / provenance
    DATA_SOURCES,
    DataSource,
    data_source,
    describe_data_sources,
    fetch_input,
    input_dir,
    file_digest,
    data_provenance,
    available_data,
    data_summary,
    buildable,
    buildable_sources,
    # regional cube
    RegionalCubeConfig,
    load_cube_config,
    standard_ocean_depths,
    assimilate_regional_cube,
    build_cube_hsi_evaluator,
    evaluate_bioenergetic_scope,
    # catalog
    GeoDataCatalog,
    DatasetEntry,
    CatalogStats,
    default_catalog_path,
    load_catalog!,
    save_catalog,
    register_dataset!,
    unregister_dataset!,
    update_dataset!,
    geopublish!,
    geofetch,
    get_dataset,
    get_dataset_by_key,
    get_datasets_by_name,
    find_datasets,
    get_best_dataset,
    access_dataset!,
    record_download!,
    get_stats,
    export_catalog_to_csv,
    get_global_catalog,
    init_global_catalog!,
    # lakehouse
    lakehouse_root_dir,
    lakehouse_path,
    lakehouse_tiers,
    compute_lakehouse_checksum,
    geopublish_dataset!,
    geofetch_dataset

function __init__()
    # Register GeoDataSources as acquisition driver plugins for GeoData.geoget
    GeoData.register_source_provider!(:erddap, (uri; cache_dir=nothing, bounds=nothing, kwargs...) -> begin
        lon_range = bounds !== nothing ? bounds[1] : (-71.0, -53.0)
        lat_range = bounds !== nothing ? bounds[2] : (40.0, 48.5)
        out_path = cache_dir !== nothing ? joinpath(cache_dir, "bathymetry.zarr") : joinpath("inputs", "bathymetry.zarr")
        fetch_erddap_bathymetry(; lon_range=lon_range, lat_range=lat_range, output_path=out_path, kwargs...)
    end)

    GeoData.register_source_provider!(:copernicus, (uri; cache_dir=nothing, bounds=nothing, kwargs...) -> begin
        fetch_copernicus_physics_subset(; kwargs...)
    end)

    GeoData.register_source_provider!(:open_meteo, (uri; cache_dir=nothing, bounds=nothing, kwargs...) -> begin
        lon_range = bounds !== nothing ? bounds[1] : (-71.0, -53.0)
        lat_range = bounds !== nothing ? bounds[2] : (40.0, 48.5)
        out_path = cache_dir !== nothing ? joinpath(cache_dir, "surface_winds.zarr") : joinpath("inputs", "surface_winds.zarr")
        fetch_open_meteo_winds(; lon_range=lon_range, lat_range=lat_range, output_path=out_path, kwargs...)
    end)

    GeoData.register_source_provider!(:woa23, (uri; cache_dir=nothing, bounds=nothing, kwargs...) -> begin
        lon_range = bounds !== nothing ? bounds[1] : (-71.0, -53.0)
        lat_range = bounds !== nothing ? bounds[2] : (40.0, 48.5)
        out_dir = cache_dir !== nothing ? cache_dir : store_path("woa23")
        fetch_woa23(; lon_range=lon_range, lat_range=lat_range, output_dir=out_dir, kwargs...)
    end)

    GeoData.register_source_provider!(:tides, (uri; cache_dir=nothing, bounds=nothing, kwargs...) -> begin
        out_dir = cache_dir !== nothing ? cache_dir : "inputs"
        fetch_input(:tides, out_dir; kwargs...)
    end)

    GeoData.register_source_provider!(:natural_earth, (uri; cache_dir=nothing, bounds=nothing, kwargs...) -> begin
        lon_range = bounds !== nothing ? bounds[1] : (-71.0, -53.0)
        lat_range = bounds !== nothing ? bounds[2] : (40.0, 48.5)
        out_path = cache_dir !== nothing ? joinpath(cache_dir, "coastline.dat") : joinpath("inputs", "coastline.dat")
        fetch_natural_earth_coastline(; lon_range=lon_range, lat_range=lat_range, output_path=out_path, kwargs...)
    end)
end

end # module GeoDataSources
