provider "aws" {
    region = var.aws_region
}

########################
## SQS Queue
########################
resource "aws_sqs_queue" "newhire_queue" {
    name = "newhire-queue"
    visibility_timeout_seconds = 30
    message_retention_seconds = 86400
  
}
  
########################
## S3 Bucket for logs
########################
resource "aws_s3_bucket" "onboarding_logs" {
    bucket = "onboarding-logs-${var.aws_account_id}"
    force_destroy = false
    tags = {
        Name = "log-bucket"
        Environment = "test"
    }
}

########################
## IAM Role for Lambda
########################
resource "aws_iam_role" "lambda_exec" {
    name = "onboarding-lambda-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Action = "sts:AssumeRole"
            Effect = "Allow"
            Principal ={
                Service = "lambda.amazonaws.com"
            }
        }]
    })
}