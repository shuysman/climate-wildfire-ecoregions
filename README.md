# Climatic Drivers of Wildfire Ignition Across CONUS Ecoregions

This repository contains the analysis code for a project that develops and evaluates a wildfire ignition danger rating system based on climatic water balance variables. The system is designed to be straightforward, computationally efficient, and applicable across different ecoregions in the conterminous United States (CONUS).

This work expands upon an analysis originally conducted for the Southern Rockies (Thoma et al., 2020) which was extended to the Middle Rockies as part the work for a Masters Thesis (Huysman et al., *in prep*)

## Project Goal

The primary goal is to identify the most effective climatic indicators and temporal scales for predicting wildfire ignition. This allows for the creation of a flexible, projectable fire danger rating system that can be used for both short-term management decisions and long-term conservation planning, such as identifying potential climate-resilient wildfire refugia.

## Methodology

The analysis follows a systematic approach for each Level III ecoregion in the CONUS:

1.  **Data Ingestion**: Historical wildfire ignition data is sourced from the Monitoring Trends in Burn Severity (MTBS) database. Climate and water balance time series (e.g., CWD, VPD, Temperature) are extracted for the centroid of each fire polygon from gridded datasets (gridMET, NPS Gridded Water Balance).

2.  **Indicator Calculation**: Rolling sums (for flux variables like CWD) or means (for state variables like VPD) are calculated over a range of window widths (e.g., 1 to 31 days) preceding each day in the time series.

3.  **Normalization**: To account for local climate variability, the rolling values are converted to a percentile rank. A custom percentile rank function (`my_percent_rank`) is used for zero-inflated variables to improve model sensitivity at low-to-moderate levels of dryness.

4.  **Classifier Evaluation**: The performance of each climate indicator and rolling window width as a binary classifier of ignition (fire vs. no-fire ignition on that day) is evaluated using Receiver Operating Characteristic (ROC) curves. The Area Under the Curve (AUC) and partial AUC (pAUC) are used to identify the optimal predictor, prioritizing performance under the driest conditions (high pAUC).

5.  **Danger Rating System**: An empirical cumulative distribution function (eCDF) is generated for the best-performing indicator. This function maps a given dryness percentile to the historical proportion of wildfires that ignited at or below that level, creating a tunable, risk-based danger rating.

6.  **Projection (Example Application)**: The resulting model can be used with projected climate data (e.g., MACA) to map future changes in wildfire ignition danger.

## Data Sources

*   **Wildfire Data**: [Monitoring Trends in Burn Severity (MTBS)](https://www.mtbs.gov/)
*   **Historical Climate Data**: [gridMET](https://www.climatologylab.org/gridmet.html)
*   **Projected Climate Data**: [MACA](https://www.climatologylab.org/maca.html)
*   **Water Balance Data**: [NPS 1-km Gridded Water Balance Product](https://www.yellowstoneecology.com/research/Gridded_Water_Balance_Model_Version_2_User_Manual.pdf)
*   **Vegetation Data**: [LANDFIRE Existing Vegetation Type (EVT)](https://landfire.gov/evt.php)
*   **Ecoregions**: [EPA Level III Ecoregions of the Conterminous United States](https://www.epa.gov/eco-research/ecoregions-north-america)

## Code Structure

*   `03_dryness.R`: The core analysis script. It iterates through ecoregions and cover types, calculates rolling climate metrics, performs the ROC/AUC analysis, and saves the best predictors and eCDF models.
*   `rolling_sums_historical.R`: An example script demonstrating how to apply the saved eCDF models to spatial climate data to create maps of fire danger.
*   `data/`: Directory for input data sources like shapefiles and pre-processed climate data.
*   `out/`: Directory for all generated outputs, including plots, AUC results, and final eCDF models.

## How to Run

1.  Prepare the environment by installing the required R packages using renv: `renv::install()`
2.  Retrieve the required climate data. The analysis requires local copies of the required gridMET and NPSWB netCDF files. `00_download_gridmet.sh` can be used to retrieve CONUS grids for the required gridMET variables (requires approximately 57 GB of disk space). A similar script to download the CONUS grids for the NPS 1 km gridded water balance variables is not currently provided (TODO). 
3.  Prepare the cover type (`01_extract_cover.R`) and climate data (`01_extract_gridmet.R` and `01_extract_npswb.R`) for each US L3 ecoregion.
4. Prepare a list of bad sites based on missing or erroneous data using `02_data_qc.R`.
5.  Ensure input data is correctly placed in the `data/` directory. The analysis expects pre-processed Parquet files of climate data linked to MTBS fire `Event_ID`s.
6.  Execute the main analysis script: `Rscript src/03_dryness.R`

## Acknowledgments
This work was supported by funding provided by the National Park Service through an agreement with the [Northern Rockies Conservation Cooperative](https://nrccooperative.org/)
