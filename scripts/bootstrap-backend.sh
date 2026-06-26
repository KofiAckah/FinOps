#!/usr/bin/env bash
# Creates the S3 bucket that holds Terraform remote state. Run this ONCE per
# account, before the first `terraform init`. Idempotent — safe to re-run.
#
#   ./scripts/bootstrap-backend.sh
#
# The bucket name must match backend.tf.
set -euo pipefail

REGION="eu-west-1"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="finops-tfstate-${ACCOUNT_ID}"

echo "Account : ${ACCOUNT_ID}"
echo "Bucket  : ${BUCKET}"
echo "Region  : ${REGION}"

if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "Bucket already exists — nothing to do."
else
  echo "Creating bucket..."
  aws s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
fi

# Versioning lets you recover a clobbered or corrupted state file.
aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

# Encrypt state at rest.
aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Block all public access to the state bucket.
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Backend bucket ready: ${BUCKET}"
echo "Now run: terraform init"
