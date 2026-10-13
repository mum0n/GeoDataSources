# Central GeoData storage (the lakehouse)

All products `GeoDataSources` assimilates — bathymetry (`etopo2022`, `nwa_bathymetry`),
coastline, surface winds, `woa23`, `glorys`/`copernicus` boundary physics, `tpxo9` tides,
and the bundled tier-1 products — are kept in **one central, shared registry** rather than
in each run's private `outputs/<scenario>/inputs/`. A dataset is fetched once per machine
and reused across scenarios, regions and the two modelling halves.

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
registry. `RAW_DATA_DIR`, `INGESTED_DATA_DIR`, `DISCRETIZED_DATA_DIR` (biodata.jl) and the
RegionalCube output default all resolve through `store_root()`, and the assimilation scripts
(`assimilate_cube.jl`, `fetch_inputs.jl`, the tier-1 readers) write there. The package's old
`data/` directory was the temporary home while the workflow was being built.

## Where the location is set

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

## How it is reached (store-first, then download)

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

## Machine-wide data location

`store_root()` is the *in-project* registry. NumericalEarth additionally caches its global
ETOPO tile under the Julia depot (`~/.julia/scratchspaces/<NumericalEarth uuid>/ETOPO/`);
`bathymetry_field(:etopo)` prefers `store_path("etopo")` and falls back to that scratch copy.
To make the central copy primary, drop a covering tile into `lakehouse/GeoData/etopo/`.

## Relocating existing stores

Run about as a one-liner in the store `default_storage.toml`; existing copies under
`ParticleTracking/inputs`, `…/work/*/inputs` were deduplicated into the central store, and
each reader now resolves the central copy first, so stale run-local copies can be deleted.
