#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# --- Configuration ---
# Load AWS configuration from .env file
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
fi
source "$SCRIPT_DIR/.env"

# Validate required variables
for var in AWS_ACCOUNT_ID AWS_REGION ECR_REPOSITORY_NAME ECS_CLUSTER_NAME ECS_SERVICE_NAME; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set in .env"
        exit 1
    fi
done

IMAGE_TAG="latest"

# ==============================================================================
# --- Script Logic ---
# ==============================================================================

# Construct the full ECR repository URI
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
FULL_IMAGE_NAME="$ECR_URI/$ECR_REPOSITORY_NAME:$IMAGE_TAG"

# --- 1. Build the Container Image ---
echo "Building the container image..."
podman build -t "$ECR_REPOSITORY_NAME:$IMAGE_TAG" .

# --- 2. Authenticate to Amazon ECR ---
echo "Authenticating to Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | podman login --username AWS --password-stdin "$ECR_URI"

# --- 3. Tag the Image for ECR ---
echo "Tagging the image for ECR..."
podman tag "$ECR_REPOSITORY_NAME:$IMAGE_TAG" "$FULL_IMAGE_NAME"

# --- 4. Push the Image to ECR ---
echo "Pushing the image to ECR..."
podman push "$FULL_IMAGE_NAME"

echo "--- Deployment Complete! ---"
echo "The Fargate service '$ECS_SERVICE_NAME' has been updated and a new deployment has been started."
