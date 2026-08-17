# ECR repositories for the app's three images.
#
# Previously these were created by hand, outside any script or Terraform -
# teardown.sh even had a dedicated step to delete them again since nothing
# else owned them. That broke the "rebuild from code alone" requirement:
# a fresh setup.sh run had nowhere to push images, since nothing recreated
# these repos after teardown. Bringing them into Terraform, alongside every
# other piece of this project's infra, closes that gap.
resource "aws_ecr_repository" "app_repos" {
  for_each = toset(["devops-frontend", "devops-backend", "devops-worker"])

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # matches the project-wide rule: never overwrite a tag, especially not `latest`

  image_scanning_configuration {
    scan_on_push = true
  }

  # force_delete: `terraform destroy` (via teardown.sh) must be able to
  # remove these even with images still pushed into them - otherwise destroy
  # fails mid-run and leaves the repos (and their storage cost) behind.
  force_delete = true
}
