library(shiny)
library(terra)
library(tidyverse)
library(tidyterra)
library(maptiles)
library(glue)
library(here)
library(leaflet)
library(jsonlite)
library(viridisLite)

# Define UI
ui <- fluidPage(
  tags$head(
    tags$link(rel = "stylesheet", type = "text/css", href = "style.css")
  ),
  titlePanel("Fire Danger Forecast"),
  tabsetPanel(
    tabPanel(
      "Map",
      imageOutput("map_image")
    ),
    tabPanel(
      "Threshold",
      sidebarLayout(
        sidebarPanel(
          sliderInput("threshold", "Fire Danger Threshold:",
            min = 0, max = 1, value = 0.5, step = 0.01
          ),
          helpText("The fire danger threshold represents the proportion of historical fires that occurred at or below a certain dryness level. For example, a threshold of 0.5 means that 50% of historical fires occurred at or below the corresponding dryness level.")
        ),
        mainPanel(
          plotOutput("threshold_plot")
        )
      )
    ),
    tabPanel("Lightning", leafletOutput("lightning_map", height = "800px")),
    tabPanel(
      "Info",
      fluidRow(
        column(
          6,
          plotOutput("ecdf_plot")
        ),
        column(
          6,
          includeMarkdown("info.md")
        )
      )
    )
  )
)

