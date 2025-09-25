## How This Fire Danger System Works

This tool provides a daily forecast of wildfire ignition danger, designed to be both scientifically robust and easy for land managers to use. Here’s a simplified overview of how it works:

### 1. Finding the Best Weather Indicators

Our goal was to find the simplest and most effective weather signals for predicting when and where a fire is likely to start. We analyzed decades of historical data on wildfires and weather, looking at variables like:

*   **Vapor Pressure Deficit (VPD):** A measure of how dry the air is.
*   **Climatic Water Deficit (CWD):** An indicator of drought stress in plants.
*   **Temperature**

We tested these indicators over different time windows (e.g., the last 3 days, 7 days, etc.) to find the combination that best predicted past fire ignitions for each specific ecoregion.

### 2. Creating a Local "Normal"

A hot, dry day in a desert is very different from a hot, dry day in a forest. To account for these local differences, we don’t use the raw weather values. Instead, we convert them to a **percentile rank**.

For example, a VPD value might be normal for Arizona but extreme for Oregon. By converting it to a percentile, we can see that it’s the 99th percentile of dryness for that specific location in Oregon, indicating a much higher risk than the raw value would suggest.

### 3. The eCDF: Turning Weather into Risk

The heart of our system is the **Empirical Cumulative Distribution Function (eCDF)**. This plot shows the relationship between the local dryness percentile (on the x-axis) and the historical probability of a fire starting (on the y-axis).

<img src="ecdf_example.png" alt="eCDF Example" style="max-height: 400px;">

**How to Read the eCDF Plot:**

*   The **x-axis** shows the dryness percentile. A value of 0.5 means that conditions are drier than 50% of all historical days for that location.
*   The **y-axis** shows the cumulative probability of fire ignition. A value of 0.5 (or 50%) means that 50% of all historical fires in that ecoregion started at or below that dryness level.

By looking at this plot, you can set a risk threshold that makes sense for your management needs. For example, you might decide to increase patrols or issue warnings when the fire danger index reaches a level that corresponds to 75% of historical fire ignitions.

### 4. Daily Forecasting

To generate the daily forecast maps, the system performs the following steps every day:

1.  **Gets the Latest Data:** It automatically downloads the latest historical weather data and the newest 7-day weather forecast.
2.  **Calculates Dryness:** It calculates the best-performing dryness indicator (like the 5-day average VPD) for the forecast period.
3.  **Compares to Normal:** It compares the forecast dryness to the pre-calculated local "normal" for every pixel on the map to get a percentile rank.
4.  **Creates the Danger Map:** It uses the eCDF model to convert the percentile rank into a fire danger index (from 0 to 1) for each pixel, creating the final map you see on the "Map" tab.

These daily forecasts are updated around 10 AM MST each day, depending on exact timing of availability from the Northwest Knowledge Network THREDDS server.

### 5. Cover Type

Cover type is a critical factor in fire behavior. This system uses the [LANDFIRE 2023 Existing Vegetation Type](https://www.landfire.gov/evt.php) dataset to distinguish between different vegetation types. The raw data provides detailed classifications, as shown below.

<img src="cover-landfire.png" alt="LANDFIRE Cover Types" style="max-height: 600px;">

To simplify the modeling process, these detailed classifications are grouped into two main categories: "forest" and "non-forest". The script at `src/01_extract_cover.R` automates this process by determining the majority cover type for each area. The resulting categorized data is shown below.

<img src="cover-categorized.png" alt="Categorized Cover Types" style="max-height: 600px;">

### 6. Separate Models for Each Cover Type

A separate fire danger model is generated for each ecoregion and cover type combination. For example, the "Middle Rockies" ecoregion has both a "forest" and a "non-forest" model. This is crucial because fire behavior, and therefore fire danger, differs significantly between these two environments. The script at `src/map_forecast_danger.R` demonstrates how the appropriate model is selected based on the cover type of a given area, ensuring that the fire danger forecast is tailored to the specific vegetation on the ground.
