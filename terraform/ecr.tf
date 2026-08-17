# ECR repositories for the app's three images.
#
# Used to be created by hand, outside Terraform - teardown.sh had its own
# step to delete them since nothing else owned them. That broke rebuilding
# from code alone: a fresh setup.sh run had nowhere to push images after a
# teardown. Now Terraform owns them like everything else.
resource "aws_ecr_repository" "app_repos" {
  for_each = toset(["devops-frontend", "devops-backend", "devops-worker"])

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # matches the project-wide rule: never overwrite a tag, especially not `latest`

  image_scanning_configuration {
    scan_on_push = true
  }

  # force_delete: `terraform destroy` (via teardown.sh) needs to remove
  # these even with images still in them, or destroy fails mid-run and
  # leaves the repos - and their storage cost - behind.
  force_delete = true
}
