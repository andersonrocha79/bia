#!/bin/bash

# Script para criar instância EC2 com ECS Agent para o projeto BIA

# Configurações
CLUSTER_NAME="cluster-bia"
INSTANCE_TYPE="t3.micro"
KEY_NAME=""  # Deixe vazio se não quiser usar key pair
SUBNET_ID="subnet-05ad43127af3cbec1"  # Mesma subnet da instância existente
SECURITY_GROUP="sg-0e6c34b36ac6b61eb"  # Security group bia-dev existente
IAM_INSTANCE_PROFILE="ecsInstanceRole"  # Role existente

# User Data para configurar ECS Agent
USER_DATA=$(cat << 'EOF'
#!/bin/bash
yum update -y
yum install -y ecs-init
echo ECS_CLUSTER=cluster-bia >> /etc/ecs/ecs.config
echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
service docker start
start ecs
EOF
)

# Codificar User Data em base64
USER_DATA_B64=$(echo "$USER_DATA" | base64 -w 0)

echo "Criando instância EC2 com ECS Agent..."

# Criar instância EC2
aws ec2 run-instances \
    --image-id ami-0c02fb55956c7d316 \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --subnet-id $SUBNET_ID \
    --security-group-ids $SECURITY_GROUP \
    --iam-instance-profile Name=$IAM_INSTANCE_PROFILE \
    --user-data "$USER_DATA_B64" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bia-ecs-instance}]' \
    --region us-east-1

echo "Instância criada! Aguarde alguns minutos para que ela se registre no cluster ECS."
echo "Você pode verificar o status com:"
echo "aws ecs list-container-instances --cluster cluster-bia --region us-east-1"
EOF
