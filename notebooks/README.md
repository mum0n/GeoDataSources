# Notebooks

Notebooks for the acquisition layer: what gets fetched, where it is cached, and how a result
proves which bytes produced it.

| Notebook | What it covers |
|---|---|
| [`data_sources.jl`](data_sources.jl) | the central assimilation store and how to move it; tiers; the declared registry and what each source costs; `fetch_input` and the cache-first rule; the downloader's atomic write; bathymetry source selection; the coastline fetcher and its reader; provenance; the catalogue and lakehouse tiers. |

Pluto notebooks: `.jl` files in Pluto's own format, with `md"""..."""` cells between the code.
Every cell documents the options it passes and the use case it serves, and the errors it shows on
purpose (an unbuildable source, an unknown bathymetry name, a duplicate catalogue key) are the
package's contract, not defects.

## Running them

Pluto is deliberately **not** a dependency of this package: a notebook is how you look at the
work, not something the run needs. Launched from the package directory, `Pkg.activate(@__DIR__)`
inside the first cells pins the notebook to this package's environment:

```
julia --project=. -e 'using Pluto; Pluto.run()'
```

then open the file from the notebook list. The first cells also `cd` to the package root, so
`../lakehouse/...` resolves to `projects/lakehouse/` rather than to a directory inside the
package.

## What the notebook reads

The **central store** it reports on is read-only: it lists what your machine has cached, and
fetches exactly one source — `:bathymetry` — which is served from the store rather than the
network when the store holds it. If your store does not, that cell names a source in the registry
table that it does, and the rest of the notebook still runs.

Everything the notebook writes goes under `scratch/`, which is git-ignored. Writing to the
lakehouse is a fetcher's job, and the one call that could do it is the cache-first one, which
does not download when the artefact is already there.
