#!/usr/bin/env bash
#
# build_layer.sh — Build and publish the LaunchDarkly SDK Lambda Layer
#
# Usage:
#   ./build_layer.sh                     # build + publish, prints ARN
#
# Creates a Lambda Layer containing launchdarkly-server-sdk, compatible
# with Python 3.12 on Amazon Linux 2023.
#
set -euo pipefail

if [ -z "${AWS_PROFILE:-}" ]; then
  echo "ERROR: AWS_PROFILE is not set. Export it or add it to .env"
  exit 1
fi
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
LAYER_NAME="launchdarkly-server-sdk"
PYTHON_VERSION="python3.12"

echo "============================================================"
echo "  Building LaunchDarkly SDK Lambda Layer"
echo "============================================================"
echo ""

TMPDIR=$(mktemp -d)
LAYER_DIR="$TMPDIR/python"
mkdir -p "$LAYER_DIR"

echo "--- Installing launchdarkly-server-sdk ---"
pip3 install \
  --target "$LAYER_DIR" \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  launchdarkly-server-sdk 2>&1 | tail -5

echo ""
echo "--- Packaging layer zip ---"
(cd "$TMPDIR" && zip -qr layer.zip python/)
LAYER_SIZE=$(du -sh "$TMPDIR/layer.zip" | cut -f1)
echo "  Layer size: $LAYER_SIZE"

echo ""
echo "--- Publishing Lambda Layer ---"
LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name "$LAYER_NAME" \
  --zip-file "fileb://$TMPDIR/layer.zip" \
  --compatible-runtimes "$PYTHON_VERSION" \
  --region "$REGION" \
  --output text --query 'LayerVersionArn')

rm -rf "$TMPDIR"

echo ""
echo "============================================================"
echo "  Layer published!"
echo "============================================================"
echo ""
echo "  Layer ARN: $LAYER_ARN"
echo ""
echo "  Use with setup.sh:"
echo "    ./setup.sh --ld-key sdk-xxx --layer-arn $LAYER_ARN"
echo "============================================================"
