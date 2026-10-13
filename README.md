# GeoDataSources

Dataset acquisition, provenance, and cataloguing for [`GeoData`](../GeoData/GeoData.md).

This package holds everything that touches the network or the filesystem: the fetchers that
obtain physical inputs, the source registry that states how each one is retrieved and under
what licence, the provenance machinery, the medallion catalog, and regional data-cube
assimilation.

`GeoData` re-exports `GeoDataset`, `GeoArray`, `regrid_2d_field`, the land/ocean tests, and
the bathymetry analysis (`@reexport using GeoData`), so `using GeoDataSources` provides
both packages.

---

## 1. The processing chain

```
raw ──► discretized ──► modelled ──► cube
```

Each link is selected by a **tier**, which describes *how the data were produced*, not
which dataset they came from:

| Tier | Meaning |
|---|---|
| `:raw` | the observations as delivered — measured, unmodified, optimal storage |
| `:discretized` | filtered, quality-controlled, and binned onto a resolution chosen per dataset |
| `:modelled` | output of a numerical model or reanalysis (GLORYS, ERA5, TPXO9) |
| `:cube` | assembled multi-variable product plus its lineage |

`fetch_input(key, dir; tier = ...)` dispatches by tier: `:raw`/`:discretized` go to
`FETCHERS`, `:modelled` to `MODELLERS`. The default is the source's declared tier, so
`fetch_input(:bottom_temperature, dir)` returns the raw table and `fetch_input(:glorys, dir)`
returns the reanalysis.

A tier selects the *processing level*, never the *source*: a source is a product (a dataset),
and a tier is how it was made.

---

## 2. Declared sources

`GeoDataManifest.DATA_SOURCES` declares each input with its title, kind, keyless flag,
primary URL, alternatives, cache path, licence, notes, and tier. Twelve are declared:
ten buildable, two unbuildable.

| Key | Tier | Access | Cache |
|---|---|---|---|
| `bottom_temperature` | raw | local (shipped) | `<dir>/inputs/bottom_temperature.zarr` |
| `coastline` | discretized | keyless | `<dir>/inputs/coastline.parquet` |
| `hydrography` | discretized | keyless | `<dir>/inputs/woa23_temperature_<mm>_0.25deg.zarr` |
| `nwa_bathymetry` | discretized | local | `<dir>/inputs/nwa_bathymetry.zarr` |
| `substrate` | discretized | local | `<dir>/inputs/substrate.zarr` |
| `surface_winds` | discretized | keyless | `<dir>/inputs/surface_winds.zarr` |
| `woa23` | discretized | keyless | `<dir>/inputs/woa23_oxygen_<mm>_0.25deg.zarr` |
| `atmosphere` | modelled | keyless | `<dir>/inputs/surface_winds.zarr` |
| `bathymetry` | modelled | keyless | `<dir>/inputs/bathymetry.zarr` |
| `lateral_boundary` | modelled | keyless | `<dir>/inputs/hycom_boundary.nc` |
| `glorys` | modelled | **needs account** | `<dir>/inputs/glorys.zarr` — UNBUILDABLE |
| `tides` | discretized | **needs account** | `<dir>/inputs/tpxo9/u_tpxo9.v1.nc` — UNBUILDABLE |

`glorys` and `tides` are declared but have no fetcher and no modeller. They are reported
rather than hidden:

```julia
buildable(:glorys)                      # false
buildable_sources()                     # the ten that can be requested
data_summary()                          # grouped by tier, with an access column
data_summary(show_alternatives = true)  # plus each source's fallbacks
```

A config naming an unbuildable source fails at **load time**, not hours into a run.

---

## 3. Tier 1 — raw data

Three sources ship inside the package, converted from their delivery formats to compressed
GeoParquet point tables with descriptive names:

| Directory / file | Rows |
|---|---|
| `data/raw/scotian_shelf_bottom_temperature_surveys_1970_2025.parquet` | 442 177 |
| `data/raw/scotian_shelf_substrate_grain_size.parquet` | 714 063 |
| `data/raw/northwest_atlantic_chs_15arcsec_soundings.parquet` | 28 142 338 |

`BIODATA_RAW` maps each source key to its file; `raw_data_digests()` returns the SHA-256 of
each, which is how a result can state which bytes produced it without shipping 130 MB.

```julia
raw_path(:bottom_temperature)
raw_data_digests()[:bottom_temperature]
```

Everything above `data/raw/` is build output and is git-ignored.

---

## 4. Fetching

```julia
path = fetch_input(:bathymetry, "work/run")                       # to its declared tier
path = fetch_input(:hydrography, "work/run"; tier = :raw)         # explicit tier
path = fetch_input(:glorys, "work/run")                           # errors: unbuildable
fetch_input(:coastline, "work/run"; force = true)                 # re-fetch
```

`fetch_input` resolves the declared cache path, returns it if `is_cached` unless `force`,
refuses `:analytic` sources, and calls the tier's fetcher or falls back to a plain download
of `primary`. An unavailable source is an error naming every alternative and the credentials
it needs — never a silent substitution.

The single downloader is `download_to_path(url, path; retries = 3, timeout = 600)`: it
writes `<path>.part` beside the destination and moves it into place only when complete, so a
cancelled download is never mistaken for a finished one, and a large archive never lands in
the OS temp directory. `cache_path(key, output_dir)` is the one convention for where a
cache lives.

Sources with credentials: `glorys` needs a free Copernicus Marine registration and
`~/.copernicusmarine/credentials`. `tides` and `lateral_boundary` may be reached without an
account. `data_summary()` marks which is which; the field is `keyless` in `DATA_SOURCES`.

### Access states reported

`local` — shipped with the package. `keyless` — no account needed, only a connection.
`needs account` — free registration with a credentials file. `UNBUILDABLE` — declared but no
fetcher; requesting it is an error.

