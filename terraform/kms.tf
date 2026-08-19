# Asymmetric KMS key used by CI to sign images with Cosign (awskms:// key
# provider) - no private key material anywhere, ever. Matches the IRSA
# pattern used everywhere else in this project: ci-build-sa's existing role
# just gets kms:Sign permission (see iam.tf), instead of introducing a new
# class of secret (a Cosign keypair) this project otherwise avoids entirely.
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
