# Least-Privilege IAM Policy
#
# This is the ONE thing in this file the Kubernetes side still depends on:
# setup.sh attaches this exact policy (by its fixed name below) to the
# backend-sa/worker-sa IAM roles it creates via `eksctl create iamserviceaccount`
# (IRSA). Don't rename it without also updating the POLICY_ARN line in setup.sh.
resource "aws_iam_policy" "app_least_privilege_policy" {
  name        = "DevOps-App-Least-Privilege-Policy"
  description = "Minimal permissions required for the app to access its specific S3 bucket and SNS topic."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Restrict S3 to ONLY the bucket created by Terraform, and ONLY allow uploading files
        Sid      = "S3UploadAccess"
        Effect   = "Allow"
        Action   = [
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.app_bucket.arn,
          "${aws_s3_bucket.app_bucket.arn}/*"
        ]
      },
      {
        # Restrict SNS to ONLY publishing to the exact Topic created by Terraform
        Sid      = "SNSPublishAccess"
        Effect   = "Allow"
        Action   = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.alerts.arn
        ]
      }
    ]
  })
}
