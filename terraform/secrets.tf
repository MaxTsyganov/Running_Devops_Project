# DB password is mirrored into Secrets Manager and read into the cluster by
# External Secrets Operator (see helm/devops-app/templates/externalsecret.yaml)
# instead of ever passing through a live, readable cluster object. It only
# ever exists as this Terraform variable in memory, and in Secrets Manager.
resource "aws_secretsmanager_secret" "db_password" {
  name        = "devops-app/db-password"
  description = "RDS PostgreSQL password for the DevOps app - synced into the cluster by External Secrets Operator."
  # Secrets Manager's default 30-day recovery window would block re-creating
  # a secret with this name on the next `terraform apply` after a teardown -
  # this project gets torn down and redeployed too often for that default;
  # 0 deletes it immediately instead.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}
