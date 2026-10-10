"""
    Access/Axis.jl

The single place that resolves a dataset's axes and variable names.

Each fetcher previously carried its own `haskey(ds.coords, :lon) ? ... : error(...)`
chain, and the chains had drifted apart: some accepted `:longitude`, some did not, one
silently fell back to zeros. Everything that needs to know which axis is which, in which
order, or beneath which name, asks here instead, so a spelling is decided once.

This module is the *source-side* view: `GeoDataCoordinates` resolves coordinate *values*
(nearest index, slice range, grid spacing) and this module resolves coordinate *identity*
(which axis is longitude, under what name, in what order). Both are needed and neither
reimplemented here: the alias table delegates to GeoData's `AXIS_ALIASES`, so there is one
list of accepted spellings in the repo rather than two that can disagree.

# Conventions decided here

- Longitude is `:lon`, latitude `:lat`; standard names `:longitude`/`:latitude` and
  Cartesian `x`/`y` are accepted aliases.
- Depth is `:depth`; WOA's `lev` and generic `z`/`altitude` are accepted. Positive-down
  after `to_positive_down`, in metres, whatever the file stored.
- Time is `:time`; `t`, `date`, `datetime` accepted. Numeric seconds since
  1970-01-01T00:00:00Z, documented in `Dimension.units`.
"""

using GeoData
using GeoData: standardize_dimension_name

"""
    AXIS_ALIASES

Accepted spellings per axis, ordered most-preferred first. This is what GeoData's
`GeoDataCoordinates` already aliases, exposed here so callers write `AXIS_ALIASES[:lon]`
rather than rebuilding the list.
"""
const AXIS_ALIASES = let aliases = GeoData.GeoDataCoordinates.AXIS_FIELDS
    Dict{Symbol, Vector{Symbol}}(k => collect(v) for (k, v) in aliases)
end

"""
    AXIS_UNITS

Units each axis is reported in. Not enforced - a source may legitimately store another
unit - but recorded so `require_coord` can catch a silent mismatch.
"""
const AXIS_UNITS = Dict{Symbol, String}(
    :lon => "degrees_east",
    :lat => "degrees_north",
    :depth => "m",
    :time => "seconds since 1970-01-01T00:00:00Z",
)

"""
    axis(ds::GeoDataset, name::Symbol) -> (Vector{Float64}, Dimension)

The coordinate values of axis `name` and its dimension record, resolved through
`AXIS_ALIASES` so `:longitude` and `:x` both find the longitude axis.

Raises when the dataset has no such axis. An absent axis is a fact about the dataset, not
something to invent.
"""
function axis(ds::GeoDataset, name::Symbol)
    for candidate in (name, get(AXIS_ALIASES, name, ())...)
        if haskey(ds.coords, candidate)
            return vec(Float64.(ds.coords[candidate].data)), ds.dims[candidate]
        end
    end
    error("Dataset has no $(name) axis. It has: $(sort(collect(keys(ds.coords)))).")
end

"""
    require_coord(ds::GeoDataset, name::Symbol; units = nothing) -> Vector{Float64}

Coordinate values of `name`, erroring if the stored units disagree with what the caller
expects. The units check is the point: silently mixing metres with decibars, or degrees
with radians, is how a wrong field still looks plausible.
"""
function require_coord(ds::GeoDataset, name::Symbol; units = nothing)
    values, d = axis(ds, name)
    if units !== nothing
        d.units !== nothing && !occursin(lowercase(string(units)), lowercase(string(d.units))) &&
            error("Axis :$name is stored in $(d.units), expected units containing " *
                  "$(units). Convert before use.")
    end
    return values
end

"""
    to_positive_down(z::AbstractVector) -> (Vector{Float64}, Bool)

Convention-normalise a vertical axis to positive-down (metres below the surface).

Returns the values and whether a sign flip was applied. Files disagree: WOA23 and GLORYS
store depth positive-down, HYCOM stores height negative-up, ETOPO stores elevation
positive-up. Without one decision made here, a depth of `-5` is either the surface or five
metres down, and only one of those is true.
"""
function to_positive_down(z::AbstractVector)
    v = Float64.(z)
    isempty(v) && return v, false
    upward = all(v .<= 0.0) && minimum(abs, v) > 0.0
    upward && return abs.(v), true
    return v, false
end

export AXIS_ALIASES, AXIS_UNITS, axis, require_coord, to_positive_down
