#!/usr/bin/env bash
# run_tests.sh
# Run all test suites for the fire danger forecast system

set -euo pipefail

echo "========================================="
echo "Running Fire Danger Forecast Test Suite"
echo "========================================="
echo ""

# Run core function tests
echo "Running core function tests..."
Rscript tests/test_core_functions.R

echo ""
echo "========================================="
echo "All test suites completed successfully"
echo "========================================="
