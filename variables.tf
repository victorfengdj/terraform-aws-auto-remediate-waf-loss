# Email address that receives WAF auto-remediation alerts.
# Set this in HCP Terraform workspace variables or terraform.tfvars.
# After terraform apply, AWS will send a subscription confirmation email —
# the recipient must click "Confirm subscription" before alerts are delivered.
variable "notification_email" {
  description = "Email address to receive WAF auto-remediation notifications"
  type        = string
  default     = "victorfengdj@gmail.com"
}

# Name of the golden WAF ACL to attach to unprotected CloudFront distributions.
# Defaults to aws_wafacl_golden — override if the baseline WAF name changes.
variable "golden_waf_name" {
  description = "Name of the golden/baseline WAF ACL to enforce on all CloudFront distributions"
  type        = string
  default     = "aws_wafacl_golden"
}

# Delay in seconds before Lambda checks the distribution.
# Gives the app team time to attach their own custom WAF before
# auto-remediation kicks in. Default: 15 seconds.
variable "remediation_delay_seconds" {
  description = "Seconds to wait after a CloudFront event before checking WAF attachment"
  type        = number
  default     = 10
}
