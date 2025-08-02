#!/bin/bash

# Script de Deploy Simplificado para ECS com Versionamento por Commit Hash
# Versão: 1.0 - Funcional

set -e

# Configurações padrão
DEFAULT_REGION="us-east-1"
DEFAULT_CLUSTER="cluster-bia-01082025"
DEFAULT_SERVICE="service-bia-01082025"
DEFAULT_ECR_REPO="216665870449.dkr.ecr.us-east-1.amazonaws.com/bia"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir mensagens coloridas
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

# Função de ajuda
show_help() {
    cat << EOF
🚀 Script de Deploy ECS Simplificado

USO:
    $0 [COMANDO]

COMANDOS:
    deploy          Executa o deploy completo (build + push + update)
    build           Apenas faz o build da imagem
    push            Apenas faz o push da imagem
    update          Força novo deployment no ECS
    list            Lista as últimas versões disponíveis
    help            Exibe esta ajuda

EXEMPLOS:
    # Deploy completo
    $0 deploy

    # Apenas build
    $0 build

    # Listar versões
    $0 list

FUNCIONALIDADES:
    ✅ Versionamento automático por commit hash
    ✅ Build e push para ECR
    ✅ Force new deployment no ECS
    ✅ Listagem de versões disponíveis

EOF
}

# Função para obter hash do commit atual
get_commit_hash() {
    git rev-parse --short=7 HEAD
}

# Função para obter informações do commit
get_commit_info() {
    local commit_hash=$(get_commit_hash)
    local commit_message=$(git log -1 --pretty=format:"%s" HEAD)
    local commit_author=$(git log -1 --pretty=format:"%an" HEAD)
    local commit_date=$(git log -1 --pretty=format:"%ci" HEAD)
    
    echo "Commit: $commit_hash"
    echo "Mensagem: $commit_message"
    echo "Autor: $commit_author"
    echo "Data: $commit_date"
}

# Função para validar pré-requisitos
validate_prerequisites() {
    log_info "Validando pré-requisitos..."
    
    # Verificar se está em um repositório Git
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Este diretório não é um repositório Git"
        exit 1
    fi
    
    # Verificar se Docker está instalado
    if ! command -v docker &> /dev/null; then
        log_error "Docker não está instalado"
        exit 1
    fi
    
    # Verificar se AWS CLI está instalado
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI não está instalado"
        exit 1
    fi
    
    log_success "Pré-requisitos validados"
}

# Função para fazer build da imagem
build_image() {
    local commit_hash=$(get_commit_hash)
    local image_tag="$DEFAULT_ECR_REPO:$commit_hash"
    
    log_info "Iniciando build da imagem..."
    log_info "Tag da imagem: $image_tag"
    echo
    get_commit_info
    echo
    
    # Build da aplicação React primeiro
    log_info "Fazendo build da aplicação React..."
    cd client && npm install && VITE_API_URL=http://44.210.95.32 npm run build && cd ..
    
    # Build da imagem Docker
    log_info "Fazendo build da imagem Docker..."
    docker build -t "bia-app:$commit_hash" .
    docker tag "bia-app:$commit_hash" "$image_tag"
    
    log_success "Build concluído: $image_tag"
    echo "$commit_hash" > .last_build_version
}

# Função para fazer push da imagem
push_image() {
    local commit_hash
    
    if [[ -f .last_build_version ]]; then
        commit_hash=$(cat .last_build_version)
    else
        commit_hash=$(get_commit_hash)
    fi
    
    local image_tag="$DEFAULT_ECR_REPO:$commit_hash"
    
    log_info "Fazendo push da imagem: $image_tag"
    
    # Login no ECR
    log_info "Fazendo login no ECR..."
    aws ecr get-login-password --region "$DEFAULT_REGION" | docker login --username AWS --password-stdin "$DEFAULT_ECR_REPO"
    
    # Push da imagem
    log_info "Enviando imagem para ECR..."
    docker push "$image_tag"
    
    log_success "Push concluído: $image_tag"
}

# Função para atualizar serviço ECS (force new deployment)
update_service() {
    log_info "Forçando novo deployment no ECS..."
    
    aws ecs update-service \
        --cluster "$DEFAULT_CLUSTER" \
        --service "$DEFAULT_SERVICE" \
        --force-new-deployment \
        --region "$DEFAULT_REGION" \
        --query 'service.{serviceName:serviceName,taskDefinition:taskDefinition,desiredCount:desiredCount,runningCount:runningCount}' \
        --output table
    
    log_info "Aguardando estabilização do serviço..."
    aws ecs wait services-stable \
        --cluster "$DEFAULT_CLUSTER" \
        --services "$DEFAULT_SERVICE" \
        --region "$DEFAULT_REGION"
    
    log_success "Serviço atualizado com sucesso!"
}

# Função para listar versões disponíveis
list_versions() {
    log_info "Listando versões disponíveis no ECR..."
    
    aws ecr describe-images \
        --repository-name "bia" \
        --region "$DEFAULT_REGION" \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt,imageSizeInBytes]' \
        --output table
}

# Função principal de deploy
deploy() {
    validate_prerequisites
    
    local commit_hash=$(get_commit_hash)
    
    log_info "🚀 Iniciando deploy completo..."
    echo
    get_commit_info
    echo
    
    # Build
    build_image
    
    # Push
    push_image
    
    # Update service
    update_service
    
    log_success "🎉 Deploy concluído com sucesso!"
    log_info "Versão deployada: $commit_hash"
    log_info "Acesse: http://44.210.95.32"
}

# Parsing de argumentos
COMMAND="${1:-help}"

# Executar comando
case $COMMAND in
    deploy)
        deploy
        ;;
    build)
        validate_prerequisites
        build_image
        ;;
    push)
        push_image
        ;;
    update)
        update_service
        ;;
    list)
        list_versions
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Comando desconhecido: $COMMAND"
        show_help
        exit 1
        ;;
esac
