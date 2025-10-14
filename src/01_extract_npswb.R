## Extract NPS WB data for all MTBS fire centroids
library(tidyverse)
library(terra)
library(tidyterra)
library(climateR)
library(arrow)
library(glue)

npswb_vars <- c(
  "accumswe", "AET", "PET", "Deficit", "rain", "runoff", "soil_water"
)
metdata_elev <- rast("data/metdata_elevationdata.nc")

mtbs_centroids <- vect("data/mtbs/mtbs_perims_DD.shp") %>%
  as.data.frame() %>%
  mutate(
    BurnBndLon = as.numeric(BurnBndLon),
    BurnBndLat = as.numeric(BurnBndLat)
  ) %>%
  vect(geom = c("BurnBndLon", "BurnBndLat"), crs = crs("EPSG:4326")) %>%
  filter(Incid_Type == "Wildfire") %>%
  crop(metdata_elev)

npswb_data_dir <- "/media/steve/THREDDS/daily_or_monthly/v2_historical/"

# 1. Create a temporary directory to store intermediate files
temp_dir <- "/tmp/tmp_parquet"
dir.create(temp_dir, showWarnings = FALSE, recursive = TRUE)


for (current_var in npswb_vars) {
  message(glue("Processing: {current_var}"))

  rast_path <- list.files(
    path = npswb_data_dir,
    pattern = glue("V_1_5_.*_gridmet_historical_{current_var}.nc"),
    full.names = TRUE
  )
  rast <- rast(rast_path)

  # Process data for the current variable
  single_var_data <- extract_sites(rast, mtbs_centroids, ID = "Event_ID") %>%
    as_tibble() %>%
    pivot_longer(
      cols = -date,
      names_to = "Event_ID",
      values_to = "value"
    ) %>%
    mutate(value = value / 10, variable = current_var) %>%
    drop_na(value) ## January 1st values are weird because of dates used in NPS WB dataset, on many years there is an additional redundant NA row for each var

  # Define the path for the temporary parquet file
  temp_file_path <- file.path(temp_dir, glue("{current_var}.parquet"))

  # Write the data for this single variable to its own parquet file
  write_parquet(single_var_data, temp_file_path)

  # Make sure memory is freed
  rm(single_var_data)
}

# 3. Combine all temporary files
# List all the individual parquet files we just created
temp_files <- list.files(temp_dir, pattern = "\\.parquet$", full.names = TRUE)

message("Combining temporary parquet files.")
print(temp_files)

# Open all files as a single, unified dataset (without loading into memory)
final_dataset <- open_dataset(temp_files)

# Write the unified dataset to the final Parquet file
# This streams data from the temp files to the final file efficiently.
write_parquet(final_dataset, "data/npswb_long_data.parquet")

# 4. Clean up the temporary directory and its contents
unlink(temp_dir, recursive = TRUE)
message("Temporary files removed. Final parquet file created.")

# Check the final data
final_data <- open_dataset("data/npswb_long_data.parquet")
print(head(final_data))
