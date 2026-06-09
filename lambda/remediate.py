"""
WAF Auto-Remediation Lambda
============================
Triggered by SQS (with a 15-second delay) after a CloudFront distribution
is created or updated via EventBridge/CloudTrail.

Logic:
  1. Extract the CloudFront distribution ID from the CloudTrail event.
  2. Check if the distribution currently has any WAF WebACL attached.
  3. If WAF is missing → attach the golden WAF ACL (aws_wafacl_golden).
  4. Send an email alert via SNS with details of the remediation.

The 15-second delay gives app teams time to attach their own custom WAF
before auto-remediation kicks in. If any WAF is present after the delay,
no action is taken.
"""

import json
import os
import logging
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Clients — reused across Lambda invocations (warm start optimization)
cloudfront_client = boto3.client("cloudfront")
sns_client = boto3.client("sns")

# Environment variables set by Terraform
GOLDEN_WAF_ARN  = os.environ["GOLDEN_WAF_ARN"]
GOLDEN_WAF_NAME = os.environ["GOLDEN_WAF_NAME"]
SNS_TOPIC_ARN   = os.environ["SNS_TOPIC_ARN"]


def extract_distribution_id(detail: dict) -> str | None:
    """
    Extract the CloudFront distribution ID from a CloudTrail event detail.

    CreateDistribution: ID is in responseElements.distribution.id
    UpdateDistribution: ID is in requestParameters.id
    """
    event_name = detail.get("eventName", "")

    if event_name.startswith("CreateDistribution"):
        try:
            return detail["responseElements"]["distribution"]["id"]
        except (KeyError, TypeError):
            logger.warning("CreateDistribution event missing distribution ID in responseElements")

    if event_name.startswith("UpdateDistribution"):
        try:
            return detail["requestParameters"]["id"]
        except (KeyError, TypeError):
            logger.warning("UpdateDistribution event missing distribution ID in requestParameters")

    return None


def get_distribution_config(distribution_id: str) -> tuple[dict, str]:
    """
    Fetch the CloudFront distribution config and its ETag.
    ETag is required by CloudFront for optimistic locking on UpdateDistribution.
    """
    response = cloudfront_client.get_distribution_config(Id=distribution_id)
    return response["DistributionConfig"], response["ETag"]


def attach_golden_waf(distribution_id: str, config: dict, etag: str) -> None:
    """Attach the golden WAF ACL to the CloudFront distribution."""
    config["WebACLId"] = GOLDEN_WAF_ARN
    cloudfront_client.update_distribution(
        DistributionConfig=config,
        Id=distribution_id,
        IfMatch=etag,
    )


def send_alert(distribution_id: str, event_time: str, actor: str) -> None:
    """Publish a remediation alert email via SNS."""
    subject = f"[WAF Auto-Remediation] CloudFront {distribution_id} protected"
    message = f"""
WAF Auto-Remediation Alert
===========================

A CloudFront distribution was found without WAF protection and has been
automatically secured with the enterprise baseline WAF.

Distribution ID : {distribution_id}
Action taken    : Attached golden WAF ACL '{GOLDEN_WAF_NAME}'
WAF ACL ARN     : {GOLDEN_WAF_ARN}
Event time      : {event_time}
Triggered by    : {actor}

---------------------------------------------------------------------
Your CloudFront distribution is now protected by the enterprise WAF.

If you need a custom WAF configuration, please contact the security
team BEFORE detaching the golden WAF. Unauthorized removal will
trigger automatic re-attachment within 15 seconds.
---------------------------------------------------------------------
"""
    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject,
        Message=message,
    )
    logger.info(f"Alert sent for distribution {distribution_id}")


def process_record(record: dict) -> None:
    """Process a single SQS record containing a CloudTrail event."""
    body = json.loads(record["body"])
    detail = body.get("detail", {})

    # Extract the CloudFront distribution ID
    distribution_id = extract_distribution_id(detail)
    if not distribution_id:
        logger.warning(f"Could not extract distribution ID. Skipping. Event: {json.dumps(detail)}")
        return

    event_time = detail.get("eventTime", "unknown")
    actor = detail.get("userIdentity", {}).get("arn", "unknown")

    logger.info(f"Checking WAF protection for distribution: {distribution_id}")

    # Get the current distribution configuration
    config, etag = get_distribution_config(distribution_id)
    current_waf = config.get("WebACLId", "")

    if current_waf:
        # WAF is already attached (could be the golden WAF or a custom one)
        logger.info(
            f"Distribution {distribution_id} already has WAF attached: {current_waf}. "
            f"No action needed."
        )
        return

    # No WAF attached — remediate immediately
    logger.info(
        f"Distribution {distribution_id} has NO WAF. "
        f"Attaching golden WAF: {GOLDEN_WAF_NAME}"
    )
    attach_golden_waf(distribution_id, config, etag)
    logger.info(f"Successfully attached {GOLDEN_WAF_NAME} to distribution {distribution_id}")

    # Notify the team
    send_alert(distribution_id, event_time, actor)


def handler(event: dict, context) -> None:
    """
    Lambda entry point — processes SQS records one at a time (batch_size=1).
    Raising an exception causes the message to return to the queue for retry.
    """
    for record in event.get("Records", []):
        try:
            process_record(record)
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            logger.error(f"AWS API error: {error_code} — {e}")
            raise  # Return message to queue for retry
        except Exception as e:
            logger.error(f"Unexpected error: {e}")
            raise  # Return message to queue for retry
