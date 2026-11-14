# Lets the GitHub Actions release pipeline sign in with short-lived OIDC tokens,
# so no AWS keys are stored in GitHub.

# The OIDC provider is one-per-account (not per region), so scripts/deploy.sh
# makes sure it exists and every regional deployment only looks it up.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only workflows of this repository running on the release branch.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_oidc_subject_prefix}:ref:refs/heads/${var.github_release_branch}"]
    }
  }
}

resource "aws_iam_role" "github_release" {
  name               = "${var.project}-github-release-${var.aws_region}"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

# The pipeline can publish the loader image and roll it out. Nothing else.
data "aws_iam_policy_document" "github_release" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level restrictions
  }

  statement {
    sid = "PushLoaderImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.geoloader.arn]
  }

  statement {
    sid = "RollOutLoader"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:InvokeFunction",
      "lambda:UpdateFunctionCode",
    ]
    resources = [aws_lambda_function.geoloader.arn]
  }
}

resource "aws_iam_role_policy" "github_release" {
  name   = "release"
  role   = aws_iam_role.github_release.id
  policy = data.aws_iam_policy_document.github_release.json
}
