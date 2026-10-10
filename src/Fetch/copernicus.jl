"""
    copernicus.jl

Copernicus Marine and Climate Data Store integration for geospatial data retrieval.

This module provides functions to fetch data from Copernicus Marine Service (CMEMS)
and Copernicus Climate Data Store (CDS) using their respective CLI tools.
"""
module Copernicus

using Downloads
using NCDatasets
using Base64
using JSON3
using GeoData

export copernicusmarine_executable,
       project_python,
       copernicus_credentials,
       copernicus_login_reminder,
       fetch_copernicus_physics_subset,
       fetch_copernicus_hydrography_with_fallback,
       fetch_copernicus_surface_winds

"""
    copernicusmarine_executable() -> String

Resolve the `copernicusmarine` console script path.
"""
function copernicusmarine_executable()::String
    override = get(ENV, "COPERNICUSMARINE_EXE", "")
    isempty(strip(override)) || return normpath(override)

    suffix = Sys.iswindows() ? ".exe" : ""
    beside_python = joinpath(dirname(project_python()), "copernicusmarine$(suffix)")
    isfile(beside_python) && return normpath(beside_python)

    on_path = Sys.which("copernicusmarine")
    isnothing(on_path) || return on_path

    error(
        "Could not find the `copernicusmarine` console script. It is a Python package, " *
        "so it is installed into a Python environment rather than the Julia depot. Tried, " *
        "in order: the COPERNICUSMARINE_EXE environment variable, the script directory " *
        "beside $(project_python()), and PATH. To fix, install it into the project " *
        "environment and re-run:\n" *
        "    <package_root>/.venv/Scripts/python.exe -m pip install copernicusmarine\n" *
        "then authenticate with:\n" *
        "    <package_root>/.venv/Scripts/copernicusmarine.exe login"
    )
end

"""
    project_python() -> String

Resolve the Python interpreter used to run the Copernicus helper scripts and CLI.
"""
function project_python()::String
    for var in ("PARTICLETRACKING_PYTHON", "PYTHON_EXECUTABLE")
        override = get(ENV, var, "")
        isempty(strip(override)) || return normpath(override)
    end

    exe = Sys.iswindows() ? "python.exe" : "python"
    rel = Sys.iswindows() ? joinpath("Scripts", exe) : joinpath("bin", exe)

    package_root = normpath(joinpath(@__DIR__, "..", "..", ".."))
    candidates = String[joinpath(package_root, ".venv", rel)]

    active = get(ENV, "VIRTUAL_ENV", "")
    isempty(strip(active)) || push!(candidates, joinpath(active, rel))

    for candidate in candidates
        isfile(candidate) && return normpath(candidate)
    end

    return something(Sys.which("python"), "python")
end

"""
    copernicus_credentials() -> Union{Nothing, NamedTuple}

Locate and parse the Copernicus Marine credentials.
"""
function copernicus_credentials()
    dir = joinpath(homedir(), ".copernicusmarine")
    for name in ("credentials.toml", "credentials")
        path = joinpath(dir, name)
        isfile(path) || continue
        raw = strip(read(path, String))
        isempty(raw) && continue

        text, encoded = raw, false
        u = match(r"(?m)^\s*username\s*=\s*(\S+)", text)
        p = match(r"(?m)^\s*password\s*=\s*(\S+)", text)
        if u === nothing || p === nothing
            decoded = try
                String(Base64.base64decode(raw))
            catch
                nothing
            end
            if decoded !== nothing
                du = match(r"(?m)^\s*username\s*=\s*(\S+)", decoded)
                dp = match(r"(?m)^\s*password\s*=\s*(\S+)", decoded)
                if du !== nothing && dp !== nothing
                    text, encoded = decoded, true
                    u, p = du, dp
                end
            end
        end

        if u !== nothing && p !== nothing
            return (username = u.captures[1], password = p.captures[1], path = path,
                    encoded = encoded)
        end

        error(
            "The Copernicus credentials at $(path) are neither readable INI nor base64-wrapped " *
            "INI, so no username and password could be extracted. Re-create them with:\n" *
            "    .\\.venv\\Scripts\\copernicusmarine.exe login"
        )
    end
    return nothing
end

"""
    copernicus_login_reminder() -> String

Build the reminder appended to Copernicus download failures.
"""
function copernicus_login_reminder()::String
    reminder = "\n\nIf this is the first time using Copernicus Marine, or the " *
               "credentials have expired, log in first:\n" *
               "    .\\.venv\\Scripts\\copernicusmarine.exe login\n" *
               "Login prompts for a Copernicus Marine account (free to register) and writes " *
               "~/.copernicusmarine/credentials.toml. It is interactive, so it must be run " *
               "in a terminal, not from Julia.\n" *
               "Check existing credentials at any time with:\n" *
               "    .\\.venv\\Scripts\\copernicusmarine.exe login --check-credentials-valid\n" *
               "Note that valid credentials are necessary but not sufficient: each dataset " *
               "also needs its own terms and conditions accepted in the Copernicus Marine " *
               "portal before the API will return data."

    cli = try
        copernicusmarine_executable()
    catch
        nothing
    end
    isnothing(cli) || (reminder *= "\nResolved script used for this request: $(cli)")

    return reminder