# Define server logic
server <- function(input, output, session) {
  # Reactive expression to load fire danger rasters
  fire_danger_rasters <- reactive({
    today <- today()
    # Use here() to build a robust path from the project root
    forecast_file <- here("out", "forecasts", glue("fire_danger_forecast_{today}.rds"))

    # Add a check to be sure
    if (!file.exists(forecast_file)) {
      message("Forecast file not found at: ", forecast_file)
      return(NULL)
    }

    readRDS(forecast_file)
  })

  map_image_data <- reactivePoll(10000, session,
    checkFunc = function() {
      list.files(here("out", "forecasts"), pattern = ".png$") %>%
        sort(decreasing = TRUE) %>%
        first()
    },
    valueFunc = function() {
      latest_file <- list.files(here("out", "forecasts"), pattern = ".png$") %>%
        sort(decreasing = TRUE) %>%
        first()

      list(src = here("out", "forecasts", latest_file), contentType = "image/png")
    }
  )

  output$map_image <- renderImage(
    {
      map_image_data()
    },
    deleteFile = FALSE
  )

  output$threshold_plot <- renderPlot({
    fire_danger_rast <- fire_danger_rasters()

    if (is.null(fire_danger_rast)) {
      return()
    }

    # Threshold the raster
    thresholded_rast <- fire_danger_rast >= input$threshold

    # Calculate the percentage of cells above the threshold for each layer
    percent_above <- global(thresholded_rast, fun = "mean", na.rm = TRUE)

    percent_above$date <- time(fire_danger_rast)

    ## Split date for rectangle annotations on thresholdplot
    split_date <- today() - 1.5

    ggplot(percent_above, aes(x = date, y = mean)) +
      annotate("rect",
        xmin = min(percent_above$date), xmax = split_date,
        ymin = -Inf, ymax = Inf, fill = "blue", alpha = 0.2
      ) +
      annotate("rect",
        xmin = split_date, xmax = max(percent_above$date),
        ymin = -Inf, ymax = Inf, fill = "green", alpha = 0.2
      ) +
      geom_col() +
      geom_vline(xintercept = today(), color = "red", linetype = "dashed", size = 1.25) +
      annotate("text", x = today(), y = Inf, label = "Today", vjust = -0.5, color = "red", fontface = "bold") +
      scale_x_date(date_breaks = "1 day") +
      theme(axis.text.x = element_text(angle = 90, vjust = 0.5)) +
      scale_y_continuous(labels = scales::percent) +
      labs(
        y = "% of Area at or Above Threshold", x = "Date",
        title = glue("Percentage of Parks at or Above {input$threshold} Fire Danger"),
        caption = "Blue background: Historical data (up to 2 days ago)\nGreen background: Forecast data (from yesterday onwards)"
      )
  })

  output$ecdf_plot <- renderPlot({
    ecdf <- read_rds("../out/ecdf/17-middle_rockies-forest/17-middle_rockies-forest-15-VPD-ecdf.RDS")

    ecdf_df <- tibble(
      value = environment(ecdf)$x,
      probability = environment(ecdf)$y
    )

    ggplot(ecdf_df, aes(x = value, y = probability)) +
      annotate("rect", xmin = -Inf, xmax = Inf, ymin = 0, ymax = 0.1, fill = "green", alpha = 0.3) +
      annotate("rect", xmin = -Inf, xmax = Inf, ymin = 0.1, ymax = 0.4, fill = "yellow", alpha = 0.3) +
      annotate("rect", xmin = -Inf, xmax = Inf, ymin = 0.4, ymax = 0.75, fill = "orange", alpha = 0.3) +
      annotate("rect", xmin = -Inf, xmax = Inf, ymin = 0.75, ymax = 1.0, fill = "red", alpha = 0.3) +
      geom_step(color = "black", size = 1.5) +
      labs(
        title = str_wrap("VPD Empirical Cumulative Distribution Function (eCDF)", width = 40),
        subtitle = str_wrap("Background color indicates percentile-based danger level", width = 40),
        x = str_wrap("Percentile of 15-day rolling mean of Vapor Pressure Deficit (VPD)", width = 40),
        y = "Proportion of historical fires (%)"
      ) +
      scale_y_continuous(expand = c(0, 0), labels = scales::percent_format()) +
      scale_x_continuous(expand = c(0, 0)) +
      theme_bw(base_size = 16) +
      theme(
        plot.title = element_text(hjust = 0.5, face = "bold", size = 18, lineheight = 1.1),
        plot.subtitle = element_text(hjust = 0.5, size = 18, lineheight = 1.1),
        axis.title.x = element_text(size = 18, lineheight = 1.1),
        axis.title.y = element_text(size = 18),
        axis.text = element_text(size = 18),
        panel.grid.minor = element_blank()
      )
  })

  lightning_data <- reactiveVal(NULL)
  api_timer <- reactiveTimer(600000) # 10 minutes in milliseconds

  observe({
    api_timer() # Invalidate this observer every 10 minutes

    fire_danger_rast <- fire_danger_rasters()
    if (!is.null(fire_danger_rast)) {
      bbox <- ext(fire_danger_rast)
      api_url <- glue("https://api.weatherbit.io/v2.0/history/lightning?lat=43.5459517032319&lon=-111.162554452619&end_lat=45.1292422224309&end_lon=-109.829085745439&date={today()}&key=79a7ca57b438429c93dbf9252c983550")

      tryCatch(
        {
          new_data <- fromJSON(api_url)
          lightning_data(new_data)
        },
        error = function(e) {
          message("Error fetching lightning data: ", e$message)
        }
      )
    }
  })

  output$lightning_map <- renderLeaflet({
    fire_danger_rast <- fire_danger_rasters()
    if (is.null(fire_danger_rast)) {
      return(leaflet() %>%
        addProviderTiles(providers$CartoDB.Positron) %>%
        setView(lng = -110.5, lat = 44.5, zoom = 8) %>%
        addControl("Forecast data not available.", position = "topright"))
    }

    # Get the fire danger for today
    fire_danger_today <- fire_danger_rast %>% subset(time(.) == today())
    fire_danger_today <- aggregate(fire_danger_today, fact = 2)
    pal <- colorNumeric(viridisLite::viridis(256, option = "B"),
      domain = c(0, 1),
      na.color = "transparent"
    )

    leaflet() %>%
      addProviderTiles(providers$CartoDB.Positron) %>%
      addRasterImage(fire_danger_today, colors = pal, opacity = 0.8, project = TRUE) %>%
      addLegend(
        pal = pal, values = c(0, 1),
        title = "Fire Danger"
      ) %>%
      fitBounds(ext(fire_danger_today)$xmin[[1]], ext(fire_danger_today)$ymin[[1]], ext(fire_danger_today)$xmax[[1]], ext(fire_danger_today)$ymax[[1]])
  })

  observe({
    lightning <- lightning_data()
    if (!is.null(lightning) && !is.null(lightning$lightning) && is.data.frame(lightning$lightning) && nrow(lightning$lightning) > 0) {
      fire_danger_rast <- fire_danger_rasters()
      if (is.null(fire_danger_rast)) {
        return()
      }

      fire_danger_today <- fire_danger_rast %>% subset(time(.) == today())
      fire_danger_today <- aggregate(fire_danger_today, fact = 2)

      # Extract fire danger values for each lightning strike
      lightning_vect <- vect(lightning$lightning, geom = c("lon", "lat"), crs = "EPSG:4326")
      fire_danger_values <- terra::extract(fire_danger_today, lightning_vect)
      # Create a color palette for the markers
      marker_pal <- colorNumeric(viridisLite::viridis(256, option = "B"), domain = c(0, 1), na.color = "#808080")

      # Get the colors for each marker
      marker_colors <- marker_pal(fire_danger_values[, 2])

      leafletProxy("lightning_map") %>%
        clearMarkers() %>%
        addCircleMarkers(
          data = lightning$lightning, lng = ~lon, lat = ~lat, popup = ~ paste("Time:", timestamp_utc),
          color = marker_colors, radius = 5, stroke = FALSE, fillOpacity = 0.8
        )
    }
  })
}

# Run the application
shinyApp(ui = ui, server = server)
