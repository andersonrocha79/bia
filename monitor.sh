#!/bin/bash
echo "=== Status dos Containers ==="
docker compose ps

echo -e "\n=== Teste de Conectividade RDS ==="
timeout 5 bash -c "</dev/tcp/bia.c8hyoi6ky3ub.us-east-1.rds.amazonaws.com/5432" && echo "✅ RDS OK" || echo "❌ RDS Falhou"

echo -e "\n=== Teste da API ==="
curl -s http://localhost:3001/api/versao && echo -e "\n✅ API OK" || echo "❌ API Falhou"

echo -e "\n=== Teste do Banco ==="
curl -s http://localhost:3001/api/tarefas | jq length && echo "✅ Banco OK" || echo "❌ Banco Falhou"
