#!/usr/bin/env bash
# Builds a self-contained, downloadable CloudFormation release:
#   release/edu-kb-cloudformation.zip
#     ├── edu-kb.yaml            CloudFormation template
#     ├── artifacts/             api.zip, ingest.zip, cfn-site.zip, frontend.zip
#     └── DEPLOY.txt             console deployment steps
# Usage: ./cloudformation/build-release.sh [outDir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/release}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

for cmd in node npm zip; do
  command -v "$cmd" >/dev/null || { echo "error: '$cmd' is required" >&2; exit 1; }
done

echo "==> Installing dependencies"
(cd "$ROOT/infra" && npm ci --no-audit --no-fund --loglevel=error)
(cd "$ROOT/frontend" && npm ci --no-audit --no-fund --loglevel=error)

echo "==> Building web app"
mkdir -p "$STAGE/release/artifacts"
(cd "$ROOT/frontend" && npm run build --silent)
(cd "$ROOT/frontend/dist" && zip -qr "$STAGE/release/artifacts/frontend.zip" .)

echo "==> Bundling Lambda functions"
node "$ROOT/infra/scripts/bundle-lambdas.mjs" "$STAGE/lambda"
for fn in api ingest cfn-site; do
  (cd "$STAGE/lambda/$fn" && zip -qr "$STAGE/release/artifacts/$fn.zip" .)
done

cp "$ROOT/cloudformation/edu-kb.yaml" "$STAGE/release/"
cat > "$STAGE/release/DEPLOY.txt" <<'EOF'
Education Knowledge Base - CloudFormation deployment
====================================================

1. Turn on Bedrock models (Bedrock console > Model access, same region):
   - Anthropic Claude Sonnet 4.6
   - Amazon Titan Text Embeddings V2

2. Upload the code artifacts to an S3 bucket in the SAME region:
   - Create (or pick) a private bucket, e.g. my-edu-kb-artifacts
   - Upload the 4 files in artifacts/ into a folder, e.g. edu-kb/v1/
     (api.zip, ingest.zip, cfn-site.zip, frontend.zip)
   CLI alternative:
     aws s3 cp artifacts/ s3://my-edu-kb-artifacts/edu-kb/v1/ --recursive

3. CloudFormation console > Create stack > Upload a template file > edu-kb.yaml
   Parameters:
   - InstituteName   : your institute name
   - AdminEmail      : receives a temporary password; gets the Manage tab
   - AllowSelfSignUp : true lets students register themselves
   - ArtifactBucket  : my-edu-kb-artifacts
   - ArtifactPrefix  : edu-kb/v1/      (must end with "/")
   Tick "I acknowledge that AWS CloudFormation might create IAM resources", then Create.

4. When the stack is CREATE_COMPLETE (~5-10 min), open the SiteUrl output
   and sign in with the admin email + temporary password.

Updating later: upload new artifacts to a NEW folder (e.g. edu-kb/v2/) and
update the stack with that ArtifactPrefix.

Retained on stack deletion (to protect content): documents S3 bucket,
DynamoDB table, S3 vector bucket/index, Cognito user pool.
EOF

mkdir -p "$OUT"
rm -f "$OUT/edu-kb-cloudformation.zip"
(cd "$STAGE/release" && zip -qr "$OUT/edu-kb-cloudformation.zip" .)
cp "$ROOT/cloudformation/edu-kb.yaml" "$OUT/edu-kb.yaml"
echo
echo "Release: $OUT/edu-kb-cloudformation.zip"
echo "Template: $OUT/edu-kb.yaml"
