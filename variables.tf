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