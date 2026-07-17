terraform {
  cloud {
    # Replace with your own HCP Terraform organization before `terraform init`.
    organization = "change-to-your-org"
    workspaces {
      project = "aws"
      name    = "aws_auto_remediate_waf_loss"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  required_version = ">= 1.12"
}

# All resources are in us-east-1 because:
#   - CloudFront WAFs are CLOUDFRONT-scoped and must be managed from us-east-1
#   - CloudFront API calls in CloudTrail appear in us-east-1
#   - EventBridge must be in the same region as the CloudTrail delivering events
provider "aws" {
  region = "us-east-1"
}
