variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_account_id" {
  type = string
}

variable "lambda_api_key" {
  type      = string
  sensitive = true
}

variable "lambda_artifact_bucket" {
  type    = string
  default = "my-lambda-artifacts-lead"
}

variable "lambda_s3_key" {
  type = string
  description = "S3 key for the lambda artifact, set by CI (e.g. onboarding/lambda-<sha>.zip)"
}
