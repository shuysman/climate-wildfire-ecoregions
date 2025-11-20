### Script for generating ECDF curves for inverted FM1000 in Southern Rockies
### This generates eCDF models for the inverted (100 - FM1000) relationship
### where higher inverted FM1000 = higher fire risk
###
### Configuration:
### - Ecoregion: Southern Rockies (code 21)
### - Variable: FM1000 (inverted to 100 - FM1000)
### - Forest: 5-day rolling mean
### - Non-forest: 1-day (no rolling average)

source("./src/retrospective/03_analysis/dryness_roc_analysis.R")

## 1. Load the MTBS fire data and filter for Southern Rockies forest
mtbs_polys_veg <- st_read("./data/mtbs_polys_plus_cover_ecoregion.gpkg")

southern_rockies_forest_polys <- mtbs_polys_veg %>%
  filter(
    US_L3CODE == 21,
    maj_veg_cl == "forest",
    !(Event_ID %in% bad_sites)
  )

message(glue("Southern Rockies Forest: {nrow(southern_rockies_forest_polys)} fire events"))

## 2. Prepare the climate data for that specific subset
southern_rockies_forest_climate <- prepare_climate_data_for_ecoregion(
  mtbs_polys = southern_rockies_forest_polys,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 3. Invert FM1000 in the prepared data (100 - FM1000)
message("Inverting FM1000 to (100 - FM1000) for correct fire risk relationship...")
southern_rockies_forest_climate$FM1000_inverted <- 100 - southern_rockies_forest_climate$FM1000

## 4. Generate the ECDF function using inverted FM1000
message("Generating ECDF for inverted FM1000 (forest, 5-day window)...")

# IMPORTANT: Add FM1000_inverted to state_vars_no_floor so it gets percentile-ranked
# FM1000 uses dplyr::percent_rank() (no zero-substitution, no rounding)
state_vars_no_floor_with_fm1000inv <- c(state_vars_no_floor, "FM1000_inverted")

fm1000_forest_ecdf <- generate_ecdf(
  climate_data = southern_rockies_forest_climate,
  var_name = "FM1000_inverted",
  window = 5,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor_with_fm1000inv
)

## 5. Plot and save the ECDF
message("Plotting and saving forest ECDF...")
png("./data/ecdf/21-southern_rockies-forest/21-southern_rockies-forest-5-FM1000INV-ecdf.png",
    width = 800, height = 600)
plot(fm1000_forest_ecdf, main = "5-day Inverted FM1000 ECDF for Southern Rockies Forest")
dev.off()

saveRDS(fm1000_forest_ecdf, "./data/ecdf/21-southern_rockies-forest/21-southern_rockies-forest-5-FM1000INV-ecdf.RDS")
message("✓ Forest ECDF saved")

## ============================================================================
## Non-forest
## ============================================================================

southern_rockies_nf_polys <- mtbs_polys_veg %>%
  filter(
    US_L3CODE == 21,
    maj_veg_cl == "non_forest",
    !(Event_ID %in% bad_sites)
  )

message(glue("Southern Rockies Non-forest: {nrow(southern_rockies_nf_polys)} fire events"))

## 2. Prepare the climate data for that specific subset
southern_rockies_nf_climate <- prepare_climate_data_for_ecoregion(
  mtbs_polys = southern_rockies_nf_polys,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 3. Invert FM1000 in the prepared data (100 - FM1000)
message("Inverting FM1000 to (100 - FM1000) for correct fire risk relationship...")
southern_rockies_nf_climate$FM1000_inverted <- 100 - southern_rockies_nf_climate$FM1000

## 4. Generate the ECDF function using inverted FM1000
message("Generating ECDF for inverted FM1000 (non-forest, 1-day window)...")

# IMPORTANT: Add FM1000_inverted to state_vars_no_floor so it gets percentile-ranked
# FM1000 uses dplyr::percent_rank() (no zero-substitution, no rounding)
state_vars_no_floor_with_fm1000inv <- c(state_vars_no_floor, "FM1000_inverted")

fm1000_nf_ecdf <- generate_ecdf(
  climate_data = southern_rockies_nf_climate,
  var_name = "FM1000_inverted",
  window = 1,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor_with_fm1000inv
)

## 5. Plot and save the ECDF
message("Plotting and saving non-forest ECDF...")
png("./data/ecdf/21-southern_rockies-non_forest/21-southern_rockies-non_forest-1-FM1000INV-ecdf.png",
    width = 800, height = 600)
plot(fm1000_nf_ecdf, main = "1-day Inverted FM1000 ECDF for Southern Rockies Non-forest")
dev.off()

saveRDS(fm1000_nf_ecdf, "./data/ecdf/21-southern_rockies-non_forest/21-southern_rockies-non_forest-1-FM1000INV-ecdf.RDS")
message("✓ Non-forest ECDF saved")

message("========================================")
message("ECDF generation complete!")
message("========================================")
message("Output files:")
message("  - data/ecdf/21-southern_rockies-forest/21-southern_rockies-forest-5-FM1000INV-ecdf.RDS")
message("  - data/ecdf/21-southern_rockies-forest/21-southern_rockies-forest-5-FM1000INV-ecdf.png")
message("  - data/ecdf/21-southern_rockies-non_forest/21-southern_rockies-non_forest-1-FM1000INV-ecdf.RDS")
message("  - data/ecdf/21-southern_rockies-non_forest/21-southern_rockies-non_forest-1-FM1000INV-ecdf.png")
