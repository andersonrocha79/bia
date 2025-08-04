#!/bin/bash

# Script para corrigir permissões IAM do ECS Instance Profile
# Projeto BIA - Correção de permissões

set -e

# Configurações
REGION="us-east-1"
ROLE_NAME="ecsInstanceRole"
INSTANCE_PROFILE_NAME="ecsInstanceRole"

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

# Função para verificar se role existe
check_role_exists() {
    aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" >/dev/null 2>&1
}

# Função para criar trust policy
create_trust_policy() {
    cat > /tmp/trust-policy.json << 'EOF'
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
}

# Função para criar role se não existir
create_role_if_needed() {
    if ! check_role_exists; then
        log_info "Criando IAM Role $ROLE_NAME..."
        
        create_trust_policy
        
        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document file:///tmp/trust-policy.json \
            --region "$REGION"
        
        log_success "IAM Role criada: $ROLE_NAME"
        rm -f /tmp/trust-policy.json
    else
        log_info "IAM Role $ROLE_NAME já existe"
    fi
}

# Função para anexar policies necessárias
attach_policies() {
    log_info "Anexando policies necessárias..."
    
    # Policy principal do ECS
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" \
        --region "$REGION" 2>/dev/null || log_info "Policy AmazonEC2ContainerServiceforEC2Role já anexada"
    
    # Policy para SSM (opcional, mas útil para debugging)
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
        --region "$REGION" 2>/dev/null || log_info "Policy AmazonSSMManagedInstanceCore já anexada"
    
    log_success "Policies anexadas com sucesso"
}

# Função para criar instance profile se não existir
create_instance_profile_if_needed() {
    local profile_exists=$(aws iam get-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --region "$REGION" 2>/dev/null || echo "false")
    
    if [[ "$profile_exists" == "false" ]]; then
        log_info "Criando Instance Profile $INSTANCE_PROFILE_NAME..."
        
        aws iam create-instance-profile \
            --instance-profile-name "$INSTANCE_PROFILE_NAME" \
            --region "$REGION"
        
        log_success "Instance Profile criado: $INSTANCE_PROFILE_NAME"
    else
        log_info "Instance Profile $INSTANCE_PROFILE_NAME já existe"
    fi
}

# Função para adicionar role ao instance profile
add_role_to_instance_profile() {
    log_info "Adicionando role ao instance profile..."
    
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME" \
        --region "$REGION" 2>/dev/null || log_info "Role já está no instance profile"
    
    log_success "Role adicionada ao instance profile"
}

# Função para aguardar propagação
wait_for_propagation() {
    log_info "Aguardando propagação das permissões IAM (60 segundos)..."
    sleep 60
    log_success "Propagação concluída"
}

# Função para reiniciar instâncias do Auto Scaling Group
restart_asg_instances() {
    log_info "Reiniciando instâncias do Auto Scaling Group..."
    
    # Obter nome do ASG
    local asg_name=$(aws ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=ECS Instance - cluster-bia-alb" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`aws:autoscaling:groupName`].Value' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "None")
    
    if [[ "$asg_name" != "None" && -n "$asg_name" ]]; then
        log_info "Auto Scaling Group encontrado: $asg_name"
        
        # Iniciar instance refresh
        local refresh_id=$(aws autoscaling start-instance-refresh \
            --auto-scaling-group-name "$asg_name" \
            --preferences '{"InstanceWarmup": 300, "MinHealthyPercentage": 0}' \
            --region "$REGION" \
            --query 'InstanceRefreshId' \
            --output text 2>/dev/null || echo "FAILED")
        
        if [[ "$refresh_id" != "FAILED" ]]; then
            log_success "Instance refresh iniciado: $refresh_id"
            log_info "Aguardando novas instâncias serem criadas (5 minutos)..."
            sleep 300
        else
            log_warning "Falha ao iniciar instance refresh. Tentando terminar instâncias manualmente..."
            
            # Obter instâncias do ASG
            local instances=$(aws ec2 describe-instances \
                --filters \
                    "Name=tag:aws:autoscaling:groupName,Values=$asg_name" \
                    "Name=instance-state-name,Values=running" \
                --query 'Reservations[].Instances[].InstanceId' \
                --output text \
                --region "$REGION")
            
            if [[ -n "$instances" ]]; then
                log_info "Terminando instâncias: $instances"
                aws ec2 terminate-instances \
                    --instance-ids $instances \
                    --region "$REGION"
                
                log_info "Aguardando novas instâncias serem criadas pelo ASG..."
                sleep 300
            fi
        fi
    else
        log_error "Auto Scaling Group não encontrado"
        return 1
    fi
}

# Função principal
main() {
    log_info "🔧 Iniciando correção de permissões IAM..."
    log_info "Role: $ROLE_NAME"
    log_info "Instance Profile: $INSTANCE_PROFILE_NAME"
    log_info "Região: $REGION"
    echo
    
    # Criar role se necessário
    log_info "=== ETAPA 1: IAM ROLE ==="
    create_role_if_needed
    echo
    
    # Anexar policies
    log_info "=== ETAPA 2: POLICIES ==="
    attach_policies
    echo
    
    # Criar instance profile se necessário
    log_info "=== ETAPA 3: INSTANCE PROFILE ==="
    create_instance_profile_if_needed
    echo
    
    # Adicionar role ao instance profile
    log_info "=== ETAPA 4: ASSOCIAÇÃO ==="
    add_role_to_instance_profile
    echo
    
    # Aguardar propagação
    log_info "=== ETAPA 5: PROPAGAÇÃO ==="
    wait_for_propagation
    echo
    
    # Reiniciar instâncias
    log_info "=== ETAPA 6: REINICIAR INSTÂNCIAS ==="
    restart_asg_instances
    echo
    
    # Verificação final
    log_info "=== VERIFICAÇÃO FINAL ==="
    local final_count=$(aws ecs describe-clusters \
        --clusters "cluster-bia-alb" \
        --region "$REGION" \
        --query 'clusters[0].registeredContainerInstancesCount' \
        --output text)
    
    if [[ "$final_count" -gt 0 ]]; then
        log_success "🎉 Problema resolvido! $final_count instância(s) registrada(s) no cluster"
        log_info "Agora você pode tentar fazer o deploy novamente:"
        log_info "./deploy-ecs.sh deploy"
    else
        log_warning "⏳ Instâncias ainda não registradas. Pode levar alguns minutos adicionais."
        log_info "Aguarde mais 2-3 minutos e verifique novamente:"
        log_info "aws ecs describe-clusters --clusters cluster-bia-alb --query 'clusters[0].registeredContainerInstancesCount'"
    fi
}

# Executar função principal
main "$@"
