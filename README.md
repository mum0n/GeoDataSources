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

### Shared Lakehouse Configuration

`GeoDataSources` assimilates central inputs into a shared lakehouse. The location is
resolved via `GeoData.lakehouse_dir("GeoData")`, which respects the following hierarchy:
* `default_storage.toml` (`[storage] store_root`) if non-empty.
* `ENV["GEODATA_LAKEHOUSE"]` (global override).
* `LocalPreferences.toml` (`[GeoData] lakehouse_dir`).
* `~/.geodata/storage.toml` (`[storage] store_root`).
* Proximity fallback (`projects/lakehouse/GeoData`).

Every downstream package accesses these shared products through `GeoData.lakehouse_dir("GeoData", ...)`.

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

---

## 9. Central GeoData storage (the lakehouse)

All products `GeoDataSources` assimilates — bathymetry (`etopo2022`, `nwa_bathymetry`),
coastline, surface winds, `woa23`, `glorys`/`copernicus` boundary physics, `tpxo9` tides,
and the bundled tier-1 products — are kept in **one central, shared registry** rather than
in each run's private `outputs/<scenario>/inputs/`. A dataset is fetched once per machine
and reused across scenarios, regions and runs.

```
projects/lakehouse/GeoData/
├── etopo/                  ETOPO 2022 relief tiles (read by bathymetry_field(source=:etopo))
├── bathymetry.zarr         <store>/bathymetry.zarr   (ERDDAP etopo via fetch_input)
├── nwa_bathymetry.zarr     <store>/nwa_bathymetry.zarr (from bundled tier-1 raw, gridded)
├── raw/   ingested/   discretized/        the medallion tiers (tier-1/2/3) live here too
├── woa23/                 woa23_temperature|salinity|oxygen_<mm>_0.25deg.nc  (or *.zarr)
├── tpxo9/                 TPXO9-Atlas velocity harmonics
├── glorys/                Copernicus Marine boundary physics
├── surface_winds.zarr     ERA5 surface state (stress, air T, P, humidity, cloud, shortwave)
└── coastline/             clipped Natural Earth linework (also cached as coastline.parquet)
```

Everything here — the fetched products and the medallion tiers — is one shared, machine-level
registry. `RAW_DATA_DIR`, `INGESTED_DATA_DIR`, `DISCRETIZED_DATA_DIR` (`biodata.jl`) and the
RegionalCube output default all resolve through `store_root()`, and the assimilation scripts
(`assimilate_cube.jl`, `fetch_inputs.jl`, the tier-1 readers) write there. The package's old
`data/` directory was the temporary home while the workflow was being built.

### Where the location is set

`GeoDataSources/default_storage.toml`, read **at call time** so an edit takes effect on the
next assimilation without recompiling the package:

```toml
[storage]
store_root = "../lakehouse/GeoData"   # resolved relative to the GeoDataSources package dir
verify_checksum = true                # SHA-256 a download against the manifest
```

The API (`GeoDataSources.store_root()`, `store_path(source)`) resolves `store_root`
relative to the package directory, so a **relative** value is stable no matter which package
calls the fetcher or from what working directory. `GeoDataSources/storage.jl` holds the
loader (`storage_config`, `store_root`, `store_path`); a missing or unparseable file falls
back to the built-in `../lakehouse/GeoData` rather than failing a load.

Relocate the whole registry by editing that one `store_root` — no environment variables, no
recompile.

### How it is reached (store-first, then download)

Every assimilation follows one rule: **look in the central store first; fetch only if
absent.** Both mechanisms resolve through the same `<store>` placeholder → `store_root()`:

- `fetch_input(key, output_dir)` (the manifest dispatch point) substitutes `<store>` in each
  source's declared `cache` template, so every `fetch_input`-based source lands under
  `lakehouse/GeoData/<source>` and a cache hit there is returned before any download.
- `bathymetry_field(source = :etopo)` searches `store_path("etopo")` for a covering tile
  before NumericalEarth's scratch space or a per-run `inputs/ETOPO`.
- The ocean driver resolves WOA23 through its own `_woa_store_locations`, which puts
  `store_path("woa23")` first, and `fetch_open_woa_climatology` writes there.

Per-run, domain-specific artefacts are deliberately **not** centralised, because sharing them
across domains or times is wrong: the regridded `bathymetry_active.nc`, the clipped
`coastline.dat`, the sliced `wind_active.nc` stay in the run's own `inputs/`; the
`hydrodynamics.zarr` store and its checkpoints stay in the run's output directory under
`lakehouse/Geo{Larval,Ocean}Model/…`.

### Machine-wide data location

`store_root()` is the *in-project* registry. NumericalEarth additionally caches its global
ETOPO tile under the Julia depot (`~/.julia/scratchspaces/<NumericalEarth uuid>/ETOPO/`);
`bathymetry_field(:etopo)` prefers `store_path("etopo")` and falls back to that scratch copy.
To make the central copy primary, drop a covering tile into `lakehouse/GeoData/etopo/`.

### Relocating existing stores

Run `store_root` in `default_storage.toml` as a one-liner. Where a machine already holds
run-local copies from before the central store existed, they were deduplicated into the central
store, and each reader now resolves the central copy first — so a stale run-local copy can be
deleted. `data_provenance(output_dir)` records which bytes a run actually read, which is what
distinguishes a legitimate per-domain artefact from a leftover.

---

## 10. Related

- [`GeoData.md`](../GeoData/README.md) — types, backends, coordinate operations, analysis. 