# ── IAM Role — Lambda execution role ────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "waf-auto-remediation-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# Basic Lambda execution — allows writing logs to CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy — grants only the permissions Lambda needs
resource "aws_iam_role_policy" "lambda_custom" {
  name = "waf-auto-remediation-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # Read and update CloudFront distribution configuration
      {
        Sid    = "CloudFrontAccess"
        Effect = "Allow"
        Action = [
          "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig",
          "cloudfront:UpdateDistribution"
        ]
        Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
      },

      # Read WAF ACL details (to verify the golden WAF exists)
      {
        Sid    = "WAFReadAccess"
        Effect = "Allow"
        Action = [
          "wafv2:GetWebACL",
          "wafv2:ListWebACLs"
        ]
        Resource = "*"
      },

      # Publish notifications to the SNS alerts topic
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.waf_alerts.arn
      },

      # Read and delete messages from the SQS remediation queue
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.remediation.arn
      }
    ]
  })
}
