provider "aws" {
    region = var.aws_region
}

##################
## SQS Queue
##################
resource "aws_sqs_queue" "newhire_queue" {
    name = "newhire-queue"
    visibility_timeout_seconds = 30
    message_retention_seconds = 86400
  
}

