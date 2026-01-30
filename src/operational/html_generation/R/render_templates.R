# render_templates.R - jinjar template rendering utilities
#
# Core utilities for rendering jinja2 templates using the jinjar package.
# Provides consistent template loading, rendering, and output functions.

suppressPackageStartupMessages({
  library(jinjar)
  library(glue)
  library(here)
})

# Package-level template environment (initialized lazily)
.template_env <- NULL

#' Get the path to the templates directory
#'
#' @return Character string with absolute path to templates directory
get_template_dir <- function() {
  # Use here() to reliably find the templates directory
  template_dir <- here("src", "operational", "html_generation", "templates")

  if (dir.exists(template_dir)) {
    return(template_dir)
  }

  # Fallback for container environment
  if (dir.exists("/app/src/operational/html_generation/templates")) {
    return("/app/src/operational/html_generation/templates")
  }

  stop("Could not find templates directory")
}

#' Initialize the jinjar template environment
#'
#' Sets up a jinjar environment with a file system loader pointed at
#' the templates directory. Uses caching for performance.
#'
#' @return jinjar environment object
get_template_env <- function() {
  if (is.null(.template_env)) {
    template_dir <- get_template_dir()

    if (!dir.exists(template_dir)) {
      stop(glue("Templates directory not found: {template_dir}"))
    }

    # Create a path loader that can find templates and partials
    loader <- path_loader(template_dir)

    # Create the environment with the loader
    .template_env <<- jinjar_config(loader = loader)
  }

  .template_env
}

#' Render a jinja2 template with the given data context
#'
#' @param template_name Character string with template filename (e.g., "index.jinja2")
#' @param data Named list with template context variables
#' @return Character string with rendered HTML
#'
#' @examples
#' \dontrun{
#' html <- render_template("index.jinja2", list(
#'   today = "2026-01-29",
#'   ecoregions = list(
#'     list(name_clean = "middle_rockies", name = "Middle Rockies")
#'   )
#' ))
#' }
render_template <- function(template_name, data = list()) {
  env <- get_template_env()
  template_path <- file.path(get_template_dir(), template_name)

  if (!file.exists(template_path)) {
    stop(glue("Template not found: {template_path}"))
  }

  # Read the template content
  template_content <- paste(readLines(template_path, warn = FALSE), collapse = "\n")

  # Render with jinjar
  tryCatch({
    render(template_content, !!!data, .config = env)
  }, error = function(e) {
    stop(glue("Error rendering template '{template_name}': {e$message}"))
  })
}

#' Render a partial template (from partials/ subdirectory)
#'
#' Convenience function for rendering partial templates.
#'
#' @param partial_name Character string with partial filename (without partials/ prefix)
#' @param data Named list with template context variables
#' @return Character string with rendered HTML
render_partial <- function(partial_name, data = list()) {
  render_template(file.path("partials", partial_name), data)
}

#' Write rendered HTML to a file with validation
#'
#' Writes the HTML content to the specified path, creating parent directories
#' if needed. Performs basic validation to ensure the content is not empty.
#'
#' @param content Character string with HTML content
#' @param path Character string with output file path
#' @param validate Logical; if TRUE, check that content is non-empty
#' @return Invisible NULL
write_html <- function(content, path, validate = TRUE) {
  if (validate) {
    if (is.null(content) || nchar(trimws(content)) == 0) {
      stop(glue("Cannot write empty content to {path}"))
    }

    # Basic HTML structure validation
    if (!grepl("<!DOCTYPE html>|<html", content, ignore.case = TRUE)) {
      warning(glue("Content written to {path} may not be valid HTML (no DOCTYPE or html tag found)"))
    }
  }

  # Create parent directory if needed
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)

  # Write the file
  writeLines(content, path)

  message(glue("Wrote HTML to: {path}"))
  invisible(NULL)
}

#' Format a date for display
#'
#' @param date Date object or character string
#' @param format Character string with date format (default: "%Y-%m-%d")
#' @return Character string with formatted date
format_date <- function(date, format = "%Y-%m-%d") {
  if (is.character(date)) {
    date <- as.Date(date)
  }
  format(date, format)
}

#' Round a numeric value for display
#'
#' @param x Numeric value
#' @param digits Number of decimal places
#' @return Character string with formatted number
format_number <- function(x, digits = 2) {
  sprintf(paste0("%.", digits, "f"), x)
}
