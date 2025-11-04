#!/usr/bin/env bash
# Generate index.html landing page with links to all enabled ecoregions

set -euo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)
cd "$PROJECT_DIR"

TODAY=$(date +%Y-%m-%d)
OUTPUT_FILE="out/forecasts/index.html"

echo "========================================="
echo "Generating index landing page"
echo "Date: $TODAY"
echo "========================================="

# Get enabled ecoregions from YAML config
ECOREGIONS_DATA=$(Rscript -e "
suppressPackageStartupMessages(library(yaml))
config <- read_yaml('config/ecoregions.yaml')
enabled <- config\$ecoregions[sapply(config\$ecoregions, function(x) isTRUE(x\$enabled))]
if (length(enabled) == 0) {
  stop('No enabled ecoregions found in config')
}
for (eco in enabled) {
  cat(eco\$name_clean, '|', eco\$name, '\\n', sep='')
}
")

if [ -z "$ECOREGIONS_DATA" ]; then
  echo "Error: No enabled ecoregions found" >&2
  exit 1
fi

# Create HTML header
cat > "$OUTPUT_FILE" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Wildfire Danger Forecasts</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }

        .container {
            background: white;
            border-radius: 16px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            max-width: 800px;
            width: 100%;
            padding: 40px;
        }

        h1 {
            color: #2c3e50;
            font-size: 2.5em;
            margin-bottom: 10px;
            text-align: center;
        }

        .subtitle {
            color: #7f8c8d;
            text-align: center;
            margin-bottom: 40px;
            font-size: 1.1em;
        }

        .ecoregion-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-top: 30px;
        }

        .ecoregion-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            border-radius: 12px;
            padding: 30px;
            text-decoration: none;
            color: white;
            transition: transform 0.2s, box-shadow 0.2s;
            display: block;
        }

        .ecoregion-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
        }

        .ecoregion-card h2 {
            font-size: 1.5em;
            margin-bottom: 10px;
        }

        .ecoregion-card p {
            opacity: 0.9;
            font-size: 0.95em;
        }

        .arrow {
            float: right;
            font-size: 1.5em;
        }

        .footer {
            margin-top: 40px;
            text-align: center;
            color: #7f8c8d;
            font-size: 0.9em;
        }

        @media (max-width: 600px) {
            h1 {
                font-size: 2em;
            }

            .container {
                padding: 25px;
            }

            .ecoregion-grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔥 Wildfire Danger Forecasts</h1>
        <p class="subtitle">8-Day Fire Danger Predictions by Ecoregion</p>

        <div class="ecoregion-grid">
EOF

# Add ecoregion cards
while IFS='|' read -r name_clean name; do
  cat >> "$OUTPUT_FILE" << EOF
            <a href="${name_clean}/daily_forecast.html" class="ecoregion-card">
                <h2>${name} <span class="arrow">→</span></h2>
                <p>View fire danger forecast and park analyses</p>
            </a>
EOF
done <<< "$ECOREGIONS_DATA"

# Add HTML footer
cat >> "$OUTPUT_FILE" << EOF
        </div>

        <div class="footer">
            <p>Updated: ${TODAY}</p>
            <p>National Park Service | Northern Rockies Conservation Cooperative</p>
        </div>
    </div>
</body>
</html>
EOF

echo "========================================="
echo "Successfully generated index.html"
echo "Output: $OUTPUT_FILE"
echo "Linked ecoregions:"
echo "$ECOREGIONS_DATA" | cut -d'|' -f2
echo "========================================="
