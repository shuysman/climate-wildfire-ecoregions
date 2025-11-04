# Multi-Ecoregion Deployment Guide

This document describes the refactored multi-ecoregion architecture and deployment procedures for the wildfire forecast system.

## Overview

The system has been refactored from a single-ecoregion (Middle Rockies only) implementation to a **scalable multi-ecoregion architecture** using **AWS Step Functions Map State** for parallel processing.

### Key Changes

- ✅ **YAML-based configuration** for ecoregion definitions
- ✅ **Multi-variable forecast support** (VPD, FM1000, ERC, etc.)
- ✅ **Per-ecoregion output structure** for cleaner organization
- ✅ **Parallel processing** via Step Functions Map State
- ✅ **Maintained full CPU/memory** for intensive processing (16 vCPU, 80GB per task)

---

## Architecture

### Current Implementation (2 Ecoregions)

```
Step Functions: WildfireForecastPipeline
│
├─ State 1: UpdateForecasts (ECS Task)
│   └─ Downloads VPD + FM1000 to S3
│   └─ CPU: 0.5 vCPU | Memory: 1 GB
│
├─ State 2: ProcessEcoregions (Map State - PARALLEL)
│   ├─ Process Task: middle_rockies (16 vCPU, 80 GB)
│   └─ Process Task: southern_rockies (16 vCPU, 80 GB)
│
└─ State 3: GenerateIndex (ECS Task - optional)
    └─ Creates index.html landing page
    └─ CPU: 0.25 vCPU | Memory: 512 MB
```

### Directory Structure

```
out/forecasts/
├── middle_rockies/
│   ├── 2025-11-04/
│   │   ├── fire_danger_forecast.nc
│   │   ├── fire_danger_forecast.png
│   │   ├── fire_danger_forecast_mobile.png
│   │   ├── fire_danger.tif
│   │   └── parks/
│   │       ├── YELL/fire_danger_analysis.html
│   │       └── GRTE/fire_danger_analysis.html
│   ├── 2025-11-03/
│   └── daily_forecast.html  (links to latest/)
│
├── southern_rockies/
│   ├── 2025-11-04/
│   └── daily_forecast.html
│
└── index.html  (landing page)
```

---

## Configuration

### config/ecoregions.yaml

This file defines which ecoregions to process and their optimal predictors:

```yaml
ecoregions:
  - id: 17
    name: "Middle Rockies"
    name_clean: "middle_rockies"
    enabled: true
    cover_types:
      forest:
        window: 15
        variable: "vpd"
        gridmet_varname: "vpd"
      non_forest:
        window: 5
        variable: "vpd"
        gridmet_varname: "vpd"
    parks:
      - YELL
      - GRTE
      # ... (8 parks total)

  - id: 21
    name: "Southern Rockies"
    name_clean: "southern_rockies"
    enabled: true
    cover_types:
      forest:
        window: 5
        variable: "fm1000"
        gridmet_varname: "fm1000"
      non_forest:
        window: 1
        variable: "fm1000"
        gridmet_varname: "fm1000"
    parks:
      - ROMO
      - GRSA
      # ... (8 parks total)
```

**To add a new ecoregion:**

1. Run retrospective analysis (`src/03_dryness.R`) to determine optimal predictor
2. Add ecoregion block to `config/ecoregions.yaml`
3. Set `enabled: true`
4. Deploy updated config to S3
5. No code changes required!

---

## Local Testing

### Test Single Ecoregion

```bash
# Set environment
export ENVIRONMENT=local

# Download forecasts for all required variables
bash src/update_all_forecasts.sh

# Process specific ecoregion
export ECOREGION=middle_rockies
bash src/daily_forecast.sh

# Or pass as command line argument
bash src/daily_forecast.sh middle_rockies
```

### Test Multiple Ecoregions Sequentially

```bash
for ecoregion in middle_rockies southern_rockies; do
  export ECOREGION=$ecoregion
  bash src/daily_forecast.sh
done

# Generate index page
bash src/generate_index_html.sh
```

### View Outputs

```bash
# View directory structure
tree out/forecasts/

# Open dashboards
xdg-open out/forecasts/index.html
xdg-open out/forecasts/middle_rockies/daily_forecast.html
xdg-open out/forecasts/southern_rockies/daily_forecast.html
```

---

## AWS Deployment

### Prerequisites

1. **Update S3 Data**:
   ```bash
   # Upload config
   aws s3 cp config/ecoregions.yaml s3://firecachedata/data/config/

   # Upload eCDF models and quantile rasters for Southern Rockies
   aws s3 sync data/ecdf/21-southern_rockies-forest/ \
     s3://firecachedata/data/ecdf/21-southern_rockies-forest/
   aws s3 sync data/ecdf/21-southern_rockies-non_forest/ \
     s3://firecachedata/data/ecdf/21-southern_rockies-non_forest/

   # Upload classified cover raster
   aws s3 cp data/classified_cover/ecoregion_21_classified.tif \
     s3://firecachedata/data/classified_cover/
   ```

