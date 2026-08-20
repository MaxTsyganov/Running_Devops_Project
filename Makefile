.PHONY: help init plan apply destroy k8s-deploy k8s-teardown verify-teardown

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available Targets:"
	@echo "  init             - Initialize the Terraform backend and providers"
	@echo "  plan             - Generate and show the Terraform execution plan"
	@echo "  apply            - Deploy AWS infrastructure using Terraform only (RDS, S3, SNS, IAM) -"
	@echo "                     no EKS cluster, no app. Most people want k8s-deploy instead."
	@echo "  destroy          - Terraform-only destroy. REFUSES to run if the EKS cluster still"
	@echo "                     exists (it would fail or orphan resources) - use k8s-teardown instead."
	@echo "  k8s-deploy       - Bring up infra, build/push images (see setup.sh) - app deploy is Jenkins CD's job"
	@echo "  k8s-teardown     - Remove everything: Kubernetes workloads, Jenkins, the EKS cluster, Terraform infra"
	@echo "  verify-teardown  - Read-only check that k8s-teardown left nothing billable behind"

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply

destroy:
	@if eksctl get cluster --name devops-cluster --region us-east-1 >/dev/null 2>&1; then \
		echo "Refusing: EKS cluster 'devops-cluster' still exists. A bare 'terraform destroy'"; \
		echo "here will fail or orphan resources (load balancer, security groups, the Jenkins"; \
		echo "PVC's EBS volume) that only teardown.sh releases in the right order first."; \
		echo "Run 'make k8s-teardown' instead."; \
		exit 1; \
	fi
	cd terraform && terraform destroy

k8s-deploy:
	bash setup.sh

k8s-teardown:
	bash teardown.sh

verify-teardown:
	bash verify-teardown.sh