#!/usr/bin/env bash
# Builds the Lambda bundles and the web app, zips them and uploads them to an S3
# artifact bucket (created if missing) under a new versioned prefix.
#
# Usage: ./cloudformation/package.sh <artifact-bucket> [region]
# Prints the ArtifactPrefix to pass to the CloudFormation template.
set -euo pipefail

BUCKET="${1:?usage: package.sh <artifact-bucket> [region]}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="edu-kb/$(date -u +%Y%m%d%H%M%S)/"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

for cmd in node npm zip aws; do
  command -v "$cmd" >/dev/null || { echo "error: '$cmd' is required" >&2; exit 1; }
done

echo "==> Installing dependencies"
(cd "$ROOT/infra" && npm ci --no-audit --no-fund --loglevel=error)
(cd "$ROOT/frontend" && npm ci --no-audit --no-fund --loglevel=error)

echo "==> Building web app"
(cd "$ROOT/frontend" && npm run build --silent)
(cd "$ROOT/frontend/dist" && zip -qr "$BUILD/frontend.zip" .)

echo "==> Bundling Lambda functions"
node "$ROOT/infra/scripts/bundle-lambdas.mjs" "$BUILD/lambda"
for fn in api ingest cfn-site; do
  (cd "$BUILD/lambda/$fn" && zip -qr "$BUILD/$fn.zip" .)
done

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
  echo "==> Creating private artifact bucket s3://$BUCKET in $REGION"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --region "$REGION" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

echo "==> Uploading artifacts to s3://$BUCKET/$PREFIX"
for f in api ingest cfn-site frontend; do
  aws s3 cp "$BUILD/$f.zip" "s3://$BUCKET/$PREFIX$f.zip" --region "$REGION" --only-show-errors
done

echo "$PREFIX" > "$ROOT/cloudformation/.last-artifact-prefix"
echo
echo "Done. Template parameters:"
echo "  ArtifactBucket=$BUCKET"
echo "  ArtifactPrefix=$PREFIX"
