# DB password is mirrored into Secrets Manager and synced into the cluster
# by External Secrets Operator (helm/devops-app/templates/externalsecret.yaml)
# - it only ever exists here and in Secrets Manager, never as a readable
# cluster object.
resource "aws_secretsmanager_secret" "db_password" {
  name        = "devops-app/db-password"
  description = "RDS PostgreSQL password for the DevOps app - synced into the cluster by External Secrets Operator."
  # 0 skips Secrets Manager's default 30-day recovery window, which would
  # otherwise block re-creating this secret on the next apply after a teardown.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}
