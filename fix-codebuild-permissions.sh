#!/bin/bash

# Script para verificar e corrigir permissões do CodeBuild para ECR
# Projeto BIA

set -e

# Configurações
REGION="us-east-1"
ACCOUNT_ID="216665870449"
ECR_REPO_NAME="bia"
CODEBUILD_ROLE_NAME="codebuild-bia-build-service-role"

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

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Função para verificar se o role do CodeBuild existe
check_codebuild_role() {
    log_info "Verificando role do CodeBuild: $CODEBUILD_ROLE_NAME"
    
    if aws iam get-role --role-name "$CODEBUILD_ROLE_NAME" --region "$REGION" >/dev/null 2>&1; then
        log_success "Role do CodeBuild encontrado"
        return 0
    else
        log_error "Role do CodeBuild não encontrado: $CODEBUILD_ROLE_NAME"
        return 1
    fi
}

# Função para verificar permissões ECR
check_ecr_permissions() {
    log_info "Verificando permissões ECR para o role do CodeBuild..."
    
    # Verificar se há políticas anexadas que incluem ECR
    local policies=$(aws iam list-attached-role-policies --role-name "$CODEBUILD_ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
    
    if [[ -n "$policies" ]]; then
        log_info "Políticas anexadas ao role:"
        echo "$policies" | tr '\t' '\n'
        
        # Verificar se há política com permissões ECR
        for policy_arn in $policies; do
            local policy_doc=$(aws iam get-policy --policy-arn "$policy_arn" --query 'Policy.DefaultVersionId' --output text 2>/dev/null || echo "")
            if [[ -n "$policy_doc" ]]; then
                local policy_version=$(aws iam get-policy-version --policy-arn "$policy_arn" --version-id "$policy_doc" --query 'PolicyVersion.Document' --output json 2>/dev/null || echo "{}")
                
                if echo "$policy_version" | grep -q "ecr:"; then
                    log_success "Encontrada política com permissões ECR: $policy_arn"
                    return 0
                fi
            fi
        done
    fi
    
    log_warning "Nenhuma política com permissões ECR encontrada"
    return 1
}

# Função para criar política ECR para CodeBuild
create_ecr_policy() {
    log_info "Criando política ECR para CodeBuild..."
    
    local policy_name="CodeBuildECRPolicy-bia"
    local policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "ecr:BatchCheckLayerAvailability",
                    "ecr:GetDownloadUrlForLayer",
                    "ecr:BatchGetImage",
                    "ecr:GetAuthorizationToken",
                    "ecr:InitiateLayerUpload",
                    "ecr:UploadLayerPart",
                    "ecr:CompleteLayerUpload",
                    "ecr:PutImage"
                ],
                "Resource": [
                    "arn:aws:ecr:'$REGION':'$ACCOUNT_ID':repository/'$ECR_REPO_NAME'",
                    "arn:aws:ecr:'$REGION':'$ACCOUNT_ID':registry/*"
                ]
            },
            {
                "Effect": "Allow",
                "Action": [
                    "ecr:GetAuthorizationToken"
                ],
                "Resource": "*"
            }
        ]
    }'
    
    # Criar a política
    local policy_arn=$(aws iam create-policy \
        --policy-name "$policy_name" \
        --policy-document "$policy_document" \
        --query 'Policy.Arn' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$policy_arn" ]]; then
        log_success "Política ECR criada: $policy_arn"
        
        # Anexar a política ao role
        if aws iam attach-role-policy --role-name "$CODEBUILD_ROLE_NAME" --policy-arn "$policy_arn" 2>/dev/null; then
            log_success "Política ECR anexada ao role do CodeBuild"
            return 0
        else
            log_error "Falha ao anexar política ao role"
            return 1
        fi
    else
        log_error "Falha ao criar política ECR"
        return 1
    fi
}

# Função principal
main() {
    log_info "🔍 Verificando permissões do CodeBuild para ECR..."
    log_info "Account ID: $ACCOUNT_ID"
    log_info "Região: $REGION"
    log_info "Repositório ECR: $ECR_REPO_NAME"
    echo
    
    # Verificar se o role existe
    if ! check_codebuild_role; then
        log_error "Role do CodeBuild não encontrado. Verifique se o projeto CodeBuild foi criado corretamente."
        exit 1
    fi
    
    # Verificar permissões ECR
    if check_ecr_permissions; then
        log_success "✅ Permissões ECR já configuradas corretamente"
    else
        log_warning "⚠️  Permissões ECR não encontradas. Tentando criar..."
        
        if create_ecr_policy; then
            log_success "✅ Permissões ECR configuradas com sucesso"
        else
            log_error "❌ Falha ao configurar permissões ECR"
            exit 1
        fi
    fi
    
    echo
    log_info "=== INSTRUÇÕES ADICIONAIS ==="
    log_info "1. O buildspec.yml foi corrigido para usar o ECR correto"
    log_info "2. Faça um novo build no CodeBuild para testar"
    log_info "3. Se ainda houver erro, verifique se o projeto CodeBuild está na região correta"
    log_info "4. URI do ECR correta: $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME"
}

# Executar função principal
main "$@"
