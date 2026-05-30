# 1. Create the IAM Role for EC2
resource "aws_iam_role" "ec2_app_role" {
  name = "DevOps-EC2-App-Role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# 2. Create a Custom Least-Privilege Policy
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

# 3. Attach the Custom Policy to the Role
resource "aws_iam_role_policy_attachment" "custom_policy_attach" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = aws_iam_policy.app_least_privilege_policy.arn
}

# 4. Create the Instance Profile to attach to the servers
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "DevOps-EC2-Instance-Profile"
  role = aws_iam_role.ec2_app_role.name
}