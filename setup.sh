#!/bin/bash
set -e

export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🔄 [1/6] Fetching Terraform outputs and preparing Kubernetes ConfigMap..."
cd terraform
RDS_ENDPOINT_FULL=$(terraform output -raw rds_endpoint)
DB_HOST=$(echo $RDS_ENDPOINT_FULL | cut -d':' -f1)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
SNS_TOPIC=$(terraform output -raw sns_topic_arn)
DB_NAME=$(terraform output -raw db_name 2>/dev/null || echo "appdb")
cd ..

cat <<EOF > k8s/01-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: devops-app
data:
  DB_HOST: "${DB_HOST}"
  DB_PORT: "5432"
  DB_NAME: "${DB_NAME}"
  S3_BUCKET: "${S3_BUCKET}"
  SNS_TOPIC_ARN: "${SNS_TOPIC}"
  AWS_REGION: "${AWS_REGION}"
EOF

echo "🔐 [2/6] Configuring Kubernetes Secrets (Input will be hidden for passwords)..."
# Temporarily disable exit-on-error for the prompt section
set +e
read -p "Enter Database Username: " DB_USER
read -s -p "Enter Database Password: " DB_PASSWORD
echo ""
read -p "Enter AWS Access Key ID: " AWS_ACCESS_KEY
read -s -p "Enter AWS Secret Access Key: " AWS_SECRET_KEY
echo ""
set -e

B64_DB_USER=$(echo -n "$DB_USER" | base64 | tr -d '\n')
B64_DB_PASS=$(echo -n "$DB_PASSWORD" | base64 | tr -d '\n')
B64_AWS_KEY=$(echo -n "$AWS_ACCESS_KEY" | base64 | tr -d '\n')
B64_AWS_SECRET=$(echo -n "$AWS_SECRET_KEY" | base64 | tr -d '\n')

cat <<EOF > k8s/02-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
  namespace: devops-app
type: Opaque
data:
  DB_USER: ${B64_DB_USER}
  DB_PASSWORD: ${B64_DB_PASS}
  AWS_ACCESS_KEY_ID: ${B64_AWS_KEY}
  AWS_SECRET_ACCESS_KEY: ${B64_AWS_SECRET}
EOF

echo "🚀 [3/6] Authenticating with AWS ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

echo "📦 [4/6] Building and pushing Docker images..."
for service in frontend backend worker; do
    echo " -> Processing $service..."
    docker build -t devops-$service ./$service
    docker tag devops-$service:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/devops-$service:v1.0.0
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/devops-$service:v1.0.0
done

echo "☸️  [5/6] Deploying to Kubernetes..."
kubectl apply -f k8s/

echo "⏳ [6/6] Waiting for pods to roll out..."
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