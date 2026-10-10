"""
    scripts/fetch_inputs.jl

Fetch the declared physical inputs for a run and register them in a catalog.

# Usage

    julia --project=. scripts/fetch_inputs.jl --output-dir=work/run
    julia --project=. scripts/fetch_inputs.jl --output-dir=work/run --only=bathymetry,hydrography
    julia --project=. scripts/fetch_inputs.jl --output-dir=work/run --force --strict=false

# Options

- `--output-dir=DIR`  where the run keeps its inputs (default `work/run`)
- `--only=KEY[,KEY]`  restrict to these source keys (default: every declared source)
- `--force`           re-fetch even when the cache already holds an artefact
- `--strict=false`    allow an individual fetcher to substitute a labelled fallback
- `--catalog=FILE`    catalog to register into (default `<output-dir>/catalog.json`)

Every source is fetched through `GeoDataManifest.fetch_input`, the one place that knows how
a dataset is obtained, and registered through the catalog, so what a run used is recorded
rather than remembered. `data_provenance.json` is written at the end.
"""

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using GeoDataSources:
    GeoDataManifest, CatalogModule, fetch_input, input_dir, data_provenance,
    describe_data_sources
using GeoDataSources.GeoDataManifest: DATA_SOURCES, data_source

const DEFAULT_KEYS = [:bathymetry, :surface_winds, :hydrography, :oxygen, :coastline,
                      :lateral_boundary, :atmosphere]

function parse_args(args::Vector{String})
    opts = Dict{Symbol, Any}(
        :output_dir => joinpath("work", "run"),
        :only => nothing,
        :force => false,
        :strict => true,
        :catalog => "",
    )
    for a in args
        if startswith(a, "--output-dir=")
            opts[:output_dir] = split(a, "=", limit = 2)[2]
        elseif startswith(a, "--only=")
            opts[:only] = Symbol.(split(split(a, "=", limit = 2)[2], ","))
        elseif startswith(a, "--catalog=")
            opts[:catalog] = split(a, "=", limit = 2)[2]
        elseif a == "--force"
            opts[:force] = true
        elseif a == "--strict=false"
            opts[:strict] = false
        elseif a == "--help" || a == "-h"
            println(@doc(@__MODULE__))
            exit(0)
        else
            error("Unknown argument: $(a) (see --help)")
        end
    end
    return opts
end

function main(args::Vector{String})
    opts = parse_args(args)
    output_dir = opts[:output_dir]
    mkpath(input_dir(output_dir))

    requested = isnothing(opts[:only]) ? DEFAULT_KEYS : opts[:only]
    unknown = [k for k in requested if !haskey(DATA_SOURCES, k)]
    isempty(unknown) || error("Unknown source key(s): $(unknown). Declared: " *
                              "$(sort(string.(collect(keys(DATA_SOURCES))))).")

    catalog_file = isempty(opts[:catalog]) ?
                   joinpath(output_dir, "catalog.json") : opts[:catalog]
    catalog = CatalogModule.GeoDataCatalog(catalog_file; auto_save = true)

    fetched = Dict{Symbol, String}()
    failed = Symbol[]
    for key in requested
        d = data_source(key)
        print("  $(rpad(string(key), 16))  ... ")
        flush(stdout)
        try
            path = fetch_input(key, output_dir; force = opts[:force], strict = opts[:strict])
            fetched[key] = path
            println("$(path)")
        catch err
            push!(failed, key)
            println("FAILED")
            println("     ", first(split(sprint(showerror, err), "\n")))
            continue
        end
    end

    for key in sort!(collect(keys(fetched)); by = string)
        d = data_source(key)
        CatalogModule.geopublish!(
            catalog, fetched[key];
            key = key, name = d.title, tier = :raw, source = d.primary,
            license = d.license, format = :netcdf,
        )
    end

    used = Dict{Symbol, DataSource}(k => DATA_SOURCES[k] for k in keys(fetched))
    data_provenance(output_dir; data_sources = used)

    println()
    println("Fetched $(length(fetched)) of $(length(requested)) sources into $(output_dir)")
    isempty(failed) || println("Not fetched: $(failed)  (see the errors above)")
    println("Provenance: $(joinpath(output_dir, "data_provenance.json"))")
    return isempty(failed) ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
