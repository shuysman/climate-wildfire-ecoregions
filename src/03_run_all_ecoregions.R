source("./src/03_dryness.R")

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
