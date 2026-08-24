# Asymmetric KMS key for Cosign image signing (awskms:// key provider) - no
# private key material anywhere. ci-build-sa's role gets kms:Sign via IRSA
# (iam.tf) instead of introducing a Cosign keypair as a new class of secret.
resource "aws_kms_key" "cosign_signing" {
  description              = "Asymmetric signing key for Cosign image signing (CI)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7
}

resource "aws_kms_alias" "cosign_signing" {
  name          = "alias/devops-app-cosign"
  target_key_id = aws_kms_key.cosign_signing.key_id
}
