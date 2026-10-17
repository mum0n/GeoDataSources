### A Pluto.jl notebook ###
# v1.0.4

using Markdown
using InteractiveUtils

# ╔═╡ 9f166500-c806-11f1-b6b2-6d98e9fcf603
# ╠═╡
using Pkg

# ╔═╡ 9f166500-c806-11f1-a9bf-d390270f4a24
# ╠═╡
Pkg.activate(@__DIR__)

# ╔═╡ 1a5f30e2-8d7c-4b21-9604-3f5e9c8a7b11
# ╠═╡
md"""
# GeoDataSources — acquisition, the central store, and provenance

How every physical input this stack consumes gets named, fetched, cached, and proven — and what
each option decides, because the package's whole contract is that an unavailable dataset is an
**error**, never a silently invented value.

Nothing here fabricates a field. Every fallback has to be opted into by the caller
(`fetch_input(; strict = false)`), and the cells below show what that looks like in practice.

### The one idea to take away

Every product lands in **one central, machine-level registry** — the lakehouse — configured by one
user-editable file, not by a constant in the code. A dataset is fetched once and shared by every
run on the machine, whatever asks for it. Where the store root is, and how to move it, is the
second cell, because everything else depends on that answer.
"""

# ╔═╡ 9f166500-c806-11f1-b470-1d0497e43053
# ╠═╡
md"""
## Running this notebook

Launch Pluto from an environment that already has it, and open this file:

```
julia -e 'using Pluto; Pluto.run()'
```

The first three cells pin the working directory to the package root and activate **this
package's environment**. Pluto holds one shared module across cells, so re-running a cell re-runs
everything downstream — which is what makes asking "what if I move the store root?" a one-line
change rather than a rebuild.
"""

# ╔═╡ 9f166500-c806-11f1-8177-890a6f9feb11
# ╠═╡
cd(joinpath(@__DIR__, ".."))

# ╔═╡ 9f166500-c806-11f1-a708-4d2c609c7dd2
# ╠═╡
# `GeoDataSources` re-exports `GeoData`, so one `using` gives both. The three below are what a
# coastline and a catalogue entry need, and they are direct dependencies of this package, so the
# activated environment has them.
using GeoDataSources
using GeoData
using GeoInterface, GeoParquet, DataFrames

# ╔═╡ 9f166500-c806-11f1-93ae-992c31c96025
# ╠═╡
md"""
## The central store: one registry, one file to move it

`store_root()` is where every assimilated product lives. It is read **at call time** from
`default_storage.toml` beside this package, so editing that file relocates the whole registry with
no recompile — that is the entire reason it is not a constant.

```
GeoDataSources/default_storage.toml
[storage]
store_root = "../lakehouse/GeoData"     # the default: projects/lakehouse/GeoData
```

`store_path(source)` is one source's directory inside it, e.g. `store_path("woa23")`. A relative
`store_root` resolves against this package's directory, so it stays stable whatever the caller's
working directory is — which is what a Pluto notebook needs, since it starts wherever you
launched it.

The cell below is read-only: it reports the current configuration. The point is the relationship —
`store_root()` answers for every source, so a second run reuses the same bytes instead of
downloading them again.
"""

# ╔═╡ 9f166500-c806-11f1-afad-49bb6272d9c9
# ╠═╡
println("store_root    : ", store_root())
println("configured in : ", storage_file_path())
println("woa23         : ", store_path("woa23"))
println("etopo         : ", store_path("etopo"))
println("tpxo9         : ", store_path("tpxo9"))

# The central store is a machine-level asset: whatever is already in it is shared, not per-run.
existing = [p for p in readdir(store_root()) if isdir(joinpath(store_root(), p))]
println("\nsource directories already in the store: ", existing)

