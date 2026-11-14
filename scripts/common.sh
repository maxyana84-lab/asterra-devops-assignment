#!/usr/bin/env bash
# Shared settings for deploy.sh and destroy.sh. Source it, do not run it.

set -euo pipefail

REGION="${1:-}"
if [[ -z "$REGION" ]]; then
  echo "Usage: $0 <aws-region>   e.g. $0 eu-north-1" >&2
  exit 1
fi

PROJECT="${PROJECT:-asterra}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# One private bucket per region holds the Terraform state and a copy of the IaC.
STATE_BUCKET="${PROJECT}-iac-${ACCOUNT_ID}-${REGION}"

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
export TF_IN_AUTOMATION=1
export TF_VAR_aws_region="$REGION"
export TF_VAR_project="$PROJECT"

# The application version is declared once, in app/VERSION.
APP_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/app/VERSION")"
export TF_VAR_geoloader_image_tag="$APP_VERSION"

# owner/name of the GitHub repository, taken from the git remote
# (works for both https://github.com/owner/name.git and git@github.com:owner/name.git).
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(git -C "$REPO_ROOT" remote get-url origin \
  | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')}"
export TF_VAR_github_repository="$GITHUB_REPOSITORY"

GITHUB_OIDC_URL="https://token.actions.githubusercontent.com"
github_oidc_provider_arn() {
  aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?ends_with(Arn, '/token.actions.githubusercontent.com')].Arn | [0]" \
    --output text
}

tf_init() {
  terraform -chdir="$TF_DIR" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=terraform.tfstate" \
    -backend-config="region=$REGION" \
    -backend-config="use_lockfile=true"
}
