#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Load AWS configuration from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
fi
source "$SCRIPT_DIR/.env"

# Validate required variables
for var in AWS_ACCOUNT_ID AWS_REGION ECR_REPOSITORY_NAME S3_BUCKET_NAME IAM_TASK_ROLE_NAME IAM_EXECUTION_ROLE_NAME; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set in .env"
        exit 1
    fi
done

# Generate JSON task definitions from templates
generate_task_definitions() {
  local vars='${AWS_ACCOUNT_ID} ${AWS_REGION} ${ECR_REPOSITORY_NAME} ${S3_BUCKET_NAME} ${IAM_TASK_ROLE_NAME} ${IAM_EXECUTION_ROLE_NAME}'
  for template in "$SCRIPT_DIR"/*-task-definition.json.template; do
    local output="${template%.template}"
    envsubst "$vars" < "$template" > "$output"
    echo "Generated $(basename "$output") from template"
  done
}

generate_task_definitions

# Function to register a task definition only if it has changed
register_if_changed() {
  local task_def_file="$1"
  local family_name=$(jq -r '.family' "$task_def_file")

  echo "Processing task definition: $family_name from $task_def_file"

  # Get the current active task definition, or an empty JSON if it doesn't exist
  current_task_def_json=$(aws ecs describe-task-definition --task-definition "$family_name" --query 'taskDefinition' --output json 2>/dev/null || echo "{}")

  # Prepare the new task definition JSON from the local file
  new_task_def_json=$(cat "$task_def_file")

  # Normalize both JSONs for comparison by removing volatile fields,
  # sorting keys and arrays for consistent comparison.
  normalized_current=$(echo "$current_task_def_json" | jq -S 'del(
    .taskDefinitionArn,
    .revision,
    .status,
    .registeredAt,
    .deregisteredAt,
    .compatibilities,
    .requiresAttributes,
    .placementConstraints,
    .registeredBy,
    .volumes
  ) | .containerDefinitions |= map(
    del(
      .cpu,
      .mountPoints,
      .portMappings,
      .systemControls,
      .volumesFrom,
      .dependsOn,
      .links,
      .dockerSecurityOptions,
      .ulimits,
      .extraHosts,
      .dnsServers,
      .dnsSearchDomains,
      .dockerLabels,
      .linuxParameters,
      .firelensConfiguration
    ) | .environment |= sort_by(.name)
  )')
  normalized_new=$(echo "$new_task_def_json" | jq -S 'del(.volumes) | .containerDefinitions |= map(
    del(
      .cpu,
      .mountPoints,
      .portMappings,
      .systemControls,
      .volumesFrom
    ) | .environment |= sort_by(.name)
  )')

  # Compare the normalized JSONs
  if [ "$normalized_current" == "$normalized_new" ]; then
    echo "✓ Task definition $family_name has no changes. Skipping registration."
  else
    echo "⚠ Task definition $family_name has changes. Registering new revision."

    # Optional: Show the diff for debugging (uncomment to see differences)
    # echo "Differences detected:"
    # diff <(echo "$normalized_current" | jq -S .) <(echo "$normalized_new" | jq -S .) || true

    aws ecs register-task-definition --cli-input-json "file://$task_def_file" --tags key=project,value=wildfire-forecast
  fi
}

# Call the function for each task definition file
register_if_changed "update-task-definition.json"
register_if_changed "process-task-definition.json"
register_if_changed "lightning-task-definition.json"
register_if_changed "index-task-definition.json"
register_if_changed "regenerate-html-task-definition.json"
