# HTML Regeneration Task

## Overview

This task regenerates the HTML dashboards for all enabled ecoregions without re-running the forecast generation. This is useful for:

- Updating dashboard templates after HTML/CSS changes
- Fixing display bugs without expensive forecast recomputation
- Quickly updating park analysis navigation
- Regenerating the landing page with new ecoregions

## How It Works

The `regenerate_all_html.sh` script:

1. Syncs existing forecast outputs from S3 (contains PNG maps, park plots, etc.)
2. Reads enabled ecoregions from `config/ecoregions.yaml`
3. For each enabled ecoregion:
   - Runs `generate_daily_html.sh` to rebuild the dashboard
   - Uses existing forecast data (no re-computation)
4. Regenerates the index landing page
5. Syncs updated HTML files back to S3

**Important**: This only updates HTML files. It does NOT regenerate:
- Forecast NetCDF or PNG maps
- Park threshold plots
- Cloud-Optimized GeoTIFFs
- Lightning maps

## Local Testing

```bash
# Test locally (uses local forecast outputs)
ENVIRONMENT=local bash src/regenerate_all_html.sh

# Test with Docker
docker run --rm \
  -v $(pwd)/out:/app/out \
  -v $(pwd)/config:/app/config \
  -e ENVIRONMENT=local \
  wildfire-forecast bash src/regenerate_all_html.sh
```

## AWS Deployment

### 1. Register the Task Definition

```bash
./register-task-definitions.sh
```

This registers the `wildfire-forecast-regenerate-html` task definition.

### 2. Run Manually (AWS CLI)

```bash
# Run the HTML regeneration task
aws ecs run-task \
  --cluster wildfire-forecast-cluster \
  --task-definition wildfire-forecast-regenerate-html \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxxxx],securityGroups=[sg-xxxxx],assignPublicIp=ENABLED}"
```

Replace `subnet-xxxxx` and `sg-xxxxx` with your actual subnet and security group IDs.

### 3. Run via AWS Console

1. Go to **ECS Console** → **Task Definitions**
2. Find `wildfire-forecast-regenerate-html`
3. Click **Run Task**
4. Select:
   - Launch type: **FARGATE**
   - Cluster: **wildfire-forecast-cluster**
   - VPC: Your VPC
   - Subnets: Your public subnets
   - Security group: Your wildfire forecast security group
   - Auto-assign public IP: **ENABLED**
5. Click **Run Task**

### 4. Monitor Execution

Check CloudWatch Logs:
```bash
aws logs tail /ecs/wildfire-forecast --follow --filter-pattern "regenerate-html"
```

Or view in AWS Console: **CloudWatch** → **Log Groups** → `/ecs/wildfire-forecast` → `regenerate-html-step/...`

## Task Resources

- **CPU**: 512 (0.5 vCPU) - sufficient for HTML generation
- **Memory**: 1024 MB (1 GB) - handles R script execution
- **Runtime**: ~1-2 minutes for 2 ecoregions
- **Cost**: ~$0.01 per run (Fargate pricing)

## Common Use Cases

### After Template Changes

After updating `src/daily_forecast.template.html`:

```bash
# 1. Deploy updated Docker image
./deploy.sh

# 2. Run HTML regeneration task
aws ecs run-task \
  --cluster wildfire-forecast-cluster \
  --task-definition wildfire-forecast-regenerate-html \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={...}"
```

### After Config Changes

After adding a new park to `config/ecoregions.yaml`:

```bash
# 1. Upload new config to S3
aws s3 cp config/ecoregions.yaml s3://firecachedata/config/

# 2. Run HTML regeneration
aws ecs run-task ... (same as above)
```

### After Dropdown/CSS Changes

After fixing the ecoregion dropdown CSS:

```bash
# Just run the HTML regeneration task (same as above)
```

## Integration with Step Functions (Optional)

You can add this as a step in your Step Functions pipeline if you want to regenerate HTML automatically after forecasts complete:

```json
{
  "RegenerateHTML": {
    "Type": "Task",
    "Resource": "arn:aws:states:::ecs:runTask.sync",
    "Parameters": {
      "TaskDefinition": "wildfire-forecast-regenerate-html",
      "LaunchType": "FARGATE",
      "Cluster": "${ECS_CLUSTER_ARN}",
      "NetworkConfiguration": {
        "AwsvpcConfiguration": {
          "Subnets": ["${SUBNET_1}", "${SUBNET_2}"],
          "SecurityGroups": ["${SECURITY_GROUP}"],
          "AssignPublicIp": "ENABLED"
        }
      }
    },
    "ResultPath": null,
    "Next": "NextStep"
  }
}
```

## Troubleshooting

### Issue: "No enabled ecoregions found"

**Cause**: Config file not synced to S3 or all ecoregions disabled.

**Solution**:
```bash
aws s3 cp config/ecoregions.yaml s3://firecachedata/config/
```

### Issue: "Forecast outputs not found"

**Cause**: No forecasts have been generated yet for today.

**Solution**: Run the full forecast pipeline first, then regenerate HTML.

### Issue: "Failed to sync HTML to S3"

**Cause**: IAM permissions issue or S3 bucket path incorrect.

**Solution**: Verify task role has `s3:PutObject` permission on `s3://firecachedata/out/forecasts/*`

## Files

- **Script**: `src/regenerate_all_html.sh`
- **Task Definition**: `regenerate-html-task-definition.json`
- **Registration**: Added to `register-task-definitions.sh`

## Performance

| Ecoregions | Runtime | Cost (est.) |
|------------|---------|-------------|
| 1          | ~30s    | $0.005      |
| 2          | ~1min   | $0.008      |
| 5          | ~2min   | $0.015      |
| 10         | ~4min   | $0.025      |

*Based on Fargate pricing: $0.04048/vCPU-hour + $0.004445/GB-hour*