2. **Build and Push Docker Image**:
   ```bash
   ./deploy.sh
   ```

3. **Update Task Definitions**:
   ```bash
   ./register-task-definitions.sh
   ```

### Step Functions Configuration

Update the Step Functions state machine definition in CloudFormation:

```json
{
  "Comment": "Multi-ecoregion wildfire forecast pipeline with Map State",
  "StartAt": "DownloadForecasts",
  "States": {
    "DownloadForecasts": {
      "Type": "Task",
      "Resource": "arn:aws:states:::ecs:runTask.sync",
      "Parameters": {
        "TaskDefinition": "wildfire-forecast-update",
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
      "Retry": [{
        "ErrorEquals": ["States.TaskFailed"],
        "BackoffRate": 1,
        "IntervalSeconds": 1800,
        "MaxAttempts": 12,
        "Comment": "Retry every 30min for up to 6 hours"
      }],
      "Next": "ProcessEcoregions"
    },

    "ProcessEcoregions": {
      "Type": "Map",
      "ItemsPath": "$.ecoregions",
      "ItemSelector": {
        "ecoregion.$": "$$.Map.Item.Value.ecoregion"
      },
      "ItemProcessor": {
        "ProcessorConfig": {
          "Mode": "INLINE"
        },
        "StartAt": "ProcessSingleEcoregion",
        "States": {
          "ProcessSingleEcoregion": {
            "Type": "Task",
            "Resource": "arn:aws:states:::ecs:runTask.sync",
            "Parameters": {
              "TaskDefinition": "wildfire-forecast-process",
              "LaunchType": "FARGATE",
              "Cluster": "${ECS_CLUSTER_ARN}",
              "NetworkConfiguration": {
                "AwsvpcConfiguration": {
                  "Subnets": ["${SUBNET_1}", "${SUBNET_2}"],
                  "SecurityGroups": ["${SECURITY_GROUP}"],
                  "AssignPublicIp": "ENABLED"
                }
              },
              "Overrides": {
                "ContainerOverrides": [{
                  "Name": "wildfire-process-app",
                  "Environment": [
                    {
                      "Name": "ECOREGION",
                      "Value.$": "$.ecoregion"
                    },
                    {
                      "Name": "ENVIRONMENT",
                      "Value": "cloud"
                    },
                    {
                      "Name": "S3_BUCKET_PATH",
                      "Value": "s3://firecachedata"
                    }
                  ]
                }]
              }
            },
            "End": true
          }
        }
      },
      "Next": "GenerateIndexPage"
    },

    "GenerateIndexPage": {
      "Type": "Task",
      "Resource": "arn:aws:states:::ecs:runTask.sync",
      "Parameters": {
        "TaskDefinition": "wildfire-forecast-index",
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
      "End": true
    }
  }
}
```

### Generate Input JSON

```bash
# Generate input JSON from YAML config
bash src/generate_stepfunctions_input.sh > stepfunctions_input.json

# Example output:
# {
#   "ecoregions": [
#     {"ecoregion": "middle_rockies", "ecoregion_id": 17, "ecoregion_name": "Middle Rockies"},
#     {"ecoregion": "southern_rockies", "ecoregion_id": 21, "ecoregion_name": "Southern Rockies"}
#   ]
# }
```

### Manual Trigger

```bash
# Start execution with generated input
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:REGION:ACCOUNT:stateMachine:WildfireForecastPipeline \
  --input file://stepfunctions_input.json
```

### Create Index Task Definition (NEW)

Create `index-task-definition.json`:

```json
{
  "family": "wildfire-forecast-index",
  "taskRoleArn": "arn:aws:iam::791795474719:role/WildfireS3Role",
  "executionRoleArn": "arn:aws:iam::791795474719:role/ecsTaskExecutionRole",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "containerDefinitions": [
    {
      "name": "wildfire-index-app",
      "image": "791795474719.dkr.ecr.us-west-2.amazonaws.com/wildfire-forecast",
      "essential": true,
      "command": ["/bin/bash", "-c", "cd /app && bash src/generate_index_html.sh && aws s3 cp out/forecasts/index.html s3://firecachedata/out/forecasts/ --acl public-read"],
      "environment": [
        {
          "name": "ENVIRONMENT",
          "value": "cloud"
        },
        {
          "name": "S3_BUCKET_PATH",
          "value": "s3://firecachedata"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/wildfire-forecast",
          "awslogs-region": "us-west-2",
          "awslogs-stream-prefix": "index-step"
        }
      }
    }
  ]
}
```

Register it:

```bash
aws ecs register-task-definition --cli-input-json file://index-task-definition.json
```

---

## Cost Analysis

### Per-Day Costs (2 Ecoregions)

