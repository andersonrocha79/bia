#!/bin/bash

# Script de Deploy para ECS - Projeto BIA
# Autor: Amazon Q
# Versão: 1.0

set -e

# Configurações padrão
PROJECT_NAME="bia"
ECR_REPOSITORY="bia-app"
ECS_CLUSTER="bia-cluster-alb"
ECS_SERVICE="bia-service"
TASK_DEFINITION="bia-tf"
AWS_REGION="us-east-1"

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

# Função para exibir help
show_help() {
    cat << EOF
${GREEN}Script de Deploy para ECS - Projeto BIA${NC}

${YELLOW}USAGE:${NC}
    ./deploy.sh [COMMAND] [OPTIONS]

${YELLOW}COMMANDS:${NC}
    build           Faz build da imagem Docker com tag do commit
    deploy          Faz deploy da imagem para o ECS
    rollback        Faz rollback para uma versão anterior
    list            Lista as últimas 10 imagens disponíveis
    help            Exibe esta ajuda

${YELLOW}OPTIONS:${NC}
    -r, --region    Região AWS (padrão: us-east-1)
    -c, --cluster   Nome do cluster ECS (padrão: bia-cluster-alb)
    -s, --service   Nome do serviço ECS (padrão: bia-service)
    -t, --tag       Tag específica para rollback
    --dry-run       Simula as ações sem executar

${YELLOW}EXAMPLES:${NC}
    ./deploy.sh build                    # Build com tag do commit atual
    ./deploy.sh deploy                   # Deploy da última imagem buildada
    ./deploy.sh rollback -t abc1234      # Rollback para commit abc1234
    ./deploy.sh list                     # Lista imagens disponíveis
    ./deploy.sh build --dry-run          # Simula o build

${YELLOW}WORKFLOW TÍPICO:${NC}
    1. ./deploy.sh build     # Gera imagem com tag do commit
    2. ./deploy.sh deploy    # Faz deploy para ECS
    3. ./deploy.sh rollback  # Se necessário, faz rollback

${YELLOW}CONFIGURAÇÃO:${NC}
    - AWS CLI configurado com credenciais válidas
    - Docker instalado e rodando
    - Permissões para ECR, ECS e IAM
    - ECR repository '${ECR_REPOSITORY}' deve existir

EOF
}

# Função para obter commit hash
get_commit_hash() {
    if [ "$DRY_RUN" = true ]; then
        echo "abc1234"
        return
    fi
    
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git rev-parse --short=7 HEAD
    else
        log_error "Não é um repositório Git válido"
        exit 1
    fi
}

# Função para obter account ID da AWS
get_aws_account_id() {
    if [ "$DRY_RUN" = true ]; then
        echo "123456789012"
        return
    fi
    
    aws sts get-caller-identity --query Account --output text --region $AWS_REGION
}

# Função para fazer login no ECR
ecr_login() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Faria login no ECR"
        return
    fi
    
    log_info "Fazendo login no ECR..."
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URI
}

# Função para build da imagem
build_image() {
    local commit_hash=$(get_commit_hash)
    local account_id=$(get_aws_account_id)
    ECR_URI="$account_id.dkr.ecr.$AWS_REGION.amazonaws.com"
    IMAGE_TAG="$ECR_URI/$ECR_REPOSITORY:$commit_hash"
    
    log_info "Iniciando build da imagem..."
    log_info "Commit Hash: $commit_hash"
    log_info "Image Tag: $IMAGE_TAG"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] docker build -t $IMAGE_TAG ."
        log_info "[DRY-RUN] docker push $IMAGE_TAG"
        return
    fi
    
    # Build da imagem
    log_info "Fazendo build da imagem Docker..."
    docker build -t $IMAGE_TAG .
    
    # Login no ECR
    ecr_login
    
    # Push da imagem
    log_info "Fazendo push da imagem para ECR..."
    docker push $IMAGE_TAG
    
    log_success "Build concluído com sucesso!"
    log_success "Imagem: $IMAGE_TAG"
    
    # Salvar a última tag buildada
    echo $commit_hash > .last_build_tag
}

