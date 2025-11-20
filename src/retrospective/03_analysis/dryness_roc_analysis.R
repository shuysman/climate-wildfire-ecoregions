library(tidyverse)
library(terra)
library(tidyterra)
library(arrow)
library(sf)
library(slider)
library(pROC)
library(glue)
library(janitor)
library(RColorBrewer)
library(future)
library(furrr)
library(Polychrome)

plan(multisession, workers = 4) ## Runs take about ~25G of memory each, depending on Ecoregion size

terraOptions(verbose = TRUE)

my_percent_rank <- function(x) {
  ### Custom percent rank formula
  ### Implemented to fix the "pixelation" issue that was showing
  ### on maps using the NPS gridded water balance model.  Intended to
  ### reduce sensitivity to minor changes in dryness and
  ### reduce impact of large number of days during fire season with
  ### variables = 0

  ## Round to one decimal.  Fix for floating point math issues on some
  ## platforms.
  x2 <- round(x, 1)

  ## Remove zeroes.  There are many many days per fire season with
  ## variables = 0.  Causes percentiles to inflate so any day >0 is at
  ## least ~40th percentile or so, depending on the distribution.
  x2[x2 == 0] <- NA

  ## Take unique values in the time series.  Reduce impact on
  ## percentile calculation of many low dryness days.
  x2 <- unique(x2) %>% as.numeric()

  ## Ranks of unique, rounded dryness variables
  ranks <- data.frame(x = x2, pct = percent_rank(x2))

  ## Set time series of rounded rolling variables to the %ile determined
  ## on unique values above.
  inds <- match(round(x, 1), ranks$x)
  x3 <- ranks$pct[inds]

  ## zeroes were treated as NA above, replace them
  x3 <- replace_na(x3, 0)

  return(x3)
}

prepare_climate_data_for_ecoregion <- function(mtbs_polys, flux_vars, state_vars, state_vars_no_floor) {
  gridmet_data <- open_dataset("data/gridmet_long_data.parquet")
  npswb_data <- open_dataset("data/npswb_long_data.parquet")

  event_ids <- mtbs_polys$Event_ID

  gridmet_ecoregion <- gridmet_data %>%
    filter(Event_ID %in% event_ids) %>%
    collect()
  npswb_ecoregion <- npswb_data %>%
    filter(Event_ID %in% event_ids) %>%
    collect()

  climate_ecoregion <- bind_rows(npswb_ecoregion, gridmet_ecoregion) %>%
    pivot_wider(names_from = variable, values_from = value) %>%
    rename(
      ACCUMSWE = accumswe, CWD = Deficit, RAIN = rain, RUNOFF = runoff,
      SOIL = soil_water, BI = bi, ERC = erc, FM100 = fm100,
      FM1000 = fm1000, PR = pr, VPD = vpd
    ) %>%
    group_by(Event_ID) %>% ## Ensure properties like WHC are calculated per site
    mutate(
      RH = (rmax + rmin) / 2,
      RD = 100 - RH,
      tmmn = tmmn - 273.15,
      tmmx = tmmx - 273.15,
      T = (tmmn + tmmx) / 2,
      GDD_0 = pmax(T - 0, 0),
      GDD_5 = pmax(T - 5, 0),
      GDD_10 = pmax(T - 10, 0),
      GDD_15 = pmax(T - 15, 0),
      WHC = max(SOIL, na.rm = TRUE),
      SWD = WHC - SOIL
    ) %>%
    ungroup() %>%
    select(Event_ID, date, all_of(flux_vars), all_of(state_vars), all_of(state_vars_no_floor))

  climate_ecoregion <- climate_ecoregion %>%
    left_join(select(as.data.frame(mtbs_polys), Event_ID, Ig_Date, maj_veg_cl), by = "Event_ID") %>%
    mutate(Ig_Date = as_date(with_tz(Ig_Date, "America/Denver"))) %>% ### Cast Ig_Date as date instead of dttm, to allow comparison with daily dates. Gridmet dates are in mountain timezone, so convert mtbs dates (UTC) to mountain time for proper comparison
    mutate(fire = if_else(date == Ig_Date, 1, 0))

  return(climate_ecoregion)
}

calculate_percentiles <- function(climate_data, window, state_vars, state_vars_no_floor, flux_vars) {
  climate_data %>%
    mutate(
      across(all_of(state_vars), ~ slide_dbl(.x, .f = mean, .before = window - 1)),
      across(all_of(state_vars_no_floor), ~ slide_dbl(.x, .f = mean, .before = window - 1)),
      across(all_of(flux_vars), ~ slide_dbl(.x, .f = sum, .before = window - 1))
    ) %>%
    drop_na() %>%
    mutate(
      across(
        all_of(c(flux_vars, state_vars)), my_percent_rank
      ),
      across(all_of(state_vars_no_floor), dplyr::percent_rank)
    )
}

generate_ecdf <- function(climate_data, var_name, window, state_vars, state_vars_no_floor, flux_vars) {
  climate_percentiles <- calculate_percentiles(climate_data, window, state_vars, state_vars_no_floor, flux_vars)
  ignition_data <- filter(climate_percentiles, fire == 1)
  ecdf(ignition_data[[var_name]])
}

