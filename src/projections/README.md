# Sierra Nevada Fire Danger Projections

Pipeline for applying the pyrome-fire eCDF fire danger model to MACA CMIP5
climate projections over the Sierra Nevada ecoregion (ID 5).

**Current predictor configuration** (from ROC analysis):
- Forest: 3-day rolling mean VPD
- Non-forest: 17-day rolling mean VPD

Non-forest originally used GDD_15 (26-day sum) but switched to VPD to avoid
NA pixels at high-elevation cells where historical GDD_15 was always zero.

## Grid handling — MACA vs gridMET

MACA v2 metdata is bias-corrected to gridMET statistics at 1/24° CONUS, but
its coordinate variables sit on a grid whose cell centers are offset ~611 m
(~0.13 cell width) west of gridMET's. CFSv2 metdata and gridMET share their
grid exactly, so the gridMET-native quantile raster is used unchanged by
both the operational CFSv2 forecast pipeline and the MACA projection
pipeline (one canonical artifact).

`project_fire_danger.R` remaps MACA daily VPD onto the gridMET grid with
nearest-neighbor resampling before percentile binning. This preserves raw
MACA values (no bilinear blending) while absorbing the rigid ~0.13-cell
offset; the ~611 m sub-pixel registration uncertainty is inherent to the
MACA/gridMET grid mismatch. The offset is a long-standing property of
MACA v2 metdata, verified against both the aggregated and per-year
products on thredds.northwestknowledge.net and against a MACA download
from November 2023.

## Prerequisites

1. **gridMET historical data** at `$THREDDS_ROOT/gridmet/` (vpd, tmmx, tmmn)
2. **MACA v2 downloads** at `$THREDDS_ROOT/data/MACA/sien/forecasts/daily/`
   (120 files: 20 GCMs × 2 scenarios × 3 vars)
3. **Ecoregion shapefile** at `data/us_eco_l3/us_eco_l3.shp`
4. **MTBS fire polygons** at `data/mtbs_polys_plus_cover_ecoregion.gpkg`
5. **LANDFIRE classified cover** at `data/classified_cover/ecoregion_5_classified.tif`

All commands run in the `wildfire-forecast` podman container. Rebuild after any
code changes: `podman build -t wildfire-forecast .`

`THREDDS_ROOT` is the local directory where bulk climate data files live —
gridMET historical NetCDFs, NPSWB historical NetCDFs, and MACA v2 projection
inputs/outputs. These datasets total ~150 GB for this pipeline alone, so the
directory typically sits on external or network storage. All scripts read
this env var and default to `/media/steve/THREDDS` if unset; override it (and
bind-mount the matching path into the container) to point at a different mount.

## Pipeline Steps

### 1. Generate quantile rasters (one-time, ~10 min)

Produces historical percentile breakpoints from gridMET for binning projected
values. Uses `round(1)` → `subst(0, NA)` → dedup preprocessing to match the
eCDF training path.

```bash
podman run --rm \
  -v $(pwd)/data:/app/data \
  -v "${THREDDS_ROOT:-/media/steve/THREDDS}:${THREDDS_ROOT:-/media/steve/THREDDS}" \
  -e THREDDS_ROOT="${THREDDS_ROOT:-/media/steve/THREDDS}" \
  wildfire-forecast Rscript src/retrospective/05_quantiles/save_quantiles_sierra_nevada.R
```

Outputs:
- `data/ecdf/5-sierra_nevada-forest/5-sierra_nevada-forest-3-VPD-quants.nc`
- `data/ecdf/5-sierra_nevada-non_forest/5-sierra_nevada-non_forest-17-VPD-quants.nc`

### 2. Generate eCDF models (one-time, ~5 min)

The forest eCDF already exists. Generate the non-forest VPD eCDF:

```bash
podman run --rm \
  -v $(pwd)/data:/app/data \
  wildfire-forecast Rscript src/retrospective/04_model_generation/generate_ecdf_sierra_nevada_nonforest_vpd.R
```

Outputs:
- `data/ecdf/5-sierra_nevada-non_forest/5-sierra_nevada-non_forest-17-VPD-ecdf.RDS`

