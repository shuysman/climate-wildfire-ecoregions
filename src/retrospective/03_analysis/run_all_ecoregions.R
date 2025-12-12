source("./src/retrospective/03_analysis/dryness_roc_analysis.R")

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
  # TRAIN/TEST SPLIT: Use only 1984-2017 fires for training
  # Test set (2018-2024) is held out for independent validation
  mtbs_polys_veg <- vect("./data/mtbs_polys_plus_cover_ecoregion.gpkg")

  mtbs_polys_ecoregion <- mtbs_polys_veg %>%
    filter(
      Ig_Date < as.Date("2018-01-01"),  # ← TRAIN SET: 1984-2017 only
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

# ============================================================================
# CALCULATE GLOBAL POOLED AUC (TRAINING DATA)
# ============================================================================

message("\n========================================")
message("Calculating global pooled training AUC...")
message("========================================\n")

# Pool all predictions from best models across all ecoregions
# This is the CORRECT way to get overall performance
# (do NOT average individual ecoregion AUCs!)
all_predictions <- map_dfr(results_list, function(x) {
  if (!is.null(x$predictions)) {
    return(x$predictions)
  } else {
    return(NULL)
  }
})

if (nrow(all_predictions) > 0) {
  message(glue("  Pooled {nrow(all_predictions)} observations from {length(unique(paste(all_predictions$ecoregion_id, all_predictions$cover)))} ecoregion-cover combinations"))

  # Calculate global ROC and AUC
  global_roc <- roc(fire ~ predictor, data = all_predictions, quiet = TRUE)
  global_auc <- auc(global_roc)[[1]]
  global_pauc10 <- auc(global_roc, partial.auc = c(1, 0.9))[[1]]

  # Calculate 95% confidence interval using DeLong method
  global_ci <- ci.auc(global_roc, conf.level = 0.95)

  message(glue("  ✓ Global pooled training AUC: {round(global_auc, 3)} (95% CI: {round(global_ci[1], 3)}-{round(global_ci[3], 3)})"))
  message(glue("  ✓ Global pooled pAUC10: {round(global_pauc10, 3)}\n"))

  # Save global pooled AUC results
  global_results <- tibble(
    metric = c("global_pooled_auc", "global_pooled_pauc10", "global_auc_ci_lower", "global_auc_ci_upper"),
    value = c(global_auc, global_pauc10, global_ci[1], global_ci[3]),
    n_observations = nrow(all_predictions),
    n_ecoregions = length(unique(paste(all_predictions$ecoregion_id, all_predictions$cover))),
    data_period = "1984-2017 (training)"
  )

  write_csv(global_results, file.path(out_dir, "global_pooled_training_auc.csv"))

  # Save pooled predictions for further analysis
  write_csv(all_predictions, file.path(out_dir, "all_pooled_training_predictions.csv"))

  message("Files created:")
  message("  - global_pooled_training_auc.csv (PRIMARY TRAINING RESULT)")
  message("  - all_pooled_training_predictions.csv")
  message("\nIMPORTANT: This pooled AUC is the CORRECT overall training metric.")
  message(glue("  - Pooled approach: {round(global_auc, 3)}"))
  message(glue("  - Simple average (WRONG): {round(mean(best_predictors$pAUC10), 3)}"))
  message(glue("  - Difference: {round(abs(global_auc - mean(best_predictors$pAUC10)), 3)}\n"))
} else {
  message("  WARNING: No predictions available for pooling\n")
}