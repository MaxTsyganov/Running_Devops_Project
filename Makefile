.PHONY: help init plan apply destroy k8s-deploy k8s-teardown

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available Targets:"
	@echo "  init          - Initialize the Terraform backend and providers"
	@echo "  plan          - Generate and show the Terraform execution plan"
	@echo "  apply         - Deploy AWS infrastructure using Terraform (RDS, S3, SNS, IAM)"
	@echo "  destroy       - Tear down all Terraform-provisioned infrastructure"
	@echo "  k8s-deploy    - Build/push images and deploy the app to Kubernetes (see setup.sh)"
	@echo "  k8s-teardown  - Remove Kubernetes workloads, the EKS cluster, and Terraform infra"

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply

destroy:
	cd terraform && terraform destroy

k8s-deploy:
	bash setup.sh

k8s-teardown:
	bash teardown.sh