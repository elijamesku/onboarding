provider "aws" {
    region = var.aws_region
}

################################
##         SQS Queue          ##
################################
resource "aws_sqs_queue" "newhire_queue" {
    name = "newhire-queue"
    visibility_timeout_seconds = 30
    message_retention_seconds = 86400
  
}
  
################################
##     S3 Bucket for logs     ##
################################
resource "aws_s3_bucket" "onboarding_logs" {
    bucket = "onboarding-logs-${var.aws_account_id}"
    force_destroy = false
    tags = {
        Name = "log-bucket"
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


################################
##  IAM Policy for S3 Write   ##
################################
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

################################
##      Lambda Function       ##
################################
resource "aws_lambda_function" "onboarding" {
    filename = "lambda.zip"
    function_name = "onboarding-lambda"
    role = aws_iam_role.lambda_exec.arn
    handler = "index.handler"
    runtime = "nodejs18.x"
    timeout = 10

    environment {
      variables = {
        API_KEY = var.lambda_api_key
        SQS_QUEUE_URL = aws_sqs_queue.newhire_queue.id
        AWS_REGION = var.aws_region
        LOG_BUCKET = aws_s3_bucket.onboarding_logs.id
      }
    }
}

################################
##     API Gateway (HTTP)     ##
################################
resource "aws_apigatewayv2_api" "onboarding_api" {
    name = "onboarding-api"
    protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
    api_id = aws_apigatewayv2_api.onboarding_api.id
    integration_type = "AWS_PROXY"
    integration_uri = aws_lambda_function.onboarding.arn
    payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post-newuser" {
    api_id = aws_apigatewayv2_api.onboarding_api.id
    route_key = "POST /newuser"
    target = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_lambda_permission" "apigw" {
    statement_id = "AllowAPIGatewayInvoke"
    action = "lambda:InvokeFunction"
    function_name = aws_lambda_function.onboarding.function_name
    principal = "apigateway.amazonaws.com"
    source_arn = "${aws_apigatewayv2_api.onboarding_api.execution_arn}"
}