#!/bin/bash
#
# demo_lightning.sh
#
# Convenience wrapper for running the lightning strike danger demonstration.
# Builds the container and runs the demo, then offers to open the result.
#
# Usage:
#   ./demo_lightning.sh                              # Default: middle_rockies, 50 strikes, high danger
#   ./demo_lightning.sh southern_rockies 100         # Custom ecoregion and strike count
#   ./demo_lightning.sh middle_rockies 50 extreme    # Extreme fire danger simulation
#   ./demo_lightning.sh middle_rockies 50 high --open  # Open result in browser
#
# Danger modes:
#   - extreme: Nearly all areas at maximum fire danger (demo worst-case scenario)
#   - high: Elevated fire danger across the region (default, good for demos)
#   - moderate: Moderately elevated danger
#   - normal: Use actual/unmodified fire danger values
#
# Available ecoregions:
#   - middle_rockies (has real fire danger data if forecast exists)
#   - southern_rockies
#   - colorado_plateaus
#   - mojave_basin_and_range

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Defaults
ECOREGION="${1:-middle_rockies}"
N_STRIKES="${2:-50}"
DANGER_MODE="${3:-high}"
OPEN_BROWSER=false

# Check for --open flag (can be in any position)
for arg in "$@"; do
    if [[ "$arg" == "--open" ]]; then
        OPEN_BROWSER=true
    fi
done

# If danger mode is --open, reset to default
if [[ "$DANGER_MODE" == "--open" ]]; then
    DANGER_MODE="high"
fi

OUTPUT_DIR="$PROJECT_ROOT/out/demo"
OUTPUT_FILE="$OUTPUT_DIR/lightning_demo_${ECOREGION}.html"

echo "==================================================="
echo "Lightning Strike Danger Demo"
echo "==================================================="
echo "Ecoregion: $ECOREGION"
echo "Mock strikes: $N_STRIKES"
echo "Danger mode: $DANGER_MODE"
echo "Output: $OUTPUT_FILE"
echo ""

# Build container (uses cache if no changes)
echo "Building container..."
cd "$PROJECT_ROOT"
podman build -t wildfire-forecast . -q

# Run the demo
echo ""
echo "Running demo..."
podman run --rm \
    -v "$PROJECT_ROOT/data:/app/data:ro" \
    -v "$PROJECT_ROOT/out:/app/out" \
    wildfire-forecast \
    Rscript src/operational/visualization/demo_lightning_map.R "$ECOREGION" "$N_STRIKES" /app/out/demo "$DANGER_MODE"

# Check if output was created
if [[ -f "$OUTPUT_FILE" ]]; then
    echo ""
    echo "==================================================="
    echo "Demo completed successfully!"
    echo "==================================================="
    echo ""
    echo "Output: $OUTPUT_FILE"
    echo ""

    if $OPEN_BROWSER; then
        echo "Opening in browser..."
        xdg-open "$OUTPUT_FILE" 2>/dev/null || open "$OUTPUT_FILE" 2>/dev/null || echo "Could not auto-open. Please open manually."
    else
        echo "To view the demo:"
        echo "  xdg-open $OUTPUT_FILE"
        echo ""
        echo "Or run with --open flag:"
        echo "  $0 $ECOREGION $N_STRIKES --open"
    fi
else
    echo "Error: Demo output not found at $OUTPUT_FILE"
    exit 1
fi
