### Script for generating ECDF curves for GDD_0 in Mojave Basin and Range - NON-FOREST only
### GDD_0 (Growing Degree Days, base 0) is calculated as (Tmax + Tmin) / 2
###
### Configuration:
### - Ecoregion: Mojave Basin and Range (code 14)
### - Variable: GDD_0
### - Non-forest: 27-day rolling sum
### - Forest: N/A (not present in Mojave Basin)

source("./src/retrospective/03_analysis/dryness_roc_analysis.R")

## 1. Load the MTBS fire data and filter for Mojave Basin and Range non-forest
mtbs_polys_veg <- st_read("./data/mtbs_polys_plus_cover_ecoregion.gpkg")

mojave_non_forest_polys <- mtbs_polys_veg %>%
  filter(
    US_L3CODE == 14,
    maj_veg_cl == "non_forest",
    !(Event_ID %in% bad_sites)
  )

message(glue("Mojave Basin and Range Non-Forest: {nrow(mojave_non_forest_polys)} fire events"))

## 2. Prepare the climate data for that specific subset
mojave_non_forest_climate <- prepare_climate_data_for_ecoregion(
  mtbs_polys = mojave_non_forest_polys,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 3. Calculate GDD_0 from tmax and tmin
# NOTE: If your climate data already has GDD_0 column from retrospective analysis, skip this step
if (!"GDD_0" %in% names(mojave_non_forest_climate)) {
  message("Calculating GDD_0 = (tmax + tmin) / 2...")

  # Check if tmax and tmin columns exist
  if (!all(c("tmax", "tmin") %in% names(mojave_non_forest_climate))) {
    stop(
      "ERROR: Climate data must have 'tmax' and 'tmin' columns to calculate GDD_0.\n",
      "Please ensure temperature data was extracted during data preparation."
    )
  }

  mojave_non_forest_climate$GDD_0 <- (mojave_non_forest_climate$tmax + mojave_non_forest_climate$tmin) / 2
} else {
  message("GDD_0 column already exists in climate data. Using existing values.")
}

## 4. Generate the ECDF function using GDD_0 with 27-day rolling SUM
message("Generating ECDF for GDD_0 (non-forest, 27-day rolling sum)...")

# IMPORTANT: GDD_0 is a flux variable (uses rolling SUM, not mean) like CWD
# Add GDD_0 to flux_vars so it uses my_percent_rank() for zero-inflated data
flux_vars_with_gdd <- c(flux_vars, "GDD_0")

gdd_non_forest_ecdf <- generate_ecdf(
  climate_data = mojave_non_forest_climate,
  var_name = "GDD_0",
  window = 27,
  flux_vars = flux_vars_with_gdd,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 5. Plot and save the ECDF
message("Plotting and saving non-forest ECDF...")
dir.create("./data/ecdf/14-mojave_basin_and_range-non_forest", showWarnings = FALSE, recursive = TRUE)

png("./data/ecdf/14-mojave_basin_and_range-non_forest/14-mojave_basin_and_range-non_forest-27-GDD_0-ecdf.png",
  width = 800, height = 600
)
plot(gdd_non_forest_ecdf, main = "27-day GDD_0 ECDF for Mojave Basin and Range Non-Forest")
dev.off()

saveRDS(gdd_non_forest_ecdf, "./data/ecdf/14-mojave_basin_and_range-non_forest/14-mojave_basin_and_range-non_forest-27-GDD_0-ecdf.RDS")
message("✓ Non-forest ECDF saved")

message("========================================")
message("ECDF generation complete!")
message("========================================")
message("Output files:")
message("  - data/ecdf/14-mojave_basin_and_range-non_forest/14-mojave_basin_and_range-non_forest-27-GDD_0-ecdf.RDS")
message("  - data/ecdf/14-mojave_basin_and_range-non_forest/14-mojave_basin_and_range-non_forest-27-GDD_0-ecdf.png")
message("")
message("Note: Mojave Basin and Range has no forest cover, so no forest eCDF is generated.")
