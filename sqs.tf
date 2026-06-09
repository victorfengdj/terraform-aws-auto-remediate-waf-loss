# ── SQS Queue — 15-second remediation delay ──────────────────────────────────
# EventBridge sends CloudFront events here. The delay_seconds setting holds
# each message for 15 seconds before Lambda can process it.
#
# Why the delay?
#   App teams may detach the golden WAF and attach their own custom WAF.
#   The delay gives them time to complete that swap before auto-remediation
#   triggers. If a WAF (any WAF) is present after the delay, no action is taken.
# ────────────────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "remediation" {
  name = "waf-auto-remediation"

  # Hold messages for N seconds before Lambda processes them (default: 15s)
  delay_seconds = var.remediation_delay_seconds

  # Keep unprocessed messages for 4 hours before expiry
  message_retention_seconds = 14400

  # Lambda has 30 seconds to process each message before it becomes
  # visible again for retry
  visibility_timeout_seconds = 30
}

# Allow EventBridge to send messages to this SQS queue.
resource "aws_sqs_queue_policy" "remediation" {
  queue_url = aws_sqs_queue.remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgeSend"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.remediation.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.cloudfront_changes.arn
          }
        }
      }
    ]
  })
}
