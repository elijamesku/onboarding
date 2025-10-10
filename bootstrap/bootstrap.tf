locals {
  tf_state_bucket        = "tf-state-${var.org_prefix}-prod"
  lambda_artifact_bucket = "my-lambda-artifacts-${var.org_prefix}"
  dynamodb_table         = "tf-state-locks"
  deploy_role_name       = "GitHubActionsDeployRole"
  deploy_policy_name     = "GitHubActionsDeployPolicy-${var.org_prefix}-prod"
}

resource "aws_s3_bucket" "tf_state" {
  bucket = local.tf_state_bucket
  tags = { 
    Environment = "prod" 
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state_block" {
  bucket = aws_s3_bucket.tf_state.id
  block_public_acls        = true
  block_public_policy      = true
  ignore_public_acls       = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "lambda_artifacts" {
  bucket = local.lambda_artifact_bucket
  tags = {
    Environment = "prod" 
  }
}

resource "aws_s3_bucket_public_access_block" "lambda_artifacts_block" {
  bucket = aws_s3_bucket.lambda_artifacts.id
  block_public_acls        = true
  block_public_policy      = true
  ignore_public_acls       = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = local.dynamodb_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute { 
    name = "LockID"
    type = "S" 
  }

  tags = { 
    Environment = "prod" 
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Managed policy (converted json )
resource "aws_iam_policy" "github_deploy_policy" {
  name = local.deploy_policy_name
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "AllowS3ForStateAndArtifacts",
        Effect = "Allow",
        Action = ["s3:ListBucket","s3:GetObject","s3:PutObject","s3:DeleteObject"],
        Resource = [
          "arn:aws:s3:::${local.tf_state_bucket}",
          "arn:aws:s3:::${local.tf_state_bucket}/*",
          "arn:aws:s3:::${local.lambda_artifact_bucket}",
          "arn:aws:s3:::${local.lambda_artifact_bucket}/*"
        ]
      },
      {
        Sid = "AllowDDBLock",
        Effect = "Allow",
        Action = ["dynamodb:PutItem","dynamodb:GetItem","dynamodb:DeleteItem","dynamodb:Query","dynamodb:UpdateItem"],
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${local.dynamodb_table}"
      },
      {
        Sid = "AllowLambdaMgmt",
        Effect = "Allow",
        Action = ["lambda:CreateFunction","lambda:UpdateFunctionCode","lambda:UpdateFunctionConfiguration","lambda:PublishVersion","lambda:AddPermission","lambda:DeleteFunction"],
        Resource = "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:*"
      },
      {
        Sid = "AllowAPIGatewayMgmt",
        Effect = "Allow",
        Action = ["apigateway:*","apigatewayv2:*"],
        Resource = "*"
      },
      {
        Sid = "AllowSqsMgmt",
        Effect = "Allow",
        Action = ["sqs:*"],
        Resource = "arn:aws:sqs:${var.aws_region}:${var.aws_account_id}:*"
      },
      {
        Sid = "AllowCloudWatch",
        Effect = "Allow",
        Action = ["cloudwatch:PutMetricAlarm","cloudwatch:DeleteAlarms","cloudwatch:DescribeAlarms","logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
        Resource = "*"
      },
      {
        Sid = "AllowSecretsManager",
        Effect = "Allow",
        Action = ["secretsmanager:CreateSecret","secretsmanager:PutSecretValue","secretsmanager:UpdateSecret","secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:onboarding/*"
      },
      {
        Sid = "AllowIAMManagementForTerraform",
        Effect = "Allow",
        Action = ["iam:CreateRole","iam:DeleteRole","iam:PutRolePolicy","iam:AttachRolePolicy","iam:DetachRolePolicy","iam:CreatePolicy","iam:DeletePolicy","iam:UpdateAssumeRolePolicy","iam:GetRole","iam:PassRole"],
        Resource = [
          "arn:aws:iam::${var.aws_account_id}:role/onboarding-*",
          "arn:aws:iam::${var.aws_account_id}:policy/onboarding-*",
          "arn:aws:iam::${var.aws_account_id}:role/${local.deploy_role_name}"
        ]
      }
    ]
  })
}

# Creating the github actions assumption role
resource "aws_iam_role" "github_actions_role" {
  name = local.deploy_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}"
        }
      }
    }]
  })
}

# Attaching the managed policy to the role
resource "aws_iam_role_policy_attachment" "attach_deploy_policy" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = aws_iam_policy.github_deploy_policy.arn
}

# Outputting useful values
output "deploy_role_arn" { 
    value = aws_iam_role.github_actions_role.arn 
}

output "tf_state_bucket" { 
    value = aws_s3_bucket.tf_state.bucket 
}

output "lambda_artifact_bucket" { 
    value = aws_s3_bucket.lambda_artifacts.bucket 
}

output "dynamodb_table" { 
    value = aws_dynamodb_table.tf_locks.name 
}
