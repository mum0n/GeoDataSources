"""
    boundary.jl

Boundary hydrography fetch and interpolator construction via GeoData.

Supports WOA23, GLORYS12v1 (Copernicus), HYCOM for sponge boundary conditions.
"""

using GeoData
using GeoData.GeoDataTypes: GeoDataset, GeoArray, Dimension, CoordinateSystem
using NCDatasets
using Interpolations
using Statistics

"""
    _central_glorys_subset(lon, lat; dir = nothing) -> Union{String, Nothing}

The GLORYS12V1 boundary subset already assimilated in the central store, when one covers the
requested box, else `nothing`. `dir` defaults to the `glorys` directory of the central store
and is a keyword so a test can pass a fixture directory without redirecting the store.

The store is searched because the per-domain cache path in `input_dir` is not where the
archive is kept: a subset downloaded once sits under the source's own directory, and looking
for it only by its per-domain name re-downloads what is on disk. Coverage is checked rather
than assumed, because a subset cut to a smaller box returns an empty sponge instead of an
error, which is the failure that looks like a successful run.

Latitude and longitude axes are read by name in either spelling — `longitude`/`latitude`, the
Copernicus convention — so a NetCDF using the other one is still measured rather than skipped.
"""
function _central_glorys_subset(lon::Tuple{Float64, Float64}, lat::Tuple{Float64, Float64};
                                dir::AbstractString = joinpath(store_root(), "glorys"))
    isdir(dir) || return nothing
    for name in sort(readdir(dir))
        f = joinpath(dir, name)
        endswith(name, ".nc") && isfile(f) || continue
        got_lon = got_lat = nothing
        try
            ds = NCDataset(f)
            try
                for ax in ("longitude", "lon")
                    if haskey(ds, ax)
                        v = ds[ax]
                        got_lon = (Float64(minimum(v)), Float64(maximum(v)))
                        break
                    end
                end
                for ax in ("latitude", "lat")
                    if haskey(ds, ax)
                        v = ds[ax]
                        got_lat = (Float64(minimum(v)), Float64(maximum(v)))
                        break
                    end
                end
            finally
                close(ds)
            end
        catch err
            # An unreadable NetCDF is not a candidate; the loop continues to the next one.
            continue
        end
        (got_lon === nothing || got_lat === nothing) && continue
        got_lon[1] <= lon[1] && got_lon[2] >= lon[2] &&
            got_lat[1] <= lat[1] && got_lat[2] >= lat[2] || continue
        return f
    end
    return nothing
end

