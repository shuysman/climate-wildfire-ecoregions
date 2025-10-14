source("./src/03_dryness.R")

process_ecoregion_cover <- function(i, bad_sites, flux_vars, state_vars, state_vars_no_floor, windows) {
  # Select the ecoregion and cover type for this iteration
  ecoregion_info <- ecoregions[i, ]
  ecoregion_id <- ecoregion_info$US_L3CODE
  ecoregion_name <- ecoregion_info$US_L3NAME
  cover <- ecoregion_info$maj_veg_cl
  ecoregion_name_clean <- ecoregion_name %>%
    str_replace_all("/", "-") %>%
    str_replace_all(" ", "_") %>%
    tolower()

  message(glue("Processing {cover} in ecoregion {ecoregion_id}: {ecoregion_name}"))

  # Read MTBS data and filter for the current ecoregion/cover
  mtbs_polys_veg <- vect("./data/mtbs_polys_plus_cover_ecoregion.gpkg")

  mtbs_polys_ecoregion <- mtbs_polys_veg %>%
    filter(
      US_L3CODE == ecoregion_id,
      maj_veg_cl == cover,
      !(Event_ID %in% bad_sites)
    )

  if (nrow(mtbs_polys_ecoregion) == 0) {
    message(glue("Skipping {cover} in ecoregion {ecoregion_id}: No valid polygons found."))
    return(list(auc = tibble(), best = tibble()))
  }

  # Prepare climate data
  climate_data <- prepare_climate_data_for_ecoregion(
    mtbs_polys = mtbs_polys_ecoregion,
    flux_vars = flux_vars,
    state_vars = state_vars,
    state_vars_no_floor = state_vars_no_floor
  )

  # Run ROC analysis
  results <- process_roc(
    climate_data = climate_data,
    cover = cover,
    windows = windows,
    state_vars = state_vars,
    state_vars_no_floor = state_vars_no_floor,
    flux_vars = flux_vars,
    ecoregion_id = ecoregion_id,
    ecoregion_name = ecoregion_name,
    ecoregion_name_clean = ecoregion_name_clean
  )

  return(results)
}

## Main Execution
results_list <- future_map(
  1:nrow(ecoregions),
  ~ process_ecoregion_cover(
    i = .x,
    bad_sites = bad_sites,
    flux_vars = flux_vars,
    state_vars = state_vars,
    state_vars_no_floor = state_vars_no_floor,
    windows = windows
  ),
  .options = furrr_options(seed = TRUE),
  .progress = TRUE
)

## Save results
out_dir <- "out/"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

auc_data <- map_dfr(results_list, "auc")
best_predictors <- map_dfr(results_list, "best")

write_csv(best_predictors, file.path(out_dir, "best_predictors.csv"))
write_csv(auc_data, file.path(out_dir, "auc_data.csv"))