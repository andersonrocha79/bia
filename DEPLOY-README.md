# 🚀 Script de Deploy ECS - Guia de Uso

Este script automatiza o processo de deploy da aplicação BIA no Amazon ECS com versionamento por commit hash, permitindo rollbacks fáceis e rastreabilidade completa.

## 📋 Pré-requisitos

- ✅ Docker instalado e configurado
- ✅ AWS CLI configurado com permissões adequadas
- ✅ Git repository inicializado
- ✅ Repositório ECR existente
- ✅ Cluster ECS e Service configurados

## 🎯 Funcionalidades Principais

### ✨ Versionamento Automático
- Cada build recebe uma tag baseada no hash do commit atual (7 caracteres)
- Exemplo: `216665870449.dkr.ecr.us-east-1.amazonaws.com/bia:9891703`

### 🔄 Task Definition Versionada
- Nova task definition criada para cada deploy
- Permite rollback para qualquer versão anterior
- Rastreabilidade completa de deployments

### 🛡️ Validações de Segurança
- Verifica se está em um repositório Git
- Alerta sobre mudanças não commitadas
- Valida pré-requisitos antes do deploy

## 📖 Comandos Disponíveis

### Deploy Completo
```bash
./deploy-ecs.sh deploy
```
Executa: build → push → create task definition → update service

### Build Apenas
```bash
./deploy-ecs.sh build
```
Faz apenas o build da imagem com tag do commit atual

### Push Apenas
```bash
./deploy-ecs.sh push
```
Envia a última imagem buildada para o ECR

### Atualizar Serviço
```bash
./deploy-ecs.sh update
```
Atualiza o serviço ECS com a última versão buildada

### Listar Versões
```bash
./deploy-ecs.sh list
```
Lista as 10 versões mais recentes disponíveis no ECR

### Rollback
```bash
./deploy-ecs.sh rollback --version abc1234
```
Faz rollback para uma versão específica

## ⚙️ Configurações Personalizadas

### Exemplo com Configurações Customizadas
```bash
./deploy-ecs.sh \
  --cluster meu-cluster \
  --service meu-service \
  --region us-west-2 \
  deploy
```

### Variáveis de Ambiente Suportadas
```bash
# Configurações padrão (podem ser sobrescritas via parâmetros)
DEFAULT_REGION="us-east-1"
DEFAULT_CLUSTER="cluster-bia-01082025"
DEFAULT_SERVICE="service-bia-01082025"
DEFAULT_TASK_FAMILY="task-def-bia-01082025"
DEFAULT_ECR_REPO="216665870449.dkr.ecr.us-east-1.amazonaws.com/bia"
DEFAULT_CONTAINER_NAME="bia-app"
```

## 🔧 Exemplos Práticos

### 1. Deploy de Desenvolvimento
```bash
# Fazer alterações no código
git add .
git commit -m "Implementar nova funcionalidade"

# Deploy completo
./deploy-ecs.sh deploy
```

### 2. Rollback de Emergência
```bash
# Listar versões disponíveis
./deploy-ecs.sh list

# Fazer rollback para versão anterior
./deploy-ecs.sh rollback --version 1a2b3c4
```

### 3. Deploy em Ambiente Diferente
```bash
./deploy-ecs.sh \
  --cluster cluster-producao \
  --service service-producao \
  --region us-west-2 \
  deploy
```

## 📊 Fluxo de Versionamento

```
Commit Hash: 9891703
     ↓
Docker Tag: bia:9891703
     ↓
ECR Image: 216665870449.dkr.ecr.us-east-1.amazonaws.com/bia:9891703
     ↓
Task Definition: task-def-bia-01082025:15
     ↓
ECS Service Update
```

## 🚨 Tratamento de Erros

### Mudanças Não Commitadas
```
[WARNING] Há mudanças não commitadas no repositório
Deseja continuar mesmo assim? (y/N):
```

### Versão Não Encontrada (Rollback)
```
[ERROR] Versão abc1234 não encontrada no ECR
```

### Pré-requisitos Não Atendidos
```
[ERROR] Docker não está instalado
[ERROR] Este diretório não é um repositório Git
```

## 📈 Monitoramento

### Logs Coloridos
- 🔵 **INFO**: Informações gerais
- 🟢 **SUCCESS**: Operações bem-sucedidas
- 🟡 **WARNING**: Avisos importantes
- 🔴 **ERROR**: Erros que impedem a execução

### Rastreabilidade
Cada deploy inclui:
- Hash do commit
- Mensagem do commit
- Autor do commit
- Data/hora do commit
- Versão da task definition

## 🔒 Segurança

### Permissões IAM Necessárias
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:PutImage",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload",
                "ecr:DescribeImages"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ecs:DescribeTaskDefinition",
                "ecs:RegisterTaskDefinition",
                "ecs:UpdateService",
                "ecs:DescribeServices"
            ],
            "Resource": "*"
        }
    ]
}
```

## 🆘 Troubleshooting

### Problema: Build Falha
```bash
# Verificar logs do Docker
docker logs <container-id>

# Limpar cache do Docker
docker system prune -f
```

### Problema: Push Falha
```bash
# Verificar login no ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 216665870449.dkr.ecr.us-east-1.amazonaws.com
```

### Problema: Service Não Atualiza
```bash
# Verificar eventos do serviço
aws ecs describe-services --cluster cluster-bia-01082025 --services service-bia-01082025 --query 'services[0].events'
```

## 📞 Suporte

Para problemas ou dúvidas:
1. Verificar logs coloridos do script
2. Consultar este README
3. Verificar permissões IAM
4. Validar configurações do ECS/ECR

---

**Criado por:** Amazon Q  
**Versão:** 1.0  
**Última atualização:** 2025-08-02