"""
    fetch_boundary_hydrography_geodata(source::Symbol;
        lon_range, lat_range, input_dir,
        month = 0, verbose = true) -> NamedTuple

Acquire and load boundary temperature and salinity as sponge targets using GeoData.

# Arguments
- `source`: Data source (:woa23, :glorys12v1, :glorys_climatology, :hycom)
- `lon_range`: Longitude bounds (min, max)
- `lat_range`: Latitude bounds (min, max)
- `input_dir`: Input/output directory
- `month`: Month (0 = annual mean)
- `verbose`: Print progress messages

# Returns
NamedTuple with interpolator functions (T, S).
"""
function fetch_boundary_hydrography_geodata(source::Symbol;
    lon_range, lat_range, input_dir,
    month::Int = 0, verbose::Bool = true)
    mkpath(input_dir)
    lon = (Float64(lon_range[1]), Float64(lon_range[2]))
    lat = (Float64(lat_range[1]), Float64(lat_range[2]))

    if source === :woa23
        mm = lpad(string(month), 2, '0')
        tp = joinpath(input_dir, "woa23_temperature_$(mm)_0.25deg.zarr")
        sp = joinpath(input_dir, "woa23_salinity_$(mm)_0.25deg.zarr")
        # `isdir || isfile`, because the product the fetcher writes *is* a Zarr store: a
        # directory. Testing `isfile` alone made this path fetch on every call and then
        # reject its own download -- "WOA23 boundary needs ... in <dir>" with the very files
        # the fetch had just saved into that directory sitting there. Same test as the
        # GLORYS branch below, which already had it right.
        if !(isdir(tp) || isfile(tp)) || !(isdir(sp) || isfile(sp))
            verbose && println("Fetching WOA23 climatology (keyless, NOAA)...")
            fetch_woa23(lon_range = lon_range, lat_range = lat_range,
                        month = month, output_dir = input_dir, backend=:zarr)
        end
        ((isdir(tp) || isfile(tp)) && (isdir(sp) || isfile(sp))) || error(
            "WOA23 boundary needs $(basename(tp)) and $(basename(sp)) in $(input_dir)")
        return build_boundary_tracer_interpolators_geodata(tp, sp; T_name = "t_an", S_name = "s_an")
    end

    if source in (:glorys12v1, :glorys_climatology)
        p = joinpath(input_dir, "boundary_glorys_1993_$(lon[1])_$(lon[2])_$(lat[1])_$(lat[2]).zarr")
        if !isdir(p) && !isfile(p)
            nc = replace(p, ".zarr" => ".nc")
            nc = isfile(nc) ? nc : _central_glorys_subset(lon, lat)
            if nc === nothing
                verbose && println("Fetching GLORYS12V1 boundary subset (Copernicus Marine)...")
                Copernicus.fetch_copernicus_physics_subset(
                    lon_range = lon_range, lat_range = lat_range,
                    start_date = "1993-01-01", end_date = "1993-12-31",
                    output_path = replace(p, ".zarr" => ".nc"),
                    dataset_id = "cmems_mod_glo_phy_my_0.083deg_P1M-m"
                )
                nc = replace(p, ".zarr" => ".nc")
            else
                # Already assimilated. Re-downloading a subset that is on disk is the whole
                # reason the Copernicus console script is a dependency rather than the way
                # this normally runs; the error it raises when the script is missing is
                # indistinguishable from "the data is gone", so it is avoided.
                verbose && println("Using the GLORYS12V1 subset already assimilated: $nc")
            end
            # Convert to zarr. Whichever file the science wants, the interpolator below
            # reads one path, so the converted store is the cache and the .nc is kept as is.
            ds = geoload(nc; backend = :ncdatasets)
            geosave(p, ds; backend = :zarr)
        end
        m = month == 0 ? collect(1:12) : [max(1, min(12, month))]
        return build_boundary_tracer_interpolators_geodata(p, p; T_name = "thetao", S_name = "so",
                                                            months = m)
    end

    if source === :hycom
        p = joinpath(input_dir, "boundary_hycom.zarr")
        if !isdir(p) && !isfile(p)
            error(
                "HYCOM GOFS OPeNDAP server (tds.hycom.org) is currently unreachable or returns " *
                "HTTP 400. Use source = :woa23 or source = :glorys12v1 instead, or place a " *
                "pre-downloaded 'boundary_hycom.zarr' in '$(input_dir)'."
            )
        end
        return build_boundary_tracer_interpolators_geodata(p, p; T_name = "water_temp",
                                                            S_name = "salinity", months = [1])
    end

    error(
        "Unknown boundary source \"$(source)\". Choose :woa23, :glorys12v1, :hycom, or :synthetic."
    )
end

