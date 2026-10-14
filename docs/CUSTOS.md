# Custos do lab

Estimativa do custo por hora e por dia com os padrões do lab em us-east-1, para decidir antes de
subir qualquer coisa. São **preços de tabela de referência (verificado em 2026-10-10)**: confira nas
páginas oficiais de preço da AWS antes de cada rodada; impostos e transferência de dados não entram.

## Estimativa por componente (padrões, us-east-1)

| Componente | Quantidade | Preço de referência | US$/hora | US$/dia |
|---|---|---|---|---|
| EKS, plano de controle (suporte padrão) | 1 cluster | US$0,10/h | 0,100 | 2,40 |
| EKS em suporte estendido (evitado por `upgrade_policy = STANDARD`) | — | US$0,60/h | (0,600) | (14,40) |
| Nós t3.medium / t3a.medium em SPOT | 2 | on-demand US$0,0416/h e US$0,0376/h; Spot varia por AZ e hora (estimativa: ~35 % do on-demand) | ~0,030 | ~0,72 |
| Os mesmos nós em ON_DEMAND (opcional) | 2 | US$0,0416/h | (0,083) | (2,00) |
| EBS gp3 dos nós | 2 × 20 GB | US$0,08/GB-mês | 0,004 | 0,11 |
| NAT gateway | 1 | US$0,045/h + US$0,045/GB processado | 0,045 | 1,08 + dados |
| IPv4 público | 3 (EIP do NAT, 2 do ALB) | US$0,005/h por IP | 0,015 | 0,36 |
| Application Load Balancer | 1 | US$0,0225/h + LCU (US$0,008/LCU-h) | ~0,030 | ~0,73 |
| RDS PostgreSQL db.t4g.micro, single-AZ | 1 | US$0,016/h | 0,016 | 0,38 |
| Armazenamento RDS gp3 | 20 GB | US$0,115/GB-mês | 0,003 | 0,08 |
| WAF | 1 web ACL + 5 regras | US$5/mês + US$1/regra-mês + US$0,60/milhão de requisições | 0,014 | 0,33 |
| KMS | 1 chave | US$1/mês + requisições | 0,001 | 0,03 |
| Secrets Manager | 2 segredos | US$0,40/segredo-mês + chamadas | 0,001 | 0,03 |
| CloudWatch Logs (EKS control plane, flow logs, RDS, WAF) | volume baixo | US$0,50/GB ingerido + US$0,03/GB-mês | ~0,005 | ~0,05–0,25 |
| X-Ray (traces do app pelo OpenTelemetry Collector) | volume do lab | 100.000 traces gravados por mês sem custo; depois US$5 por milhão ([preços do X-Ray](https://aws.amazon.com/xray/pricing/), verificado em 2026-10-14) | ~0 | ~0 |
| ECR, SSM (Standard), S3 do state, budget sem actions | — | centavos por mês ou sem custo | ~0 | ~0 |
| **Total com SPOT (padrão)** | | | **~0,26** | **~6,3–6,5** |
| **Total com ON_DEMAND** | | | **~0,32** | **~7,6–7,8** |

Leituras rápidas:

- Uma rodada de 3 horas (apply → testes → destroy) custa cerca de US$0,80–1,00.
- Esquecido ligado, o lab passa de US$40 por semana; o budget padrão (US$25/mês) alerta em 50 %,
  80 % e 100 % do valor real e quando a previsão passar de 100 %.
- O plano de controle do EKS e o NAT gateway são ~55 % do custo; os nós SPOT, ~10 %.

## Cenários do v1 (março de 2026)

Do `ENVIRONMENT_AUDIT_2026-03-17` do v1, para comparação (o v1 não contava IPv4 público):

| Cenário do v1 | US$/dia | Dias com US$68,25 de crédito |
|---|---|---|
| STG com EKS (4× t3.small, 2 NAT, RDS, ALB, WAF) | ~7,82 | ~8,7 |
| STG sem EKS (2× EC2 t3.micro) | ~3,66 | ~18,6 |
| STG sem EKS + 1 NAT | ~2,50 | ~27,3 |
| STG sem EKS e sem NAT | ~1,34 | ~50,9 |

Detalhe do cenário com EKS no v1: EKS US$2,40; 4× t3.small US$2,00; 2× NAT US$2,16; RDS US$0,38;
ALB US$0,55; WAF US$0,23; ECR/S3/CloudWatch/Secrets Manager ~US$0,10 por dia. O v2 troca os 2 NATs
fixos por 1 e nós on-demand por SPOT, e ainda inclui KMS, WAF com 5 regras e IPv4 público.

## Dicas

- Destrua no mesmo dia e rode `scripts/leftovers.sh` até não haver nada `BILLABLE`.
- Mantenha `node_capacity_type = "SPOT"` e `nat_gateway_per_az = false`; RDS single-AZ.
- Não troque `upgrade_policy` para EXTENDED: o plano de controle passa a US$0,60/h.
- Load balancers criados pelo controller custam enquanto existirem: o destroy só roda depois do
  `platform/uninstall.sh`, que espera o ALB sumir.
- A chave KMS fica `PendingDeletion` por 7 dias depois do destroy; consulte a página de preços do KMS.
- Créditos promocionais escondem a fatura: o budget exclui créditos e reembolsos de propósito.
- Logs com retenção de 7 dias; o log de auditoria do EKS é o maior volume — desligue a rodada cedo.