# ╔═╡ 9f166500-c806-11f1-bb40-19f0ca30a6f3
# ╠═╡
md"""
## Tiers: how the data were made, not what they are

Every source declares a **tier**, and a tier describes the *processing level*. Three, and only
three — these are the only values `fetch_input` accepts:

| tier | meaning | example |
|---|---|---|
| `:raw` | the observations as delivered — measured, unmodified | bottom temperature surveys, CHS soundings |
| `:discretized` | filtered, quality-controlled, and binned onto a resolution chosen per dataset | WOA23 climatology, the coastline |
| `:modelled` | output of a numerical model or reanalysis, at whatever resolution the model carries | GLORYS12V1, ERA5, TPXO9 |

A tier is a property **of the source**, so it belongs in the manifest rather than in a config.
`fetch_input(key, dir; tier = ...)` defaults to the source's declared tier, which is why
`fetch_input(:bottom_temperature, dir)` hands back the measured tables while
`fetch_input(:bathymetry, dir)` hands back the modelled product: one word, two processing levels,
and naming the tier is how you say which you want. `buildable(key; tier)` is the same question
about whether it can be produced here.

A source declares its tier; a tier does not select a source. The tier decides *how* the artefact
is produced — `:raw` and `:discretized` come from a fetcher, `:modelled` from a modeller — not
*which* dataset answers. That is why a source with no entry for the tier you asked for fails
here, listing its alternatives, rather than quietly handing you a different product.

### The other tier vocabulary: the lakehouse catalogue

`lakehouse_path` and `GeoDataCatalog` use a **different** three-tier vocabulary —
`lakehouse_tiers() == [:raw, :processed, :derived]`, the medallion names — for what a *project*
owns and produces. It is unrelated to the tier vocabulary above: one describes how upstream data
was made, the other where a project's own artefacts sit. The cell on the catalogue uses the
lakehouse one; the cells up to here use the manifest one.
"""

# ╔═╡ 9f166500-c806-11f1-8bd3-0d4cb6579941
# ╠═╡
md"""
## The declared registry: what can be asked for, and what it costs

`available_data()` is the function to call *before writing a config*. It answers "what can I
actually request, and what will that cost me" — one row per declared source, with its tier, its
access requirement, and where its cache lives. `buildable_sources()` narrows that to the sources
this package can actually produce.

Access states, and they are not the same claim:

- **keyless** — no account, token, or licence click; only a connection.
- **needs account** — free registration and a credentials file (Copernicus Marine reads
  `~/.copernicusmarine/credentials`).
- **local** — shipped inside this package, so nothing is downloaded at all.

`buildable(key)` is how a config can name something the package cannot build and fail at **load
time** rather than hours into a run.
"""

# ╔═╡ 9f166500-c806-11f1-90b0-833d41239230
# ╠═╡
rows = available_data()

println(rpad("key", 20), rpad("tier", 14), rpad("access", 10), "cache (relative to the store)")
println(repeat("-", 88))
for r in rows
    access = r.keyless ? "keyless" : "ACCOUNT"
    println(rpad(string(r.key), 20), rpad(string(r.tier), 14), rpad(access, 10), r.cache)
end

boundary = GeoDataSources.DATA_SOURCES[:lateral_boundary]
println("\nbuildable sources              : ", join(string.(buildable_sources()), ", "))
println("the Copernicus boundary        : buildable=", buildable(:lateral_boundary),
        ", needs an account=", !boundary.keyless)

# ╔═╡ 9f166500-c806-11f1-a13b-47c6f8dcaa76
# ╠═╡
md"""
## Fetching: cache first, then the network, never a substitution

`fetch_input(key, output_dir; tier, force, strict)` is the one dispatcher:

1. resolve the declared cache path, substituting `<store>` for the central registry,
   `<output_dir>` for the run, and `<mm>` for a month placeholder;
2. **return it if it is already there** — the cache test is `is_cached`, not `isfile`, because a
   Zarr store is a *directory* and `isfile` reports the two most common cache forms as missing;
3. otherwise call the fetcher for that tier; a source with no fetcher for its tier is an error at
   this call, not a surprise later.

`force = true` re-obtains. `strict = false` lets an individual fetcher choose a *labelled*
fallback instead of failing — the fallback is recorded, which is the whole difference between
that and a silent substitution.

The cell below is safe on a fresh checkout: it asks for a source the store already holds, so it
demonstrates the cache-first path without a download, and prints where the artefact actually
lives. If your central store has no `bathymetry`, pick a source in the table above that it does.
"""

# ╔═╡ 9f166500-c806-11f1-8530-bb14b1d944d0
# ╠═╡
# `strict` and `force` are the two options worth understanding; `tier` is the one worth naming
# explicitly when a source offers more than one processing level.
key = :bathymetry
run_dir = normpath(joinpath("scratch", "notebook_sources"))