end

"""
    fetch_copernicus_physics_subset(; kwargs...) -> String

Download a regional subset of 3D temperature (`thetao`) and salinity (`so`) from a
Copernicus Marine global ocean physics product using the `copernicusmarine` CLI.
"""
function fetch_copernicus_physics_subset(;
    lon_range::Union{Nothing, Tuple{Real, Real}} = nothing,
    lat_range::Union{Nothing, Tuple{Real, Real}} = nothing,
    start_date::AbstractString = "2023-06-01",
    end_date::AbstractString = "2023-06-30",
    output_path::AbstractString = joinpath("inputs", "copernicus_ts.nc"),
    dataset_id::AbstractString = "GLOBAL_MULTIYEAR_PHY_001_030",
    service_url::Union{Nothing, AbstractString} = nothing,
    verbose::Bool = true,
    # Part of the package's canonical fetcher keyword set. This fetcher always
    # re-downloads, so there is no store for orce to invalidate; it is accepted (and
    # has no effect) rather than absent, which is what previously made
    # _fetcher_copernicus_physics forward a keyword no method accepted and fail on every
    # live fetch.
    force::Bool = false,
    backend::Symbol = :zarr,
)
    # Default domain if not provided
    lon_range = isnothing(lon_range) ? (-71.0, -53.0) : lon_range
    lat_range = isnothing(lat_range) ? (40.0, 48.5) : lat_range
    
    min_lon, max_lon = Float64(lon_range[1]), Float64(lon_range[2])
    min_lat, max_lat = Float64(lat_range[1]), Float64(lat_range[2])
    mkpath(dirname(output_path))

    cli = copernicusmarine_executable()

    if verbose
        println("Requesting Copernicus Marine subset ($dataset_id)...")
        println("Bounding box: Lon [$min_lon, $max_lon], Lat [$min_lat, $max_lat]")
        println("Using CLI: $cli")
    end

    valid_datasets = [
        "cmems_mod_glo_phy_my_0.083deg_P1M-m",
        "cmems_mod_glo_phy_my_0.083deg_P1D-m",
        "GLOBAL_MULTIYEAR_PHY_001_030",
        "GLOBAL_MULTIYEAR_PHY_001_033",
        "GLOBAL_REANALYSIS_PHY_001_031",
        "GLOBAL_ANALYSISFORECAST_PHY_001_024",
    ]
    known_datasets = valid_datasets

    # Use exactly what was asked for. The previous logic replaced any non-`cmems_mod_`
    # product with the default *even when it was in the known list*, so
    # `fetch_copernicus_hydrography_with_fallback` requested the same default product four
    # times and called it a fallback chain.
    dataset = dataset_id
    if !(dataset_id in known_datasets)
        error("Unknown CMEMS dataset id '$dataset_id'. Known ids: " *
              "$(join(known_datasets, ", ")).")
    end

    creds = copernicus_credentials()
    auth = isnothing(creds) ? `` : `--username $(creds.username) --password $(creds.password)`
    if verbose
        isnothing(creds) || println(
            "Credentials read from $(basename(creds.path))" *
            (creds.encoded ? " (base64-encoded; the client cannot read that form itself)" : "") *
            "."
        )
    end

    cmd = `$cli subset \
            $auth \
            --dataset-id $dataset \
            --variable thetao \
            --variable so \
            --minimum-longitude $min_lon \
            --maximum-longitude $max_lon \
            --minimum-latitude $min_lat \
            --maximum-latitude $max_lat \
            --start-datetime "$(start_date)T00:00:00" \
            --end-datetime "$(end_date)T23:59:59" \
            --output-filename $(basename(output_path)) \
            --output-directory $(dirname(output_path))`

    try
        run(cmd)
        if verbose
            println("Copernicus subset successfully saved to: $(output_path)")
        end
    catch err
        @warn "Copernicus download failed for dataset $dataset. " *
              "Causes, in the order they actually occur: credentials not found or not " *
              "readable (run copernicusmarine login); the dataset's terms and conditions " *
              "not yet accepted in the Copernicus Marine portal; or the requested date " *
              "outside the dataset's span (the -climatology_ dataset covers 2004 only, " *
              "while the monthly dataset covers 1993-present)." *
              copernicus_login_reminder()
        rethrow(err)
    end

    return output_path
end