| Component | Specs | Runtime | Cost/Day |
|-----------|-------|---------|----------|
| Update Task | 0.5 vCPU, 1 GB | ~10 min | $0.002 |
| Process Task (Middle Rockies) | 16 vCPU, 80 GB | ~10 min | $0.11 |
| Process Task (Southern Rockies) | 16 vCPU, 80 GB | ~10 min | $0.11 |
| Index Task | 0.25 vCPU, 512 MB | ~1 min | $0.001 |
| **Total** | | | **~$0.22/day** |

### Monthly Cost: **~$6.60/month**

---

## Scaling to Additional Ecoregions

### Adding a 3rd Ecoregion (e.g., Northern Rockies)

**Cost Impact:**
- Additional process task: +$0.11/day
- **New monthly cost: ~$9.90/month** (50% increase)

**No infrastructure changes needed!**

1. Add to `config/ecoregions.yaml`
2. Upload pre-computed eCDF models to S3
3. Next scheduled run will automatically include it

### Scaling to 10+ Ecoregions

Consider switching to **Distributed Map State** for truly large-scale deployments:

```json
"ProcessorConfig": {
  "Mode": "DISTRIBUTED",
  "ExecutionType": "EXPRESS"
}
```

This allows processing 10,000+ ecoregions in parallel.

---

## Monitoring

### CloudWatch Logs

```bash
# View update task logs
aws logs tail /ecs/wildfire-forecast --follow --filter-pattern "update-step"

# View process task logs
aws logs tail /ecs/wildfire-forecast --follow --filter-pattern "process-step"

# Filter for specific ecoregion
aws logs filter-log-events \
  --log-group-name /ecs/wildfire-forecast \
  --filter-pattern "southern_rockies"
```

### S3 Output Verification

```bash
# Check outputs for both ecoregions
aws s3 ls s3://firecachedata/out/forecasts/middle_rockies/$(date +%Y-%m-%d)/
aws s3 ls s3://firecachedata/out/forecasts/southern_rockies/$(date +%Y-%m-%d)/

# Verify index page
aws s3 ls s3://firecachedata/out/forecasts/index.html
```

---

## Troubleshooting

### Issue: "Forecast file not found"

**Cause:** Update task failed to download variable forecasts.

**Solution:**
1. Check CloudWatch logs for update task
2. Verify CFSv2 THREDDS server is accessible
3. Manually trigger update task:
   ```bash
   aws ecs run-task \
     --cluster wildfire-forecast-cluster \
     --task-definition wildfire-forecast-update \
     --launch-type FARGATE \
     --network-configuration "awsvpcConfiguration={subnets=[...],securityGroups=[...],assignPublicIp=ENABLED}"
   ```

### Issue: "Ecoregion not found in config"

**Cause:** Config file not synced to S3 or ecoregion disabled.

**Solution:**
1. Verify config in S3:
   ```bash
   aws s3 cp s3://firecachedata/data/config/ecoregions.yaml - | grep -A 5 "southern_rockies"
   ```
2. Ensure `enabled: true` for the ecoregion

### Issue: "Out of memory" errors

**Cause:** Processing multiple high-resolution ecoregions simultaneously.

**Current Architecture:** Each ecoregion gets its own 80GB task, so this shouldn't occur with Map State.

**If it does occur:**
- Check if classified cover rasters are at correct resolution
- Verify `memfrac` setting in R scripts (currently 0.9)

---

## Rollback Plan

If issues arise, revert to single-ecoregion mode:

1. **Disable Southern Rockies in config:**
   ```yaml
   - id: 21
     enabled: false  # <-- Change this
   ```

2. **Update S3 config:**
   ```bash
   aws s3 cp config/ecoregions.yaml s3://firecachedata/data/config/
   ```

3. **System will process only Middle Rockies on next run**

---

## Future Enhancements

1. **Add more ecoregions** (Central Basin & Range, Northern Rockies, etc.)
2. **Implement email notifications** per ecoregion using SNS topics
3. **Add CloudFront caching** for faster page loads
4. **Create REST API** for programmatic access to forecasts
5. **Add historical archive viewer** with date picker

---

## Reference

### Key Files Modified

- `config/ecoregions.yaml` - Central configuration
- `src/map_forecast_danger.R` - Refactored for single-ecoregion mode
- `src/daily_forecast.sh` - Accepts ECOREGION parameter
- `src/update_all_forecasts.sh` - Multi-variable downloader
- `src/generate_index_html.sh` - Landing page generator
- `update-task-definition.json` - Updated to 0.5 vCPU, 1 GB
- CloudFormation - Map State configuration (to be deployed)

### Helpful Commands

```bash
# Generate Step Functions input
bash src/generate_stepfunctions_input.sh

# Test locally
ENVIRONMENT=local ECOREGION=middle_rockies bash src/daily_forecast.sh

# Deploy to AWS
./deploy.sh && ./register-task-definitions.sh

# Check S3 sync status
aws s3 ls --recursive s3://firecachedata/out/forecasts/ | tail -20
```

---

**Last Updated:** 2025-11-04
**Contact:** Northern Rockies Conservation Cooperative / National Park Service