process_roc <- function(climate_data, cover, windows, state_vars, state_vars_no_floor, flux_vars, ecoregion_id, ecoregion_name, ecoregion_name_clean) {
  best_pauc10 <- 0
  best_varname <- ""
  best_window <- 0
  ecdf_fn <- NULL

  roc_img_dir <- glue("out/img/roc/{ecoregion_id}-{ecoregion_name_clean}")
  ecdf_dir <- glue("data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-{cover}")
  dir.create(roc_img_dir, showWarnings = FALSE, recursive = TRUE)
  dir.create(ecdf_dir, showWarnings = FALSE, recursive = TRUE)

  roc_formula <- as.formula(paste("fire ~", paste(c(state_vars, state_vars_no_floor, flux_vars), collapse = " + ")))

  n_vars <- length(c(state_vars, state_vars_no_floor, flux_vars))
  color_palette <- glasbey.colors(n_vars + 1)[2:(n_vars + 1)]
  names(color_palette) <- NULL ## GGplot only applies colors if names match levels

  auc_results_list <- map(windows, function(window) {
    message(glue("Processing window length of {window} on cover {cover} for ecoregion {ecoregion_id}: {ecoregion_name}"))

    climate_percentiles <- calculate_percentiles(climate_data, window, state_vars, state_vars_no_floor, flux_vars)

    roc_list <- roc(roc_formula, data = climate_percentiles)

    data_auc <- map_dfr(roc_list, ~ tibble(
      AUC = auc(.x)[[1]],
      AUC10 = auc(.x, partial.auc = c(1, .9))[[1]],
      AUC20 = auc(.x, partial.auc = c(1, .8))[[1]],
      window = window,
      ecoregion_id = ecoregion_id,
      ecoregion_name = ecoregion_name_clean,
      cover = cover
    ), .id = "name")

    data_labels <- data_auc %>% mutate(label_long = paste0(name, ", AUC = ", round(AUC, 2)))

    ggroc(roc_list, legacy.axes = TRUE, size = 1.1, alpha = 0.9) +
      scale_color_manual(labels = data_labels$label_long, values = color_palette) +
      geom_abline(intercept = 0, slope = 1, color = "darkgrey", linetype = "dashed") +
      labs(x = "False Positive Rate", y = "True Positive Rate", color = "Variable") +
      theme_classic(base_size = 18)
    ggsave(file.path(roc_img_dir, glue("{ecoregion_id}-{ecoregion_name_clean}-{cover}-{window}_days-roc.png")), width = 10, height = 8)

    best_model_this_loop <- data_auc %>%
      arrange(desc(AUC10), desc(AUC20), desc(AUC)) %>%
      slice(1)

    if (best_model_this_loop$AUC10 > best_pauc10) {
      best_pauc10 <<- best_model_this_loop$AUC10
      best_varname <<- as.character(best_model_this_loop$name)
      best_window <<- best_model_this_loop$window
      ignition_data <- filter(climate_percentiles, fire == 1)
      ecdf_fn <<- ecdf(ignition_data[[best_varname]])
    }
    return(data_auc)
  })

  auc_data <- bind_rows(auc_results_list)

  if (is.null(ecdf_fn)) {
    return(list(auc = auc_data, best = tibble()))
  }

  png(filename = file.path(ecdf_dir, glue("{ecoregion_id}-{ecoregion_name_clean}-{cover}-{best_window}-{best_varname}-ecdf.png")), pointsize = 32, width = 1280, height = 1280)
  plot(ecdf_fn, xlab = glue("Percentile of {best_varname}, window = {best_window}"), ylab = "Percentile of historical wildfires", main = glue("eCDF {cover}"), xlim = c(0, 1))
  dev.off()

  saveRDS(ecdf_fn, file = file.path(ecdf_dir, glue("{ecoregion_id}-{ecoregion_name_clean}-{cover}-{best_window}-{best_varname}-ecdf.RDS")))

  best_predictors <- tibble(
    ecoregion_id = ecoregion_id, ecoregion_name = ecoregion_name_clean, window = best_window,
    var = best_varname, cover = cover, pAUC10 = best_pauc10
  )

  return(list(auc = auc_data, best = best_predictors))
}

bin_rast <- function(new_rast, quants_rast, probs) {
  # Count how many quantile layers the new value is greater than.
  # This results in a raster of integers from 0 to 9.
  bin_index_rast <- sum(new_rast > quants_rast)

  # Now, map this integer index back to a percentile value.
  # We need a mapping from [0, 1, 2, ..., 9] to [0, 0.1, 0.2, ..., 0.9]
  # A value of 0 means it was smaller than the 1st quantile (q_0.1)
  # A value of 9 means it was larger than the 9th quantile (q_0.9)
  percentile_map <- c(0, probs)
  from_vals <- 0:length(probs)
  rcl_matrix <- cbind(from_vals, percentile_map)

  # Use classify to create the final approximate percentile raster
  percentile_rast_binned <- classify(bin_index_rast, rcl = rcl_matrix)

  return(percentile_rast_binned)
}

## Global parameters
windows <- seq(1:31) ## Rolling window widths to test

### State variables: variables to average in rolling window calculations
state_vars <- c("RD", "VPD", "SWD", "ACCUMSWE", "BI", "ERC")
## my_percent_rank() doesnt make sense for fuel moisture because they
## have an inverted scale where lower values are drier, more dangerous
## conditions. my_percent_rank() is intended to increase sensitivty to
## small changes above a zero-value baseline for zero-inflated variables
state_vars_no_floor <- c("FM100", "FM1000")
### Flux Variables: varibles to sum in rolling window calculations
flux_vars <- c("AET", "CWD", "PET", "RAIN", "RUNOFF", "GDD_0", "GDD_5", "GDD_10", "GDD_15")

## Bad sites determined in 02_data_qc.R
bad_sites <- read_lines("data/bad_sites.txt")

min_cover <- 20 ## Minimum samples for cover type to run analysis
ecoregions <- read_csv("data/ecoregion_cover_counts.csv") %>%
  filter(!is.na(US_L3CODE)) %>%
  filter(n >= min_cover)