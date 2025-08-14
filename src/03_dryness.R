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

prepare_climate_data_for_ecoregion <- function(mtbs_polys, flux_vars, state_vars, state_vars_no_floor, T_base) {
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
      GDD = pmax(T - T_base, T_base),
      WHC = max(SOIL, na.rm = TRUE),
      SWD = WHC - SOIL
    ) %>%
    ungroup() %>%
    select(Event_ID, date, all_of(flux_vars), all_of(state_vars), all_of(state_vars_no_floor))

  climate_ecoregion <- climate_ecoregion %>%
    left_join(select(as.data.frame(mtbs_polys), Event_ID, Ig_Date, maj_veg_cl), by = "Event_ID") %>%
    mutate(fire = if_else(date == Ig_Date, 1, 0))

  return(climate_ecoregion)
}

process_roc <- function(climate_data, cover, windows, state_vars, state_vars_no_floor, flux_vars, ecoregion_id, ecoregion_name, ecoregion_name_clean) {
  best_pauc10 <- 0
  best_varname <- ""
  best_window <- 0
  ecdf_fn <- NULL

  roc_img_dir <- glue("out/img/roc/{ecoregion_id}-{ecoregion_name_clean}")
  ecdf_dir <- glue("out/ecdf/{ecoregion_id}-{ecoregion_name_clean}-{cover}")
  dir.create(roc_img_dir, showWarnings = FALSE, recursive = TRUE)
  dir.create(ecdf_dir, showWarnings = FALSE, recursive = TRUE)

  roc_formula <- as.formula(paste("fire ~", paste(c(state_vars, state_vars_no_floor, flux_vars), collapse = " + ")))
  color_palette <- c(brewer.pal(name = "Dark2", n = 8), brewer.pal(name = "Paired", n = 6))

  auc_results_list <- map(windows, function(window) {
    message(glue("Processing window length of {window} on cover {cover} for ecoregion {ecoregion_id}: {ecoregion_name}"))

    climate_percentiles <- climate_data %>%
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

process_ecoregion_cover <- function(i, bad_sites, flux_vars, state_vars, state_vars_no_floor, windows, T_base) {
  ecoregion <- ecoregions[i, ]
  ecoregion_id <- ecoregion$US_L3CODE
  ecoregion_name <- ecoregion$US_L3NAME
  ecoregion_name_clean <- make_clean_names(ecoregion_name)
  cover <- ecoregion$maj_veg_cl

  mtbs_data <- vect("data/mtbs_polys_plus_cover_ecoregion.gpkg") %>%
    filter(US_L3CODE == ecoregion_id, maj_veg_cl == cover) %>%
    filter(!(Event_ID %in% bad_sites)) ## remove blacklisted sites

  ## Map for each cover type for each ecoregion
  map_img_dir <- "out/img/map/"
  ecoregion_shp <- vect("data/us_eco_l3/us_eco_l3.shp") %>% filter(US_L3CODE == ecoregion_id)
  dir.create(map_img_dir, showWarnings = FALSE, recursive = TRUE)
  ggplot() +
    geom_spatvector(data = ecoregion_shp) +
    geom_spatvector(data = mtbs_data, fill = "blue", alpha = 0.5) +
    labs(fill = "Cover")
  ggsave(file.path(map_img_dir, glue("{ecoregion_id}-{ecoregion_name_clean}-{cover}-map.png")))

  ## Analysis code
  climate_ecoregion_cover <- prepare_climate_data_for_ecoregion(mtbs_data, flux_vars, state_vars, state_vars_no_floor, T_base)

  roc_results <- process_roc(
    climate_data = climate_ecoregion_cover,
    cover = cover,
    windows = windows,
    state_vars = state_vars,
    state_vars_no_floor = state_vars_no_floor,
    flux_vars = flux_vars,
    ecoregion_id = ecoregion_id,
    ecoregion_name = ecoregion_name,
    ecoregion_name_clean = ecoregion_name_clean
  )

  auc_data <- roc_results$auc
  best_predictors <- roc_results$best

  return(list(
    auc = auc_data,
    best = best_predictors
  ))
}

## Global parameters
T_base <- 0 ## Temperature (C) for GDD calculations
windows <- seq(1:31) ## Rolling window widths to test

### State variables: variables to average in rolling window calculations
state_vars <- c("RD", "VPD", "SWD", "ACCUMSWE", "BI", "ERC", "FM100", "FM1000")
## my_percent_rank() doesnt make sense for T because 0 is not an
## absolute minimum (for T in C like we are using). my_percent_rank()
## is intended to increase sensitivty to small changes above a
## zero-value baseline
state_vars_no_floor <- c("T")
### Flux Variables: varibles to sum in rolling window calculations
flux_vars <- c("AET", "CWD", "PET", "RAIN", "RUNOFF")

## Bad sites determined in 02_data_qc.R
bad_sites <- read_lines("data/bad_sites.txt")

min_cover <- 20 ## Minimum samples for cover type to run analysis
ecoregions <- read_csv("data/ecoregion_cover_counts.csv") %>%
  filter(!is.na(US_L3CODE)) %>%
  filter(n >= min_cover)

## test Execution
## results_list <- future_map(
##   9,
##   ~ process_ecoregion(
##     i = .x,
##     bad_sites = bad_sites,
##     flux_vars = flux_vars,
##     state_vars = state_vars,
##     windows = 1,
##     T_base = T_base
##   ),
##   .options = furrr_options(seed = TRUE)
## )

## Main Execution
results_list <- future_map(
  1:nrow(ecoregions),
  ~ process_ecoregion_cover(
    i = .x,
    bad_sites = bad_sites,
    flux_vars = flux_vars,
    state_vars = state_vars,
    state_vars_no_floor = state_vars_no_floor,
    windows = windows,
    T_base = T_base
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
