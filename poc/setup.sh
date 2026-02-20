#!/usr/bin/env bash
#
# setup.sh — Deploy the Pipeline Router stack to AWS
#
# Usage:
#   ./setup.sh --ld-key sdk-xxx --layer-arn arn:aws:lambda:...
#
# Requires:
#   --ld-key      LaunchDarkly server-side SDK key
#   --layer-arn   ARN of the launchdarkly-server-sdk Lambda Layer
#
# Optional:
#   --stack-name  CloudFormation stack name (default: pipeline-router)
#
set -euo pipefail

if [ -z "${AWS_PROFILE:-}" ]; then
  echo "ERROR: AWS_PROFILE is not set. Export it or add it to .env"
  exit 1
fi
STACK_NAME="pipeline-router"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
LD_SDK_KEY=""
LD_LAYER_ARN=""
LD_SECRET_NAME="pipeline/launchdarkly-sdk-key"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --ld-key)
      LD_SDK_KEY="$2"
      shift 2
      ;;
    --layer-arn)
      LD_LAYER_ARN="$2"
      shift 2
      ;;
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      echo "Usage: ./setup.sh --ld-key sdk-xxx --layer-arn arn:aws:lambda:..."
      exit 1
      ;;
  esac
done

# Validate required args
if [ -z "$LD_SDK_KEY" ]; then
  echo "ERROR: --ld-key is required"
  echo "Usage: ./setup.sh --ld-key sdk-xxx --layer-arn arn:aws:lambda:..."
  exit 1
fi

if [ -z "$LD_LAYER_ARN" ]; then
  echo "ERROR: --layer-arn is required"
  echo "Run ./build_layer.sh first to create the Lambda Layer."
  exit 1
fi

echo "============================================================"
echo "  Pipeline Router PoC — AWS Deployment"
echo "============================================================"
echo ""
echo "  Stack name:  $STACK_NAME"
echo "  Region:      $REGION"
echo "  Profile:     $AWS_PROFILE"
echo "  LD SDK key:  ${LD_SDK_KEY:0:12}..."
echo "  LD Layer:    $LD_LAYER_ARN"
echo ""

# -----------------------------------------------------------------
# Step 1: Store LD SDK key in Secrets Manager
# -----------------------------------------------------------------
echo "--- Storing LD SDK key in Secrets Manager ---"
aws secretsmanager create-secret \
  --name "$LD_SECRET_NAME" \
  --secret-string "{\"sdk_key\": \"${LD_SDK_KEY}\"}" \
  --region "$REGION" \
  --output text --query 'ARN' 2>/dev/null \
|| \
aws secretsmanager update-secret \
  --secret-id "$LD_SECRET_NAME" \
  --secret-string "{\"sdk_key\": \"${LD_SDK_KEY}\"}" \
  --region "$REGION" \
  --output text --query 'ARN'
echo "  Done."
echo ""

# -----------------------------------------------------------------
# Step 2: Deploy CloudFormation stack
# -----------------------------------------------------------------
echo "--- Deploying CloudFormation stack ---"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/../pipeline-router-stack.yaml" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides \
    LDLayerArn="${LD_LAYER_ARN}" \
    LDSecretName="${LD_SECRET_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset

echo "  Stack deployed."
echo ""

# -----------------------------------------------------------------
# Step 3: Get stack outputs
# -----------------------------------------------------------------
echo "--- Retrieving stack outputs ---"

BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue" \
  --output text)

ROUTER_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RouterLambdaName'].OutputValue" \
  --output text)

V1_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='PipelineV1Url'].OutputValue" \
  --output text)

V2_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='PipelineV2Url'].OutputValue" \
  --output text)

echo "  Artifact bucket: $BUCKET"
echo "  Router Lambda:   $ROUTER_NAME"
echo ""

# -----------------------------------------------------------------
# Step 4: Upload placeholder source artifact to S3
# -----------------------------------------------------------------
echo "--- Uploading placeholder source artifact ---"

TMPDIR=$(mktemp -d)
echo '{"app": "placeholder", "version": "1.0.0"}' > "$TMPDIR/buildspec.yml"
echo 'print("hello world")' > "$TMPDIR/app.py"
(cd "$TMPDIR" && zip -q app.zip buildspec.yml app.py)

aws s3 cp "$TMPDIR/app.zip" "s3://$BUCKET/source/app.zip" --region "$REGION"
rm -rf "$TMPDIR"

echo "  Uploaded s3://$BUCKET/source/app.zip"
echo ""

# -----------------------------------------------------------------
# Summary
# -----------------------------------------------------------------
echo "============================================================"
echo "  Setup complete!"
echo "============================================================"
echo ""
echo "  Stack:           $STACK_NAME"
echo "  Router Lambda:   $ROUTER_NAME"
echo "  Artifact Bucket: $BUCKET"
echo ""
echo "  Pipeline V1: $V1_URL"
echo "  Pipeline V2: $V2_URL"
echo ""
echo "  Next steps:"
echo "    ./deploy.sh                    # trigger both apps"
echo "    ./deploy.sh drug-research-portal     # trigger one app"
echo "    ./teardown.sh                  # delete everything"
echo ""
echo "  Pipeline version is controlled in the LaunchDarkly dashboard."
echo "============================================================"
