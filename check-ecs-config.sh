#!/bin/bash

# Script para verificar configuração do ECS Agent
# Projeto BIA - Diagnóstico de configuração

set -e

# Configurações
CLUSTER_NAME="cluster-bia-alb"
REGION="us-east-1"

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

# Função para obter instâncias ECS
get_ecs_instances() {
    aws ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=ECS Instance - $CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId,LaunchTime,Tags[?Key==`AmazonECSManaged`].Value|[0]]' \
        --output table \
        --region "$REGION"
}

# Função para verificar se cluster existe
check_cluster() {
    log_info "Verificando se cluster $CLUSTER_NAME existe..."
    
    local cluster_status=$(aws ecs describe-clusters \
        --clusters "$CLUSTER_NAME" \
        --region "$REGION" \
        --query 'clusters[0].status' \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$cluster_status" == "ACTIVE" ]]; then
        log_success "Cluster $CLUSTER_NAME está ATIVO"
        return 0
    elif [[ "$cluster_status" == "None" ]]; then
        log_error "Cluster $CLUSTER_NAME não encontrado!"
        return 1
    else
        log_warning "Cluster $CLUSTER_NAME tem status: $cluster_status"
        return 1
    fi
}

# Função para verificar Launch Template
check_launch_template() {
    log_info "Verificando configuração do Launch Template..."
    
    # Obter Launch Template ID das instâncias
    local lt_id=$(aws ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=ECS Instance - $CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`aws:ec2launchtemplate:id`].Value' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "None")
    
    if [[ "$lt_id" != "None" && -n "$lt_id" ]]; then
        log_info "Launch Template ID: $lt_id"
        
        # Obter UserData
        local user_data=$(aws ec2 describe-launch-template-versions \
            --launch-template-id "$lt_id" \
            --region "$REGION" \
            --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' \
            --output text)
        
        if [[ -n "$user_data" && "$user_data" != "None" ]]; then
            log_info "UserData encontrado. Decodificando..."
            echo "$user_data" | base64 -d
            echo
            
            # Verificar se contém o cluster correto
            local decoded_user_data=$(echo "$user_data" | base64 -d)
            if echo "$decoded_user_data" | grep -q "ECS_CLUSTER=$CLUSTER_NAME"; then
                log_success "UserData contém o cluster correto: $CLUSTER_NAME"
            else
                log_error "UserData NÃO contém o cluster correto!"
                log_info "Esperado: ECS_CLUSTER=$CLUSTER_NAME"
            fi
        else
            log_error "UserData não encontrado no Launch Template"
        fi
    else
        log_error "Launch Template ID não encontrado"
    fi
}

# Função para verificar IAM Instance Profile
check_iam_profile() {
    log_info "Verificando IAM Instance Profile das instâncias..."
    
    local profiles=$(aws ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=ECS Instance - $CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].IamInstanceProfile.Arn' \
        --output text \
        --region "$REGION")
    
    if [[ -n "$profiles" ]]; then
        log_info "Instance Profiles encontrados:"
        echo "$profiles"
        
        # Verificar se é o profile correto
        if echo "$profiles" | grep -q "ecsInstanceRole"; then
            log_success "Instance Profile correto encontrado: ecsInstanceRole"
        else
            log_warning "Instance Profile pode não ser o correto para ECS"
        fi
    else
        log_error "Nenhum Instance Profile encontrado nas instâncias"
    fi
}

# Função para verificar conectividade de rede
check_network() {
    log_info "Verificando configuração de rede..."
    
    # Verificar Security Groups
    local sg_ids=$(aws ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=ECS Instance - $CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].SecurityGroups[].GroupId' \
        --output text \
        --region "$REGION")
    
    if [[ -n "$sg_ids" ]]; then
        log_info "Security Groups das instâncias: $sg_ids"
        
        # Verificar regras de saída (ECS precisa de acesso HTTPS)
        for sg_id in $sg_ids; do
            log_info "Verificando regras de saída do SG: $sg_id"
            
            local egress_rules=$(aws ec2 describe-security-groups \
                --group-ids "$sg_id" \
                --region "$REGION" \
                --query 'SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1` || (IpProtocol==`tcp` && (FromPort<=`443` && ToPort>=`443`))]' \
                --output text 2>/dev/null || echo "None")
            
            if [[ "$egress_rules" != "None" && -n "$egress_rules" ]]; then
                log_success "SG $sg_id tem regras de saída adequadas"
            else
                log_warning "SG $sg_id pode não ter regras de saída adequadas para HTTPS"
            fi
        done
    else
        log_error "Nenhum Security Group encontrado"
    fi
}

# Função para sugerir soluções
suggest_solutions() {
    log_info "=== POSSÍVEIS SOLUÇÕES ==="
    echo
    log_info "1. AGUARDAR MAIS TEMPO:"
    log_info "   - As instâncias podem levar até 10-15 minutos para se registrar"
    log_info "   - Comando para verificar: aws ecs list-container-instances --cluster $CLUSTER_NAME"
    echo
    
    log_info "2. VERIFICAR LOGS DO ECS AGENT:"
    log_info "   - Conectar na instância via Session Manager"
    log_info "   - Verificar: sudo journalctl -u ecs -f"
    log_info "   - Verificar: cat /var/log/ecs/ecs-agent.log"
    echo
    
    log_info "3. REINICIAR ECS AGENT:"
    log_info "   - sudo systemctl restart ecs"
    log_info "   - sudo systemctl status ecs"
    echo
    
    log_info "4. VERIFICAR CONECTIVIDADE:"
    log_info "   - curl -I https://ecs.us-east-1.amazonaws.com/"
    log_info "   - nslookup ecs.us-east-1.amazonaws.com"
    echo
    
    log_info "5. RECRIAR INSTÂNCIAS:"
    log_info "   - Terminar instâncias atuais"
    log_info "   - Auto Scaling Group criará novas automaticamente"
    echo
}

# Função principal
main() {
    log_info "🔍 Verificando configuração do ECS..."
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Região: $REGION"
    echo
    
    # Verificar cluster
    log_info "=== VERIFICAÇÃO DO CLUSTER ==="
    if ! check_cluster; then
        log_error "Problema com o cluster. Abortando verificação."
        exit 1
    fi
    echo
    
    # Listar instâncias
    log_info "=== INSTÂNCIAS ECS ==="
    get_ecs_instances
    echo
    
    # Verificar Launch Template
    log_info "=== LAUNCH TEMPLATE ==="
    check_launch_template
    echo
    
    # Verificar IAM
    log_info "=== IAM INSTANCE PROFILE ==="
    check_iam_profile
    echo
    
    # Verificar rede
    log_info "=== CONFIGURAÇÃO DE REDE ==="
    check_network
    echo
    
    # Status final do cluster
    log_info "=== STATUS ATUAL DO CLUSTER ==="
    aws ecs describe-clusters \
        --clusters "$CLUSTER_NAME" \
        --region "$REGION" \
        --query 'clusters[0].[status,registeredContainerInstancesCount,activeServicesCount]' \
        --output table
    echo
    
    # Sugerir soluções
    suggest_solutions
}

# Executar função principal
main "$@"
