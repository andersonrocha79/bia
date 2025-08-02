#!/bin/bash

# Script de Deploy para ECS com Versionamento por Commit Hash
# Autor: Amazon Q
# Versão: 1.0

set -e

# Configurações padrão
DEFAULT_REGION="us-east-1"
DEFAULT_CLUSTER="cluster-bia-01082025"
DEFAULT_SERVICE="service-bia-01082025"
DEFAULT_TASK_FAMILY="task-def-bia-01082025"
DEFAULT_ECR_REPO="216665870449.dkr.ecr.us-east-1.amazonaws.com/bia"
DEFAULT_CONTAINER_NAME="bia-app"

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
🚀 Script de Deploy ECS com Versionamento por Commit Hash

USO:
    $0 [OPÇÕES] COMANDO

COMANDOS:
    deploy          Executa o deploy completo (build + push + update)
    build           Apenas faz o build da imagem
    push            Apenas faz o push da imagem (requer build anterior)
    update          Apenas atualiza o serviço ECS
    rollback        Faz rollback para uma versão anterior
    list            Lista as últimas versões disponíveis
    help            Exibe esta ajuda

OPÇÕES:
    -r, --region REGION         Região AWS (padrão: $DEFAULT_REGION)
    -c, --cluster CLUSTER       Nome do cluster ECS (padrão: $DEFAULT_CLUSTER)
    -s, --service SERVICE       Nome do serviço ECS (padrão: $DEFAULT_SERVICE)
    -t, --task-family FAMILY    Família da task definition (padrão: $DEFAULT_TASK_FAMILY)
    -e, --ecr-repo REPO         Repositório ECR (padrão: $DEFAULT_ECR_REPO)
    -n, --container-name NAME   Nome do container (padrão: $DEFAULT_CONTAINER_NAME)
    -v, --version VERSION       Versão específica para rollback (formato: commit-hash)
    -h, --help                  Exibe esta ajuda

EXEMPLOS:
    # Deploy completo
    $0 deploy

    # Deploy com configurações customizadas
    $0 --cluster meu-cluster --service meu-service deploy

    # Apenas build da imagem
    $0 build

    # Rollback para versão específica
    $0 rollback --version abc1234

    # Listar versões disponíveis
    $0 list

FUNCIONALIDADES:
    ✅ Versionamento automático por commit hash
    ✅ Criação de nova task definition para cada deploy
    ✅ Rollback para versões anteriores
    ✅ Listagem de versões disponíveis
    ✅ Build otimizado com cache
    ✅ Validação de pré-requisitos

PRÉ-REQUISITOS:
    - Docker instalado e configurado
    - AWS CLI configurado com permissões adequadas
    - Git repository inicializado
    - Repositório ECR existente

EOF
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
    
    # Verificar se há mudanças não commitadas
    if [[ -n $(git status --porcelain) ]]; then
        log_warning "Há mudanças não commitadas no repositório"
        read -p "Deseja continuar mesmo assim? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deploy cancelado pelo usuário"
            exit 0
        fi
    fi
    
    log_success "Pré-requisitos validados"
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

# Função para fazer build da imagem
build_image() {
    local commit_hash=$(get_commit_hash)
    local image_tag="$ECR_REPO:$commit_hash"
    
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
    
    local image_tag="$ECR_REPO:$commit_hash"
    
    log_info "Fazendo push da imagem: $image_tag"
    
    # Login no ECR
    log_info "Fazendo login no ECR..."
    aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_REPO"
    
    # Push da imagem
    log_info "Enviando imagem para ECR..."
    docker push "$image_tag"
    
    log_success "Push concluído: $image_tag"
}