target = replace(replace(replace(GeoDataSources.DATA_SOURCES[key].cache,
                                 "<store>" => store_root()),
                         "<output_dir>" => run_dir), "<mm>" => "00")

println("declared cache : ", target)
println("already there  : ", is_cached(target))

path = fetch_input(key, run_dir)
println("fetch_input    -> ", path)
println("same artefact  : ", abspath(path) == abspath(target))
println("inside the store: ", startswith(abspath(path), abspath(store_root())),
        "   a machine-level asset, not a per-run download")

# ╔═╡ 9f166500-c806-11f1-8002-235a8db1af94
# ╠═╡
md"""
## The downloader: scratch, then a rename

Every download goes through `download_to_path(url, path; retries = 3, timeout = 600)`, which
writes `<path>.part` beside the destination and **moves it into place only when complete**. Two
consequences worth knowing:

- a cancelled or failed download is never mistaken for a finished artefact — the `.part` file is
  recognisable and removable;
- a large archive never lands in the OS temp directory, which matters when the target is a
  multi-gigabyte tidal atlas and the temp volume is small.
"""

# ╔═╡ 9f166500-c806-11f1-bea5-cb95a4376473
# ╠═╡
md"""
## Bathymetry: a named source wins, coverage decides otherwise

`preferred_bathymetry_source(; source, lon_range, lat_range)` resolves which sea floor to use,
by these rules:

1. **A named source wins.** `"etopo2022"`, `"scotian_shelf"`, `"nwa"` — substituting a different
   product behind the operator's back is exactly the silent substitution this package refuses. An
   unrecognised spelling is an error listing every accepted alias.
2. **Otherwise, coverage decides.** A domain lying entirely inside a regional source's soundings
   gets that source: on this shelf the CHS soundings are *survey measurements* of the shelf being
   modelled, while ETOPO is a global model that happens to include it.
3. **Otherwise `:etopo`.** It is modelled and global, so a request for it cannot fail for want of
   data.

`source = nothing`, `""` or `"auto"` all mean "you decide" and take step 2. Passing
`lon_range`/`lat_range` as `nothing` skips the coverage test and goes straight to `:etopo`.

Two products, and they are **not the same sea floor**: ETOPO 2022 is a global model at arc-second
resolution; the NW Atlantic soundings are measured. They disagree on the shelf by metres to tens
of metres, and neither is wrong — which is why you pick one per run and record which, rather than
averaging them into a bathymetry that came from nowhere.
"""

# ╔═╡ 9f166500-c806-11f1-84b0-199fa75356d0
# ╠═╡
for (label, lon_r, lat_r) in (("scotian shelf (inside the CHS survey)", (-62.5, -61.5), (45.5, 46.5)),
                              ("mid-Pacific (no regional survey)", (-150.0, -149.0), (20.0, 21.0)),
                              ("global (spans every survey)", (-180.0, 179.0), (-70.0, 70.0)))
    println(rpad(label, 40), " -> ",
            preferred_bathymetry_source(lon_range = lon_r, lat_range = lat_r))
end

println()
println("named \"etopo2022\", any domain    -> ", preferred_bathymetry_source(source = "etopo2022"))
println("named \"scotian_shelf\", any domain-> ", preferred_bathymetry_source(source = "scotian_shelf"))
println("coverage keys declared           -> ", keys(GeoDataSources.BATHYMETRY_COVERAGE),
        " (regional survey); everything else falls to :etopo")

try
    preferred_bathymetry_source(source = "made_up")
catch err
    println("\nunknown name -> error: ", first(split(sprint(showerror, err), "\n")))
end

