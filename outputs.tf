output "api_gateway_url" {
  value = aws_apigatewayv2_api.onboarding_api.api_endpoint
}

output "sqs_queue_url" {
  value = aws_sqs_queue.newhire_queue.id
}

output "lambda_function_name" {
  value = aws_lambda_function.onboarding.function_name
}

output "s3_log_bucket" {
  value = aws_s3_bucket.onboarding_logs.id
}