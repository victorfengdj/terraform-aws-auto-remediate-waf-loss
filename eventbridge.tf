# ── EventBridge Rule — detect CloudFront create/update events ────────────────
# Captures CloudTrail API calls for CloudFront distribution changes.
#
# PREREQUISITE: CloudTrail must be enabled in this AWS account.
# Without CloudTrail, EventBridge cannot receive API call events.
#
# Monitored events:
#   CreateDistribution* — new distribution created without WAF
#   UpdateDistribution* — existing distribution WAF may have been removed
#
# The prefix match (e.g. "CreateDistribution") catches all versioned API
# calls such as CreateDistribution2020_05_31 used by newer SDK versions.
# ────────────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "cloudfront_changes" {
  name        = "detect-cloudfront-waf-changes"
  description = "Detects CloudFront distributions created or updated that may lack WAF protection"

  event_pattern = jsonencode({
    source      = ["aws.cloudfront"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["cloudfront.amazonaws.com"]
      eventName = [
        # Prefix match catches all versioned API calls (e.g. CreateDistribution2020_05_31)
        { prefix = "CreateDistribution" },
        { prefix = "UpdateDistribution" }
      ]
    }
  })
}

# Send matching events to SQS queue (with 15-second built-in delay)
resource "aws_cloudwatch_event_target" "sqs" {
  rule = aws_cloudwatch_event_rule.cloudfront_changes.name
  arn  = aws_sqs_queue.remediation.arn
}
