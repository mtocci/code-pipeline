#!/usr/bin/env bash
#
# teardown.sh — Delete the Pipeline Router stack and all resources
#
# Usage:
#   ./teardown.sh                     # default stack name
#   ./teardown.sh my-stack-name       # custom stack name
#
set -euo pipefail

if [ -z "${AWS_PROFILE:-}" ]; then
  echo "ERROR: AWS_PROFILE is not set. Export it or add it to .env"
  exit 1
fi
STACK_NAME="${1:-pipeline-router}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "============================================================"
echo "  Tearing down: $STACK_NAME"
echo "  Region:       $REGION"
echo "============================================================"
echo ""

# -----------------------------------------------------------------
# Step 1: Get and empty the artifact bucket
# -----------------------------------------------------------------
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  echo "--- Emptying S3 bucket: $BUCKET ---"

  # Delete all object versions (required for versioned buckets)
  aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --output json 2>/dev/null | \
  python3 -c "
import json, sys, subprocess
data = json.load(sys.stdin)
objects = []
for v in data.get('Versions', []):
    objects.append({'Key': v['Key'], 'VersionId': v['VersionId']})
for m in data.get('DeleteMarkers', []):
    objects.append({'Key': m['Key'], 'VersionId': m['VersionId']})
if objects:
    # Delete in batches of 1000
    for i in range(0, len(objects), 1000):
        batch = objects[i:i+1000]
        delete_json = json.dumps({'Objects': batch, 'Quiet': True})
        subprocess.run([
            'aws', 's3api', 'delete-objects',
            '--bucket', '$BUCKET',
            '--region', '$REGION',
            '--delete', delete_json,
        ], check=True, capture_output=True)
    print(f'  Deleted {len(objects)} object versions')
else:
    print('  Bucket already empty')
" 2>/dev/null || echo "  Warning: could not empty bucket (may already be empty)"
  echo ""
fi

# -----------------------------------------------------------------
# Step 2: Delete the CloudFormation stack
# -----------------------------------------------------------------
echo "--- Deleting CloudFormation stack ---"
aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "  Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION" 2>/dev/null || true

echo "  Stack deleted."
echo ""

# -----------------------------------------------------------------
# Step 3: Delete the LD secret (if it exists)
# -----------------------------------------------------------------
echo "--- Cleaning up Secrets Manager ---"
aws secretsmanager delete-secret \
  --secret-id "pipeline/launchdarkly-sdk-key" \
  --force-delete-without-recovery \
  --region "$REGION" 2>/dev/null \
  && echo "  Deleted pipeline/launchdarkly-sdk-key" \
  || echo "  No LD secret found (already deleted or never created)"

echo ""
echo "============================================================"
echo "  Teardown complete: $STACK_NAME"
echo "============================================================"
