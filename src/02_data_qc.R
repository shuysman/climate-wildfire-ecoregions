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


## Load in water balance and climate data from 01_extract_*.R scripts
gridmet_data <- open_dataset("data/gridmet_long_data.parquet")
## gridmet_pdsi_data <- open_dataset("data/gridmet_pdsi_long_data.parquet")
npswb_data <- open_dataset("data/npswb_long_data.parquet")

## npswb_data %>%
##   select(Event_ID) %>%
##   distinct() %>%
##   collect()
### 15,555 sites total
## gridmet_data %>%
##   select(Event_ID) %>%
##   distinct() %>%
##   collect()
### 15,555 sites total

weird_gridmet <- gridmet_data %>%
  filter(value < 0 | is.na(value)) %>%
  collect()

weird_gridmet %>%
  group_by(Event_ID, variable) %>%
  summarize(n = n())

weird_gridmet %>%
  filter(is.na(value))


weird_npswb <- npswb_data %>%
  filter(value < 0 | is.na(value)) %>%
  collect()

weird_npswb %>%
  group_by(Event_ID, variable) %>%
  summarize(n = n())

weird_npswb %>%
  filter(value <= -900)

weird_npswb %>%
  filter(is.na(value))


weird_npswb %>%
  filter(0 > value & value > -900) %>%
  group_by(Event_ID, variable) %>%
  summarize(n = n())


bad_gridmet_sites <- weird_gridmet %>%
  select(Event_ID) %>%
  distinct()

bad_npswb_sites <- weird_npswb %>%
  select(Event_ID) %>%
  distinct()

all_bad_sites <- c(bad_gridmet_sites$Event_ID, bad_npswb_sites$Event_ID)

write_lines(all_bad_sites, file = "data/bad_sites.txt")