# Função para criar nova task definition
create_task_definition() {
    local image_uri=$1
    local commit_hash=$2
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Criaria nova task definition com imagem: $image_uri"
        return "bia-tf:123"
    fi
    
    log_info "Criando nova task definition..."
    
    # Obter task definition atual
    local current_td=$(aws ecs describe-task-definition \
        --task-definition $TASK_DEFINITION \
        --region $AWS_REGION \
        --query 'taskDefinition' \
        --output json)
    
    # Criar nova task definition com nova imagem
    local new_td=$(echo $current_td | jq --arg image "$image_uri" '
        .containerDefinitions[0].image = $image |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ')
    
    # Registrar nova task definition
    local new_td_arn=$(echo $new_td | aws ecs register-task-definition \
        --region $AWS_REGION \
        --cli-input-json file:///dev/stdin \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)
    
    log_success "Nova task definition criada: $new_td_arn"
    echo $new_td_arn
}

# Função para fazer deploy
deploy_service() {
    local tag=${1:-$(cat .last_build_tag 2>/dev/null || echo "")}
    
    if [ -z "$tag" ]; then
        log_error "Nenhuma tag especificada e nenhum build anterior encontrado"
        log_info "Execute primeiro: ./deploy.sh build"
        exit 1
    fi
    
    local account_id=$(get_aws_account_id)
    ECR_URI="$account_id.dkr.ecr.$AWS_REGION.amazonaws.com"
    local image_uri="$ECR_URI/$ECR_REPOSITORY:$tag"
    
    log_info "Iniciando deploy..."
    log_info "Tag: $tag"
    log_info "Imagem: $image_uri"
    
    # Criar nova task definition
    local new_td_arn=$(create_task_definition $image_uri $tag)
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --task-definition $new_td_arn"
        return
    fi
    
    # Atualizar serviço
    log_info "Atualizando serviço ECS..."
    aws ecs update-service \
        --cluster $ECS_CLUSTER \
        --service $ECS_SERVICE \
        --task-definition $new_td_arn \
        --region $AWS_REGION \
        --query 'service.serviceName' \
        --output text
    
    log_success "Deploy iniciado com sucesso!"
    log_info "Aguardando estabilização do serviço..."
    
    # Aguardar estabilização
    aws ecs wait services-stable \
        --cluster $ECS_CLUSTER \
        --services $ECS_SERVICE \
        --region $AWS_REGION
    
    log_success "Deploy concluído com sucesso!"
    log_success "Serviço estabilizado com a nova versão"
    
    # Salvar informações do deploy
    echo "$tag|$(date)|$new_td_arn" >> .deploy_history
}

# Função para listar imagens
list_images() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Listaria imagens do ECR"
        return
    fi
    
    log_info "Listando últimas 10 imagens do ECR..."
    
    aws ecr describe-images \
        --repository-name $ECR_REPOSITORY \
        --region $AWS_REGION \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' \
        --output table
}

# Função para rollback
rollback_service() {
    local target_tag=$1
    
    if [ -z "$target_tag" ]; then
        log_error "Tag para rollback não especificada"
        log_info "Use: ./deploy.sh rollback -t <commit_hash>"
        log_info "Ou veja as tags disponíveis: ./deploy.sh list"
        exit 1
    fi
    
    log_warning "Iniciando rollback para tag: $target_tag"
    read -p "Tem certeza que deseja continuar? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Rollback cancelado"
        exit 0
    fi
    
    deploy_service $target_tag
    log_success "Rollback concluído para tag: $target_tag"
}

# Parse dos argumentos
COMMAND=""
DRY_RUN=false
TARGET_TAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        build|deploy|rollback|list|help)
            COMMAND=$1
            shift
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -c|--cluster)
            ECS_CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            ECS_SERVICE="$2"
            shift 2
            ;;
        -t|--tag)
            TARGET_TAG="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            log_error "Opção desconhecida: $1"
            show_help
            exit 1
            ;;
    esac
done

# Verificar se comando foi especificado
if [ -z "$COMMAND" ]; then
    log_error "Nenhum comando especificado"
    show_help
    exit 1
fi

# Executar comando
case $COMMAND in
    help)
        show_help
        ;;
    build)
        build_image
        ;;
    deploy)
        deploy_service
        ;;
    rollback)
        rollback_service $TARGET_TAG
        ;;
    list)
        list_images
        ;;
    *)
        log_error "Comando inválido: $COMMAND"
        show_help
        exit 1
        ;;
esac
