#!/bin/bash

# Script para diagnosticar e corrigir problemas do ECS Agent
# Projeto BIA - Correção de instâncias não registradas no cluster

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

# Função para obter instâncias do cluster
get_cluster_instances() {
    aws ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=ECS Instance - $CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text \
        --region "$REGION"
}

# Função para reiniciar ECS Agent via Systems Manager
restart_ecs_agent() {
    local instance_id="$1"
    
    log_info "Tentando reiniciar ECS Agent na instância $instance_id..."
    
    # Comando para reiniciar o ECS Agent
    local command_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["sudo systemctl restart ecs","sudo systemctl status ecs"]' \
        --region "$REGION" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null || echo "FAILED")
    
    if [[ "$command_id" != "FAILED" ]]; then
        log_info "Comando enviado: $command_id"
        
        # Aguardar execução
        sleep 10
        
        # Verificar resultado
        local status=$(aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --region "$REGION" \
            --query 'Status' \
            --output text 2>/dev/null || echo "Unknown")
        
        log_info "Status do comando: $status"
        
        if [[ "$status" == "Success" ]]; then
            log_success "ECS Agent reiniciado com sucesso na instância $instance_id"
            return 0
        else
            log_warning "Falha ao reiniciar ECS Agent via SSM na instância $instance_id"
            return 1
        fi
    else
        log_warning "Não foi possível enviar comando SSM para instância $instance_id"
        return 1
    fi
}

# Função para recriar instâncias problemáticas
recreate_instances() {
    log_warning "Tentando recriar instâncias do Auto Scaling Group..."
    
    # Obter nome do Auto Scaling Group
    local asg_name=$(aws ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=ECS Instance - $CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`aws:autoscaling:groupName`].Value' \
        --output text \
        --region "$REGION")
    
    if [[ -n "$asg_name" && "$asg_name" != "None" ]]; then
        log_info "Auto Scaling Group encontrado: $asg_name"
        
        # Forçar refresh das instâncias
        log_info "Iniciando refresh das instâncias..."
        
        local refresh_id=$(aws autoscaling start-instance-refresh \
            --auto-scaling-group-name "$asg_name" \
            --preferences '{"InstanceWarmup": 300, "MinHealthyPercentage": 50}' \
            --region "$REGION" \
            --query 'InstanceRefreshId' \
            --output text 2>/dev/null || echo "FAILED")
        
        if [[ "$refresh_id" != "FAILED" ]]; then
            log_success "Instance refresh iniciado: $refresh_id"
            log_info "Aguarde alguns minutos para que as novas instâncias sejam criadas e registradas no cluster"
            return 0
        else
            log_error "Falha ao iniciar instance refresh"
            return 1
        fi
    else
        log_error "Auto Scaling Group não encontrado"
        return 1
    fi
}

# Função para verificar conectividade com ECS
check_ecs_connectivity() {
    local instance_id="$1"
    
    log_info "Verificando conectividade ECS na instância $instance_id..."
    
    # Comando para testar conectividade
    local command_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["curl -s https://ecs.us-east-1.amazonaws.com/ | head -5","cat /etc/ecs/ecs.config","sudo systemctl status ecs --no-pager"]' \
        --region "$REGION" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null || echo "FAILED")
    
    if [[ "$command_id" != "FAILED" ]]; then
        sleep 5
        
        # Obter output
        local output=$(aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --region "$REGION" \
            --query 'StandardOutputContent' \
            --output text 2>/dev/null || echo "No output")
        
        log_info "Output do diagnóstico:"
        echo "$output"
        return 0
    else
        log_warning "Não foi possível executar diagnóstico na instância $instance_id"
        return 1
    fi
}

# Função principal
main() {
    log_info "🔍 Iniciando diagnóstico do cluster ECS..."
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Região: $REGION"
    echo
    
    # Verificar status do cluster
    log_info "=== STATUS DO CLUSTER ==="
    local cluster_info=$(aws ecs describe-clusters \
        --clusters "$CLUSTER_NAME" \
        --region "$REGION" \
        --query 'clusters[0].[status,registeredContainerInstancesCount,activeServicesCount]' \
        --output text)
    
    echo "Status do cluster: $cluster_info"
    echo
    
    # Obter instâncias EC2
    log_info "=== INSTÂNCIAS EC2 ==="
    local instances=$(get_cluster_instances)
    
    if [[ -z "$instances" ]]; then
        log_error "Nenhuma instância EC2 encontrada para o cluster $CLUSTER_NAME"
        exit 1
    fi
    
    log_info "Instâncias encontradas: $instances"
    echo
    
    # Verificar cada instância
    log_info "=== DIAGNÓSTICO DAS INSTÂNCIAS ==="
    local fixed_any=false
    
    for instance_id in $instances; do
        log_info "Processando instância: $instance_id"
        
        # Verificar conectividade
        if check_ecs_connectivity "$instance_id"; then
            log_info "Diagnóstico executado para $instance_id"
        fi
        
        # Tentar reiniciar ECS Agent
        if restart_ecs_agent "$instance_id"; then
            fixed_any=true
            log_success "ECS Agent reiniciado em $instance_id"
        else
            log_warning "Falha ao reiniciar ECS Agent em $instance_id"
        fi
        
        echo
    done
    
    # Se reiniciar não funcionou, tentar recriar instâncias
    if [[ "$fixed_any" == "false" ]]; then
        log_warning "Reinicialização do ECS Agent não funcionou. Tentando recriar instâncias..."
        recreate_instances
    fi
    
    # Aguardar e verificar resultado
    log_info "=== VERIFICAÇÃO FINAL ==="
    log_info "Aguardando 60 segundos para verificar se as instâncias se registraram..."
    sleep 60
    
    local final_count=$(aws ecs describe-clusters \
        --clusters "$CLUSTER_NAME" \
        --region "$REGION" \
        --query 'clusters[0].registeredContainerInstancesCount' \
        --output text)
    
    if [[ "$final_count" -gt 0 ]]; then
        log_success "🎉 Problema resolvido! $final_count instância(s) registrada(s) no cluster"
        log_info "Agora você pode tentar fazer o deploy novamente:"
        log_info "./deploy-ecs.sh deploy"
    else
        log_error "❌ Problema persiste. Instâncias ainda não registradas no cluster"
        log_info "Possíveis soluções adicionais:"
        log_info "1. Verificar se o IAM Instance Profile tem as permissões corretas"
        log_info "2. Verificar conectividade de rede (Security Groups, NACLs)"
        log_info "3. Verificar logs do ECS Agent nas instâncias"
        log_info "4. Considerar recriar o cluster e as instâncias"
    fi
}

# Executar função principal
main "$@"
