#!/usr/bin/env bash
# Generate Step Functions input JSON for Map State from YAML config
# This script reads the enabled ecoregions from config and generates
# the JSON array needed for the Step Functions Map State

set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. &> /dev/null && pwd)
cd "$PROJECT_DIR"

echo "Generating Step Functions input JSON from config/ecoregions.yaml..." >&2

# Generate JSON array from YAML config
Rscript -e "
suppressPackageStartupMessages(library(yaml))
suppressPackageStartupMessages(library(jsonlite))

config <- read_yaml('config/ecoregions.yaml')
enabled <- config\$ecoregions[sapply(config\$ecoregions, function(x) isTRUE(x\$enabled))]

if (length(enabled) == 0) {
  stop('No enabled ecoregions found in config')
}

# Create array of ecoregion objects for Step Functions
ecoregions_array <- lapply(enabled, function(eco) {
  list(
    ecoregion = eco\$name_clean,
    ecoregion_id = eco\$id,
    ecoregion_name = eco\$name
  )
})

# Wrap in input object
input_json <- list(ecoregions = ecoregions_array)

# Output pretty JSON
cat(toJSON(input_json, pretty = TRUE, auto_unbox = TRUE))
"

echo "" >&2
echo "Step Functions input JSON generated successfully." >&2
echo "Use this JSON when manually triggering the Step Functions state machine." >&2
