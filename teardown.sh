#!/bin/bash

echo "🗑️ [1/2] Deleting Kubernetes workloads..."
kubectl delete -f k8s/ --ignore-not-found=true

echo "🔥 [2/2] Deleting EKS Cluster (this takes about 10 minutes)..."
eksctl delete cluster --region=us-east-1 --name=devops-cluster

echo "====================================================="
echo "✅ CLUSTER DELETED."
echo "⚠️ Don't forget to run 'terraform destroy' in your previous assignment folder to delete the Database and S3!"
echo "====================================================="
