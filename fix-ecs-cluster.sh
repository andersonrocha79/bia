#!/bin/bash

# Script para corrigir cluster ECS - Criar instâncias EC2
# Projeto BIA - Correção de cluster sem instâncias

set -e

# Configurações
CLUSTER_NAME="cluster-bia-01082025"
REGION="us-east-1"
INSTANCE_TYPE="t3.micro"
VPC_ID="vpc-09e9102b46edf0375"
SUBNET_ID="subnet-05ad43127af3cbec1"  # us-east-1a

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Função para criar Security Group
create_security_group() {
    log_info "Verificando Security Group bia-ec2..."
    
    # Verificar se já existe
    local sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=bia-ec2" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region $REGION 2>/dev/null || echo "None")
    
    if [[ "$sg_id" != "None" && "$sg_id" != "null" ]]; then
        log_info "Security Group já existe: $sg_id"
        echo "$sg_id"
        return 0
    fi
    
    log_info "Criando Security Group bia-ec2..."
    
    # Criar Security Group
    sg_id=$(aws ec2 create-security-group \
        --group-name "bia-ec2" \
        --description "Security group para instancias ECS do projeto BIA" \
        --vpc-id "$VPC_ID" \
        --region "$REGION" \
        --query 'GroupId' \
        --output text)
    
    # Adicionar regras de entrada
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --region "$REGION"
    
    # Adicionar regra para portas dinâmicas ECS
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 32768-65535 \
        --source-group "$sg_id" \
        --region "$REGION"
    
    # Adicionar tag
    aws ec2 create-tags \
        --resources "$sg_id" \
        --tags Key=Name,Value=bia-ec2 \
        --region "$REGION"
    
    log_success "Security Group criado: $sg_id"
    echo "$sg_id"
}