"""
    build_boundary_tracer_interpolators_geodata(temp_file, salt_file; T_name, S_name, months=[1]) -> NamedTuple

Build (lon, lat, z, t) interpolators for boundary T and S from GeoData files.

# Arguments
- `temp_file`: Path to temperature GeoDataset
- `salt_file`: Path to salinity GeoDataset
- `T_name`: Temperature variable name
- `S_name`: Salinity variable name
- `months`: Months to average (if time dimension present)

# Returns
NamedTuple with (T, S) interpolator functions.
"""
function build_boundary_tracer_interpolators_geodata(
    temp_file::AbstractString, salt_file::AbstractString;
    T_name::AbstractString = "t_an", S_name::AbstractString = "s_an",
    months::Vector{Int} = [1]
)
    # Load temperature GeoDataset
    temp_ds = geoload(temp_file)
    salt_ds = geoload(salt_file)

    # Get coordinate arrays. `axis` returns (values, Dimension), so the dimension record is
    # dropped here: everything below works on the values, and taking the pair as-is made
    # `minimum(deps)` fail on a tuple of (Vector, Dimension) the first time this path ran.
    # `axis` names what is missing rather than silently handing back nothing, and it resolves
    # aliases, so `t` or `datetime` is found too.
    lons, _ = axis(temp_ds, :lon)
    lats, _ = axis(temp_ds, :lat)
    deps, _ = axis(temp_ds, :depth)
      # Time is optional: a static source legitimately has no time axis. The presence test
      # goes through the same alias table `axis` uses, so a file that spells the axis `t`
      # does not read as "no time axis" and silently fall back to a single frame.
      times = any(k -> standardize_dimension_name(k) === :time,
                  keys(temp_ds.coords)) ? first(axis(temp_ds, :time)) : Float64[0.0]

    # Get data arrays
    T_data = temp_ds.variables[T_name].data
    S_data = salt_ds.variables[S_name].data

    # Handle time dimension - average over specified months if multiple
    if ndims(T_data) == 4 && length(months) > 1
        T_data = mean(T_data[:, :, :, months], dims=4)[:, :, :, 1]
        S_data = mean(S_data[:, :, :, months], dims=4)[:, :, :, 1]
    elseif ndims(T_data) == 4
        T_data = T_data[:, :, :, months[1]]
        S_data = S_data[:, :, :, months[1]]
    end

    # Ensure (lon, lat, depth) ordering
    if size(T_data, 1) == length(lats) && size(T_data, 2) == length(lons)
        T_data = permutedims(T_data, (2, 1, 3))
        S_data = permutedims(S_data, (2, 1, 3))
    end

    # Convert depth to negative-up if positive-down
    if !isempty(deps) && minimum(deps) > -0.5 * maximum(abs, deps)
        deps = -deps
    end

    # Sort coordinates
    if !issorted(lons)
        p = sortperm(lons); lons = lons[p]; T_data = T_data[p, :, :]; S_data = S_data[p, :, :]
    end
    if !issorted(lats)
        p = sortperm(lats); lats = lats[p]; T_data = T_data[:, p, :]; S_data = S_data[:, p, :]
    end
    if !issorted(deps)
        p = sortperm(deps); deps = deps[p]; T_data = T_data[:, :, p]; S_data = S_data[:, :, p]
    end

    # Extrapolate downward from surface to seabed to fill below-seabed bathymetric
    # NaNs with the deepest valid bottom marine water value at each (lon, lat) column.
    # Note: `deps` is sorted ascending in signed z (e.g., -5700 m at k=1 to 0 m at k=end),
    # so downward through the water column corresponds to descending index k.
    for j in 1:size(T_data, 2), i in 1:size(T_data, 1)
        last_valid_T = NaN
        last_valid_S = NaN
        for k in length(deps):-1:1
            if !isnan(T_data[i, j, k])
                last_valid_T = T_data[i, j, k]
            elseif !isnan(last_valid_T)
                T_data[i, j, k] = last_valid_T
            end

            if !isnan(S_data[i, j, k])
                last_valid_S = S_data[i, j, k]
            elseif !isnan(last_valid_S)
                S_data[i, j, k] = last_valid_S
            end
        end
    end

    # Replace any remaining fully-dry land column NaNs with domain-average ocean values
    valid_T_all = filter(!isnan, T_data)
    valid_S_all = filter(!isnan, S_data)
    default_T = isempty(valid_T_all) ? 10.0 : mean(valid_T_all)
    default_S = isempty(valid_S_all) ? 35.0 : mean(valid_S_all)
    replace!(T_data, NaN => default_T)
    replace!(S_data, NaN => default_S)

    # Create 3D interpolators (lon, lat, depth)
    itp_T = interpolate((lons, lats, deps), T_data, Gridded(Linear()))
    itp_T_ext = extrapolate(itp_T, Flat())
    itp_S = interpolate((lons, lats, deps), S_data, Gridded(Linear()))
    itp_S_ext = extrapolate(itp_S, Flat())

    # Return callable functions supporting both (lon, lat, z) and (lon, lat, z, t) -> value
    # Time dimension is handled by the sponge relaxation, not interpolation
    T_fn = (lon, lat, z, t=0.0) -> Float64(itp_T_ext(Float64(lon), Float64(lat), Float64(z)))
    S_fn = (lon, lat, z, t=0.0) -> Float64(itp_S_ext(Float64(lon), Float64(lat), Float64(z)))

    return (T = T_fn, S = S_fn)
end
