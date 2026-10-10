"""
    scripts/assimilate_cube.jl

Assimilate a unified regional environmental data cube from a region config.

# Usage

    julia --project=. scripts/assimilate_cube.jl --config=configs/regions/scotian_shelf.toml
    julia --project=. scripts/assimilate_cube.jl --config=... --strict=false
    julia --project=. scripts/assimilate_cube.jl --config=... --list-vars

# Options

- `--config=FILE`    region configuration to build (required)
- `--strict=false`   skip a variable whose source is unavailable instead of aborting the run
- `--list-vars`      print the variables the config would build, then exit

Each variable's source is declared in `CUBE_VARIABLE_SOURCES` (src/regional_cube.jl) and
described in `DATA_SOURCES` (src/manifest.jl); the config names the variables. A variable
whose source cannot be fetched is left out of the cube and recorded as such, unless
`--strict=false` was not passed, in which case the run aborts: a cube that silently omits
a field the caller asked for is worse than one that failed.
"""

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using GeoDataSources: GeoDataManifest, RegionalCubeConfig, load_cube_config,
    standard_ocean_depths, assimilate_regional_cube, CUBE_VARIABLE_SOURCES

function parse_args(args::Vector{String})
    opts = Dict{Symbol, Any}(:config => "", :strict => true, :list_vars => false)
    for a in args
        if startswith(a, "--config=")
            opts[:config] = split(a, "=", limit = 2)[2]
        elseif a == "--strict=false"
            opts[:strict] = false
        elseif a == "--list-vars"
            opts[:list_vars] = true
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
    isfile(opts[:config]) || error("Config not found: $(opts[:config])")

    cfg = load_cube_config(opts[:config])

    if opts[:list_vars]
        println("$(cfg.region_name): $(length(cfg.variables)) variables, " *
                "$(length(GeoDataManifest.DATA_SOURCES)) declared sources")
        for v in cfg.variables
            key = get(CUBE_VARIABLE_SOURCES, v, nothing)
            println("  ", rpad(string(v), 20), " <- ", key === nothing ? "(unmapped)" : key)
        end
        return 0
    end

    println("Assimilating $(cfg.region_name) -> $(cfg.output_path)")
    println("  variables: ", join(string.(cfg.variables), ", "))
    println("  depth levels: ", length(GeoDataManifest.DATA_SOURCES) > 0 ?
            length(cfg.depth_levels) : length(standard_ocean_depths()))
    println("  time mode: ", cfg.time_mode)

    path = assimilate_regional_cube(cfg; verbose = true, strict = opts[:strict])
    println("Done: ", path)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
