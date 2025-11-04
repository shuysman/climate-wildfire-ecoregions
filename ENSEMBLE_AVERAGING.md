# Ensemble Averaging for CFSv2 Forecasts

## Problem

Some CFSv2 variables (like FM1000, FM100, ERC) are distributed as **ensemble members** rather than pre-aggregated daily means. The files are named:

```
cfsv2_metdata_forecast_{VARIABLE}_daily_{HH}_{EM}_{DAY}.nc
```

Where:
- **HH** = Forecast hour (00, 06, 12, 18)
- **EM** = Ensemble member (1, 2, 3, 4)
- **DAY** = Day offset (0 = today, 1 = yesterday, 2 = 2 days ago)

For a single day, there are **16 files** (4 forecast hours × 4 ensemble members).

**VPD is the exception** - it has pre-aggregated files (`cfsv2_metdata_forecast_vpd_daily.nc`).

## Solution

The updated `update_rotate_forecast_variable.sh` script automatically:

1. **Detects variable type** (aggregated vs. ensemble)
2. **Downloads all 16 ensemble members** for ensemble variables
3. **Computes ensemble mean** using NCO's `ncea` tool
4. **Creates single forecast file** matching the expected naming convention

## How It Works

### For VPD (Aggregated Format)
```bash
# Downloads single pre-aggregated file
wget http://.../cfsv2_metdata_forecast_vpd_daily.nc

# Saved as:
data/forecasts/vpd/cfsv2_metdata_forecast_vpd_daily_0.nc
```

### For FM1000 (Ensemble Format)
```bash
# Downloads all 16 ensemble members
wget http://.../cfsv2_metdata_forecast_fm1000_daily_00_1_0.nc
wget http://.../cfsv2_metdata_forecast_fm1000_daily_00_2_0.nc
wget http://.../cfsv2_metdata_forecast_fm1000_daily_00_3_0.nc
...
wget http://.../cfsv2_metdata_forecast_fm1000_daily_18_4_0.nc

# Computes ensemble mean using NCO
ncea -O ensemble_temp_fm1000_0/*.nc output.nc

# Saved as:
data/forecasts/fm1000/cfsv2_metdata_forecast_fm1000_daily_0.nc
```

## Required Tools

### NCO (NetCDF Operators)

The script uses `ncea` (NetCDF Ensemble Averager) from the NCO toolkit.

**Installation:**

- **Ubuntu/Debian:**
  ```bash
  apt-get install nco
  ```

- **Conda:**
  ```bash
  conda install -c conda-forge nco
  ```

- **macOS:**
  ```bash
  brew install nco
  ```

**Already included in Dockerfile** (line 10).

## Testing

### Test FM1000 Download Locally

```bash
# Download FM1000 ensemble and compute mean
bash src/update_rotate_forecast_variable.sh fm1000

# Check output
ls -lh data/forecasts/fm1000/

# Should see:
# cfsv2_metdata_forecast_fm1000_daily_0.nc
# cfsv2_metdata_forecast_fm1000_daily_1.nc
# cfsv2_metdata_forecast_fm1000_daily_2.nc

# Check log
cat log/fm1000_forecast.log
```

### Expected Log Output

```
2025-11-04 10:00:00 - [fm1000] Variable fm1000 uses ensemble format - will compute ensemble means
2025-11-04 10:00:01 - [fm1000] Downloading ensemble members for day 0...
2025-11-04 10:00:05 - [fm1000] Warning: Failed to download 06_3_0
2025-11-04 10:00:10 - [fm1000] Successfully downloaded 15 ensemble members for day 0
2025-11-04 10:00:11 - [fm1000] Computing ensemble mean from 15 members...
2025-11-04 10:00:12 - [fm1000] Successfully created ensemble mean: cfsv2_metdata_forecast_fm1000_daily_0.nc
2025-11-04 10:00:12 - [fm1000] Forecast update complete.
```

## Adding New Ensemble Variables

To add support for other ensemble variables (FM100, ERC, etc.), update the `uses_ensemble_format()` function:

```bash
# In src/update_rotate_forecast_variable.sh

uses_ensemble_format() {
  local var=$1
  # VPD has aggregated daily files; others use ensemble format
  case "$var" in
    vpd)
      return 1  # false - uses aggregated format
      ;;
    fm1000|fm100|erc|bi)
      return 0  # true - uses ensemble format
      ;;
    *)
      # Default: assume ensemble format for safety
      return 0
      ;;
  esac
}
```

## Performance Considerations

### Download Time
- **VPD**: ~10 seconds (1 file, ~7 MB)
- **FM1000**: ~2-3 minutes (16 files, ~160 MB total)

### Storage
- Each ensemble variable requires **~160 MB × 3 days = 480 MB**
- VPD requires **~20 MB × 3 days = 60 MB**

### AWS Costs
The update task has been increased to **0.5 vCPU, 1 GB memory** to handle the additional download and processing time for ensemble variables.

**Estimated runtime:**
- VPD only: ~5 minutes
- VPD + FM1000: ~10 minutes

## Ensemble Statistics

The `ncea` tool computes a **simple arithmetic mean** across all ensemble members:

```
ensemble_mean(x,y,t) = (1/N) * Σ(ensemble_member_i(x,y,t))
```

Where N is the number of successfully downloaded ensemble members (typically 15-16).

### Handling Missing Members

If some ensemble members fail to download, the script:
1. ✅ Continues with available members (minimum 1)
2. ✅ Logs warnings for missing members
3. ✅ Computes mean from available members only
4. ❌ Fails only if **all 16 downloads fail**

This provides robustness against transient THREDDS server issues.

## Troubleshooting

### "NCO tools (ncea) not found"

**Problem:** NCO not installed.

**Solution:**
```bash
# Ubuntu/Debian
apt-get install nco

# Verify
ncea --version
```

### "No ensemble files could be downloaded"

**Problem:** THREDDS server unreachable or variable name incorrect.

**Solution:**
1. Check THREDDS server status
2. Verify variable name exists:
   ```bash
   curl -I http://thredds.northwestknowledge.net:8080/thredds/fileServer/NWCSC_INTEGRATED_SCENARIOS_ALL_CLIMATE/cfsv2_metdata_90day/cfsv2_metdata_forecast_fm1000_daily_00_1_0.nc
   ```
3. Check firewall/network access

### "Ensemble mean file is much smaller than expected"

**Problem:** Only partial ensemble members downloaded.

**Solution:**
1. Check log for download warnings
2. Verify THREDDS server stability
3. Increase retry attempts if needed

## References

- **NCO Documentation**: http://nco.sourceforge.net/
- **CFSv2 THREDDS Server**: http://thredds.northwestknowledge.net:8080/thredds/
- **NWCSC Integrated Scenarios**: https://www.northwestknowledge.net/metdata/data/

---

**Last Updated:** 2025-11-04
