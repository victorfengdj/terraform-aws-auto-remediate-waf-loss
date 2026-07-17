# terraform-aws-auto-remediate-waf-loss

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.12-7B42BC?logo=terraform)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python)
![AWS Lambda](https://img.shields.io/badge/AWS-Lambda-FF9900?logo=amazon-aws)

Serverless auto-remediation pipeline that detects CloudFront distributions without WAF
protection and re-attaches the enterprise baseline WAF within 15 seconds.

---

## Project Abstract

A CloudFront distribution loses its WAF in two common scenarios: an engineer creates a new
distribution without attaching one, or an update to the distribution config accidentally
clears the `WebACLId`. Either way, the window between the change and the next compliance
scan can leave production traffic unprotected.

`terraform-aws-auto-remediate-waf-loss` closes that window automatically. It monitors
CloudTrail for every `CreateDistribution` and `UpdateDistribution` API call, waits 15 seconds
to allow intentional WAF swaps, then checks whether any WAF is attached. If not, it attaches
the golden baseline WAF
([terraform-aws-wafacl-golden](https://github.com/victorfengdj/terraform-aws-wafacl-golden))
and emails the team — all without human intervention.

---

## Architecture Blueprint

```
CloudFront API call
(CreateDistribution / UpdateDistribution)
        │
        ▼
┌──────────────────────┐
│  AWS CloudTrail      │  records all management events
└──────────┬───────────┘
           │  event stream
           ▼
┌──────────────────────┐
│  Amazon EventBridge  │  rule: source=aws.cloudfront
│  (event rule)        │        eventName prefix match
└──────────┬───────────┘
           │  send event
           ▼
┌──────────────────────┐
│  Amazon SQS          │  delay_seconds = 15 (grace period)
│  (remediation queue) │  Gives app teams time to attach
│                      │  their own custom WAF
└──────────┬───────────┘
           │  trigger (batch_size=1)
           ▼
┌──────────────────────────────────────────────────────┐
│  AWS Lambda  (Python 3.12)                           │
│  ─────────────────────────────────────────────────   │
│  1. Extract distribution ID from CloudTrail event    │
│  2. GET distribution config + ETag                   │
│  3. If WebACLId is empty → attach golden WAF         │
│     (PUT UpdateDistribution with IfMatch ETag)       │
│  4. If WAF present → no-op, log and exit             │
└──────────┬───────────────────────────────────────────┘
           │  remediation taken
           ▼
┌──────────────────────┐     ┌──────────────────────┐
│  Amazon SNS          │────▶│  Email alert         │
│  (waf-alerts topic)  │     │  to ops/security team │
└──────────────────────┘     └──────────────────────┘

           │  reads WAF ARN at deploy time
           ▼
┌──────────────────────────────────┐
│  terraform-aws-wafacl-golden     │  (separate Terraform workspace)
│  WAFv2 Web ACL                   │
└──────────────────────────────────┘
```

| Component | Technology | Role |
|---|---|---|
| Event source | AWS CloudTrail + Amazon EventBridge | Captures every CloudFront distribution change |
| Delay buffer | Amazon SQS (`delay_seconds = 15`) | 15-second grace period before auto-remediation |
| Remediation logic | AWS Lambda (Python 3.12) | Checks WAF state; attaches golden WAF if missing |
| Alerting | Amazon SNS (email subscription) | Notifies the team after remediation |
| Golden WAF reference | `data.aws_wafv2_web_acl` | Looks up the WAF ARN at apply time (no hardcoding) |
| IAM | Least-privilege custom policy | Scoped to CloudFront, WAF read, SQS, SNS only |
| Infrastructure-as-Code | Terraform ≥ 1.12 | All AWS resources declared and version-controlled |
| Remote state | HCP Terraform Cloud | State locking, secrets-free local workflow |

### Lambda logic (remediate.py)

```
handler(event)
  └── for each SQS record:
        process_record(record)
          ├── extract_distribution_id()   # CreateDistribution → responseElements
          │                               # UpdateDistribution → requestParameters
          ├── get_distribution_config()   # returns config dict + ETag
          ├── if config["WebACLId"] != "" → log "already protected", return
          ├── attach_golden_waf()         # UpdateDistribution with IfMatch ETag
          └── send_alert()               # SNS publish with remediation details
```

Failures raise an exception, returning the SQS message to the queue for automatic retry.

### 15-second grace period

Application teams are permitted to detach the golden WAF and replace it with a custom WAF
that inherits the baseline rules. The SQS `delay_seconds` gives them exactly 15 seconds to
complete that swap. If any WAF (golden or custom) is present when Lambda runs, no action is
taken. If the distribution is still unprotected after the delay, the golden WAF is attached
and the team is notified.

---

## Usage

### As a Terraform module

```hcl
module "auto_remediate_waf_loss" {
  source = "github.com/victorfengdj/terraform-aws-auto-remediate-waf-loss"

  notification_email        = "security-team@example.com"
  golden_waf_name           = "aws_wafacl_golden"
  remediation_delay_seconds = 15
}
```

### As a standalone deployment

```bash
git clone https://github.com/victorfengdj/terraform-aws-auto-remediate-waf-loss.git
cd terraform-aws-auto-remediate-waf-loss
# edit terraform.tf: set organization to your own HCP Terraform org
terraform login        # authenticate with HCP Terraform (one-time)
terraform init
terraform plan
terraform apply
```

---

## Deployment Instructions

### Prerequisites

| Requirement | Version / Detail |
|---|---|
| [Terraform CLI](https://developer.hashicorp.com/terraform/downloads) | ≥ 1.12 |
| AWS provider | ~> 6.0 |
| archive provider | ~> 2.7 |
| **terraform-aws-wafacl-golden deployed first** | The golden WAF ACL must exist before this workspace is applied |
| CloudTrail enabled | Must be active in `us-east-1`; EventBridge cannot receive API call events without it |

> **Region note:** All resources deploy to `us-east-1`. CloudFront-scoped WAFs, CloudFront
> CloudTrail events, and the EventBridge rule that captures them must all be in the same region.

### Credentials & secrets handling

This project stores no secrets in the repository, in Terraform state, or at runtime.

| Layer | Mechanism | Detail |
|---|---|---|
| Remote state | HCP Terraform | org — edit `organization` in `terraform.tf` to your own HCP Terraform org; workspace — defaults to `aws_auto_remediate_waf_loss` (project `aws`). State is stored remotely, encrypted at rest, with access restricted to the workspace |
| Deployment credentials | HCP Terraform workspace environment variables, marked **Sensitive** | Write-only once saved — cannot be read back through the UI or API; never appear in the repository, plan output, or on a local machine. For production, [dynamic provider credentials](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials) (OIDC) are recommended — Terraform assumes a short-lived IAM role per run, so no static credentials are stored at all |

### Steps

```bash
# 1. Clone the repository
git clone https://github.com/victorfengdj/terraform-aws-auto-remediate-waf-loss.git
cd terraform-aws-auto-remediate-waf-loss

# 2. Set the notification email variable
#    Option A — HCP Terraform workspace variable (recommended for teams)
#    Option B — create a local terraform.tfvars (never commit this file)
echo 'notification_email = "your-team@example.com"' > terraform.tfvars

# 3. Point at your own HCP Terraform organization —
#    edit terraform.tf and replace organization = "change-to-your-org"
#    with your org name (adjust the workspace project/name if desired)

# 4. Authenticate with HCP Terraform (one-time setup)
terraform login

# 5. Initialise — downloads providers, packages Lambda zip, connects to workspace
terraform init

# 6. Preview the changes
terraform plan

# 7. Apply
terraform apply
```

### Post-deployment: confirm the SNS email subscription

After `terraform apply`, AWS sends a **"Confirm subscription"** email to the address in
`notification_email`. Remediation alerts will not be delivered until the link in that email
is clicked.

### Variables

| Variable | Default | Description |
|---|---|---|
| `notification_email` | _(required)_ | Email address for remediation alerts |
| `golden_waf_name` | `aws_wafacl_golden` | Name of the baseline WAF ACL to enforce |
| `remediation_delay_seconds` | `15` | SQS delay in seconds before Lambda checks the distribution |