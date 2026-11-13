#!/usr/bin/env bash
# Packages the code and creates/updates the CloudFormation stack in one step.
#
# Usage:
#   ./cloudformation/deploy.sh --bucket <artifact-bucket> [--region us-east-1] [--stack EduKnowledgeBase]
#                              [--institute "ABC College"] [--admin-email admin@example.edu] [--self-signup true|false]
# On updates, parameters you omit keep their current values.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK="EduKnowledgeBase"
BUCKET="" INSTITUTE="" ADMIN_EMAIL="" SELF_SIGNUP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --institute) INSTITUTE="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --self-signup) SELF_SIGNUP="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[ -n "$BUCKET" ] || { echo "error: --bucket <artifact-bucket> is required" >&2; exit 1; }

"$DIR/package.sh" "$BUCKET" "$REGION"
PREFIX="$(cat "$DIR/.last-artifact-prefix")"

PARAMS=("ArtifactBucket=$BUCKET" "ArtifactPrefix=$PREFIX")
[ -n "$INSTITUTE" ] && PARAMS+=("InstituteName=$INSTITUTE")
[ -n "$ADMIN_EMAIL" ] && PARAMS+=("AdminEmail=$ADMIN_EMAIL")
[ -n "$SELF_SIGNUP" ] && PARAMS+=("AllowSelfSignUp=$SELF_SIGNUP")

echo "==> Deploying stack $STACK to $REGION (first deploy takes ~5-10 minutes)"
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$DIR/edu-kb.yaml" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides "${PARAMS[@]}"

echo
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table
