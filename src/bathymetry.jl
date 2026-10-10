"""
    bathymetry.jl

Bathymetry fetch, load, save, and query operations via GeoData.

Supports ERDDAP (NOAA), ETOPO2022, and generic NetCDF/Zarr formats.
"""

using GeoData
using NCDatasets
using Random
using Statistics

# Optional NumericalEarth for ETOPO bathymetry
const _has_numerical_earth = try
    import NumericalEarth
    true
catch
    false
end

"""
    fetch_erddap_bathymetry(;
        dataset_id::AbstractString = "ETOPO_2022_v1_15s",
        lon_range::Tuple{Real, Real} = (-71.0, -53.0),
        lat_range::Tuple{Real, Real} = (40.0, 48.5),
        stride::Int = 1,
        output_path::AbstractString = joinpath("inputs", "bathymetry.zarr"),
        backend::Symbol = :zarr,
        verbose::Bool = true
    ) -> GeoDataset

Fetch bathymetry from NOAA ERDDAP and save as a GeoDataset.

# Arguments
- `dataset_id`: ERDDAP dataset ID (e.g., "ETOPO_2022_v1_15s", "etopo180", "srtm30plus")
- `lon_range`: Longitude bounds (min, max) in degrees east
- `lat_range`: Latitude bounds (min, max) in degrees north
- `stride`: Subsampling stride (1 = full resolution)
- `output_path`: Destination path (Zarr directory or NetCDF file)
- `backend`: Storage backend (:zarr, :ncdatasets)
- `verbose`: Print progress messages

# Returns
GeoDataset with elevation, lon, lat coordinates.
"""
function fetch_erddap_bathymetry(;
    dataset_id::AbstractString = "ETOPO_2022_v1_15s",
    lon_range::Tuple{Real, Real} = (-71.0, -53.0),
    lat_range::Tuple{Real, Real} = (40.0, 48.5),
    stride::Int = 1,
    output_path::AbstractString = joinpath("inputs", "bathymetry.zarr"),
    backend::Symbol = :zarr,
    force::Bool = false,
    verbose::Bool = true
)
    # Reuse the cached store: the manifest already resolved the destination, and
    # re-downloading a gridded product to rebuild an identical store is wasted work.
    if !force && is_cached(output_path)
        verbose && println("Using cached bathymetry at $(output_path)")
        return geoload(output_path; backend = backend)
    end

    erddap_vars = Dict(
        "ETOPO_2022_v1_15s" => "z",
        "etopo180"          => "altitude",
        "srtm30plus"        => "elevation"
    )
    var = get(erddap_vars, dataset_id, "z")

    # ERDDAP subset syntax uses literal brackets; encode them for a safe URL. The bounds are
    # ordered here rather than assumed from the caller: `lon_range` is a range, and handing
    # ERDDAP an inverted one returns an empty subset that loads without complaint.
    min_lon, max_lon = minmax(lon_range...)
    min_lat, max_lat = minmax(lat_range...)
    url = "https://coastwatch.pfeg.noaa.gov/erddap/griddap/$(dataset_id).nc?" *
          "$(var)%5B($(min_lat)):$(stride):$(max_lat)%5D%5B($(min_lon)):$(stride):$(max_lon)%5D"

    verbose && println("Fetching bathymetry from ERDDAP...")
    # Scratch beside the destination on purpose: a large ERDDAP file must not land in the OS temp dir.
    scratch = joinpath(dirname(output_path), ".bathymetry-$(dataset_id).nc")
    download_to_path(url, scratch; verbose = verbose, retries = 2)
    # Load the downloaded NetCDF and convert to GeoDataset
    ds = geoload(scratch; backend=:ncdatasets)
    # Save as Zarr (or other backend)
    geosave(output_path, ds; backend=backend, overwrite = force)
    rm(scratch, force=true)
    verbose && println("Saved bathymetry to $(output_path)")
    return ds
end

