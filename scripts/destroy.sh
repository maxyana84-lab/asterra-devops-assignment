#!/usr/bin/env bash
# Removes the whole environment from one AWS region, including the IaC bucket.
#   ./scripts/destroy.sh eu-north-1

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Destroying '$PROJECT' in $REGION (account $ACCOUNT_ID)"

if ! aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  echo "No IaC bucket $STATE_BUCKET: nothing was deployed to $REGION by this script."
  exit 0
fi

tf_init
terraform -chdir="$TF_DIR" destroy -input=false -auto-approve

# The bucket is versioned, so every object version has to go before the bucket can.
echo "==> Emptying and deleting $STATE_BUCKET"
python3 - "$STATE_BUCKET" "$REGION" <<'PY'
import json, subprocess, sys

bucket, region = sys.argv[1], sys.argv[2]
while True:
    out = subprocess.run(
        ["aws", "s3api", "list-object-versions", "--bucket", bucket,
         "--region", region, "--max-items", "500", "--output", "json"],
        check=True, capture_output=True, text=True).stdout
    data = json.loads(out) if out.strip() else {}
    objects = [{"Key": o["Key"], "VersionId": o["VersionId"]}
               for o in (data.get("Versions") or []) + (data.get("DeleteMarkers") or [])]
    if not objects:
        break
    subprocess.run(
        ["aws", "s3api", "delete-objects", "--bucket", bucket, "--region", region,
         "--delete", json.dumps({"Objects": objects, "Quiet": True})],
        check=True, stdout=subprocess.DEVNULL)
PY
aws s3api delete-bucket --bucket "$STATE_BUCKET"

# The GitHub OIDC provider is shared by all regions: remove it with the last one.
OTHER_REGIONS="$(aws s3api list-buckets \
  --query "length(Buckets[?starts_with(Name, '${PROJECT}-iac-${ACCOUNT_ID}-')])" --output text)"
OIDC_ARN="$(github_oidc_provider_arn)"
if [[ "$OTHER_REGIONS" == "0" && "$OIDC_ARN" != "None" ]]; then
  echo "==> No other region is deployed: removing the GitHub OIDC provider"
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"
fi

echo "==> $REGION is clean."
