#!/usr/bin/env bash
# Deploys the whole environment into one AWS region.
#   ./scripts/deploy.sh eu-north-1
# Safe to re-run: every step is idempotent.

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Deploying '$PROJECT' to $REGION (account $ACCOUNT_ID)"

# 1. Private bucket for the Terraform state and the IaC copy.
if ! aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  echo "==> Creating IaC bucket $STATE_BUCKET"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$STATE_BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$STATE_BUCKET" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi
aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# GitHub's OIDC identity provider is one-per-account, shared by all regions.
if [[ "$(github_oidc_provider_arn)" == "None" ]]; then
  echo "==> Registering GitHub as an OIDC identity provider"
  aws iam create-open-id-connect-provider --url "https://token.actions.githubusercontent.com" \
    --client-id-list sts.amazonaws.com >/dev/null
fi

# 2. Image registry first: the Lambda function cannot be created before its image exists.
tf_init
terraform -chdir="$TF_DIR" apply -input=false -auto-approve \
  -target=aws_ecr_repository.geoloader

# 3. Build and publish the loader image, tagged with the version in app/VERSION.
REPO_URL="$(terraform -chdir="$TF_DIR" output -raw geoloader_repository_url)"
if aws ecr describe-images --repository-name "${REPO_URL#*/}" \
     --image-ids "imageTag=$APP_VERSION" >/dev/null 2>&1; then
  echo "==> Image $APP_VERSION is already published; bump app/VERSION to publish a new one"
else
  echo "==> Building and pushing $REPO_URL:$APP_VERSION"
  aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO_URL%%/*}"
  # --provenance=false: Lambda accepts a plain image manifest, not an OCI index.
  docker build --platform linux/amd64 --provenance=false \
    -t "$REPO_URL:$APP_VERSION" "$REPO_ROOT/app"
  docker push "$REPO_URL:$APP_VERSION"
fi

# 4. Everything else.
terraform -chdir="$TF_DIR" apply -input=false -auto-approve

# 5. Keep a copy of the IaC next to the state, in the same private bucket.
echo "==> Uploading IaC to s3://$STATE_BUCKET/iac/"
aws s3 sync "$REPO_ROOT" "s3://$STATE_BUCKET/iac/" --delete --only-show-errors \
  --exclude ".git/*" --exclude "*.terraform/*" --exclude "*.tfstate*" \
  --exclude "*.tfvars" --exclude "*.pem" --exclude ".env" --exclude "*__pycache__/*" \
  --exclude "*.venv/*" --exclude "*.pytest_cache/*" --exclude "*.ruff_cache/*"

# 6. Point the GitHub release pipeline at this environment.
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  echo "==> Pointing the release pipeline of $GITHUB_REPOSITORY at $REGION"
  gh variable set AWS_REGION --repo "$GITHUB_REPOSITORY" --body "$REGION"
  gh variable set AWS_ROLE_ARN --repo "$GITHUB_REPOSITORY" --body "$(tf_out github_release_role_arn)"
  gh variable set ECR_REPOSITORY --repo "$GITHUB_REPOSITORY" --body "$(tf_out geoloader_repository_name)"
  gh variable set LAMBDA_FUNCTION --repo "$GITHUB_REPOSITORY" --body "$(tf_out geoloader_function)"
else
  echo "!!  GitHub CLI is not signed in: set the repository variables AWS_REGION, AWS_ROLE_ARN," >&2
  echo "!!  ECR_REPOSITORY and LAMBDA_FUNCTION by hand from the outputs below." >&2
fi

echo "==> Done. Outputs:"
terraform -chdir="$TF_DIR" output