"""
    etopo_bathymetry_field(;
        lon_range::Tuple{Real, Real} = (-71.0, -53.0),
        lat_range::Tuple{Real, Real} = (40.0, 48.5),
        resolution::Real = 600,
        minimum_depth::Real = 0.0,
        interpolation_passes::Integer = 1,
        major_basins::Real = 1,
            cache = true  # Bool
    ) -> Matrix{Float64}

Get regional bathymetry as a raw matrix from ETOPO2022 using NumericalEarth.jl.
"""
function etopo_bathymetry_field(;
    lon_range::Tuple{Real, Real} = (-71.0, -53.0),
    lat_range::Tuple{Real, Real} = (40.0, 48.5),
    resolution::Real = 600,
    minimum_depth::Real = 0.0,
    interpolation_passes::Integer = 1,
    major_basins::Real = 1,
        cache = true  # Bool
)
    _has_numerical_earth || error("NumericalEarth.jl required for ETOPO bathymetry regridding. Add NumericalEarth to your environment.")
    
    lat_mid = 0.5 * (lat_range[1] + lat_range[2])
    m_per_deg = 111_320.0 * cosd((lat_range[1] + lat_range[2]) / 2)
    n_lon = clamp(round(Int, abs(lon_range[2] - lon_range[1]) * 111_320.0 * cosd((lat_range[1] + lat_range[2]) / 2) / resolution), 16, 21600)
    n_lat = clamp(round(Int, abs(lat_range[2] - lat_range[1]) * 111_320.0 / resolution), 16, 10800)
    
    scratch = NumericalEarth.LatitudeLongitudeGrid(
        NumericalEarth.CPU(), Float32;
        n_lon = n_lon, n_lat = n_lat,
        lon_min = lon_range[1], lon_max = lon_range[2],
        lat_min = lat_range[1], lat_max = lat_range[2]
    )
    
    etopo = NumericalEarth.ETOPO()
    bathy = NumericalEarth.regrid_bathymetry(etopo, scratch; major_basins = 1, interpolation_passes = 1)
    
    return Float64.(bathy)
end

"""
    load_bathymetry_geodata(filepath::AbstractString; backend=nothing) -> GeoDataset

Load bathymetry from a GeoData-compatible file (Zarr, NetCDF, GeoParquet, etc.),
auto-detecting the backend from the file extension when not specified.
"""
function load_bathymetry_geodata(filepath::AbstractString; backend = nothing)
    return geoload(filepath; backend = backend)
end

"""
    save_bathymetry_geodata(ds::GeoDataset, filepath::AbstractString; backend=nothing) -> String

Save bathymetry GeoDataset to a file, auto-detecting the backend from the file extension
when not specified.
"""
function save_bathymetry_geodata(ds::GeoDataset, filepath::AbstractString; backend = nothing)
    mkpath(dirname(filepath))
    geosave(filepath, ds; backend = backend)
    return filepath
end

function regrid_bathymetry_from_etopo(; lon_range::Tuple{Real, Real} = (-71.0, -53.0),
    lat_range::Tuple{Real, Real} = (40.0, 48.5),
    resolution::Real = 600,
    minimum_depth::Real = 0.0,
    interpolation_passes::Integer = 1,
    major_basins::Real = 1,
    cache::Bool = true,
)
    ds = etopo_bathymetry_field(; lon_range = lon_range, lat_range = lat_range,
                                resolution = resolution, minimum_depth = minimum_depth,
                                interpolation_passes = interpolation_passes,
                                major_basins = major_basins, cache = cache)
    lon_coords = Float64.(ds.axes[1])
    lat_coords = Float64.(ds.axes[2])
    elev = Float64.(ds.data)
    bat = CoordinateSystem(crs = "EPSG:4326")
    dims = (
        Dimension(name = :lon, size = length(lon_coords), coords = lon_coords, units = "degrees_east", dim_type = DIM_SPATIAL),
        Dimension(name = :lat, size = length(lat_coords), coords = lat_coords, units = "degrees_north", dim_type = DIM_SPATIAL)
    )
    vars = Dict(
        "elevation" => GeoArray(elev, dims, bat, Dict{String, Any}("units" => "m")),
    )
    return GeoDataset(variables = vars, coords = Dict(), dims = Dict(dims...), crs = bat, attrs = Dict{String, Any}(), backend = nothing, source = "ETOPO2022")
end