# Look up the golden WAF ACL ARN at apply time.
# This ensures we always get the correct ARN even if the WAF was recreated.
# The WAF is managed by the aws_wafacl_golden workspace — we reference it here
# as a read-only data source (no ownership, no dependency).
data "aws_wafv2_web_acl" "golden" {
  name  = var.golden_waf_name
  scope = "CLOUDFRONT"
}

# Current AWS account ID — used in IAM policies and resource names.
data "aws_caller_identity" "current" {}
