# Zip the Lambda function code for deployment
data "archive_file" "remediate" {
  type        = "zip"
  source_file = "${path.module}/lambda/remediate.py"
  output_path = "${path.module}/lambda/remediate.zip"
}

# ── Lambda Function — WAF auto-remediation ───────────────────────────────────
# Triggered by SQS after a 15-second delay.
# Checks if the CloudFront distribution has any WAF attached.
# If not → attaches the golden WAF and sends an email alert.
# ────────────────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "remediate" {
  function_name    = "waf-auto-remediation"
  description      = "Attaches the golden WAF to CloudFront distributions that have no WAF protection"
  role             = aws_iam_role.lambda.arn
  handler          = "remediate.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.remediate.output_path
  source_code_hash = data.archive_file.remediate.output_base64sha256

  environment {
    variables = {
      # ARN of the golden WAF ACL to attach to unprotected distributions
      GOLDEN_WAF_ARN = data.aws_wafv2_web_acl.golden.arn
      # Human-readable name for notification messages
      GOLDEN_WAF_NAME = var.golden_waf_name
      # SNS topic for email alerts
      SNS_TOPIC_ARN = aws_sns_topic.waf_alerts.arn
    }
  }
}

# Trigger Lambda from the SQS remediation queue
# batch_size = 1 ensures each CloudFront event is processed independently
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.remediation.arn
  function_name    = aws_lambda_function.remediate.arn
  batch_size       = 1
  enabled          = true
}
