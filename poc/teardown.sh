#!/usr/bin/env bash
#
# teardown.sh — Delete the Pipeline Router stack and all resources
#
# Usage:
#   ./teardown.sh                     # default stack name
#   ./teardown.sh my-stack-name       # custom stack name
#
set -euo pipefail

# Source .env from repo root if it exists
if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a
  source "$(dirname "$0")/../.env"
  set +a
fi

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
BUCKET_RESULT=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue" \
  --output text 2>&1) && BUCKET="$BUCKET_RESULT" || {
  echo "  WARNING: Could not describe stack '$STACK_NAME': $BUCKET_RESULT"
  echo "  Stack may not exist or may already be deleted. Attempting cleanup anyway."
  BUCKET=""
}

if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  echo "--- Emptying S3 bucket: $BUCKET ---"

  # Delete all object versions (required for versioned buckets)
  VERSIONS_JSON=$(aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --output json 2>&1) || {
    echo "  WARNING: Could not list object versions for '$BUCKET': $VERSIONS_JSON"
    echo "  Bucket may already be empty or deleted."
    VERSIONS_JSON=""
  }

  if [ -n "$VERSIONS_JSON" ]; then
    echo "$VERSIONS_JSON" | python3 -c "
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
        r = subprocess.run([
            'aws', 's3api', 'delete-objects',
            '--bucket', '$BUCKET',
            '--region', '$REGION',
            '--delete', delete_json,
        ], capture_output=True, text=True)
        if r.returncode != 0:
            print(f'  WARNING: delete-objects failed: {r.stderr.strip()}', file=sys.stderr)
    print(f'  Deleted {len(objects)} object versions')
else:
    print('  Bucket already empty')
" || echo "  WARNING: Failed to empty bucket '$BUCKET'"
  fi
  echo ""
fi

# -----------------------------------------------------------------
# Step 2: Delete the CloudFormation stack
# -----------------------------------------------------------------
echo "--- Deleting CloudFormation stack ---"
if ! aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION"; then
  echo "ERROR: Failed to initiate stack deletion for '$STACK_NAME'"
  exit 1
fi

echo "  Waiting for stack deletion..."
if ! aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION" 2>&1; then
  echo "ERROR: Stack deletion failed or timed out. Check the AWS console for details:"
  aws cloudformation describe-stack-events \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
    --output table 2>/dev/null || true
  exit 1
fi

echo "  Stack deleted."
echo ""

# -----------------------------------------------------------------
# Step 3: Delete the LD secret (if it exists)
# -----------------------------------------------------------------
echo "--- Cleaning up Secrets Manager ---"
SECRET_RESULT=$(aws secretsmanager delete-secret \
  --secret-id "pipeline/launchdarkly-sdk-key" \
  --force-delete-without-recovery \
  --region "$REGION" 2>&1) \
  && echo "  Deleted pipeline/launchdarkly-sdk-key" \
  || {
    if echo "$SECRET_RESULT" | grep -q "ResourceNotFoundException"; then
      echo "  No LD secret found (already deleted or never created)"
    else
      echo "  WARNING: Failed to delete secret: $SECRET_RESULT"
    fi
  }

echo ""
echo "============================================================"
echo "  Teardown complete: $STACK_NAME"
echo "============================================================"