# ╔═╡ 9f168c10-c806-11f1-a245-97fdf1864dc4
# ╠═╡
md"""
## The coastline: a vector outline, not a grid

`fetch_natural_earth_coastline(; lon_range, lat_range, resolution, output_path, margin_deg)`

- `resolution` is one of `"10m"` (full detail), `"50m"`, `"110m"` (coarse). 10m is what figures
  want; 110m is enough for a mask and downloads a fraction of the bytes.
- `margin_deg = 1.0` widens the bounding box so the shoreline is complete rather than clipped at
  the model edges — a coastline that stops at the domain edge masks land that should be drawn.
- `output_path` is GeoParquet, one row per shoreline segment, each row a `LineString`. A
  `MultiLineString` feature is split into its parts at fetch time, so the reader finds one ring
  per curve.
- The fetcher reuses a cached file unless `force = true`, like every other fetcher here.

The reader, `GeoData.load_coastline_polygons(file)`, turns that file into rings of
`(name, code, lons, lats)` — and dispatches on `GeoInterface.trait`, because the geometry column
comes back as well-known binary and `isa GeoInterface.LineString` never matches it.

The cell below writes its own small coastline instead of downloading one, so it runs offline
while still exercising the real reader.
"""

# ╔═╡ 9f168c10-c806-11f1-bded-df6264ce55d1
# ╠═╡
ring_path = normpath(joinpath("scratch", "notebook_sources", "coastline.parquet"))
mkpath(dirname(ring_path))

# Two features with deliberately different shapes: a closed ring, which encloses, and an open
# polyline, which does not. `is_point_on_land_geodata` skips an open ring rather than guessing
# which side is land, so the answer for the second one is the documented one.
GeoParquet.write(ring_path,
                 DataFrame(id = [1, 2], name = ["cape breton", "glace bay"],
                           code = ["cape_breton", "glace_bay"],
                           geometry = [
                               GeoInterface.LineString([
                                   (-60.3, 46.2), (-60.0, 46.2), (-59.8, 46.0),
                                   (-60.3, 46.0), (-60.3, 46.2)]),
                               GeoInterface.LineString([(-59.9, 46.1), (-59.7, 46.1)])
                           ]), (:geometry,))

rings = load_coastline_polygons(ring_path)
println("rings read from the file: ", length(rings))
for r in rings
    closed = r.lons[1] == r.lons[end] && r.lats[1] == r.lats[end]
    println("  ", rpad(r.name, 14), " code=", rpad(string(r.code), 14),
            "  ", length(r.lons), " vertices, lon ",
            round(extrema(r.lons)[1], digits = 2), "..", round(extrema(r.lons)[2], digits = 2),
            "  closed=", closed)
end

println("\npoint inside the closed ring : ",
        is_point_on_land_geodata(-60.0, 46.1; coastline = [rings[1]]))
println("point outside it             : ",
        is_point_on_land_geodata(-61.5, 46.1; coastline = [rings[1]]))
println("point on the open polyline   : ",
        is_point_on_land_geodata(-59.8, 46.1; coastline = [rings[2]]),
        "   (an open line encloses nothing)")

# What the fetcher itself checks before touching the network.
declared_coast = replace(GeoDataSources.DATA_SOURCES[:coastline].cache,
                         "<store>" => store_root())
println("\nwhere a fetched coastline goes: ", declared_coast)
println("already cached on this machine: ", is_cached(declared_coast))

# ╔═╡ 9f168c10-c806-11f1-8014-9bf982ad1207
# ╠═╡
md"""
## The other sources, and what each is for

| fetcher | what it provides | account? | notes |
|---|---|---|---|
| `fetch_woa23` | monthly mean temperature and salt, optionally O₂ | no | writes a store per variable; `month = 0` picks January, `include_o2` adds oxygen |
| `fetch_open_meteo_winds` | real past weather → wind stress, or the bulk flux terms | no | `bulk_flux = true` carries the surface flux fields as well |
| `fetch_tpxo9_velocity` | the tidal atlas in two forms — amplitude/phase and complex | **yes** | the two readers in the workflow disagree about which they want, so the returned field records which it found |
| `fetch_copernicus_physics_subset` | GLORYS12V1 reanalysis for the open edges and initial hydrography | **yes** | reads `~/.copernicusmarine/credentials` |
| `fetch_nwa_bathymetry` | measured NW Atlantic soundings as a gridded field | no | the alternative to ETOPO's global model |
| `fetch_bottom_temperature`, `fetch_substrate_grainsize` | benthic survey tables | no | tier-1 raw data, shipped inside this package |

The pattern in the options column is the same everywhere: a cache check first, an error naming
every alternative second, and a labelled fallback only when the caller opts in.
"""

