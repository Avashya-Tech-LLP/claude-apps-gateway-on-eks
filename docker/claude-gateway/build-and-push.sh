#!/usr/bin/env bash
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)
PROJECT="claude-gateway"
CLAUDE_VERSION="${1:-2.1.195}"

ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${PROJECT}-claude-gateway"
IMAGE_TAG="${ECR_REPO}:${CLAUDE_VERSION}"

echo "==> Logging in to ECR..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> Building image: ${IMAGE_TAG}"
docker buildx build \
  --platform linux/amd64 \
  --build-arg CLAUDE_VERSION="${CLAUDE_VERSION}" \
  -t "${IMAGE_TAG}" \
  -t "${ECR_REPO}:latest" \
  --push \
  .

echo "==> Done. Image pushed:"
echo "    ${IMAGE_TAG}"
