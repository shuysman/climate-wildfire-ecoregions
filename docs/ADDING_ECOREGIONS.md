# Adding a New Ecoregion to the Forecast System

This guide walks through the data artifacts required to onboard a new US EPA
Level III ecoregion into the daily forecast pipeline, and shows which artifacts
are already pre-generated in the repo vs. which you need to build yourself.

For the full AWS/deployment path once the artifacts exist, see
`MULTI_ECOREGION_DEPLOYMENT.md`. This document is only about producing the
per-ecoregion data artifacts that the forecast pipeline consumes.

## Overview — the three artifacts

For each `(ecoregion, cover_type)` combination you need three things before
the operational forecast script will run:

| # | Artifact | File location | Purpose |
|---|----------|---------------|---------|
| 1 | Classified cover raster | `data/classified_cover/ecoregion_<ID>_classified.tif` | Forest (2) / non-forest (1) mask at LANDFIRE resolution |
| 2 | eCDF model | `data/ecdf/<ID>-<name>-<cover>/<ID>-<name>-<cover>-<WINDOW>-<VAR>-ecdf.RDS` | Maps dryness-percentile → fire-danger percentile |
| 3 | Quantile raster | `data/ecdf/<ID>-<name>-<cover>/<ID>-<name>-<cover>-<WINDOW>-<VAR>-quants.nc` | 1st–100th percentile lookup of the chosen predictor at each grid cell |

Naming convention: `<ID>` is the US_L3CODE (integer), `<name>` is a lowercased
slug with underscores (e.g. `middle_rockies`), `<cover>` is `forest` or
`non_forest`, `<WINDOW>` is the rolling-window length in days, and `<VAR>` is
the predictor variable in uppercase (e.g. `VPD`, `FM1000INV`, `GDD_0`).

## Choosing a predictor first

Before generating artifacts 2 and 3, you need to know the `(variable, window,
cover)` combination you are building for. Two cases:

- **You trust the batch ROC run.** The retrospective analysis
  (`src/retrospective/03_analysis/dryness_roc_analysis.R`) already ran for
  every ecoregion with ≥20 MTBS fires per cover type and selected the best
  partial-AUC predictor. Those eCDFs are on disk (see the inventory below).
  **Catch:** the best predictor is often one of CWD, PET, AET, SWD, ACCUMSWE,
  RUNOFF — none of which are in the CFSv2 operational forecast pipeline.
  Unless your best predictor is one of `VPD, RD, RAIN, FM100, FM1000, BI, ERC,
  GDD_*`, you will need case #2.

- **You need a different predictor for operational deployment.** Pick the
  best-performing operationally-available predictor from the QC/ROC curves
  (`out/img/roc/<ID>-<name>/` for that ecoregion), then generate fresh eCDF
  and quantile artifacts for that `(variable, window)` pair. See the
  `generate_ecdf_*` and `save_quantiles_*` per-ecoregion scripts for examples.

See `CLAUDE.md` § "Optimal vs Operational Predictors" for the full list of
operationally-available variables.

## Prerequisites

All three artifact scripts run against local input data. Download/prepare
each of these once; they are shared across all ecoregions.

The bulk climate inputs (gridMET historical NetCDFs, NPSWB historical
NetCDFs) typically live on external or network storage because of their
size. Their root directory is configured via the `THREDDS_ROOT` environment
variable, which defaults to `/media/steve/THREDDS` if unset. Override it
(and bind-mount the matching path into the container) to point at a
different mount.

### 1. gridMET historical NetCDFs — needed for quantiles

- **What:** daily gridded weather variables, 1979–present, CONUS, 4 km.
- **Where:** `$THREDDS_ROOT/gridmet/` (defaults to `/media/steve/THREDDS/gridmet/`;
  override by setting the `THREDDS_ROOT` env var).
- **How to obtain:** `bash src/retrospective/01_data_extraction/download_gridmet.sh`
  (edits `OUT_DIR` at the top; it `wget`s from northwestknowledge.net).
- **Which variables:** only the predictor you picked is strictly required for
  quantiles. `tmmx` and `tmmn` are required for any `GDD_*` predictor.

### 2. LANDFIRE EVT raster — needed for classified cover

