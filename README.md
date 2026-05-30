# AWS Application - DevOps Project

This project demonstrates a fully automated Infrastructure as Code (IaC) deployment of a 3-tier web application on AWS, utilizing Terraform and Ansible.

## Project Architecture

The application runs on three separate Ubuntu servers configured as a secure 3-tier architecture:

1. **Frontend Server (Public Subnet):** Acts as the entry point, running Nginx to serve the static website and reverse-proxying API requests.
2. **Backend Server (Private Subnet):** Runs the Python API (Flask + Gunicorn), isolated from the internet.
3. **Worker Server (Private Subnet):** Processes background tasks, isolated from the internet.
4. **Network & Security:** * Servers in private subnets access the internet via a **NAT Gateway** for package updates.
* The database is deployed in private subnets with strictly limited access.
* **Dynamic SSH Security:** The deployment script dynamically fetches your local public IP and updates AWS Security Groups to allow SSH access *only* from your current location.



## Components Created by Terraform

Terraform is responsible for provisioning all physical cloud infrastructure:

* **Networking:** VPC, Public/Private Subnets, Internet Gateway, NAT Gateway, and Route Tables.
* **Security:** Strict Security Groups and Least-Privilege IAM Roles (giving servers granular access to S3/SNS without hardcoded credentials).
* **Compute:** 3 EC2 instances (Frontend, Backend, Worker).
* **Managed Services:** RDS PostgreSQL database, S3 Bucket, and an SNS Topic.
* **Integration:** Terraform dynamically generates the Ansible `inventory.ini` and `vars.yml` files, including secure `ProxyCommand` tunnels for private subnet access.

## Actions Performed by Ansible

Ansible connects to the servers after they are built to install and configure the software:

* Updates packages and installs base dependencies (Python, Git, pip).
* **Frontend:** Installs Nginx, generates a self-signed SSL certificate for HTTPS, and configures the reverse proxy.
* **Backend & Worker:** Copies application code, manages virtual environments, and dynamically generates `.env` files.
* **Services:** Configures Systemd services to ensure the API and Worker run persistently.
* **Health Checks:** Executes automated HTTP checks to verify the UI and API proxy functionality.

## Secret Management

* **Terraform State:** Sensitive state is ignored by Git and never committed to version control.
* **Ansible Vault:** Sensitive configuration data is encrypted inside `ansible/secrets.yml`.
* **Decryption Code:** `11223311`


* **Deployment Script Security:** The `deploy.sh` script handles secrets securely:
* Secrets are written to an isolated `/tmp` directory.
* A `bash trap` ensures all temporary sensitive files are wiped immediately upon exit, regardless of whether the deployment succeeded or crashed.



## How to Run the Project

The fastest and safest method is the automated deployment script:

1. Open a terminal (Linux/WSL) in the root project folder.
2. Run: `bash deploy.sh`
3. Enter your AWS details when prompted.
4. When prompted for the Ansible Vault Password, enter: `11223311`
5. The script handles all provisioning, Bastion/tunnel setup, and configuration.

**To run manually:**

* **Terraform:** Navigate to the `terraform` folder. Run `terraform init` followed by `terraform apply`.
* **Important:** You need to create your own `terraform.tfvars` file before running the command. You can use the template provided in `terraform.tfvars.example`, Instructions are provided inside.
* **Ansible:** Navigate to the `ansible` folder. Run `ansible-playbook -i inventory.ini playbook.yml --vault-password-file /path/to/pass`.

## How to Verify the System Works

Once the deployment finishes successfully:

1. Open a web browser and navigate to the Public IP of the Frontend server.
2. **Test RDS & SNS:** Create a new item in the UI. It should appear at the bottom with a "pending" status, and you should receive an email alert.
3. **Test S3:** Upload a file through the UI. You should see a success message containing the S3 Key, and a second email will be sent.
4. **Test the Worker:** Wait approximately 30 seconds and refresh the page. The item's status should change from "pending" to "done".

## How to Delete the Environment

To avoid ongoing charges for the NAT Gateway and RDS:

1. Open a terminal and navigate to the `terraform` folder.
2. Run the command: `terraform destroy`
3. Type `yes` when prompted. Terraform will safely delete all resources.