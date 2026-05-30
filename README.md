# AWS Application - DevOps Project

This project demonstrates a fully automated Infrastructure as Code (IaC) deployment of a 3-tier web application on AWS, utilizing Terraform and Ansible.

## Project Architecture

The application runs on three separate Ubuntu servers working together:

1. **Frontend Server:** Runs Nginx to serve the static website and acts as a reverse proxy, routing API requests to the Backend server.
2. **Backend Server:** Runs a Python API (Flask + Gunicorn) that writes data to the database, uploads files to cloud storage, and triggers email alerts.
3. **Worker Server:** Runs a Python script in the background that checks the database every 30 seconds for pending tasks and processes them.

* **Network and Security:** The EC2 servers are placed in a Public Subnet to save NAT Gateway costs, but security is strictly enforced via AWS Security Groups (e.g., the database only accepts connections from the Backend and Worker servers). The database is placed in Private Subnets.

## Components Created by Terraform

Terraform is responsible for provisioning all physical cloud infrastructure:

* **Networking:** VPC, Public Subnets, Private Subnets, Internet Gateway, and Route Tables.
* **Security:** Strict Security Groups and IAM Roles (giving servers access to AWS services without hardcoded credentials).
* **Compute:** 3 EC2 instances (Frontend, Backend, Worker).
* **Managed Services:** RDS PostgreSQL database, S3 Bucket for file storage, and an SNS Topic for email alerts.
* **Integration:** Terraform dynamically generates the Ansible `inventory.ini` and `vars.yml` files using the newly created IP addresses.

## Actions Performed by Ansible

Ansible connects to the servers after they are built to install and configure the software:

* Updates packages and installs base dependencies (Python, Git, pip).
* **Frontend:** Installs Nginx, generates a self-signed SSL certificate for HTTPS, and configures the reverse proxy block.
* **Backend & Worker:** Copies the Python code, sets up virtual environments, installs dependencies, and dynamically generates the `.env` configuration files.
* **Services:** Creates and enables Systemd services to ensure the API and Worker run persistently in the background.
* **Health Checks:** Runs automated HTTP checks at the end of the deployment to verify the UI is reachable and the API proxy is functioning.

## Required Variables

* **Terraform Variables:** Variables such as the S3 bucket name, email address, database password, and SSH key name are prompted interactively and generated automatically by the deployment script.
* **Ansible Variables:** Most variables (IP addresses, AWS links) are auto-injected by Terraform. The only manual variable required is the Ansible Vault password.

## Secret Management

* **Terraform State:** The `terraform.tfstate` file contains sensitive information in plain text. It is explicitly ignored in the `.gitignore` file and is never uploaded to version control.
* **Ansible Vault:** Sensitive configuration data is encrypted inside `ansible/secrets.yml`.
* **Important:** The decryption code for the vault in this project is `11223311`.


* **Deployment Script Security:** The `deploy.sh` script securely handles the Vault password and SSH key by temporarily copying them to the isolated Linux `/tmp` directory and deleting them immediately after the deployment finishes.

## How to Run the Project

The fastest and safest method is to use the automated deployment script:

1. Open a terminal (Linux/WSL) in the root project folder.
2. Run the command: `bash deploy.sh`
3. The script will interactively ask for your AWS details to build the environment.
4. When prompted for the Ansible Vault Password, enter: `11223311`
5. The script will automatically run Terraform, wait 60 seconds for the servers to boot, and then run Ansible.

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

To avoid unexpected AWS charges, you must destroy the infrastructure when you are finished testing:

1. Open a terminal and navigate to the `terraform` folder.
2. Run the command: `terraform destroy`
3. Type `yes` when prompted. Terraform will safely delete all servers, databases, and network components.

