# AWS Application - DevOps Project

This project demonstrates a fully automated Infrastructure as Code (IaC) deployment of a secure 3-tier web application on AWS, utilizing Terraform and Ansible.

## Project Architecture

The application runs on three separate Ubuntu servers working together in a strict 3-tier model:

1. **Frontend Server (Public Subnet):** Runs Nginx to serve the static website and acts as a reverse proxy, routing API requests to the Backend server. Acts as a Bastion Host for SSH tunneling.
2. **Backend Server (Private Subnet):** Runs a Python API (Flask + Gunicorn) that writes data to the database, uploads files to cloud storage, and triggers email alerts. Safely isolated from the public internet.
3. **Worker Server (Private Subnet):** Runs a Python script in the background that checks the database every 30 seconds for pending tasks and processes them. Safely isolated from the public internet.

* **Network and Security:** The Frontend server is public, but the Backend and Worker servers are placed in Private Subnets and use a **NAT Gateway** to securely access the internet for updates. The RDS database is deployed in its own isolated Private Subnet Groups and only accepts traffic from the application instances.

## Components Created by Terraform

Terraform is responsible for provisioning all physical cloud infrastructure:

* **Networking:** VPC, Public Subnets, Private Subnets, Internet Gateway, NAT Gateway, and Route Tables.
* **Security:** * **Dynamic SSH:** Uses Terraform's HTTP provider to fetch the deployer's exact local IP address, locking down port 22 access exclusively to the executor's machine.
  * **Strict IAM:** Applies the Principle of Least Privilege. Servers are assigned a custom inline IAM policy granting only explicit `s3:PutObject`, `s3:ListBucket`, and `sns:Publish` permissions restricted exactly to the provisioned resources.
* **Compute:** 3 EC2 instances (Frontend, Backend, Worker).
* **Managed Services:** RDS PostgreSQL database, S3 Bucket for file storage, and an SNS Topic for email alerts.
* **Integration:** Terraform dynamically generates the Ansible `inventory.ini` and `vars.yml` files, injecting dynamic IPs and a `ProxyCommand` to tunnel Ansible through the Bastion Host.

## Actions Performed by Ansible

Ansible connects to the servers after they are built to install and configure the software:

* Updates packages and installs base dependencies (Python, Git, pip).
* **Frontend:** Installs Nginx, generates a self-signed SSL certificate for HTTPS, and configures the reverse proxy block.
* **Backend & Worker:** Tunnels securely into the private subnets, copies the Python code, sets up virtual environments, installs dependencies, and dynamically generates the `.env` configuration files.
* **Services:** Creates and enables Systemd services to ensure the API and Worker run persistently in the background.
* **Health Checks:** Runs automated HTTP checks at the end of the deployment to verify the UI is reachable and the API proxy is functioning.

## Required Variables

* **Terraform Variables:** Variables such as the S3 bucket name, email address, database password, and SSH key name are prompted interactively and generated automatically by the deployment script.
* **Ansible Variables:** Most variables (IP addresses, AWS links) are auto-injected by Terraform. The only manual variable required is the Ansible Vault password.

## Secret Management

* **Terraform State:** The `terraform.tfstate` file contains sensitive information in plain text. It is explicitly ignored in the `.gitignore` file and is never uploaded to version control.
* **Ansible Vault:** Sensitive configuration data is encrypted inside `ansible/secrets.yml`.
  * **Important:** The decryption code for the vault in this project is `11223311`.
* **Deployment Script Security:** The `deploy.sh` script temporarily copies the Vault password and SSH key to the isolated Linux `/tmp` directory. It utilizes a Bash `trap` command to guarantee these sensitive files are wiped immediately upon script exit, whether the deployment succeeds or crashes.

## ⚠️ AWS Cost Warning & Teardown

This architecture provisions a **NAT Gateway** to allow resources in private subnets to securely access the internet (e.g., to download packages or hit AWS APIs). 

**Please note: NAT Gateways are NOT covered under the AWS Free Tier. They incur an hourly charge (~$0.045/hour) for as long as they exist, regardless of traffic.**

To prevent unexpected AWS charges, you must **always destroy the infrastructure** when you are done working. You can do this easily using the included Makefile:

```bash
make destroy

## How to Run the Project

The fastest and safest method is to use the automated deployment script:

1. Open a terminal (Linux/WSL) in the root project folder.
2. Run the command: `bash deploy.sh`
3. The script will interactively ask for your AWS details to build the environment.
4. To run the playbook, create a .vault_pass file in the root directory containing the vault password.
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

To avoid unexpected AWS charges (especially for the NAT Gateway, which incurs hourly costs), you must destroy the infrastructure when you are finished testing:

1. Open a terminal and navigate to the `terraform` folder.
2. Run the command: `terraform destroy`
3. Type `yes` when prompted. Terraform will safely delete all servers, databases, NAT Gateway, and network components.