# ╔═╡ 9f168c10-c806-11f1-b047-d7445f18ceb8
# ╠═╡
md"""
## Provenance: which bytes produced this result

A run does not just consume data; it records what it consumed.

- **`data_provenance(output_dir)`** writes a record per source: the cache path, whether it was
  present, its size, and its SHA-256. This is deliberately a *separate* file from the resolved
  config: the config records what was *asked for*, and this records what was *actually read*. When
  a run degrades, or a cached artefact is stale, those two diverge — and the divergence is the
  point.
- **`file_digest(path)`** is the SHA-256 of one file.
- **`raw_data_digests()`** returns the digest of each tier-1 raw file shipped with this package,
  which is how a result can state which bytes produced it without committing 130 MB.
- `is_cached` (not `isfile`) is the cache test everywhere, because a Zarr store is a directory.
"""

# ╔═╡ 9f168c10-c806-11f1-aea2-d7b3315aa5db
# ╠═╡
using JSON3

# The record is generated, not written by hand: it hashes what is on disk, so a stale artefact
# shows up as a digest that no longer matches the one recorded earlier.
provenance_dir = normpath(joinpath("scratch", "notebook_sources"))
returned = data_provenance(provenance_dir)
record = JSON3.read(read(returned, String))

present = [String(k) for (k, v) in record.inputs if v.present == true]
println("wrote ", basename(returned))
println("declared sources : ", length(record.inputs))
println("present here      : ", join(sort(present), ", "))
println("absent here       : ",
        join(sort([String(k) for (k, v) in record.inputs if v.present != true]), ", "))

digest = file_digest(ring_path)
println("\ndigest of the ring file : ", digest)
println("digest again            : ", file_digest(ring_path) == digest,
        "   (stable, which is what makes it usable for comparison)")
println("raw files shipped with digests: ", join(keys(raw_data_digests()), ", "))

# One entry in full, to show what a record promises.
entry = record.inputs["bathymetry"]
println("\none record, field by field:")
for f in ("title", "cache", "present", "bytes", "sha256", "license")
    println("  ", rpad(f, 8), " ", getproperty(entry, Symbol(f)))
end

# ╔═╡ 9f168c10-c806-11f1-bf85-4390b53ca5d3
# ╠═╡
md"""
## The catalog and the lakehouse tiers

`GeoDataCatalog` indexes what a project owns and produces. An entry carries a UUID, a short key, a
name, a tier (`:raw`, `:processed`, `:derived`), its variables, spatial and temporal bounds,
lineage (`derived_from`), producer, and a checksum:

- **`geopublish!(catalog, url; key, name, tier, ...)`** registers a *named upstream source*.
- **`geopublish_dataset!(catalog, path; tier, key, name)`** registers a *produced artefact*.
- **`geofetch(catalog, key)`** / `find_datasets(catalog; tier, producer)` look it up again.
- **`lakehouse_path(key; tier, ext)`** is the destination path constructor — **pure**: it never
  creates a directory as a side effect of being asked where something would go.
- **`compute_lakehouse_checksum(path)`** is the SHA-256 of a file *or* a Zarr store, with a schema
  header so a future schema change produces a different digest even for identical content.

The tiers are `lakehouse_tiers() == [:raw, :processed, :derived]`, and the root is
`lakehouse_root_dir()` (from `GEODATA_LAKEHOUSE_ROOT`, defaulting to `~/.geodata`) — which is a
*different* registry from the assimilated-data store above, on purpose: one holds what the
project was **given**, the other what it **produces**.
"""

# ╔═╡ 9f168c10-c806-11f1-bff8-79b1ab040dcc
# ╠═╡
# A small dataset, built the way the GeoData notebook builds one, so the catalogue has a real
# artefact to describe.
crs = GeoData.CoordinateSystem(crs = "EPSG:4326")
dlon = Dimension(name = :lon, size = 6, coords = collect(1.0:6.0), units = "degrees_east",
                 dim_type = GeoData.GeoDataTypes.DIM_SPATIAL)
dlat = Dimension(name = :lat, size = 5, coords = collect(1.0:5.0), units = "degrees_north",
                 dim_type = GeoData.GeoDataTypes.DIM_SPATIAL)
