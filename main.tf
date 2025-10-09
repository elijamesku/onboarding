provider "aws" {
    region = var.aws_region
}

###########################
## SQS Queue
###########################
resource "aws_sqs_queue" "newhire_queue" {
    name = "newhire-queue"
    visibility_timeout_seconds = 30
    message_retention_seconds = 86400
  
}
  
###########################
## S3 Bucket for logs
###########################
resource "aws_s3_bucket" "onboarding_logs" {
    bucket = "onboarding-logs-${var.aws_account_id}"
    force_destroy = false
    tags = {
        Name = "log-bucket"
        Environment = "test"
    }
}

###########################
## IAM Role for Lambda
###########################
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

# Attaching the policies to lambda
resource "aws_iam_role_policy_attachment" "lambda_sqs" {
    role = aws_iam_role.lambda_exec.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonSQSFullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
    role = aws_iam_role.lambda_exec.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_s3_write" {
    role = aws_iam_role.lambda_exec.name
    policy_arn = aws_iam_policy.lambda_s3_write_policy.arn
}


###########################
## IAM Policy for S3 Write
###########################
resource "aws_iam_policy" "s3_write_policy"{
    name = "onboarding-s3-write"
    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Action = ["s3:PutObject", "s3:GetObject"]
            Resource = "${aws_s3_bucket.onboarding_logs.arn}"
        }]
    })
}