provider "aws" {
  region = var.aws_region
}

terraform {
  backend "s3" {
    bucket         = "tf-state-lead-prod"
    key            = "onboarding/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-state-locks"
    encrypt        = true
  }
}

################################
##         SQS Queue          ##
################################
resource "aws_sqs_queue" "newhire_queue" {
  name                       = "newhire-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400

}

################################
##     S3 Bucket for logs     ##
################################
resource "aws_s3_bucket" "onboarding_logs" {
  bucket        = "onboarding-logs-${var.aws_account_id}"
  force_destroy = false
  tags = {
    Name        = "log-bucket"
    Environment = "test"
  }
}

################################
##    Iam role for lambda     ##
################################
resource "aws_iam_role" "lambda_exec" {
  name = "onboarding-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Least-privilege SQS policy for Lambda (SendMessage)
resource "aws_iam_policy" "lambda_sqs_policy" {
  name = "onboarding-lambda-sqs"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes"
        ],
        Resource = aws_sqs_queue.newhire_queue.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_sqs_policy.arn
}


resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

################################
##  IAM Policy for S3 Write   ##
################################
resource "aws_iam_policy" "s3_write_policy" {
  name = "onboarding-s3-write"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject"]
      Resource = "${aws_s3_bucket.onboarding_logs.arn}/jobs/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_s3_write" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.s3_write_policy.arn
}


################################
##      Lambda Function       ##
################################
resource "aws_lambda_function" "onboarding" {
  function_name = "onboarding-lambda"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 10

  s3_bucket = var.lambda_artifact_bucket
  s3_key    = var.lambda_s3_key


  environment {
    variables = {
      API_KEY       = var.lambda_api_key
      SQS_QUEUE_URL = aws_sqs_queue.newhire_queue.url
      LOG_BUCKET    = aws_s3_bucket.onboarding_logs.bucket
    }
  }
}


################################
##     API Gateway (HTTP)     ##
################################
resource "aws_apigatewayv2_api" "onboarding_api" {
  name          = "onboarding-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.onboarding_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.onboarding.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post-newuser" {
  api_id    = aws_apigatewayv2_api.onboarding_api.id
  route_key = "POST /newuser"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.onboarding.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.onboarding_api.execution_arn}/*/*"
}

################################
##      IAM role for EC2      ##
################################
resource "aws_iam_role" "op_sqs_role" {
  name = "op-sqs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow",
      Principal = {Service = "ec2.amazonaws.com"},
      Action  = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "op_sqs_policy" {
  name = "op-sqs-policy"
  role = aws_iam_role.op_sqs_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = aws_sqs_queue.newhire_queue.arn
    }]
  })
}

################################
##  EC2 Instance for Poller   ##
################################
resource "aws_instance" "poller" {
  ami           = var.ami_id       # Replace with your desired AMI ID
  instance_type = "t3.medium"
  subnet_id     = var.subnet_id    # Replace with your subnet
  key_name      = var.key_name     # Optional, if you want SSH access

  # Attach the IAM instance profile
  iam_instance_profile = aws_iam_instance_profile.op_sqs_profile.name

  tags = {
    Name = "OnboardingPoller"
    Environment = "prod"
  }
}