elevation = GeoData.GeoDataset(
    Dict("elevation" => GeoData.GeoArray(
        10.0 .* rand(6, 5), (dlon, dlat), crs, Dict{String, Any}())),
    Dict(:lon => GeoData.GeoArray(collect(1.0:6.0), (dlon,), crs, Dict{String, Any}()),
         :lat => GeoData.GeoArray(collect(1.0:5.0), (dlat,), crs, Dict{String, Any}())),
    Dict(:lon => dlon, :lat => dlat), crs, Dict{String, Any}(), nothing, "synthetic")

cat_dir = normpath(joinpath("scratch", "notebook_sources"))
isdir(cat_dir) || mkpath(cat_dir)
cat_file = joinpath(cat_dir, "catalog.json")
# A fresh catalogue each run, so this cell can be re-run — Pluto re-runs cells constantly. The
# *duplicate* case is checked below rather than avoided: registering the same key twice would
# shadow the earlier entry, and it is an error for that reason.
ispath(cat_file) && rm(cat_file)
artefact = normpath(joinpath(cat_dir, "elevation.nc"))
GeoData.geosave(artefact, elevation; backend = :ncdatasets, overwrite = true)

cat = GeoDataSources.GeoDataCatalog(cat_file; auto_save = true)
uuid = GeoDataSources.geopublish_dataset!(cat, artefact; tier = :processed, key = :shelf_bathy,
                                          name = "Shelf elevation",
                                          variables = ["elevation"], producer = "notebook")
println("registered   : ", uuid)
lpath = GeoDataSources.lakehouse_path(:shelf_bathy; tier = :processed, ext = "zarr")
println("lakehouse dir: ", lpath)
println("nothing created: ", !isdir(lpath),
        "   (lakehouse_path is a path constructor, not mkpath)")

found = GeoDataSources.geofetch(cat, :shelf_bathy)
println("\nread back      : ", found.name, "  tier ", found.tier, "  vars ", found.variables)
println("by tier query  : ", length(GeoDataSources.find_datasets(cat; tier = :processed)), " entry")
println("checksum       : ", GeoDataSources.compute_lakehouse_checksum(artefact))
println("tiers          : ", GeoDataSources.lakehouse_tiers())
println("catalogue root : ", GeoDataSources.lakehouse_root_dir())

try
    GeoDataSources.geopublish_dataset!(cat, artefact; key = :shelf_bathy, name = "Shelf elevation")
catch err
    println("\nsame key again -> ", first(split(sprint(showerror, err), "\n")))
end

# ╔═╡ 9f168c10-c806-11f1-8e9a-27ce8286d453
# ╠═╡
md"""
## Use cases, end to end

**"I have a new domain and need its sea floor."** Call `preferred_bathymetry_source(;
lon_range, lat_range)` and pass the result as the config's source. If it names the regional
survey, check that the domain really is inside the survey's coverage — a domain straddling the
edge is *not* covered, because the part outside would be silently replaced by the global model
and the result would be two products in one field.

**"I need a coastline for a figure."** `fetch_natural_earth_coastline(; lon_range, lat_range,
resolution = "10m")` into `<run>/inputs/coastline.parquet`, then
`load_coastline_polygons(path)` for the rings the land test wants.

**"I want my run reproducible on another machine."** `data_provenance(output_dir)` after the
fetch, and keep the JSON. The digests state which bytes produced the result, without shipping
them.

**"Something is unavailable."** Read the error: it names every alternative and the credentials
needed. Then decide — switch source, add a credentials file, or opt into a labelled fallback with
`strict = false`. What you never do is let the run proceed as though the data were the same one
you asked for.

## Expectations this package holds itself to

- One dispatcher per tier; a config naming an unbuildable source fails at load time.
- No silent substitution: an unavailable source errors, and a fallback requires opt-in and is
  recorded.
- One implementation per fact: a source's tier, cache path, and products live in `DATA_SOURCES`.
- The cache test is `is_cached`, not `isfile`.
- No depth is looked up from elsewhere: depth is either measured or absent.
- Provenance is generated, not written by hand.
- Build output is never committed; only `data/raw/` is versioned.

Design and per-source layout: `GeoDataSources/STORAGE.md`.
"""

