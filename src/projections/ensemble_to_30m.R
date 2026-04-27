## Resample 4km cross-GCM ensemble stat NetCDFs (from compute_period_ensemble.sh)
## to 30m and combine forest/non-forest via the LANDFIRE classified cover.
##
## Inputs (per scenario, period):
##   <ens_root>/<scenario>/4km/<period>_ens_<stat>_forest.nc
##   <ens_root>/<scenario>/4km/<period>_ens_<stat>_non_forest.nc
##   for stat in {mean, median, q25, q75}; each has 4 vars (days_above_50/75/90/95).
##
## Outputs (per scenario, period, stat — 4 bands per file, one per threshold):
##   <ens_root>/<scenario>/<period>_ensemble_<stat>_days_above_thresholds.tif
##
## Process one (cover, stat) pair at a time so peak RSS stays bounded — only
## one 4-band 30m raster per cover is held resident, plus the lapp temporary.
##
## Usage: Rscript ensemble_to_30m.R <scenario> <period_name>

library(terra)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript ensemble_to_30m.R <scenario> <period_name>")
}
scenario    <- args[1]
period_name <- args[2]

start_time <- Sys.time()
terraOptions(verbose = FALSE, memfrac = 0.5)

ecoregion_id    <- 5
thredds_root    <- Sys.getenv("THREDDS_ROOT", "/media/steve/THREDDS")
ens_root        <- file.path(thredds_root, "data/MACA/sien/ensemble_thresholds")
in_dir          <- file.path(ens_root, scenario, "4km")
out_dir         <- file.path(ens_root, scenario)
threshold_names <- paste0("days_above_", c(50, 75, 90, 95))
stats           <- c("mean", "median", "q25", "q75")

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

## Establish CRS template from any 4km ensemble input.
sample_in <- file.path(in_dir, glue("{period_name}_ens_mean_forest.nc"))
if (!file.exists(sample_in)) {
  stop(glue("Missing 4km input {sample_in} — run compute_period_ensemble.sh first."))
}
template <- rast(sample_in, subds = threshold_names[1])

message(glue("Loading classified cover and projecting to MACA grid..."))
classified <- rast(glue("data/classified_cover/ecoregion_{ecoregion_id}_classified.tif"))
classified <- project(classified, crs(template))
forest_mask <- classified == "forest"

read_4band_4km <- function(nc_path) {
  rast(lapply(threshold_names, function(v) rast(nc_path, subds = v)))
}

for (s in stats) {
  out_path <- file.path(out_dir,
                        glue("{period_name}_ensemble_{s}_days_above_thresholds.tif"))
  if (file.exists(out_path)) {
    message(glue("  {basename(out_path)}: exists, skipping"))
    next
  }

  forest_in    <- file.path(in_dir, glue("{period_name}_ens_{s}_forest.nc"))
  nonforest_in <- file.path(in_dir, glue("{period_name}_ens_{s}_non_forest.nc"))
  if (!file.exists(forest_in) || !file.exists(nonforest_in)) {
    message(glue("  missing 4km inputs for stat {s}, skipping"))
    next
  }

  s_start <- Sys.time()

  forest_30m    <- resample(read_4band_4km(forest_in),    classified, method = "near")
  nonforest_30m <- resample(read_4band_4km(nonforest_in), classified, method = "near")

  layers <- vector("list", length(threshold_names))
  for (i in seq_along(threshold_names)) {
    layers[[i]] <- lapp(c(forest_30m[[i]], nonforest_30m[[i]], forest_mask),
                       fun = function(f, n, m) ifelse(m == 1, f, n))
  }
  out_rast <- rast(layers)
  names(out_rast) <- paste0(s, "_", threshold_names)

  ## FLT4S since mean / quantiles produce non-integer values.
  writeRaster(out_rast, out_path, overwrite = TRUE, datatype = "FLT4S",
              gdal = c("COMPRESS=DEFLATE", "ZLEVEL=2", "TILED=YES",
                       "BLOCKXSIZE=512", "BLOCKYSIZE=512", "BIGTIFF=IF_SAFER"))

  rm(forest_30m, nonforest_30m, layers, out_rast); gc()

  s_elapsed <- round(as.numeric(difftime(Sys.time(), s_start, units = "secs")), 1)
  message(glue("  wrote {basename(out_path)} ({s_elapsed} s)"))
}

elapsed <- round(as.numeric(difftime(Sys.time(), start_time, units = "mins")), 1)
message(glue("ensemble_to_30m complete: {scenario} {period_name} ({elapsed} min)"))
