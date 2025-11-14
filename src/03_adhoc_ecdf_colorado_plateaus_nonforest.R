### Script for generating ECDF curves for VPD in Colorado Plateaus - NON-FOREST
### This generates eCDF models for VPD
### where higher VPD = higher fire risk
###
### Configuration:
### - Ecoregion: Colorado Plateaus (code 20)
### - Variable: VPD
### - Non-forest: 27-day rolling mean

source("./src/03_dryness.R")

## 1. Load the MTBS fire data and filter for Colorado Plateaus non-forest
mtbs_polys_veg <- st_read("./data/mtbs_polys_plus_cover_ecoregion.gpkg")

colorado_plateaus_nf_polys <- mtbs_polys_veg %>%
  filter(
    US_L3CODE == 20,
    maj_veg_cl == "non_forest",
    !(Event_ID %in% bad_sites)
  )

message(glue("Colorado Plateaus Non-forest: {nrow(colorado_plateaus_nf_polys)} fire events"))

## 2. Prepare the climate data for that specific subset
colorado_plateaus_nf_climate <- prepare_climate_data_for_ecoregion(
  mtbs_polys = colorado_plateaus_nf_polys,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 3. Generate the ECDF function using VPD
message("Generating ECDF for VPD (non-forest, 27-day window)...")

# VPD is in state_vars, so it uses my_percent_rank() (with zero-substitution and rounding)
vpd_nf_ecdf <- generate_ecdf(
  climate_data = colorado_plateaus_nf_climate,
  var_name = "VPD",
  window = 27,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 4. Plot and save the ECDF
message("Plotting and saving non-forest ECDF...")
dir.create("./data/ecdf/20-colorado_plateaus-non_forest", showWarnings = FALSE, recursive = TRUE)

png("./data/ecdf/20-colorado_plateaus-non_forest/20-colorado_plateaus-non_forest-27-VPD-ecdf.png",
    width = 800, height = 600)
plot(vpd_nf_ecdf, main = "27-day VPD ECDF for Colorado Plateaus Non-forest")
dev.off()

saveRDS(vpd_nf_ecdf, "./data/ecdf/20-colorado_plateaus-non_forest/20-colorado_plateaus-non_forest-27-VPD-ecdf.RDS")
message("✓ Non-forest ECDF saved")

message("========================================")
message("ECDF generation complete!")
message("========================================")
message("Output files:")
message("  - data/ecdf/20-colorado_plateaus-non_forest/20-colorado_plateaus-non_forest-27-VPD-ecdf.RDS")
message("  - data/ecdf/20-colorado_plateaus-non_forest/20-colorado_plateaus-non_forest-27-VPD-ecdf.png")
