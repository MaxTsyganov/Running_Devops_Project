# ECR repositories for the app's three images. Used to be created by hand
# outside Terraform, which broke a fresh setup.sh run after teardown (no
# repos left to push to) - now Terraform owns them like everything else.
resource "aws_ecr_repository" "app_repos" {
  for_each = toset(["devops-frontend", "devops-backend", "devops-worker"])

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # matches the project-wide rule: never overwrite a tag, especially not `latest`

  image_scanning_configuration {
    scan_on_push = true
  }

  # force_delete: lets `terraform destroy` (via teardown.sh) remove these
  # even with images still in them, instead of failing mid-run and leaving
  # the repos - and their storage cost - behind.
  force_delete = true
}
