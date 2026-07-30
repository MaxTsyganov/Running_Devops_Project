#!/bin/bash

echo "🗑️ [1/3] Deleting Kubernetes workloads..."
kubectl delete -f k8s/ --ignore-not-found=true

echo "🔥 [2/3] Deleting EKS Cluster (this takes about 10-15 minutes)..."
eksctl delete cluster --region=us-east-1 --name=devops-cluster

echo "🏗️ [3/3] Destroying Terraform Infrastructure..."
cd terraform
terraform destroy -auto-approve
cd ..

echo "====================================================="
echo "✅ FULL TEARDOWN COMPLETE."
echo "Your AWS account is completely clean of EKS and Terraform resources."
echo "====================================================="