### 3. Precompute rolled MACA variables (~30-60 min for all 40 combos)

Uses CDO to compute rolling means/sums on raw MACA downloads. Output files are
~600 MB each, compressed.

```bash
bash src/projections/precompute_rolled_vpd.sh
```

Per GCM/scenario, produces (in `$THREDDS_ROOT/data/MACA/sien/forecasts/daily/`):
- `vpd_rolled_3_<MODEL>_<SCENARIO>_2006-2099_daily_sien.nc` (forest)
- `vpd_rolled_17_<MODEL>_<SCENARIO>_2006-2099_daily_sien.nc` (non-forest)
- `gdd15_rolled_26_<MODEL>_<SCENARIO>_2006-2099_daily_sien.nc` (legacy, can ignore)

### 4. Run fire danger projections (~4 h per GCM/scenario, parallelize)

For a single GCM/scenario:

```bash
podman run --rm \
  -v $(pwd)/data:/app/data \
  -v "${THREDDS_ROOT:-/media/steve/THREDDS}:${THREDDS_ROOT:-/media/steve/THREDDS}" \
  -e THREDDS_ROOT="${THREDDS_ROOT:-/media/steve/THREDDS}" \
  wildfire-forecast Rscript src/projections/project_fire_danger.R BNU-ESM rcp45
```

For all 40 combos with 4-way parallelism (safe default on a 128 GB box):

```bash
bash src/projections/run_projections.sh --parallel 4
```

Outputs per year (in `$THREDDS_ROOT/data/MACA/sien/projections/<MODEL>/<SCENARIO>/`):
- `<YEAR>_fire_danger_forest.nc` — daily forest fire danger (4km NetCDF, ~1 MB)
- `<YEAR>_fire_danger_non_forest.nc` — daily non-forest fire danger (4km NetCDF, ~1 MB)

Scripts skip years where output files already exist — safe to stop and resume.

### 5. Compute days-above-threshold summaries (~5 min/year, parallelize)

Combines forest/non-forest at 30m LANDFIRE resolution using classified cover:

```bash
podman run --rm \
  -v $(pwd)/data:/app/data \
  -v "${THREDDS_ROOT:-/media/steve/THREDDS}:${THREDDS_ROOT:-/media/steve/THREDDS}" \
  -e THREDDS_ROOT="${THREDDS_ROOT:-/media/steve/THREDDS}" \
  wildfire-forecast Rscript src/projections/compute_thresholds.R BNU-ESM rcp45
```

Optional year range: `... compute_thresholds.R BNU-ESM rcp45 2050 2099`

Outputs per year: `<YEAR>_days_above_thresholds.tif` (30m GeoTIFF, ~15 MB, 4 threshold layers)

## Resource Requirements

- **RAM**: ~9 GB RSS per process (measured on Sierra Nevada ecoregion after
  the nearest-neighbor MACA→gridMET remap was added). Safe ceiling on a
  128 GB box is ~10 parallel; the older "~3-6 GB, 16 parallel" figure in
  prior revisions of this doc was pre-remap and no longer applies.
  `--parallel 4` uses ~36 GB and leaves headroom for other work.
- **CPU**: 1 core per process
- **Disk**: ~150 GB total (raw MACA + rolled + projections + thresholds)
- **Wall time**: ~4 h per GCM/scenario × 40 combos ÷ N parallel workers.
  `--parallel 4` → ~1.7 days; `--parallel 10` → ~16 h. Parallelism can be
  raised mid-run — the skip logic preserves completed years, so the worst
  case on restart is losing each worker's in-flight year (~2.5 min each).

## Monitoring Running Jobs

```bash
# Check running containers
podman ps

# Check specific container logs
podman logs --tail 20 <CONTAINER_ID>

# Check downloaded output files
ls -lh $THREDDS_ROOT/data/MACA/sien/projections/<MODEL>/<SCENARIO>/
```

## Stopping and Resuming

Kill containers with `podman stop <ID>`. The skip logic in both
`project_fire_danger.R` and `compute_thresholds.R` will pick up where it left
off on the next run — any fully-written output file is considered done.