# Função para criar nova task definition
create_task_definition() {
    local commit_hash="$1"
    local image_tag="$ECR_REPO:$commit_hash"
    
    log_info "Criando nova task definition..."
    
    # Obter task definition atual
    local current_task_def=$(aws ecs describe-task-definition \
        --task-definition "$TASK_FAMILY" \
        --region "$REGION" \
        --query 'taskDefinition' \
        --output json)
    
    # Criar nova task definition com a nova imagem
    local new_task_def=$(echo "$current_task_def" | jq --arg image "$image_tag" --arg version "$commit_hash" '
        .containerDefinitions[0].image = $image |
        if .containerDefinitions[0].environment then
            .containerDefinitions[0].environment |= map(select(.name != "DEPLOY_VERSION")) + [{"name": "DEPLOY_VERSION", "value": $version}]
        else
            .containerDefinitions[0].environment = [{"name": "DEPLOY_VERSION", "value": $version}]
        end |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ')
    
    # Salvar em arquivo temporário para debug
    echo "$new_task_def" > /tmp/new_task_def.json
    
    # Registrar nova task definition
    local new_task_arn=$(aws ecs register-task-definition \
        --region "$REGION" \
        --cli-input-json file:///tmp/new_task_def.json \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)
    
    # Limpar arquivo temporário
    rm -f /tmp/new_task_def.json
    
    log_success "Nova task definition criada: $new_task_arn"
    echo "$new_task_arn"
}

# Função para atualizar serviço ECS
update_service() {
    local task_definition_arn="$1"
    
    log_info "Atualizando serviço ECS..."
    
    aws ecs update-service \
        --cluster "$CLUSTER" \
        --service "$SERVICE" \
        --task-definition "$task_definition_arn" \
        --region "$REGION" \
        --query 'service.{serviceName:serviceName,taskDefinition:taskDefinition,desiredCount:desiredCount,runningCount:runningCount}' \
        --output table
    
    log_info "Aguardando estabilização do serviço..."
    aws ecs wait services-stable \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$REGION"
    
    log_success "Serviço atualizado com sucesso!"
}

# Função para listar versões disponíveis
list_versions() {
    log_info "Listando versões disponíveis no ECR..."
    
    aws ecr describe-images \
        --repository-name "bia" \
        --region "$REGION" \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt,imageSizeInBytes]' \
        --output table
}

# Função para fazer rollback
rollback_version() {
    local target_version="$1"
    
    if [[ -z "$target_version" ]]; then
        log_error "Versão não especificada para rollback"
        echo "Use: $0 rollback --version <commit-hash>"
        exit 1
    fi
    
    log_info "Iniciando rollback para versão: $target_version"
    
    # Verificar se a imagem existe no ECR
    local image_exists=$(aws ecr describe-images \
        --repository-name "bia" \
        --image-ids imageTag="$target_version" \
        --region "$REGION" \
        --query 'imageDetails[0].imageTags[0]' \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$image_exists" == "None" ]]; then
        log_error "Versão $target_version não encontrada no ECR"
        exit 1
    fi
    
    # Criar nova task definition com a versão anterior
    local new_task_arn=$(create_task_definition "$target_version")
    
    # Atualizar serviço
    update_service "$new_task_arn"
    
    log_success "Rollback concluído para versão: $target_version"
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
    
    # Criar nova task definition
    local new_task_arn=$(create_task_definition "$commit_hash")
    
    # Atualizar serviço
    update_service "$new_task_arn"
    
    log_success "🎉 Deploy concluído com sucesso!"
    log_info "Versão deployada: $commit_hash"
}

# Parsing de argumentos
REGION="$DEFAULT_REGION"
CLUSTER="$DEFAULT_CLUSTER"
SERVICE="$DEFAULT_SERVICE"
TASK_FAMILY="$DEFAULT_TASK_FAMILY"
ECR_REPO="$DEFAULT_ECR_REPO"
CONTAINER_NAME="$DEFAULT_CONTAINER_NAME"
VERSION=""
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -t|--task-family)
            TASK_FAMILY="$2"
            shift 2
            ;;
        -e|--ecr-repo)
            ECR_REPO="$2"
            shift 2
            ;;
        -n|--container-name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        deploy|build|push|update|rollback|list|help)
            COMMAND="$1"
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
if [[ -z "$COMMAND" ]]; then
    log_error "Comando não especificado"
    show_help
    exit 1
fi

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
        if [[ -f .last_build_version ]]; then
            commit_hash=$(cat .last_build_version)
            new_task_arn=$(create_task_definition "$commit_hash")
            update_service "$new_task_arn"
        else
            log_error "Nenhuma versão encontrada. Execute 'build' primeiro."
            exit 1
        fi
        ;;
    rollback)
        rollback_version "$VERSION"
        ;;
    list)
        list_versions
        ;;
    help)
        show_help
        ;;
    *)
        log_error "Comando desconhecido: $COMMAND"
        show_help
        exit 1
        ;;
esac
