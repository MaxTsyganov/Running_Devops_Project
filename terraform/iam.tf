# Least-Privilege IAM Policies
#
# Split by workload instead of one shared policy: backend is the only
# service that touches S3 (file uploads); worker only calls SNS Publish.
# setup.sh attaches these exact policies, by name, to the backend-sa/
# worker-sa IAM roles it creates via `eksctl create iamserviceaccount`
# (IRSA). Don't rename them without updating the POLICY_ARN lines in setup.sh.
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
# secret it needs - nothing else in this account's Secrets Manager.
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

# Separate policy for Jenkins CI (attached to ci-build-sa via IRSA). Scoped
# to pushing AND pulling images in exactly this project's three ECR
# repositories - nothing else. ecr:GetAuthorizationToken has to be Resource
# "*" (ECR doesn't support resource-level restriction on that one action),
# but everything else is locked to the specific repo ARNs below.
resource "aws_iam_policy" "ci_ecr_push_policy" {
  name        = "DevOps-CI-ECR-Push-Policy"
  description = "Minimal permissions for Jenkins CI to push/pull images in this project's ECR repositories - nothing else."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "ECRPushToOurRepositoriesOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          # Pull actions - Kaniko doesn't need these (it only pushes), but
          # Trivy does: it scans the image straight from ECR after Kaniko
          # pushes it, so it has to read back what was just pushed.
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for repo in aws_ecr_repository.app_repos : repo.arn]
      }
    ]
  })
}

# Separate policy for Cosign image signing (attached to ci-build-sa via IRSA,
# alongside the ECR policy above - kept as its own policy since it's a
# distinct concern, same pattern as every other single-purpose policy in
# this file). Scoped to exactly the one signing key (kms.tf) and exactly the
# three actions `cosign sign --key awskms://...` actually calls: get the
# public key, describe it (cosign checks key spec/usage before signing), and
# sign. No kms:Decrypt, no kms:CreateKey/kms:ScheduleKeyDeletion - CI only
# ever signs, it never manages the key itself.
resource "aws_iam_policy" "ci_cosign_sign_policy" {
  name        = "DevOps-CI-Cosign-Sign-Policy"
  description = "Minimal permissions for Jenkins CI to sign images with this project's Cosign KMS key - nothing else."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CosignSignWithOurKeyOnly"
        Effect = "Allow"
        Action = [
          "kms:GetPublicKey",
          "kms:DescribeKey",
          "kms:Sign",
        ]
        Resource = [aws_kms_key.cosign_signing.arn]
      }
    ]
  })
}

# Separate policy for Fluent Bit (setup.sh attaches this to fluent-bit-sa via
# IRSA, same pattern as above). No logs:CreateLogGroup here on purpose - the
# log group is created by Terraform (logging.tf), not Fluent Bit, so it
# never needs permission to create one.
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
