# Least-Privilege IAM Policies
#
# Split by workload: backend touches S3 (uploads), worker only calls SNS
# Publish. setup.sh attaches these by name to backend-sa/worker-sa via IRSA -
# don't rename them without updating the POLICY_ARN lines there.

# Only used to scope the Cluster Autoscaler policy's eks:DescribeNodegroup
# statement below to this account's own resources, not "*".
data "aws_caller_identity" "current" {}

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

# Separate policy for External Secrets Operator (attached to
# external-secrets-sa via IRSA in setup.sh). Scoped to GetSecretValue on
# exactly the one secret it needs.
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

# Separate policy for Jenkins CI (ci-build-sa via IRSA), scoped to push/pull
# on this project's three ECR repos only. GetAuthorizationToken must be
# Resource "*" (ECR doesn't support scoping that action); everything else is
# locked to the specific repo ARNs below.
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
          # Pull actions - Kaniko only pushes, but Trivy needs these to scan
          # the image straight from ECR after Kaniko pushes it.
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for repo in aws_ecr_repository.app_repos : repo.arn]
      }
    ]
  })
}

# Cosign image-signing policy (ci-build-sa via IRSA, alongside the ECR
# policy above). Scoped to the one signing key (kms.tf) and only the three
# actions `cosign sign --key awskms://...` calls - no kms:Decrypt or
# key-management actions, since CI only ever signs, never manages the key.
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

# Separate policy for Fluent Bit (fluent-bit-sa via IRSA). No
# logs:CreateLogGroup - the log group is Terraform-managed (logging.tf), so
# Fluent Bit never needs permission to create one.
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

# Cluster Autoscaler - added after concurrent Jenkins CI matrix builds (up
# to 6 ephemeral agent Pods) transiently starved the cluster's fixed 3-node
# baseline. Describe actions can't be resource-scoped (AWS limitation,
# Resource "*"); mutating actions are instead gated by a Condition on
# devops-cluster's own ASG auto-discovery tag (set in
# jenkins/scripts/install-jenkins.sh), so they can't touch any other ASG.
resource "aws_iam_policy" "cluster_autoscaler_policy" {
  name        = "DevOps-ClusterAutoscaler-Policy"
  description = "Minimal permissions for Cluster Autoscaler to scale devops-cluster's own managed node group - AWS's documented minimal policy shape for this, not a broader one."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ClusterAutoscalerReadOnly"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions"
        ]
        Resource = ["*"]
      },
      {
        # EKS-managed node groups need this too, confirmed live (Cluster
        # Autoscaler logs AccessDeniedException without it). Separate
        # statement since, unlike Describe above, this action supports ARN
        # scoping - devops-cluster's own nodegroups only.
        Sid      = "ClusterAutoscalerDescribeOurNodegroupsOnly"
        Effect   = "Allow"
        Action   = ["eks:DescribeNodegroup"]
        Resource = ["arn:aws:eks:*:${data.aws_caller_identity.current.account_id}:nodegroup/devops-cluster/*/*"]
      },
      {
        Sid    = "ClusterAutoscalerMutateOwnASGOnly"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "autoscaling:UpdateAutoScalingGroup"
        ]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/devops-cluster" = "owned"
          }
        }
      }
    ]
  })
}
