#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# Register Step Functions state machine definitions with AWS
# Updates both WildfireForecastPipeline and WildfireForecastPipelineTest
# if the local definition differs from the deployed version.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
fi
source "$SCRIPT_DIR/.env"

# Validate required variables
for var in AWS_ACCOUNT_ID AWS_REGION ECS_CLUSTER_NAME S3_BUCKET_NAME SNS_TOPIC_NAME VPC_SUBNET_1 VPC_SUBNET_2 VPC_SECURITY_GROUP; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set in .env"
        exit 1
    fi
done

# Generate JSON definitions from templates
generate_definitions() {
    local vars='${AWS_ACCOUNT_ID} ${AWS_REGION} ${ECS_CLUSTER_NAME} ${S3_BUCKET_NAME} ${SNS_TOPIC_NAME} ${VPC_SUBNET_1} ${VPC_SUBNET_2} ${VPC_SECURITY_GROUP}'
    for template in "$SCRIPT_DIR"/stepfunctions-pipeline*.json.template; do
        local output="${template%.template}"
        envsubst "$vars" < "$template" > "$output"
        echo "Generated $(basename "$output") from template"
    done
}

generate_definitions

# Update a state machine if its definition has changed
update_if_changed() {
    local definition_file="$1"
    local state_machine_name="$2"
    local state_machine_arn="arn:aws:states:${AWS_REGION}:${AWS_ACCOUNT_ID}:stateMachine:${state_machine_name}"

    echo "Processing state machine: $state_machine_name"

    # Get current definition from AWS
    current_definition=$(aws stepfunctions describe-state-machine \
        --state-machine-arn "$state_machine_arn" \
        --query 'definition' --output text 2>/dev/null || echo "{}")

    # Normalize both for comparison (sort keys, compact)
    normalized_current=$(echo "$current_definition" | jq -S '.' 2>/dev/null || echo "{}")
    normalized_new=$(jq -S '.' "$definition_file")

    if [ "$normalized_current" == "$normalized_new" ]; then
        echo "✓ $state_machine_name has no changes. Skipping update."
    else
        echo "⚠ $state_machine_name has changes. Updating..."
        aws stepfunctions update-state-machine \
            --state-machine-arn "$state_machine_arn" \
            --definition "file://$definition_file"
        echo "✓ $state_machine_name updated successfully."
    fi
}

update_if_changed "$SCRIPT_DIR/stepfunctions-pipeline.json" "WildfireForecastPipeline"
update_if_changed "$SCRIPT_DIR/stepfunctions-pipeline-test.json" "WildfireForecastPipelineTest"