# Função para criar IAM Role
create_iam_role() {
    log_info "Verificando IAM Role para instâncias ECS..."
    
    # Verificar se já existe
    local role_exists=$(aws iam get-role \
        --role-name "bia-ecs-instance-role" \
        --query 'Role.RoleName' \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$role_exists" != "None" ]]; then
        log_info "IAM Role já existe: bia-ecs-instance-role"
        return 0
    fi
    
    log_info "Criando IAM Role bia-ecs-instance-role..."
    
    # Criar trust policy
    cat > /tmp/trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
    
    # Criar role
    aws iam create-role \
        --role-name "bia-ecs-instance-role" \
        --assume-role-policy-document file:///tmp/trust-policy.json \
        --region "$REGION"
    
    # Anexar policies
    aws iam attach-role-policy \
        --role-name "bia-ecs-instance-role" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" \
        --region "$REGION"
    
    aws iam attach-role-policy \
        --role-name "bia-ecs-instance-role" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
        --region "$REGION"
    
    # Criar instance profile
    aws iam create-instance-profile \
        --instance-profile-name "bia-ecs-instance-profile" \
        --region "$REGION"
    
    # Adicionar role ao instance profile
    aws iam add-role-to-instance-profile \
        --instance-profile-name "bia-ecs-instance-profile" \
        --role-name "bia-ecs-instance-role" \
        --region "$REGION"
    
    # Aguardar propagação
    log_info "Aguardando propagação da IAM Role (30 segundos)..."
    sleep 30
    
    # Limpar arquivo temporário
    rm -f /tmp/trust-policy.json
    
    log_success "IAM Role criada: bia-ecs-instance-role"
}

# Função para obter AMI ECS-optimized mais recente
get_ecs_ami() {
    log_info "Obtendo AMI ECS-optimized mais recente..."
    
    local ami_id=$(aws ec2 describe-images \
        --owners amazon \
        --filters \
            "Name=name,Values=amzn2-ami-ecs-hvm-*-x86_64-ebs" \
            "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text \
        --region "$REGION")
    
    log_info "AMI selecionada: $ami_id"
    echo "$ami_id"
}

# Função para criar instância EC2
create_ec2_instance() {
    local sg_id="$1"
    local ami_id="$2"
    
    log_info "Criando instância EC2 para o cluster ECS..."
    
    # Criar user data script
    cat > /tmp/user-data.sh << EOF
#!/bin/bash
echo ECS_CLUSTER=$CLUSTER_NAME >> /etc/ecs/ecs.config
echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
yum update -y
yum install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
EOF
    
    # Criar instância
    local instance_id=$(aws ec2 run-instances \
        --image-id "$ami_id" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --security-group-ids "$sg_id" \
        --subnet-id "$SUBNET_ID" \
        --iam-instance-profile Name=bia-ecs-instance-profile \
        --user-data file:///tmp/user-data.sh \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=bia-ecs-instance},{Key=Project,Value=BIA}]" \
        --query 'Instances[0].InstanceId' \
        --output text \
        --region "$REGION")
    
    # Limpar arquivo temporário
    rm -f /tmp/user-data.sh
    
    log_success "Instância EC2 criada: $instance_id"
    
    # Aguardar instância ficar running
    log_info "Aguardando instância ficar em estado 'running'..."
    aws ec2 wait instance-running \
        --instance-ids "$instance_id" \
        --region "$REGION"
    
    log_success "Instância está rodando!"
    
    # Aguardar registro no cluster ECS
    log_info "Aguardando registro no cluster ECS (pode levar alguns minutos)..."
    
    local attempts=0
    local max_attempts=20
    
    while [[ $attempts -lt $max_attempts ]]; do
        local container_instances=$(aws ecs list-container-instances \
            --cluster "$CLUSTER_NAME" \
            --query 'length(containerInstanceArns)' \
            --output text \
            --region "$REGION")
        
        if [[ "$container_instances" -gt 0 ]]; then
            log_success "Instância registrada no cluster ECS!"
            break
        fi
        
        attempts=$((attempts + 1))
        log_info "Tentativa $attempts/$max_attempts - Aguardando registro..."
        sleep 15
    done
    
    if [[ $attempts -eq $max_attempts ]]; then
        log_warning "Timeout aguardando registro no cluster. Verifique os logs da instância."
        log_info "Instance ID: $instance_id"
        log_info "Comando para verificar logs: aws logs describe-log-streams --log-group-name /aws/ecs/containerinsights/$CLUSTER_NAME/performance"
    fi
    
    echo "$instance_id"
}

# Função principal
main() {
    log_info "🚀 Iniciando correção do cluster ECS..."
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Região: $REGION"
    echo
    
    # Verificar se cluster existe
    log_info "Verificando se cluster existe..."
    local cluster_status=$(aws ecs describe-clusters \
        --clusters "$CLUSTER_NAME" \
        --query 'clusters[0].status' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "None")
    
    if [[ "$cluster_status" == "None" ]]; then
        log_error "Cluster $CLUSTER_NAME não encontrado!"
        exit 1
    fi
    
    log_info "Cluster encontrado com status: $cluster_status"
    echo
    
    # Criar Security Group
    log_info "=== ETAPA 1: SECURITY GROUP ==="
    local sg_id=$(create_security_group)
    echo
    
    # Criar IAM Role
    log_info "=== ETAPA 2: IAM ROLE ==="
    create_iam_role
    echo
    
    # Obter AMI
    log_info "=== ETAPA 3: AMI ECS-OPTIMIZED ==="
    local ami_id=$(get_ecs_ami)
    echo
    
    # Criar instância EC2
    log_info "=== ETAPA 4: INSTÂNCIA EC2 ==="
    local instance_id=$(create_ec2_instance "$sg_id" "$ami_id")
    echo
    
    # Verificar status final
    log_info "=== STATUS FINAL ==="
    log_info "Verificando status do cluster..."
    
    local final_instances=$(aws ecs list-container-instances \
        --cluster "$CLUSTER_NAME" \
        --query 'length(containerInstanceArns)' \
        --output text \
        --region "$REGION")
    
    log_success "🎉 Correção concluída!"
    log_info "Instâncias no cluster: $final_instances"
    log_info "Instance ID: $instance_id"
    log_info "Security Group: $sg_id"
    echo
    log_info "Agora você pode tentar fazer o deploy novamente:"
    log_info "./deploy-ecs.sh deploy"
}

# Executar função principal
main "$@"
