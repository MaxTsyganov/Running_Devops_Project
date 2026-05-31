#!/bin/bash
# Stop the script immediately if any command fails
set -e

# --- Secure Cleanup Trap ---
# Guarantees secrets are wiped from /tmp on ANY exit (success or crash)
trap 'rm -f /tmp/.vault_tmp /tmp/project_key.pem; echo "Security cleanup complete."' EXIT

# Check if Terraform and Ansible are installed before starting
command -v terraform >/dev/null 2>&1 || { echo "Terraform is not installed. Aborting."; exit 1; }
command -v ansible-playbook >/dev/null 2>&1 || { echo "Ansible is not installed. Aborting."; exit 1; }

echo "Starting infrastructure deployment..."

# --- 1. Smart Terraform Configuration ---
if [ ! -f "terraform/terraform.tfvars" ]; then
    echo "No terraform.tfvars file found. Let's configure your environment!"
    read -r -p "Enter AWS Key Pair Name: " USER_KEY_NAME
    read -r -p "Enter S3 Bucket name (lowercase, hyphens only): " USER_BUCKET
    read -r -p "Enter email for SNS alerts: " USER_EMAIL
    read -r -s -p "Enter a strong password for your RDS Database: " DB_PASS
    echo ""
    
    # Generate the file safely
    cat <<EOF > terraform/terraform.tfvars
key_name    = "${USER_KEY_NAME}"
bucket_name = "${USER_BUCKET}"
my_email    = "${USER_EMAIL}"
db_password = "${DB_PASS}"
EOF
    echo "Created terraform/terraform.tfvars successfully."
    echo "---"
else
    echo "Found existing terraform/terraform.tfvars. Using saved configuration."
    # Dynamically extract the saved database password to pass to Ansible
    DB_PASS=$(grep 'db_password' terraform/terraform.tfvars | cut -d '"' -f 2)
fi

# --- 2. Gather Ansible Runtime Credentials ---
read -r -p "Enter full path to your .pem file: " USER_PEM_PATH
read -r -s -p "Enter Ansible Vault Password: " VAULT_PASS
echo ""

# Sanitize the path:
USER_PEM_PATH="${USER_PEM_PATH//\"/}"
USER_PEM_PATH="${USER_PEM_PATH//\'/}"
USER_PEM_PATH="${USER_PEM_PATH//$'\r'/}"

# NEW: Expand the tilde (~) to the absolute home directory path
USER_PEM_PATH="${USER_PEM_PATH/#\~/$HOME}"

# --- 3. Run Terraform ---
echo "Initializing and Applying Terraform..."
cd terraform
terraform init -input=false
terraform apply -auto-approve

# Grab the public IP directly from Terraform's outputs
FRONTEND_IP=$(terraform output -raw frontend_public_ip)
cd ..

# Wait for the EC2 servers to fully start up before configuring them
echo "Waiting for EC2 instances to initialize (60 seconds)..."
sleep 60

# --- 4. Configure Application (Ansible) ---
echo "Running Ansible Playbook..."
cd ansible

# 1. Secure the Vault Password in /tmp
echo "$VAULT_PASS" > /tmp/.vault_tmp
chmod 600 /tmp/.vault_tmp

# 2. Copy the PEM key securely (Cross-Platform compatibility)
if command -v wslpath >/dev/null 2>&1; then
    # We are on WSL, convert the Windows path
    cp -f "$(wslpath -u "${USER_PEM_PATH}")" /tmp/project_key.pem
else
    # We are on Mac or Native Linux, use the path as-is
    cp -f "${USER_PEM_PATH}" /tmp/project_key.pem
fi
chmod 400 /tmp/project_key.pem

# 3. Apply configurations
export ANSIBLE_CONFIG=ansible.cfg
export ANSIBLE_HOST_KEY_CHECKING=False

# Execute the playbook using the safe Linux paths and inject the dynamic DB password
ansible-playbook -i inventory.ini playbook.yml \
    -e "db_password=${DB_PASS}" \
    --private-key /tmp/project_key.pem \
    --vault-password-file /tmp/.vault_tmp

# Unset the variables from memory to ensure no secrets linger
unset VAULT_PASS
unset DB_PASS

cd ..

# --- 5. Finish ---
echo ""
echo "--------------------------------------------------------"
echo "Deployment finished successfully!"
echo "Your application is live at: https://${FRONTEND_IP}"
echo "--------------------------------------------------------"