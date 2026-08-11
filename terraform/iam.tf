# Least-Privilege IAM Policies
#
# Split by workload instead of one shared policy: backend is the only service
# that touches S3 (file uploads), worker only ever calls SNS Publish. This is
# the ONE thing in this file the Kubernetes side still depends on: setup.sh
# attaches these exact policies (by their fixed names below) to the
# backend-sa/worker-sa IAM roles it creates via `eksctl create iamserviceaccount`
# (IRSA). Don't rename them without also updating the POLICY_ARN lines in setup.sh.
resource "aws_iam_policy" "backend_least_privilege_policy" {
  name        = "DevOps-Backend-Least-Privilege-Policy"
  description = "Minimal permissions required for the backend to access its specific S3 bucket and SNS topic."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Restrict S3 to ONLY the bucket created by Terraform, and ONLY allow uploading files
        Sid    = "S3UploadAccess"
        Effect = "Allow"
        Action = [
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
        Sid    = "SNSPublishAccess"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.alerts.arn
        ]
      }
    ]
  })
}

resource "aws_iam_policy" "worker_least_privilege_policy" {
  name        = "DevOps-Worker-Least-Privilege-Policy"
  description = "Minimal permissions required for the worker to publish to its specific SNS topic. No S3 access - worker.py never touches S3."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SNSPublishAccess"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.alerts.arn
        ]
      }
    ]
  })
}

# Separate policy for External Secrets Operator (setup.sh attaches this to
# external-secrets-sa via IRSA). Scoped to GetSecretValue on exactly the one
# secret it needs to read - it has no reason to see anything else in this
# AWS account's Secrets Manager.
resource "aws_iam_policy" "external_secrets_policy" {
  name        = "DevOps-ExternalSecrets-Policy"
  description = "Minimal permissions for External Secrets Operator to read the DB password from Secrets Manager - nothing else."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbPasswordOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_password.arn]
      }
    ]
  })
}

# Separate policy for Fluent Bit (setup.sh attaches this to fluent-bit-sa via
# IRSA, same pattern as above). No logs:CreateLogGroup here on purpose - the
# log group is created by Terraform (logging.tf), not by Fluent Bit itself,
# so it never needs permission to create one.
resource "aws_iam_policy" "fluent_bit_logging_policy" {
  name        = "DevOps-FluentBit-Logging-Policy"
  description = "Minimal permissions for Fluent Bit to write container logs to this project's CloudWatch log group."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteToOurLogGroupOnly"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.app_logs.arn}:*"
        ]
      }
    ]
  })
}
