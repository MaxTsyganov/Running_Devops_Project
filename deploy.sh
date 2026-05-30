#!/bin/bash
# Stop the script immediately if any command fails
set -e

# Check if Terraform and Ansible are installed before starting
command -v terraform >/dev/null 2>&1 || { echo "Terraform is not installed. Aborting."; exit 1; }
command -v ansible-playbook >/dev/null 2>&1 || { echo "Ansible is not installed. Aborting."; exit 1; }

echo "Starting infrastructure deployment..."

# --- 1. Smart Terraform Configuration ---
# Check if the variables file exists. If not, create it interactively.
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
fi

# --- 2. Gather Ansible Runtime Credentials ---
read -r -p "Enter full path to your .pem file: " USER_PEM_PATH
read -r -s -p "Enter Ansible Vault Password: " VAULT_PASS
echo ""

# Sanitize the Windows path:
# 1. Remove double quotes
USER_PEM_PATH="${USER_PEM_PATH//\"/}"
# 2. Remove single quotes
USER_PEM_PATH="${USER_PEM_PATH//\'/}"
# 3. Remove invisible Windows carriage returns (\r)
USER_PEM_PATH="${USER_PEM_PATH//$'\r'/}"

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

# 2. Copy the PEM key to /tmp to prevent SSH path-spacing errors
cp "$(wslpath -u "${USER_PEM_PATH}")" /tmp/project_key.pem
chmod 400 /tmp/project_key.pem

# 3. Apply configurations
export ANSIBLE_CONFIG=ansible.cfg
export ANSIBLE_HOST_KEY_CHECKING=False

# Execute the playbook using the safe Linux paths
ansible-playbook -i inventory.ini playbook.yml \
    --private-key /tmp/project_key.pem \
    --vault-password-file /tmp/.vault_tmp

# 4. Clean up all temporary security files
rm -f /tmp/.vault_tmp
rm -f /tmp/project_key.pem
unset VAULT_PASS

cd ..

# --- 5. Finish ---
echo ""
echo "--------------------------------------------------------"
echo "Deployment finished successfully!"
echo "Your application is live at: https://${FRONTEND_IP}"
echo "--------------------------------------------------------"