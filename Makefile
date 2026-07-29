.PHONY: help init plan apply destroy deploy deploy-ci

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available Targets:"
	@echo "  init        - Initialize the Terraform backend and providers"
	@echo "  plan        - Generate and show the Terraform execution plan"
	@echo "  apply       - Deploy AWS infrastructure using Terraform"
	@echo "  destroy     - Tear down all Terraform-provisioned infrastructure"
	@echo "  deploy      - Run the full end-to-end interactive deployment (Terraform + Ansible)"
	@echo "  deploy-ci   - Run the full end-to-end non-interactive deployment (for CI/CD)"

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply

destroy:
	cd terraform && terraform destroy

deploy:
	bash deploy.sh

deploy-ci:
	bash deploy.sh --ci