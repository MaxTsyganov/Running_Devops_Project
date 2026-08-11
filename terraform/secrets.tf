# DB password mirrored into Secrets Manager, read into the cluster by
# External Secrets Operator (see helm/devops-app/templates/externalsecret.yaml)
# instead of ever passing through the ArgoCD Application spec - which
# persists as a live, readable cluster object, unlike a value that only ever
# existed as a Terraform variable in memory.
resource "aws_secretsmanager_secret" "db_password" {
  name        = "devops-app/db-password"
  description = "RDS PostgreSQL password for the DevOps app - synced into the cluster by External Secrets Operator, never passed through ArgoCD."
  # Secrets Manager's default 30-day recovery window would block re-creating
  # a secret with this same name on the very next `terraform apply` after a
  # teardown - this project gets torn down and redeployed often enough that
  # that default doesn't fit; 0 deletes it immediately instead.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}
