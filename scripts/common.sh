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

# Each service image has its own version file: services/<name>/VERSION.
# shellcheck disable=SC2034 # used by deploy.sh, which sources this file
SERVICES=(gdal mapserver)
service_version() { tr -d '[:space:]' < "$REPO_ROOT/services/$1/VERSION"; }
TF_VAR_service_image_tags="$(printf '{"gdal":"%s","mapserver":"%s"}' \
  "$(service_version gdal)" "$(service_version mapserver)")"
export TF_VAR_service_image_tags

# owner/name of the GitHub repository, taken from the git remote
# (works for both https://github.com/owner/name.git and git@github.com:owner/name.git).
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(git -C "$REPO_ROOT" remote get-url origin \
  | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')}"

# How GitHub names this repository in OIDC tokens. Newer repositories use an
# immutable form with numeric ids, so ask GitHub instead of assuming.
GITHUB_OIDC_SUBJECT_PREFIX="${GITHUB_OIDC_SUBJECT_PREFIX:-$(gh api \
  "repos/$GITHUB_REPOSITORY/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' \
  2>/dev/null || true)}"
export TF_VAR_github_oidc_subject_prefix="${GITHUB_OIDC_SUBJECT_PREFIX:-repo:$GITHUB_REPOSITORY}"

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
