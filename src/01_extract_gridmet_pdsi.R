## Extract gridMET PDSI for all MTBS fire centroids
## PDSI is in a single file, while other gridmet vars are split by year, so needs to be extracted separately
library(tidyverse)
library(terra)
library(tidyterra)
library(climateR)
library(arrow)
library(glue)

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

gridmet_data_dir <- "/home/steve/data/gridmet/"

# 1. Create a temporary directory to store intermediate files
temp_dir <- "/tmp/tmp_parquet"
dir.create(temp_dir, showWarnings = FALSE, recursive = TRUE)

message(glue("Processing: pdsi"))

rast_path <- list.files(
  path = gridmet_data_dir,
  pattern = glue("pdsi.nc"),
  full.names = TRUE
)
rast <- rast(rast_path)
time(rast) <- as_date(depth(rast), origin = "1900-01-01")

# Process data for the current variable
single_var_data <- extract_sites(rast, mtbs_centroids, ID = "Event_ID") %>%
  as_tibble() %>%
  pivot_longer(
    cols = -date,
    names_to = "Event_ID",
    values_to = "value"
  ) %>%
  mutate(variable = "pdsi")

# Define the path for the temporary parquet file
temp_file_path <- file.path(temp_dir, glue("pdsi.parquet"))

# Write the data for this single variable to its own parquet file
write_parquet(single_var_data, temp_file_path)

# Make sure memory is freed
rm(single_var_data)

# 3. Combine all temporary files
# List all the individual parquet files we just created
temp_files <- list.files(temp_dir, pattern = "\\.parquet$", full.names = TRUE)

message("Combining temporary parquet files.")
print(temp_files)

# Open all files as a single, unified dataset (without loading into memory)
final_dataset <- open_dataset(temp_files)

# Write the unified dataset to the final Parquet file
# This streams data from the temp files to the final file efficiently.
write_parquet(final_dataset, "data/gridmet_pdsi_long_data.parquet")

# 4. Clean up the temporary directory and its contents
unlink(temp_dir, recursive = TRUE)
message("Temporary files removed. Final parquet file created.")

# Check the final data
final_data <- open_dataset("data/gridmet_pdsi_long_data.parquet")
print(head(final_data))
