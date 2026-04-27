## Generate eCDF for Sierra Nevada non-forest using VPD 17-day mean
## Switching from GDD_15 to VPD to avoid NA pixels at high-elevation cells

source("./src/retrospective/snapshot_config.R")
source("./src/retrospective/03_analysis/dryness_roc_analysis.R")

mtbs_polys_veg <- st_read("./data/mtbs_polys_plus_cover_ecoregion.gpkg")

sierra_nevada_non_forest_polys <- mtbs_polys_veg %>%
  filter(
    US_L3CODE == 5,
    maj_veg_cl == "non_forest",
    !(Event_ID %in% bad_sites)
  )

sierra_nevada_climate <- prepare_climate_data_for_ecoregion(
  mtbs_polys = sierra_nevada_non_forest_polys,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

vpd_ecdf <- generate_ecdf(
  climate_data = sierra_nevada_climate,
  var_name = "VPD",
  window = 17,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## Save
out_dir <- "./data/ecdf/5-sierra_nevada-non_forest"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

saveRDS(vpd_ecdf, file.path(out_dir, "5-sierra_nevada-non_forest-17-VPD-ecdf.RDS"))
message("Saved eCDF to ", file.path(out_dir, "5-sierra_nevada-non_forest-17-VPD-ecdf.RDS"))

## Plot
png(file.path(out_dir, "5-sierra_nevada-non_forest-17-VPD-ecdf.png"), width = 800, height = 600)
curve(vpd_ecdf(x), from = 0, to = 1, main = "Sierra Nevada Non-Forest: VPD 17-day Mean eCDF",
      xlab = "Percentile", ylab = "Fire Danger", lwd = 2)
dev.off()
message("Saved plot")
