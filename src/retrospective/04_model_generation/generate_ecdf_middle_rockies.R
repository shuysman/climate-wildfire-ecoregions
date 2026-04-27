### Script for generating ecdf curves for specific combinations of
### var/window/cover/ecoregion, in case the "best" predictor found in
### the main run isn't what you want to use. For example: CWD is
### "best" predictor but isn't available in gridmet forecasts so we
### use this to generate curves with VPD to use.
###
### Can use the post-run QC script to identify which predictors also
### perform well.

source("./src/retrospective/03_analysis/dryness_roc_analysis.R")

## 1. Load the MTBS fire data and filter for your target ecoregion and cover
mtbs_polys_veg <- st_read("./data/mtbs_polys_plus_cover_ecoregion.gpkg")

middle_rockies_forest_polys <- mtbs_polys_veg %>%
  filter(
    US_L3CODE == 17,
    maj_veg_cl == "forest",
    !(Event_ID %in% bad_sites)
  )

## 2. Prepare the climate data for that specific subset
middle_rockies_climate <- prepare_climate_data_for_ecoregion(
  mtbs_polys = middle_rockies_forest_polys,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 3. Generate the ECDF function
vpd_ecdf <- generate_ecdf(
  climate_data = middle_rockies_climate,
  var_name = "VPD",
  window = 15,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 4. (Optional) Plot and save the ECDF
plot(vpd_ecdf, main = "15-day VPD ECDF for Middle Rockies Forest")
saveRDS(vpd_ecdf, "17-middle_rockies-forest-15-VPD-ecdf.RDS")


middle_rockies_non_forest_polys <- mtbs_polys_veg %>%
  filter(
    US_L3CODE == 17,
    maj_veg_cl == "non_forest",
    !(Event_ID %in% bad_sites)
  )

## 2. Prepare the climate data for that specific subset
middle_rockies_nf_climate <- prepare_climate_data_for_ecoregion(
  mtbs_polys = middle_rockies_non_forest_polys,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 3. Generate the ECDF function
vpd_nf_ecdf <- generate_ecdf(
  climate_data = middle_rockies_nf_climate,
  var_name = "VPD",
  window = 5,
  flux_vars = flux_vars,
  state_vars = state_vars,
  state_vars_no_floor = state_vars_no_floor
)

## 4. (Optional) Plot and save the ECDF
plot(vpd_nf_ecdf, main = "5-day VPD ECDF for Middle Rockies Non-forest")
saveRDS(vpd_nf_ecdf, "17-middle_rockies-non_forest-5-VPD-ecdf.RDS")