# ╔═╡ 9f168c10-c806-11f1-a8a0-2918bf688239
# ╠═1a5f30e2-8d7c-4b21-9604-3f5e9c8a7b11
# ╠═6fa4e8537-d2c1-4a76-eb59-8fbe5cefd077
# ╠═2b60a41f3-9e8d-4c32-a715-4a6f0d9b8c22
# ╠═3c71b5204-a9fe-4d43-b826-5b7a1eac9d33
# ╠═4d82c6315-b0af-4e54-c937-6c8b2fbdae44
# ╠═5e93d7426-c1b0-4f65-da48-7d9c3acebf55
# ╠═70b5f9648-e3d2-4b87-fc6a-9fbe5cefd077
# ╠═81c60a759-f4e3-4c98-ad7b-bcf6dface088
# ╠═92d71b860-a05f-4a09-be8c-cdf7eabfd199
# ╠═a3e82c971-b1a0-4b1a-9f9d-def8bfce2a0a
# ╠═b4f93da82-c2b1-4c2b-aade-ef09cdd03b1b
# ╠═c50a3eb93-d3c2-4c3b-bbef-ff0dcee14c2c
# ╠═d61b4fca4-e4d3-4d4c-ccf0-012def25d3d
# ╠═e72c50db5-f5e4-4e5c-bf11-123faf36e4e
# ╠═f83061ec6-a0f5-4f6e-bf22-234bcf47f5f
# ╠═091720fd7-b1a6-4a06-bf33-345cdf58a6a0
# ╠═1a2831fe8-c2b7-4b17-bf44-456def69b1b1
# ╠═2b3942079-d3c8-4c28-bf55-567efa70c2c2
# ╠═4d5b64291-f5ea-4e4a-bf77-789bca92e4e4
# ╠═61c0e2503-b2d1-4d59-bf99-9abcdef12345
# ╠═72d1f3614-c3e2-4e6a-210c-abdef2345678
# ╠═83e204725-d4f3-4b7c-321d-bcef34567890
# ╠═94f315836-e5a0-4c8d-432e-cdfa456789a1
# ╠═a504426a4f-b1c-4d29-543f-defb567890b2
# ╠═b615540b5a-2c3-4e5a-654f-efbc678901c

# ╔═╡ Cell order:
# ╠═1a5f30e2-8d7c-4b21-9604-3f5e9c8a7b11
# ╠═9f166500-c806-11f1-b470-1d0497e43053
# ╠═9f166500-c806-11f1-b6b2-6d98e9fcf603
# ╠═9f166500-c806-11f1-8177-890a6f9feb11
# ╠═9f166500-c806-11f1-a9bf-d390270f4a24
# ╠═9f166500-c806-11f1-a708-4d2c609c7dd2
# ╠═9f166500-c806-11f1-93ae-992c31c96025
# ╠═9f166500-c806-11f1-afad-49bb6272d9c9
# ╠═9f166500-c806-11f1-bb40-19f0ca30a6f3
# ╠═9f166500-c806-11f1-8bd3-0d4cb6579941
# ╠═9f166500-c806-11f1-90b0-833d41239230
# ╠═9f166500-c806-11f1-a13b-47c6f8dcaa76
# ╠═9f166500-c806-11f1-8530-bb14b1d944d0
# ╠═9f166500-c806-11f1-8002-235a8db1af94
# ╠═9f166500-c806-11f1-bea5-cb95a4376473
# ╠═9f166500-c806-11f1-84b0-199fa75356d0
# ╠═9f168c10-c806-11f1-a245-97fdf1864dc4
# ╠═9f168c10-c806-11f1-bded-df6264ce55d1
# ╠═9f168c10-c806-11f1-8014-9bf982ad1207
# ╠═9f168c10-c806-11f1-b047-d7445f18ceb8
# ╠═9f168c10-c806-11f1-aea2-d7b3315aa5db
# ╠═9f168c10-c806-11f1-bf85-4390b53ca5d3
# ╠═9f168c10-c806-11f1-bff8-79b1ab040dcc
# ╠═9f168c10-c806-11f1-8e9a-27ce8286d453
# ╠═9f168c10-c806-11f1-a8a0-2918bf688239
