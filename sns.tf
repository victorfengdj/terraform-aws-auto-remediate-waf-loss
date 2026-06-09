# ── SNS Topic — email notifications ─────────────────────────────────────────
# Lambda publishes here after attaching the golden WAF to a distribution.
# The email subscription requires manual confirmation — after terraform apply,
# the recipient will receive a "Confirm subscription" email from AWS.
# Alerts will not be delivered until the subscription is confirmed.
# ────────────────────────────────────────────────────────────────────────────
resource "aws_sns_topic" "waf_alerts" {
  name = "waf-auto-remediation-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.waf_alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

output "sns_topic_arn" {
  description = "SNS topic ARN for WAF remediation alerts"
  value       = aws_sns_topic.waf_alerts.arn
}

output "notification_email" {
  description = "Email address subscribed to WAF remediation alerts"
  value       = var.notification_email
}