"""
    fetch_copernicus_hydrography_with_fallback(; kwargs...) -> String

Fetch 3D temperature/salinity from Copernicus Marine, trying multiple datasets in sequence
until one succeeds.
"""
function fetch_copernicus_hydrography_with_fallback(; 
    lon_range::Union{Nothing, Tuple{Real, Real}} = nothing, 
    lat_range::Union{Nothing, Tuple{Real, Real}} = nothing, 
    start_date::AbstractString = "2023-06-01", 
    end_date::AbstractString = "2023-06-30", 
    output_path::AbstractString = joinpath("inputs", "copernicus_ts.nc"),
    verbose::Bool = true
)
    datasets = [
        "GLOBAL_MULTIYEAR_PHY_001_033",
        "GLOBAL_REANALYSIS_PHY_001_031",
        "GLOBAL_MULTIYEAR_PHY_001_030",
        "GLOBAL_ANALYSISFORECAST_PHY_001_024",
    ]

    last_err = nothing
    for ds in datasets
        try
            if verbose
                println("Attempting Copernicus dataset: $ds")
            end
            return fetch_copernicus_physics_subset(
                lon_range = lon_range,
                lat_range = lat_range,
                start_date = start_date,
                end_date = end_date,
                output_path = output_path,
                dataset_id = ds,
                verbose = verbose
            )
        catch err
            last_err = err
            if verbose
                println("  -> Failed: $(typeof(err))")
            end
        end
    end

    error("All Copernicus Marine datasets failed. Last error: $last_err. " *
          "Ensure 'copernicusmarine' is installed and credentials configured." *
          copernicus_login_reminder())
end

"""
    fetch_copernicus_surface_winds(; kwargs...) -> String

Retrieve 10-meter surface wind components from Copernicus Climate Data Store 
(ERA5 hourly reanalysis on single levels) using local CDS Python client integration.
"""
function fetch_copernicus_surface_winds(; 
    lon_range::Union{Nothing, Tuple{Real, Real}} = nothing, 
    lat_range::Union{Nothing, Tuple{Real, Real}} = nothing, 
    time_iso::AbstractString = "2023-06-01T00:00:00Z", 
    output_path::AbstractString = joinpath("inputs", "copernicus_surface_winds.nc"), 
    verbose::Bool = true
)
    # Default domain if not provided
    lon_range = isnothing(lon_range) ? (-71.0, -53.0) : lon_range
    lat_range = isnothing(lat_range) ? (40.0, 48.5) : lat_range
    
    min_lat, max_lat = Float64(lat_range[1]), Float64(lat_range[2])
    min_lon, max_lon = Float64(lon_range[1]), Float64(lon_range[2])
    mkpath(dirname(output_path))

    if verbose
        println("Initiating Copernicus ERA5 surface wind extraction for $(time_iso)...")
        println("Bounding box: North=$(max_lat), South=$(min_lat), West=$(min_lon), East=$(max_lon)")
    end

    date_part, time_part = split(time_iso, 'T')
    year_str, month_str, day_str = split(date_part, '-')
    hour_str = string(split(time_part, ':')[1], ":00")

    cds_script_path = replace(output_path, ".nc" => "_cds_request.py")
    
    open(cds_script_path, "w") do io
        write(io, 
"""
import cdsapi
import sys

c = cdsapi.Client()

request_new = {
    'product_type': ['reanalysis'],
    'variable': ['10m_u_component_of_wind', '10m_v_component_of_wind'],
    'year': ['$year_str'],
    'month': ['$month_str'],
    'day': ['$day_str'],
    'time': ['$hour_str'],
    'data_format': 'netcdf',
    'download_format': 'unarchived',
    'area': [$max_lat, $min_lon, $min_lat, $max_lon],
}
target = '$output_path'

try:
    c.retrieve('reanalysis-era5-single-levels', request_new, target)
    sys.exit(0)
except Exception as e:
    print(f"CDS-Beta retrieve error: {e}. Trying legacy dataset format...")

request_legacy = {
    'product_type': 'reanalysis',
    'variable': ['10m_u_component_of_wind', '10m_v_component_of_wind'],
    'year': '$year_str',
    'month': '$month_str',
    'day': '$day_str',
    'time': '$hour_str',
    'format': 'netcdf',
    'area': [$max_lat, $min_lon, $min_lat, $max_lon],
}
try:
    c.retrieve('reanalysis-era5-single-levels', request_legacy, target)
except Exception:
    c.retrieve('reanalysis-era5', request_legacy, target)
""")
    end

    if verbose
        println("Generated Copernicus CDS request script at: $(cds_script_path)")
        println("Executing request via CDS API...")
    end

    try
        run(`$(project_python()) $(cds_script_path)`)
        if verbose
            println("Copernicus surface winds successfully downloaded to: $(output_path)")
        end
    catch err
        @warn "Automated execution via python cdsapi failed ($(err)). " *
              "Ensure your CDS API credentials (~/.cdsapirc) are configured, and that " *
              "`cdsapi` is installed in $(dirname(project_python())). " *
              "Note: this ERA5 wind path uses the CDS API and is a separate service from " *
              "Copernicus Marine — `copernicusmarine login` does not authenticate here."
        rethrow(err)
    end

    return output_path
end

end # module