---

## 5. Cube configuration

A regional cube is described by a TOML config. The config names the **variables**; where
each comes from is a per-variable choice:

```toml
region_name = "scotian_shelf"
resolution_km = 1.0                      # preferred unit; degrees accepted via resolution_deg

variables = ["temperature", "salinity", "u", "v", "dissolved_oxygen", "bottom_temperature",
             "survey_depth", "elevation", "bottom_depth", "substrate"]

output_path = "data/cubes/scotian_shelf_environmental.zarr"

[sources]
temperature = {source = "hydrography", tier = "discretized"}
salinity    = {source = "hydrography", tier = "discretized"}
u           = {source = "lateral_boundary", tier = "modelled"}
v           = {source = "lateral_boundary", tier = "modelled"}
dissolved_oxygen = {source = "woa23", tier = "discretized"}
bottom_temperature = {source = "bottom_temperature", tier = "raw"}
survey_depth = {source = "bottom_temperature", tier = "raw"}
elevation    = {source = "nwa_bathymetry", tier = "discretized"}
bottom_depth = {source = "nwa_bathymetry", tier = "discretized"}
substrate    = {source = "substrate", tier = "discretized"}

[domain]
lon_min = -71.0
lon_max = -53.0
lat_min = 40.0
lat_max = 48.5
```

`[domain]` is last on purpose: everything after a TOML table header is read as a key *of that
table*, so a scalar key placed after one is silently ignored.

Each `[sources]` entry must name a declared source, a source that is buildable, and a tier
matching the source's declaration. A mismatch between config and manifest is an error at
load time, which is what prevents a cube nobody can explain later.

`variables` are resolved against `DATA_SOURCES`, and the cube is built by
`assimilate_regional_cube(config)`. Each variable is taken from the source its `[sources]`
entry names, restricted to the configured box, and recorded in the cube's `_provenance` as
`(source, tier, product, sha256)`. A variable whose source yields nothing is **left absent**,
never written as a constant.

---

## 6. Catalog

`GeoDataCatalog` is the metadata index for what a project owns and produces.

```julia
catalog = GeoDataCatalog("work/run/catalog.json"; auto_save = true)

uuid = geopublish!(catalog, "https://example.com/obs.nc";
                   key = :noaa_obs, name = "NOAA In-Situ Observations", tier = :raw,
                   variables = ["temp"])

entry = geofetch(catalog, :climate_projections)
results = find_datasets(catalog; tier = :derived, producer = "GeoDataSources")
```

Entries carry a UUID, a short key, a name, a tier, variables, spatial and temporal bounds,
lineage (`derived_from`), producer, access counts, and checksums. The tiers are `:raw`,
`:processed`, `:derived`.

Tier paths for a project's own outputs:

```julia
lakehouse_tiers()                                                 # [:raw, :processed, :derived]
lakehouse_path(:temperature_grid; tier = :processed, ext = "zarr")  # pure: no mkpath
geopublish_dataset!(catalog, path; tier = :derived, key = :kernels, name = "Kernels")
```

`lakehouse_path` is a pure path constructor: it never creates a directory as a side effect
of being asked where something would go.

---

## 7. Expectations

- **One dispatcher per tier.** A config names an unbuildable source → load-time error.
- **No silent substitution.** An unavailable source errors naming every alternative; a
  fallback requires explicit opt-in and is recorded.
- **One implementation per fact.** A source's tier, cache path, and accessible products live
  in `DATA_SOURCES`; the cube's variable-to-source mapping lives in the config.
- **The cache test is `is_cached`, not `isfile`.** A Zarr store is a directory; `isfile`
  reports the two most common cache forms as missing.
- **No depth is looked up from elsewhere.** Depth is either measured or absent.
- **Provenance is generated, not written by hand**: raw file name, SHA-256, source, tier,
  and product per variable, in the artefact's own attributes.
- **Build output is never committed.** Only `data/raw/` (tier 1) is versioned.

---

## 8. Layout

```
GeoDataSources/
  src/
    GeoDataSources.jl      root module: includes and re-exports
    Access/Axis.jl         axis resolution (aliases, ordering, conventions)
    Fetch/Download.jl      the single downloader
    Fetch/copernicus.jl    CMEMS and CDS access
    coastline.jl  bathymetry.jl  winds.jl  woa23.jl  boundary.jl  biodata.jl
    manifest.jl            DATA_SOURCES, FETCHERS, MODELLERS, provenance
    regional_cube.jl       cube config, assembly, and lineage
    catalog.jl             GeoDataCatalog, DatasetEntry
    lakehouse.jl           medallion tiers and checksums
    regrid_utils.jl        slicing helpers for fetched datasets
  configs/regions/*.toml   cube configurations
  scripts/fetch_inputs.jl  fetch and register declared inputs
  scripts/assimilate_cube.jl  build a cube from a config
  default_storage.toml     central assimilation store root (user-editable)
  storage.jl (in src/)     store_root()/store_path() loader
```

Test coverage: 199 assertions.

## Central assimilated-data store

Every product this package fetches or assimilates lands in **one** central, shared registry
— `GeoDataSources/default_storage.toml` sets its `store_root` (default
`../lakehouse/GeoData`, i.e. `projects/lakehouse/GeoData/<source>`), read at call time so
editing that one file relocates the whole registry without a recompile. Each `DATA_SOURCES`
entry declares its cache as `<store>/<source>…`, and `fetch_input` substitutes `<store>` from
`store_root()` — **store first, then download**. Full design, per-source layout, and the
check in [`STORAGE.md`](./STORAGE.md).

## Related

- [`GeoData.md`](../GeoData/README.md) — types, backends, coordinate operations, analysis. 