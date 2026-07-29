#!/bin/bash
set -e

export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🚀 [1/4] Authenticating with AWS ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

echo "📦 [2/4] Building and pushing Docker images..."
for service in frontend backend worker; do
    echo " -> Processing $service..."
    docker build -t devops-$service ./$service
    docker tag devops-$service:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/devops-$service:v1.0.0
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/devops-$service:v1.0.0
done

echo "☸️  [3/4] Deploying to Kubernetes..."
kubectl apply -f k8s/

echo "⏳ [4/4] Waiting for pods to roll out..."
kubectl rollout status deployment/frontend-deployment -n devops-app --timeout=120s
kubectl rollout status deployment/backend-deployment -n devops-app --timeout=120s

echo "🌐 Waiting for AWS to provision the Load Balancer URL (this takes a minute)..."
EXTERNAL_IP=""
while [ -z "$EXTERNAL_IP" ]; do
  sleep 5
  EXTERNAL_IP=$(kubectl get svc frontend-service -n devops-app --template="{{range .status.loadBalancer.ingress}}{{.hostname}}{{end}}")
done

echo "====================================================="
echo "✅ DEPLOYMENT COMPLETE!"
echo "🌍 Access your application at: http://$EXTERNAL_IP"
echo "====================================================="