- **What:** `LC23_EVT_240.tif`, ~9 GB, 30 m existing vegetation type raster.
- **Where:** `data/LF2023_EVT_240_CONUS/Tif/4326/LC23_EVT_240.tif`
- **How to obtain:** download from <https://landfire.gov/evt.php> (LANDFIRE
  2023, EVT, CONUS) and unzip into `data/`. The 4326-reprojected copy in
  `Tif/4326/` is what `pregenerate_cover.R` expects.

### 3. EPA Level III ecoregion shapefile — needed for all three

- **What:** `us_eco_l3.shp` with `US_L3CODE` and `US_L3NAME` fields.
- **Where:** `data/us_eco_l3/us_eco_l3.shp` (already checked into `data/`).
- **How to obtain:** <https://www.epa.gov/eco-research/ecoregions-north-america>
  (US Level III). Already present.

### 4. MTBS polygons + cover + ecoregion join — needed for eCDF training

- **What:** `data/mtbs_polys_plus_cover_ecoregion.gpkg` — MTBS fire polygons
  with `maj_veg_cl` (forest/non_forest) and `US_L3CODE` columns joined in.
- **How to obtain:** run
  `Rscript src/retrospective/01_data_extraction/extract_cover.R`.
  Requires `data/mtbs/mtbs_perims_DD.shp` (download from
  <https://www.mtbs.gov/>, unzip `mtbs_perimeter_data.zip`) plus the
  LANDFIRE raster and ecoregion shapefile above. Output is already checked
  into `data/` for CONUS through the last MTBS release.

### 5. Long-format gridMET + NPSWB parquet files — needed for eCDF training

- **What:** `data/gridmet_long_data.parquet` (7.9 GB) and
  `data/npswb_long_data.parquet` (4.9 GB) — per-MTBS-event daily climate
  timeseries. Consumed by `prepare_climate_data_for_ecoregion()` in
  `dryness_roc_analysis.R`.
- **How to obtain:**
  - gridMET: `Rscript src/retrospective/01_data_extraction/extract_gridmet.R`
    (needs gridMET NetCDFs from step 1 and `mtbs_perims_DD.shp`).
  - NPSWB: `Rscript src/retrospective/01_data_extraction/extract_npswb.R`
    (needs NPS water balance v2 historical NetCDFs at
    `$THREDDS_ROOT/daily_or_monthly/v2_historical/`).
- **Bad-sites blacklist:** `data/bad_sites.txt` is generated by
  `src/retrospective/02_data_qc/data_qc.R` from the two parquet files above.
  Already present.

Both parquet files are too large for git — see `CLAUDE.md` § "Important
Gotchas". They are required only if you need to retrain an eCDF; cover-raster
and quantile-raster generation do not use them.

## Artifact 1 — classified cover raster

**Already pre-generated for every CONUS Level III ecoregion.** Check
`data/classified_cover/ecoregion_<ID>_classified.tif` — the repo ships rasters
for every `US_L3CODE` that `pregenerate_cover.R` found in the shapefile.

If you ever need to regenerate (e.g. LANDFIRE version bump):

```bash
podman run --rm \
  -v $(pwd)/data:/app/data \
  wildfire-forecast Rscript src/retrospective/01_data_extraction/pregenerate_cover.R
```

The script skips any `ecoregion_<ID>_classified.tif` that already exists, so
to force a rebuild delete the target file first. LANDFIRE EVT categories map
to cover classes as: `Tree` → 2 (forest); `Herb`, `Shrub`, `Sparse` → 1
(non_forest); everything else → NA.

Runtime: ~1–10 min per ecoregion depending on size. Output is 30 m GeoTIFF.

## Artifact 2 — eCDF model

The eCDF takes the historical daily percentile of the dryness predictor at
each MTBS fire's ignition date, and turns those percentiles into an empirical
CDF. At forecast time, the pipeline computes today's dryness-percentile at
every grid cell and passes it through this eCDF to get a fire-danger value
in [0, 1].

### What's already generated

The batch retrospective run (`dryness_roc_analysis.R` with
`plan(multisession, workers = 4)`) produced an eCDF for the highest-pAUC10
predictor in every ecoregion/cover with ≥20 fires. Those live at
`data/ecdf/<ID>-<name>-<cover>/<ID>-<name>-<cover>-<WINDOW>-<VAR>-ecdf.RDS`.

Inventory as of this writing — 80+ ecoregion/cover folders populated.
Representative examples, all `.RDS` + matching `.png`:

- `15-northern_rockies-forest-25-CWD-ecdf` (CWD, not operationally forecastable)
- `15-northern_rockies-non_forest-25-CWD-ecdf` (CWD, not operationally forecastable)
- `17-middle_rockies-forest-13-CWD-ecdf` (batch best)
- `17-middle_rockies-forest-15-VPD-ecdf` (operational alternative, hand-generated)
- `20-colorado_plateaus-forest-2-CWD-ecdf` (batch best)
- `20-colorado_plateaus-forest-5-FM1000INV-ecdf` (operational alternative)
- `14-mojave_basin_and_range-non_forest-31-PET-ecdf` (batch best; PET not forecastable)
- `14-mojave_basin_and_range-non_forest-27-GDD_0-ecdf` (operational alternative)

If your target ecoregion folder already contains an eCDF matching the
`(variable, window)` you intend to deploy, skip to artifact 3.

### Generating a new eCDF

Two entry points depending on what you need:

**Option A — custom `(variable, window)` for an existing ecoregion.**
Use `src/retrospective/04_model_generation/generate_ecdf_middle_rockies.R` as a
template. It sources `dryness_roc_analysis.R` for the helper functions
(`prepare_climate_data_for_ecoregion`, `generate_ecdf`), filters
`mtbs_polys_plus_cover_ecoregion.gpkg` by `US_L3CODE` and `maj_veg_cl`, drops
`bad_sites`, and calls `generate_ecdf(..., var_name, window, ...)`. Save the
output as
`data/ecdf/<ID>-<name>-<cover>/<ID>-<name>-<cover>-<WINDOW>-<VAR>-ecdf.RDS`.

Examples for reference:

- Plain variable (VPD): `generate_ecdf_middle_rockies.R` (middle_rockies VPD).
- Inverted variable (FM1000 → FM1000INV): `generate_ecdf_fm1000.R` shows the
  pattern — subtract from 100 **before** calling `generate_ecdf`, and add the
  inverted column to `state_vars_no_floor` so it gets the right
  percent-rank treatment (no floor, no zero-substitution).
- Flux variable with rolling sum (GDD_0): `generate_ecdf_mojave_gdd.R` —
  compute the column (from tmax/tmin) if absent, and pass it through
  `flux_vars` so `my_percent_rank()` does the zero-inflated handling.

**Option B — rerun the full batch ROC analysis for a brand-new ecoregion.**
Only needed if the ecoregion is outside what the batch run covered. Edit
`ecoregions` in `dryness_roc_analysis.R` (it reads
`data/ecoregion_cover_counts.csv` and filters `n >= min_cover`), confirm your
target ecoregion is in that CSV with sufficient fires, and run the script.
It writes `ecdf.RDS` + `ecdf.png` + per-window ROC plots to
`out/img/roc/<ID>-<name>/` and `data/ecdf/<ID>-<name>-<cover>/`.

Runtime: seconds to a few minutes per `(ecoregion, cover, window)` in option
A; hours for a full option-B batch run (31 windows × all ecoregions × 4
parallel workers, ~25 GB RAM each).

### `my_percent_rank` vs `dplyr::percent_rank` — which one your variable uses

This matters because the quantile raster in artifact 3 must use the same
percentile convention as the eCDF training data, or the lookup will be
wrong. See `dryness_roc_analysis.R:99-113`:

- **`my_percent_rank`** — rounds to 1 decimal, treats zeros as NA, uses
  unique values only. Applied to `flux_vars` (AET, CWD, PET, RAIN, RUNOFF,
  GDD_0/5/10/15) and `state_vars` (RD, VPD, SWD, ACCUMSWE, BI, ERC).
- **`dplyr::percent_rank`** — plain rank-based percentile, no floor, no
  rounding. Applied to `state_vars_no_floor` (FM100, FM1000, and by
  convention anything inverted like FM1000INV).

Match this in your quantile script (artifact 3 below).

## Artifact 3 — quantile raster

The quantile raster is a per-cell lookup of the 1st–100th percentile of the
rolled predictor at each gridMET cell within the ecoregion. At forecast
time, the pipeline compares today's rolled predictor value to these layers
to derive a percentile without having to re-rank the entire historical
record. 100 bands per file, written with `writeCDF(..., split = TRUE)`.

### What's already generated

Only a handful of quantile rasters are checked in — one per operationally-
deployed `(ecoregion, cover, variable, window)`. As of this writing:

| Ecoregion | Cover | Variable | Window | Script |
|-----------|-------|----------|--------|--------|
| 5 Sierra Nevada | forest | VPD | 3 | `save_quantiles_sierra_nevada.R` |
| 5 Sierra Nevada | non_forest | GDD_15 | 26 | `save_quantiles_sierra_nevada.R` |
| 14 Mojave Basin and Range | non_forest | GDD_0 | 27 | `save_quantiles_mojave_gdd.R` |
| 17 Middle Rockies | forest | VPD | 15 | `save_quantiles_middle_rockies.R` |
| 17 Middle Rockies | non_forest | VPD | 5 | `save_quantiles_middle_rockies.R` |
| 20 Colorado Plateaus | forest | FM1000INV | 5 | `save_quantiles_colorado_plateaus.R` |
| 20 Colorado Plateaus | non_forest | VPD | 27 | `save_quantiles_colorado_plateaus.R` |
| 21 Southern Rockies | forest | FM1000INV | 5 | `save_quantiles_southern_rockies.R` |
| 21 Southern Rockies | non_forest | FM1000INV | 1 | `save_quantiles_southern_rockies.R` |

**Unlike the eCDFs, quantile rasters were *not* generated by the batch run
— they must be produced explicitly per ecoregion.** Any new operational
deployment needs fresh quantiles.

### Generating a new quantile raster

Copy `save_quantiles_middle_rockies.R` (middle_rockies VPD) or the closest
per-ecoregion script and adapt:

```bash
podman run --rm \
  -v $(pwd)/data:/app/data \
  -v "${THREDDS_ROOT:-/media/steve/THREDDS}:${THREDDS_ROOT:-/media/steve/THREDDS}" \
  -e THREDDS_ROOT="${THREDDS_ROOT:-/media/steve/THREDDS}" \
  wildfire-forecast Rscript src/retrospective/05_quantiles/save_quantiles_<your_ecoregion>.R
```

Key points when adapting a script:

1. **Filter the ecoregion shapefile** to your `US_L3NAME`, crop/mask the
   gridMET raster to that polygon.
2. **Rolling window type must match the variable class** in
   `dryness_roc_analysis.R`:
   - State variables (VPD, RD, BI, ERC, etc.) → `terra::roll(..., fun = mean)`
   - Flux variables (CWD, RAIN, GDD_*, PET) → `terra::roll(..., fun = sum)`
   - Window of 1 → skip `roll()` entirely, use the raw data.
3. **Preprocessing must match the percent-rank function:**
   - `my_percent_rank` variables: `round(digits = 1) %>% subst(0, NA) %>% app(replace_duplicated)` before `quantile()`.
   - `dplyr::percent_rank` variables (FM100, FM1000, FM1000INV): **no** rounding, **no** zero-substitution, **no** duplicate removal.
4. **Inverted variables** (FM1000INV): subtract the raw gridMET values from
   100 before any rolling or quantile step.
5. **Derived variables** (GDD_0/5/10/15): compute from tmmx + tmmn (both
   Kelvin in gridMET) before rolling. See `save_quantiles_mojave_gdd.R`:
   `(tmmx + tmmn) / 2 - 273.15`, then `clamp(..., lower = 0)`.
6. **Probabilities:** `probs <- seq(.01, 1.0, by = .01)` — keep this
   constant; the forecast-time lookup assumes 100 percentile layers.
7. **Output path:** `data/ecdf/<ID>-<name>-<cover>/<ID>-<name>-<cover>-<WINDOW>-<VAR>-quants.nc`,
   written with `writeCDF(..., overwrite = TRUE, split = TRUE)`.

Runtime: 5–15 min per cover/window on a 128 GB machine with `memfrac = 0.9`.
Larger ecoregions (Colorado Plateaus, Sierra Nevada) can push 30 min.

## After the artifacts exist

1. Add the ecoregion block to `config/ecoregions.yaml` with the correct
   `id`, `name_clean`, `variable`, `window`, `gridmet_varname`, and park
   list. Start with `enabled: false` until you've smoke-tested locally.
2. Smoke-test: `ECOREGION=<name_clean> bash src/operational/pipeline/daily_forecast.sh`.
3. Upload `data/ecdf/<folder>/`, `data/classified_cover/ecoregion_<ID>_classified.tif`,
   and the updated `config/ecoregions.yaml` to S3 (see
   `MULTI_ECOREGION_DEPLOYMENT.md` § "AWS Deployment").
4. Flip `enabled: true` and push the config to S3.
