#!/bin/bash
# Stop script on first error
set -e

# Clean up sensitive files when script exits
trap 'rm -f /tmp/.vault_tmp /tmp/project_key.pem; echo "Cleanup complete."' EXIT

# Verify required tools are installed
command -v terraform >/dev/null 2>&1 || { echo "Terraform required. Aborting."; exit 1; }
command -v ansible-playbook >/dev/null 2>&1 || { echo "Ansible required. Aborting."; exit 1; }

echo "Starting deployment..."

# Check for CI/CD flag
NON_INTERACTIVE=false
if [[ "$1" == "--ci" ]]; then
    NON_INTERACTIVE=true
    echo "Running in CI/CD non-interactive mode."
fi

# 1. Setup Terraform Variables
if [ ! -f "terraform/terraform.tfvars" ]; then
    echo "Configuring environment variables..."
    
    if [ "$NON_INTERACTIVE" = true ]; then
        # In CI mode, fail immediately if these variables are missing
        USER_KEY_NAME="${DEPLOY_KEY_NAME:?DEPLOY_KEY_NAME must be set in CI mode}"
        USER_BUCKET="${DEPLOY_BUCKET:?DEPLOY_BUCKET must be set in CI mode}"
        USER_EMAIL="${DEPLOY_EMAIL:?DEPLOY_EMAIL must be set in CI mode}"
        DB_PASS="${DEPLOY_DB_PASS:?DEPLOY_DB_PASS must be set in CI mode}"
    else
        read -r -p "AWS Key Pair Name: " USER_KEY_NAME
        read -r -p "S3 Bucket Name (lowercase, hyphens): " USER_BUCKET
        read -r -p "SNS Alert Email: " USER_EMAIL
        read -r -s -p "RDS Database Password: " DB_PASS
        echo ""
    fi
    
    cat <<EOF > terraform/terraform.tfvars
key_name    = "${USER_KEY_NAME}"
bucket_name = "${USER_BUCKET}"
my_email    = "${USER_EMAIL}"
db_password = "${DB_PASS}"
EOF
else
    echo "Using existing terraform.tfvars file."
    DB_PASS=$(grep 'db_password' terraform/terraform.tfvars | cut -d '"' -f 2)
fi

# 2. Setup Ansible Credentials
if [ "$NON_INTERACTIVE" = true ]; then
    USER_PEM_PATH="${DEPLOY_PEM_PATH:?DEPLOY_PEM_PATH must be set in CI mode}"
    VAULT_PASS="${DEPLOY_VAULT_PASS:?DEPLOY_VAULT_PASS must be set in CI mode}"
else
    read -r -p "Path to .pem file: " USER_PEM_PATH
    read -r -s -p "Ansible Vault Password: " VAULT_PASS
    echo ""
fi

# Format file path for cross-platform compatibility
USER_PEM_PATH="${USER_PEM_PATH//\"/}"
USER_PEM_PATH="${USER_PEM_PATH//\'/}"
USER_PEM_PATH="${USER_PEM_PATH//$'\r'/}"
USER_PEM_PATH="${USER_PEM_PATH/#\~/$HOME}"

# 3. Apply Infrastructure (Terraform)
cd terraform
terraform init -input=false
terraform apply -auto-approve
FRONTEND_IP=$(terraform output -raw frontend_public_ip)
cd ..

echo "Waiting 60 seconds for servers to boot..."
sleep 60

# 4. Configure Servers (Ansible)
cd ansible

# Save Vault password securely
echo "$VAULT_PASS" > /tmp/.vault_tmp
chmod 600 /tmp/.vault_tmp

# Copy SSH key securely to handle path formatting
if command -v wslpath >/dev/null 2>&1; then
    cp -f "$(wslpath -u "${USER_PEM_PATH}")" /tmp/project_key.pem
else
    cp -f "${USER_PEM_PATH}" /tmp/project_key.pem
fi
chmod 400 /tmp/project_key.pem

export ANSIBLE_CONFIG=ansible.cfg
export ANSIBLE_HOST_KEY_CHECKING=False

# Run configuration playbook
ansible-playbook -i inventory.ini playbook.yml \
    -e "db_password=${DB_PASS}" \
    --private-key /tmp/project_key.pem \
    --vault-password-file /tmp/.vault_tmp

# Clear sensitive variables from memory
unset VAULT_PASS
unset DB_PASS
cd ..

# 5. Success Output
echo "--------------------------------------------------------"
echo "Deployment complete."
echo "Application URL: https://${FRONTEND_IP}"
echo "--------------------------------------------------------"