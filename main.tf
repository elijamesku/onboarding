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