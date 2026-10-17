# Lições aprendidas do lab AWS v1 (nov/2025 – mar/2026)

> A tabela de decisões e as lições preservam o estado inicial de cada rodada. O escopo
> atual de HA/backup/PITR/DR está em [CONTINUIDADE.md](CONTINUIDADE.md), e capacidade,
> OpenCost/VPA/Spot e estimativa em [FINOPS.md](FINOPS.md). Decisões antigas marcadas
> como fora de escopo não revogam as construções posteriores R7–R10.

Este documento destila as anotações de campo do lab v1 (`maringelix/tx01`: Terraform com VPC, EKS, RDS, EC2, ALB, WAF e ECR; GitHub Actions; Prometheus/Grafana; OPA Gatekeeper; AWS Backup), executado com créditos do AWS Free Tier entre novembro/2025 e março/2026.
O objetivo é que quem for reproduzir o lab gaste menos crédito, não repita os mesmos erros e saiba o que conferir antes de copiar um comando.

O v2 (`tx01v2`) foi redesenhado a partir destas lições: EKS Pod Identity em vez de IRSA; acesso ao cluster por access entries, sem o ConfigMap `aws-auth`; senha do banco como argumento write-only, fora do plan e do state; um único NAT Gateway e nodes SPOT; AWS Budgets desde o bootstrap; destroy seguido de verificação de recursos remanescentes; e um harness/CI que valida tudo sem credenciais de nuvem.

## Como ler

- Cada lição segue **Sintoma → Causa → Correção → Recomendação**. "Correção" é o que foi feito no v1 ("nenhuma" quando ficou pendente); "Recomendação" é o que vale em out/2026 e orienta o v2.
- [versão: ...] marca o que depende de versão. Confira a documentação oficial antes de copiar.
- Identificadores reais viraram marcadores: `<ACCOUNT_ID>`, `<STATE_BUCKET>`, `<IAM_USER>`, `<CLUSTER>`, `<INSTANCE_ID>`, `<RDS_SG_ID>` etc.
- O que perdeu validade foi cortado ou aparece só como alerta (números de versão de dez/2025, ingress-nginx, Promtail).

## 1. Custos e créditos

### 1.1 O "Free Tier" não cobria o que as anotações supunham

- **Sintoma:** as anotações estimavam "6× t3.micro = US$ 0/mês" e "750 h/mês bastam para ~6 instâncias 24/7", enquanto os créditos acabavam. Em 17/03/2026 restavam US$ 68,25, com o plano Free expirando em 26/05/2026.
- **Causa:** 750 h/mês cobrem uma instância ligada o mês todo (um mês tem ~730 h), não seis. Além disso, contas criadas a partir de 15/07/2025 usam o Free Tier baseado em créditos (US$ 100 na criação + até US$ 100 por atividades; o plano Free termina em 6 meses ou quando o crédito acaba), sem as 750 h/mês de EC2 do modelo antigo. A conta do lab estava nesse modelo. Control plane do EKS, NAT Gateway, ALB, WAF e IPv4 público nunca foram gratuitos.
- **Correção:** a auditoria de março/2026 montou um modelo de custo por hora (1.4) e mostrou que, com EKS ligado, o saldo duraria ~8,7 dias.
- **Recomendação:** confirme no console de Billing qual modelo de Free Tier vale para a conta e planeje em US$/hora multiplicado pelas horas em que o lab fica de pé.

### 1.2 Créditos escondem o gasto

- **Sintoma:** "gasto desde nov/2025 ≈ US$ 0 líquido". A fatura zerada não mostrava o ritmo de consumo; só a consulta ao saldo revelou o problema. O v1 não tinha budget.
- **Causa:** a fatura e os budgets enxergam, por padrão, o custo já descontado dos créditos. No AWS Budgets o tipo de custo "créditos" vem incluído (`include_credit = true` no Terraform), então um budget comum não dispara enquanto houver crédito.
- **Correção:** nenhuma; o saldo era conferido à mão.
- **Recomendação:** crie o budget antes do primeiro cluster (o v2 faz isso no bootstrap) e, em conta com créditos, use `cost_types { include_credit = false }`, com alertas em 50/80/100 % do real e 100 % do previsto. No Cost Explorer, filtre `RECORD_TYPE = Usage` para ver o consumo bruto. A API do Cost Explorer cobra US$ 0,01 por requisição: nada de `aws ce get-cost-and-usage` em loop.

### 1.3 Estimativas divergentes e as alavancas que pesaram

- **Sintoma:** cada documento trazia um total diferente para variações do mesmo ambiente: US$ 88, 133, 138, 183 e 202 por mês.
- **Causa:** estimativas mensais feitas à mão, com premissas diferentes (Free Tier, número de NAT, ALB extra) e sem uma tabela de preços única.
- **Correção:** a auditoria de 17/03/2026 consolidou tudo em US$/dia por componente.
- **Recomendação:** mantenha uma única tabela de preço/hora versionada no repositório. O que mais pesou no v1:
  - 2 NAT Gateways fixos no código (um por AZ): US$ 2,16/dia, ~28 % do total. Para lab, um basta.
  - ALB duplicado, um do Terraform e outro do Ingress (4.2).
  - Escalar pods para zero não economiza: cobram nodes, control plane, NAT e ALB. Economia real é `terraform destroy` no fim da sessão.
  - EC2 parada continua pagando EBS (e Elastic IP associado).
  - Cluster fora do suporte padrão custa 6× mais no control plane (3.7).

### 1.4 Modelo de custo de referência

Preços de referência de março/2026 em us-east-1 — confira a página oficial. Ambiente STG da auditoria de 17/03/2026, com os tfvars da época:

| Componente | Preço de referência | US$/dia |
|---|---|---|
| EKS control plane (suporte padrão) | US$ 0,10/h | 2,40 |
| 4× t3.small on-demand (nodes) | US$ 0,0208/h cada | 2,00 |
| 2× NAT Gateway | US$ 0,045/h cada | 2,16 |
| RDS db.t4g.micro, single-AZ, 20 GB | US$ 0,016/h | 0,38 |
| ALB | ~US$ 0,023/h (+ LCU) | 0,55 |
| WAF (Web ACL + 2 regras) | ~US$ 7/mês | 0,23 |
| ECR, S3, CloudWatch, Secrets Manager | variável | ~0,10 |
| Total da auditoria | | ~7,82 |

Fora da tabela da auditoria, e relevante:

- Todo endereço IPv4 público é cobrado (US$ 0,005/h, ~US$ 0,12/dia, ~US$ 3,65/mês por IP), inclusive os Elastic IPs dos NAT e os IPs que o ALB mantém em cada AZ. No STG acima, 2 EIPs + 2 IPs do ALB somam ~US$ 0,48/dia.
- O control plane do EKS custa US$ 0,10/h em suporte padrão e US$ 0,60/h em suporte estendido. No estendido, o mesmo ambiente sobe para ~US$ 19,82/dia.
- NAT cobra também US$ 0,045 por GB processado; pull de imagens grandes passando pela NAT aparece na conta.

Cenários com os US$ 68,25 que restavam (a linha de suporte estendido é cálculo deste documento; as demais são da auditoria):

| Cenário | US$/dia | Dias de crédito |
|---|---|---|
| STG com EKS (tfvars da época) | ~7,82 | ~8,7 |
| STG com EKS em suporte estendido | ~19,82 | ~3,4 |
| STG sem EKS (2× EC2 t3.micro) | ~3,66 | ~18,6 |
| Sem EKS + 1 NAT | ~2,50 | ~27,3 |
| Sem EKS e sem NAT | ~1,34 | ~50,9 |

Leitura prática: o ambiente completo custava ~US$ 0,33/h. Uma sessão de estudo de 4 h sai por ~US$ 1,30 se o destroy rodar no fim; esquecido ligado, o mesmo ambiente consome ~US$ 235 em 30 dias.

## 2. Terraform, state e bootstrap

### 2.1 Backend inexistente na primeira execução

- **Sintoma:** `terraform init` falhava na primeira execução e depois de cada limpeza completa da conta ("S3 backend not found", "Backend initialization required").
- **Causa:** bucket de state e tabela de lock precisam existir antes do `init`. O nome `<STATE_BUCKET>` estava fixo no código e nos workflows; nome de bucket é global, então um fork público colide com o original.
- **Correção:** workflow `terraform-bootstrap.yml` com state local, executado antes de tudo; os scripts de limpeza preservavam bucket e tabela.
- **Recomendação:** bootstrap como raiz separada, fora do fluxo de destroy. Backend por configuração parcial (`terraform init -backend-config=backend.hcl`), com nome derivado de `<ACCOUNT_ID>` e da região, nada fixo no repositório. Lock nativo do S3 (`use_lockfile = true`) no lugar do DynamoDB [versão: GA no Terraform 1.11, que deprecia `dynamodb_table`].

### 2.2 `force_destroy` no bucket e o conselho de apagar o state

- **Sintoma:** o bootstrap criava o bucket com `force_destroy = true` "para facilitar testes", e o troubleshooting do v1 mandava, diante de state corrompido, apagar `.terraform` e `terraform.tfstate*` e recriar a infraestrutura.
- **Causa:** conveniência de lab aplicada ao recurso mais crítico. Apagar o state faz o Terraform esquecer recursos que continuam existindo e cobrando.
- **Correção:** o state foi para S3 com versionamento; o conselho ficou só no documento.
- **Recomendação:** `force_destroy = false`, versionamento e lifecycle para versões antigas. State quebrado se recupera restaurando uma versão anterior do objeto no S3; recurso que saiu do state volta com `import`, nunca com destroy + apply.

### 2.3 Lock preso

- **Sintoma:** state travado ("Error acquiring the state lock"), tipicamente depois de um job cancelado no meio do apply.
- **Causa:** o processo morreu sem liberar o lock.
- **Correção:** `terraform force-unlock <LOCK_ID>`.
- **Recomendação:** `force-unlock` só depois de confirmar que não há outro apply rodando. Nos workflows, `concurrency:` por ambiente impede dois applies simultâneos.

### 2.4 Flags `enable_*`, `count` e código que contradiz o comentário

- **Sintoma:** endereços como `module.infrastructure.aws_eks_addon.ebs_csi_driver[0]`, toggles `enable_eks` e `instance_count = 0`, e workflows separados para ligar e desligar partes (`manage-environment`, `switch-environment`, `eks-deploy` com `provision`/`destroy`). No launch template dos nodes, o comentário dizia que o hop limit do IMDS impedia os pods de alcançar o metadata, mas o valor era `2`, que permite.
- **Causa:** um root module por ambiente com tudo dentro. Cada flag multiplicou caminhos pouco testados, e nada verificava se o código fazia o que o comentário afirmava.
- **Correção:** workflows dedicados para cada modo.
- **Recomendação:** poucas variações, cada uma coberta por teste. Para lab, o ciclo mais barato e previsível é apply completo → estudo → destroy completo. Propriedades de segurança viram asserções em `terraform test` (no v2: IMDSv2 obrigatório e hop limit 1), não comentários.

### 2.5 Provider Kubernetes no mesmo Terraform do cluster

- **Sintoma:** o `aws-auth` era gerenciado por `kubernetes_config_map_v1_data`, com o provider Kubernetes configurado a partir do próprio `aws_eks_cluster` (`host = var.enable_eks ? <endpoint> : ""`), mapeando `<IAM_USER>` para `system:masters`.
- **Causa:** provider que depende de um recurso criado no mesmo apply é frágil no primeiro apply, no destroy e quando a flag desliga o cluster; e `system:masters` é um grupo de superusuário que nenhuma regra de RBAC consegue restringir.
- **Correção:** nenhuma no v1.
- **Recomendação:** nada de providers kubernetes/helm no Terraform da infraestrutura (como no v2). Acesso ao cluster por access entries do EKS (`authentication_mode = "API"`, `aws_eks_access_entry` + associação de access policy), e o que roda dentro do cluster é instalado por script ou workflow depois do apply.

## 3. EKS: nodes, add-ons, armazenamento e upgrades

### 3.1 t3.micro não serve como node de EKS

- **Sintoma:** pods `Pending` com "Too many pods". Foram precisos 7–8 nodes t3.micro (ASG com desired 8 e max 15) para caber sistema, aplicação e uma observabilidade mínima.
- **Causa:** o limite de pods vem das ENIs/IPs da VPC CNI: `ENIs × (IPs por ENI − 1) + 2`. Dá 4 pods no t3.micro, 11 no t3.small, 17 no t3.medium e 35 no t3.large. `aws-node` e `kube-proxy` já ocupam 2 dos 4; com `ebs-csi-node`, sobra 1. E 1 GiB de RAM, descontadas as reservas, deixa ~600 MiB. As próprias anotações se contradiziam (um documento falava em ~11 pods por t3.micro).
- **Correção:** réplica única para CoreDNS, Load Balancer Controller e `ebs-csi-controller` (`kubectl scale deployment -n kube-system <NOME> --replicas=1`), checagem de capacidade (`READY_NODES × 4`) antes do deploy e, por fim, troca para t3.small.
- **Recomendação:** t3.small é o mínimo prático; t3.medium dá folga para observabilidade (o v2 usa t3.medium/t3a.medium). Prefix delegation na VPC CNI sobe o limite de IPs, mas em instância pequena a memória continua sendo o gargalo.

### 3.2 SPOT e quotas de vCPU

- **Sintoma:** o node group era `ON_DEMAND` com o comentário "or SPOT to save costs", e o troubleshooting do v1 já previa "Quota Exceeded" ao subir instâncias.
- **Causa:** SPOT nunca foi ativado; e contas novas têm quotas baixas de vCPU, separadas para on-demand e spot.
- **Correção:** nenhuma.
- **Recomendação:** SPOT com 2–3 tipos equivalentes no node group; a AWS pode retomar a instância com aviso de 2 minutos, e com 2 nodes o lab sobrevive. Antes do primeiro apply, confira as quotas `L-1216C47A` (on-demand padrão) e `L-34B43A08` (spot padrão) com `aws service-quotas get-service-quota --service-code ec2 --quota-code <CODIGO>`.

### 3.3 Node que sobe e não entra no cluster

- **Sintoma:** 8 instâncias `running`, com status checks OK, mas `kubectl get nodes` listava 7; `aws ssm send-command` respondia `InvalidInstanceId`.
- **Causa:** o bootstrap do node falhou (o kubelet não registrou) e o SSM Agent não estava acessível, então não havia como olhar por dentro.
- **Correção:** cruzar IPs entre EC2 e Kubernetes, terminar a instância órfã e deixar o ASG criar outra, que entrou normalmente (comandos abaixo).
- **Recomendação:** em node group gerenciado, substituir sai mais barato que depurar. Para poder depurar, anexe `AmazonSSMManagedInstanceCore` à role dos nodes e use Session Manager em vez de SSH. Não coloque security group próprio no launch template (o código final do v1 fazia isso): o EKS deixa de anexar o SG do cluster aos nodes, que podem não conseguir entrar. E não combine launch template com `disk_size` no node group (o código final do v1 também fazia): a criação do node group falha; o disco vai no launch template.

```bash
aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=<CLUSTER>" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,LaunchTime]' --output table
kubectl get nodes -o wide
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>
```

### 3.4 Capacidade decidida dentro do workflow

- **Sintoma:** o workflow de observabilidade escalava o node group (até 12 nodes) e esperava os nodes entrarem; resultado: timeouts e deploys falhos.
- **Causa:** provisionar capacidade e instalar software no mesmo job, sem previsibilidade do tempo de join.
- **Correção:** auto-scaling removido do workflow e trocado por validação estrita (exige 3 slots livres), com mensagem dizendo o que ajustar.
- **Recomendação:** capacidade se define no Terraform; workflow só valida e falha cedo.

### 3.5 EBS CSI Driver criado à mão

- **Sintoma:** os PVCs do Prometheus e do Grafana dependiam do driver EBS CSI, instalado manualmente. O state divergia da conta e `prd` não teria o driver.
- **Causa:** add-on, role IAM com trust OIDC (IRSA), attachment da `AmazonEBSCSIDriverPolicy` e provider OIDC criados fora do código. Depois, o workflow de observabilidade ganhou um passo "cria o add-on se não existir": dois donos para o mesmo recurso.
- **Correção:** workflow de import dos quatro recursos (`aws_iam_openid_connect_provider`, `aws_iam_role`, `aws_iam_role_policy_attachment`, `aws_eks_addon`), validado com `terraform plan` → "No changes" e `terraform state list | grep -E "ebs_csi|oidc"`.
- **Recomendação:** se o lab precisar de volumes, o add-on entra no Terraform desde o primeiro apply, com credencial por EKS Pod Identity (add-on `eks-pod-identity-agent` + `aws_eks_pod_identity_association` para `kube-system/ebs-csi-controller-sa`): sem provider OIDC por cluster e sem trust policy presa à URL do emissor. Para adotar algo criado à mão, blocos `import {}` revisáveis no plan [versão: Terraform ≥ 1.5]. Crie uma StorageClass gp3 marcada como default: em clusters novos a gp2 não vem mais como default, e PVC sem `storageClassName` fica `Pending` [versão: EKS ≥ 1.30].

### 3.6 Versões de add-ons fixadas à mão

- **Sintoma:** tfvars com `v1.19.0-eksbuild.1` (VPC CNI), `v1.32.0-eksbuild.2` (kube-proxy), `v1.11.3-eksbuild.2` (CoreDNS) e `v1.53.0-eksbuild.1` (EBS CSI) [versão: EKS 1.32, dez/2025]. A lista envelhecia a cada mudança de versão do cluster.
- **Causa:** cada add-on tem matriz de compatibilidade por versão do Kubernetes (o kube-proxy acompanha a minor do cluster). E, ao contrário do que as anotações diziam, add-on gerenciado não se atualiza sozinho.
- **Correção:** valores trocados à mão no upgrade para 1.32.
- **Recomendação:** omita `addon_version` para o EKS instalar a versão padrão da minor, ou derive-a no Terraform (abaixo); atualize os add-ons como passo explícito de cada upgrade. Consulta manual: `aws eks describe-addon-versions --addon-name kube-proxy --kubernetes-version <VERSAO>`.

```hcl
data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}
```

### 3.7 Upgrades e suporte estendido

- **Sintoma:** o código do cluster apontava para 1.28, já em suporte estendido (cobrança extra por hora de cluster) e com o fim do estendido marcado para nov/2025.
- **Causa:** cada minor do EKS tem ~14 meses de suporte padrão e mais 12 de estendido. No estendido, o control plane custa US$ 0,60/h em vez de US$ 0,10/h; no fim dele, a AWS atualiza o control plane por conta própria.
- **Correção:** versão levada para 1.32, junto com kubectl 1.32, provider Kubernetes `~> 2.35`, chart do Load Balancer Controller e add-ons gerenciados [versão: dez/2025].
- **Recomendação:** upgrade in-place sobe uma minor por vez (1.28 → 1.29 → … → 1.32): control plane, depois add-ons, depois nodes. Em lab, recriar o cluster costuma ser mais rápido. Em out/2026, 1.32 e 1.33 já estão em suporte estendido: comece numa versão em suporte padrão (calendário oficial do EKS) e declare `upgrade_policy { support_type = "STANDARD" }` no `aws_eks_cluster`, porque o padrão da API é `EXTENDED`. O kubectl aceita uma minor de diferença do API server, para mais ou para menos; não precisa ser idêntico, como dizia uma anotação.

### 3.8 metrics-server condicional

- **Sintoma:** em t3.micro o workflow pulava o metrics-server e, com ele, o HPA; `kubectl top` não funcionava e o escalonamento virou manual (`kubectl scale deployment <APP> --replicas=N`).
- **Causa:** economia de slots. A decisão vinha de `grep "eks_node_instance_type" terraform/stg/terraform.tfvars | awk ...`, que lia sempre o tfvars de stg, qualquer que fosse o ambiente; a instalação usava `.../releases/latest/download/components.yaml`.
- **Correção:** instalação condicional (t3.small ou maior) e HPA aplicado só se o deployment `metrics-server` existisse.
- **Recomendação:** com nodes ≥ t3.small, instale sempre: é 1 pod, com requests padrão de ~100m de CPU e 200 MiB, não os "2–3 slots" estimados. Use o add-on comunitário `metrics-server` do EKS (o v2 faz isso) ou um chart com versão fixa, nunca `latest`. Decisão de workflow vem de output do Terraform do ambiente certo, não de grep ou sed em tfvars. Sem metrics-server, o HPA mostra alvo `<unknown>`.

## 4. ALB, AWS Load Balancer Controller e WAF

### 4.1 Dois donos para o mesmo caminho de tráfego

- **Sintoma:** a primeira versão do `switch-environment` desregistrava as EC2, registrava pods num target group criado pelo Terraform e mexia em regras de listener; acabou reescrita.
- **Causa:** o Load Balancer Controller reconcilia continuamente o ALB, os target groups e as regras que cria a partir do Ingress; mudanças manuais são desfeitas ou entram em conflito.
- **Correção:** `switch-environment-v2` só escala o Deployment e espera o Ingress; o controller cuida de ALB, target group (tipo `ip`) e roteamento.
- **Recomendação:** um dono por load balancer. Para ligar um Service a um target group criado pelo Terraform, use o CRD `TargetGroupBinding` do controller, não registro de IPs de pod via CLI.

### 4.2 Dois ALBs pagos e o WAF no ALB errado

- **Sintoma:** com EKS ligado havia dois ALBs, o do Terraform (modo EC2) e o `k8s-default-...` do Ingress, e o guia tratava isso como normal. A Web ACL estava associada ao ALB do Terraform, enquanto o tráfego do modo EKS passava pelo outro, sem WAF.
- **Causa:** os modos EC2 e EKS foram mantidos em paralelo, cada um com seu ALB; a associação do WAF (`aws_wafv2_web_acl_association`) ficou no ALB antigo e o Ingress não tinha a anotação de WAF.
- **Correção:** nenhuma; o switch só alternava qual ALB recebia tráfego.
- **Recomendação:** cada ALB custa hora + LCU + um IPv4 público por AZ. Use um só; vários Ingress compartilham o mesmo ALB com `alb.ingress.kubernetes.io/group.name`. Proteja o ALB que recebe tráfego (`alb.ingress.kubernetes.io/wafv2-acl-arn` no Ingress) e confira com `aws wafv2 get-web-acl-for-resource --resource-arn <ALB_ARN>`.

### 4.3 Comandos de log que apontavam para lugar nenhum

- **Sintoma:** o troubleshooting mandava "ativar" access logs com `access_logs.s3.enabled,Value=false` e depois acompanhar `aws logs tail /aws/alb/<ENV>` e `aws logs tail /aws/waf/<ENV>`.
- **Causa:** access logs do ALB vão só para S3 (com bucket policy para o serviço de ELB), não para CloudWatch Logs. E o log do WAF só aceita destinos cujo nome começa com `aws-waf-logs-`.
- **Correção:** nenhuma registrada.
- **Recomendação:** para lab, métricas do CloudWatch bastam (`HTTPCode_Target_5XX_Count`, `TargetResponseTime`, `BlockedRequests`), junto com `kubectl describe ingress` e os logs do controller. O v2 manda o log do WAF para um log group `aws-waf-logs-<NOME>`, com o header `authorization` redigido.

### 4.4 Ingress lento, versão do controller e HTTP sem TLS

- **Sintoma:** o endereço do Ingress levava 2–3 minutos para aparecer, e mais um pouco até os health checks passarem; os erros só apareciam nos eventos. A documentação citava HSTS, mas o listener era só HTTP na porta 80.
- **Causa:** o controller cria ALB e target groups de forma assíncrona. E HSTS servido por HTTP é ignorado pelo navegador.
- **Correção:** `kubectl get ingress -w`, `kubectl describe ingress <NOME>` e `kubectl logs -n kube-system deployment/aws-load-balancer-controller`.
- **Recomendação:** o v1 fixou "1.10.1", que é versão do chart Helm; não existe app 1.10.1, a linha da época era a v2.x [versão: dez/2025]. A linha atual do controller é a v3.x: fixe chart e app, leia as notas de versão antes de mudar de major e atualize a policy IAM com o `iam_policy.json` da mesma tag. Com IMDS em hop limit 1, informe `region` e `vpcId` nos values. Não troque por ingress-nginx: o projeto foi aposentado em março/2026. Sem domínio e certificado ACM, não anuncie HTTPS nem HSTS.

## 5. RDS e credenciais do banco

### 5.1 Timeout de conexão a partir dos pods

- **Sintoma:** a aplicação falhava ao inicializar o banco com "Connection terminated due to connection timeout".
- **Causa:** o security group do RDS liberava 5432 só para o SG das EC2; os pods saíam com o SG do cluster EKS, ausente da regra.
- **Correção:** regra temporária via CLI (`aws ec2 authorize-security-group-ingress --group-id <RDS_SG_ID> --protocol tcp --port 5432 --source-group <EKS_CLUSTER_SG_ID>`), depois a regra no Terraform (abaixo) e `kubectl rollout restart deployment/<APP>`.
- **Recomendação:** timeout é rede/SG; "password authentication failed" é credencial. Correção por CLI só para destravar, e no código no mesmo dia. A regra com origem no SG do cluster só vale se os nodes tiverem esse SG; launch template com SG próprio (3.3) ou security groups por pod mudam a origem.

```hcl
resource "aws_security_group_rule" "rds_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
```

### 5.2 Senha do banco em texto puro

- **Sintoma:** o documento de configuração do banco trazia a senha real, o endpoint do RDS e o DNS do ALB, copiados da saída de `aws secretsmanager get-secret-value`. O workflow criava o Secret do Kubernetes com a senha como argumento de linha de comando (`kubectl create secret generic ... --from-literal`), e a senha também ficava no state do Terraform.
- **Causa:** saída de comando colada em documentação versionada, e o argumento `password` clássico do `aws_db_instance`, que é gravado no state.
- **Correção:** os documentos saíram do repositório numa limpeza posterior, e o banco foi destruído.
- **Recomendação:** apagar o arquivo não apaga o histórico do git: trate como vazado e rotacione. Em docs, só marcadores. No v2 a senha vem de `ephemeral "random_password"` e entra por `password_wo`/`password_wo_version`; o segredo no Secrets Manager usa `secret_string_wo`/`secret_string_wo_version`; nada vai para plan ou state [versão: Terraform ≥ 1.11]. Para levar a senha ao pod, External Secrets Operator (como no v2) em vez de `--from-literal` no CI. Ative secret scanning e push protection no GitHub.

### 5.3 Nome de segredo preso depois do destroy

- **Sintoma:** o segredo do banco do v1 acabou com sufixo `-v2` no nome, sinal típico de colisão de nome após um destroy.
- **Causa (provável):** `DeleteSecret` só agenda a exclusão (janela padrão de 30 dias) e, nesse período, criar outro segredo com o mesmo nome falha com erro de segredo "já agendado para exclusão".
- **Correção:** renomear o segredo.
- **Recomendação:** em lab, `recovery_window_in_days = 0` no `aws_secretsmanager_secret` (o v2 usa 0 por padrão) ou `aws secretsmanager delete-secret --secret-id <NOME> --force-delete-without-recovery`.

### 5.4 O que sobra do RDS

- **Sintoma:** snapshots do RDS estavam entre os itens que a limpeza manual precisou apagar depois do destroy.
- **Causa:** snapshot final (`skip_final_snapshot = false`) e snapshots manuais ou do AWS Backup não saem com a instância e seguem cobrando armazenamento.
- **Correção:** remoção pelos scripts de limpeza.
- **Recomendação:** em lab, `skip_final_snapshot = true` e `deletion_protection = false` como escolha consciente e documentada; snapshots e recovery points entram no check pós-destroy. Referência do v1 [versão: dez/2025]: PostgreSQL 17.6, db.t4g.micro (Graviton), 20 GB gp3, single-AZ, retenção de backup de 1 dia, criptografia com a chave gerenciada `aws/rds`.

## 6. GitHub Actions e segredos

### 6.1 Chaves de longa duração e acesso de administrador

- **Sintoma:** os dois repositórios usavam `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` do usuário `<IAM_USER>`, que tinha `AdministratorAccess` e duas access keys ativas. O troubleshooting resolvia `AccessDenied` anexando `AdministratorAccess`, e o deploy na EC2 usava uma chave SSH guardada como segredo. O guia de setup dizia que o workflow "já usava OIDC por padrão".
- **Causa:** a opção simples ficou; OIDC existiu só no documento.
- **Correção:** a auditoria recomendou apagar uma das chaves.
- **Recomendação:** OIDC do GitHub com uma role por finalidade (plan, apply, deploy) e nenhuma chave no repositório: `permissions: id-token: write` no job e trust policy com `sub` exato. Quando o job declara `environment:`, o `sub` vira `repo:<OWNER>/<REPO>:environment:<ENV>`; trust escrita para `ref:refs/heads/main` falha com "Not authorized to perform sts:AssumeRoleWithWebIdentity". Para entrar nos nodes, Session Manager em vez de SSH; para o cluster, access entries (2.5).

### 6.2 Environments ausentes ou duplicados

- **Sintoma:** `tf-deploy.yml` aceitava `prd`, mas o environment `prd` não existia; havia `stg` e `staging` duplicados; o repo da aplicação não tinha nenhum.
- **Causa:** environments criados à mão, sem convenção. Job que referencia um environment inexistente faz o GitHub criá-lo na hora, sem regras de proteção nem segredos: um "deploy em prd" rodaria sem aprovação.
- **Correção:** registrado como bloqueio na auditoria.
- **Recomendação:** um nome por ambiente, criado antes do primeiro run (script com `gh api` ou IaC), com required reviewers onde fizer sentido e segredos/variáveis no escopo do environment. O `sub` do OIDC (6.1) depende desse nome.

### 6.3 CI vermelho por semanas

- **Sintoma:** "Terraform Plan and Validate" falhava no `terraform fmt -check` (12 arquivos fora do formato) e "Terraform Tests" no tflint, com "Failed to parse CLI options; Invalid value 'ormat' for option -f, --format". No repo da aplicação, 7 falhas seguidas de um job `terraform-tests` que apontava para `./terraform`, diretório que só existia no repo de infraestrutura. Havia "testes" que só faziam `echo`.
- **Causa:** a formatação não rodava antes do commit; `-format compact` com um hífen é lido como `-f ormat`; jobs copiados entre repositórios; nenhum teste real.
- **Correção:** `terraform fmt -recursive terraform/`, `tflint --format compact` e remoção do job copiado.
- **Recomendação:** `fmt`, `validate` e `tflint` com versões fixadas, em pre-commit e no CI [versão: tflint ≥ 0.47 não aceita diretório como argumento; use `--chdir` ou `--recursive`]. CI vermelho por dias deixa de ser sinal. Cada repo testa só o que é dele.

### 6.4 Muitos workflows, poucos exercitados

- **Sintoma:** 20 workflows ativos no repo de infraestrutura, 14 nunca executados; o deploy da aplicação falhava desde dez/2025; o workflow de destroy terminava com `terraform destroy ... || echo "Some resources may have failed..."`, então verde não significava conta limpa.
- **Causa:** um workflow por operação (switch, scale, manage, import, configure, restore…), todos `workflow_dispatch`, sem teste que os executasse, e erros engolidos para o job "passar".
- **Correção:** nenhuma no v1; a limpeza foi feita por scripts locais (10.1).
- **Recomendação:** poucos workflows, cada um coberto por um harness que roda sem nuvem: `terraform fmt -check`, `terraform init -backend=false` + `validate`, `tflint`, `trivy config`, `terraform test` com `mock_provider` [versão: Terraform ≥ 1.7], `actionlint`, `shellcheck`, `kubeconform` nos manifests e um scanner de segredos. É o que o CI do v2 executa, sem credenciais AWS. Nunca `|| echo` em passo que precisa falhar.

### 6.5 `latest` num repositório ECR imutável

- **Sintoma:** o runbook de rollback retagueava uma versão antiga como `latest` e fazia push, e os deploys usavam `image_tag: latest`, num repositório ECR com tags imutáveis.
- **Causa:** em repositório imutável, o push de uma tag que já existe é rejeitado (a tag não pode ser sobrescrita); e `latest` não diz qual código está rodando.
- **Correção:** nenhuma registrada.
- **Recomendação:** tag = SHA do commit (ou digest), tags imutáveis, rollback = redeploy do SHA anterior; lifecycle policy para imagens antigas (o v1 mantinha as 10 últimas).

## 7. Observabilidade com poucos recursos

### 7.1 kube-prometheus-stack completo não cabe

- **Sintoma:** a stack completa (Prometheus, Grafana, Alertmanager, node-exporter, Loki, Promtail) foi estimada em ~14 pods e ~1,7–2,2 GB de RAM; em t3.micro não havia slots nem memória.
- **Causa:** os limites de 3.1 e defaults de chart pensados para clusters maiores.
- **Correção:** "micro stack" de 4 pods (Prometheus, Grafana, kube-state-metrics, operator) com ~288 MiB e 105m de requests: Prometheus 128–256 MiB, 1 Gi de disco, retenção 2 d, scrape 60 s; Grafana 64–128 MiB sem persistência; kube-state-metrics 32–64 MiB; operator 64–128 MiB com admission webhooks desligados; Alertmanager, node-exporter e regras padrão desligados.
- **Recomendação:** esses valores são um bom ponto de partida em t3.small/t3.medium. Com os webhooks do operator desligados, PrometheusRule inválida não é rejeitada no apply: valide com `promtool` no CI. Sem persistência no Grafana, provisione dashboards como código (ConfigMaps lidos pelo sidecar) e o restart não perde nada. Volume de PVC sobrevive ao destroy do cluster se o PVC não for apagado antes (10.1).

### 7.2 Logs com Loki e Promtail

- **Sintoma:** o guia instalava `grafana/loki-stack` com Promtail.
- **Causa:** era o caminho comum em 2024–2025.
- **Correção:** na micro stack, Loki e Promtail ficaram desligados e os logs ficaram no CloudWatch.
- **Recomendação:** o Promtail chegou ao fim de vida em 02/03/2026; use Grafana Alloy como coletor e o chart `grafana/loki` [versão: 2026]. Em lab pequeno, `kubectl logs` e CloudWatch Logs com retenção curta costumam bastar.

### 7.3 Grafana exposto com credencial padrão

- **Sintoma:** o guia instalava o Grafana com `service.type=LoadBalancer` e `adminPassword` fixado em `admin`, e listava `admin` como usuário e senha. Depois a senha passou para um segredo do repositório, mas o Grafana seguiu exposto por LoadBalancer.
- **Causa:** atalho de instalação manual.
- **Correção:** senha via segredo do repositório (`GRAFANA_PASSWORD`).
- **Recomendação:** nada de LoadBalancer para ferramenta interna: `kubectl port-forward -n monitoring svc/<GRAFANA_SVC> 3000:80`. Isso também evita mais um load balancer (~US$ 18/mês na estimativa do v1) e seus IPv4 públicos. Senha via `admin.existingSecret` do chart, nunca em `--set`.

### 7.4 Regras de alerta para métricas inexistentes

- **Sintoma:** as regras de exemplo usavam `http_requests_total`, `up{job="rds"}` e `pg_stat_database_numbackends`, e um `PodNotRunning` com `kube_pod_status_phase{phase!="Running"} > 0`.
- **Causa:** sem instrumentação na aplicação e sem `postgres_exporter`, essas séries não existem e a regra nunca dispara; a de fase dispara para pods `Succeeded` de Jobs.
- **Correção:** a micro stack desligou regras e Alertmanager; mais tarde o Alertmanager foi ligado ao Slack por workflow, com o webhook no segredo `SLACK_WEBHOOK_URL`.
- **Recomendação:** comece pelas regras padrão do kube-prometheus-stack, escreva regra só para série que aparece no Prometheus e teste com `promtool test rules`. A URL do webhook é credencial: Secret do Kubernetes referenciado pela configuração do Alertmanager, nunca em values versionados.

## 8. OPA Gatekeeper

### 8.1 Gatekeeper não cabia em t3.micro

- **Sintoma:** controller e audit (~256 MiB cada) não cabiam nos nodes.
- **Causa:** os limites de 3.1.
- **Correção:** modo "micro": só o controller (80–150 MiB), audit desligado e 7 políticas (containers privilegiados, hostPath etc.) em `dryrun`.
- **Recomendação:** para privileged, hostPath e hostNetwork, o Pod Security Admission nativo resolve com um label no namespace (`pod-security.kubernetes.io/enforce: baseline` ou `restricted`) e nenhum pod extra. Deixe o Gatekeeper para regras próprias (registries permitidos, labels obrigatórias), quando houver memória para controller e audit.

### 8.2 `dryrun` sem audit não mostra nada

- **Sintoma:** o modo micro combinava `dryrun` com audit desligado e contava com ver as violações "nos logs".
- **Causa:** em `dryrun` a admissão não bloqueia nem avisa; as violações aparecem no status das constraints, que é preenchido pelo audit; log de admissão só existe com `logDenies` habilitado.
- **Correção:** nenhuma registrada.
- **Recomendação:** sem audit, use `enforcementAction: warn` (o kubectl mostra o aviso na hora) e passe para `deny` depois de zerar as violações. Com uma réplica só, lembre que o webhook do Gatekeeper é fail-open por padrão (`failurePolicy: Ignore`): se o pod cair, tudo passa.

## 9. Backup e restore

### 9.1 Seleção por tag que não seleciona nada

- **Sintoma:** plano diário do AWS Backup (03:00 UTC) para RDS e EBS selecionados por tag; o troubleshooting do v1 já apontava "recurso sem a tag certa" e "janela curta" como causas de job sem backup.
- **Causa:** seleção por tag falha em silêncio: recurso sem a tag simplesmente fica de fora.
- **Correção:** o workflow `configure-backup` aplicava as tags, além de criar vault, plano e role.
- **Recomendação:** depois do primeiro ciclo, confirme que existem recovery points: `aws backup list-recovery-points-by-backup-vault --backup-vault-name <VAULT>`. O agendamento usa o cron de 6 campos da AWS (`cron(0 3 * * ? *)`), não o de 5 campos.

### 9.2 Restore cria outro recurso

- **Sintoma:** o runbook restaurava o RDS para uma instância nova (`...-restored-<TIMESTAMP>`) e mandava editar `DB_HOST` no Secret, mas o Secret usava a chave `host` (`DB_HOST` era o nome da variável no Deployment). Para EBS, sugeria `aws ec2 attach-volume` direto no node.
- **Causa:** restore nunca devolve o mesmo endpoint, e inconsistências desse tipo só aparecem quando o restore é executado de ponta a ponta.
- **Correção:** nenhuma registrada.
- **Recomendação:** ensaie o restore uma vez por ciclo de lab e cronometre. No RDS, informe subnet group, security groups e parameter group; sem isso a instância restaurada recebe o SG padrão da VPC e a aplicação volta ao timeout de 5.1. No Kubernetes, não anexe volume restaurado à mão: crie um PersistentVolume estático com `csi.volumeHandle: <VOLUME_ID>` e afinidade de AZ, ou use VolumeSnapshot do CSI.

### 9.3 Imutabilidade, outra região e o destroy

- **Sintoma:** a estratégia previa cópia para us-west-2 em prd e afirmava que os backups eram "imutáveis"; o workflow de destroy precisava apagar recovery points antes do vault.
- **Causa:** recovery point só é imutável com AWS Backup Vault Lock; o vault só pode ser apagado vazio; e cada região extra é mais um lugar para esquecer recurso.
- **Correção:** cross-region desligado em stg e passo de exclusão de recovery points no destroy.
- **Recomendação:** em lab, retenção curta (7 dias), sem cópia entre regiões e sem Vault Lock em modo compliance: nele, ninguém, nem a conta root, apaga recovery points antes do fim da retenção, e o destroy deixa de limpar a conta. Recovery points sobrevivem ao destroy e cobram armazenamento.

## 10. Limpeza, destroy e recursos órfãos

### 10.1 `terraform destroy` não limpava tudo

- **Sintoma:** foram precisos dois scripts PowerShell (`cleanup-aws-manual.ps1` e `cleanup-aws-deep.ps1`, ~386 linhas cada) para apagar o que o destroy deixou: load balancers, target groups, ENIs, security groups, NAT e EIPs, log groups, segredos, snapshots e repositórios ECR. Uma role de nodes órfã ficou para trás.
- **Causa:** parte dos recursos nasce fora do state: ALB, target groups e SGs criados pelo Load Balancer Controller, ENIs da VPC CNI, volumes de PVCs, log groups criados pelos serviços e add-ons criados à mão ou por workflow. Enquanto existem, subnets e VPC não saem (erros de dependência, tipicamente `DependencyViolation`). State vazio não significa conta vazia.
- **Correção:** ordem fixa no destroy do EKS (recursos Kubernetes → Load Balancer Controller → add-ons → node group → cluster) e scripts para o resto.
- **Recomendação:** destroy em três fases (o v2 segue esse desenho): (1) apagar o que os controllers criaram na AWS (Ingress, Services `LoadBalancer`, PVCs) e esperar ALBs e volumes sumirem; (2) `terraform destroy` sem engolir erro; (3) checagem de remanescentes que falha se sobrar algo cobrável. Crie no Terraform os log groups que os serviços criariam sozinhos (ex.: `/aws/eks/<CLUSTER>/cluster`), com retenção, para que saiam no destroy.

### 10.2 Resource Explorer mostra o que não existe

- **Sintoma:** depois da limpeza, o Resource Explorer listava 111 recursos (50 EC2 Fleets, 15 regras de SG, 6 subnets, 4 ENIs…); ao abrir um deles: "The networkInterface ID 'eni-<ID>' does not exist".
- **Causa:** o Resource Explorer é um índice com atualização eventual (as anotações registraram até 24–48 h). Os EC2 Fleets são registros do tipo `instant` criados pelo Auto Scaling ao lançar nodes: ficam em estado `deleted_*`, não cobram e expiram sozinhos.
- **Correção:** verificação direta por API e, para limpar a vista, exclusão e recriação do índice (`aws resource-explorer-2 delete-index` e `create-index`).
- **Recomendação:** o check pós-destroy consulta a API de cada serviço, em cada região usada, inclusive a de cópia de backup (a limpeza do v1 mexeu em duas regiões):

```bash
aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,stopping,stopped"
aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available"
aws ec2 describe-addresses
aws ec2 describe-network-interfaces --filters "Name=status,Values=available"
aws ec2 describe-volumes --filters "Name=status,Values=available"
aws elbv2 describe-load-balancers
aws eks list-clusters
aws rds describe-db-instances
aws rds describe-db-snapshots --snapshot-type manual
aws logs describe-log-groups --log-group-name-prefix /aws/eks/
aws secretsmanager list-secrets --include-planned-deletion
```

### 10.3 O que pode ficar na conta

- **Sintoma:** depois de tudo restavam ~61 itens na conta, e a dúvida era se algum cobrava.
- **Causa:** padrões da conta e itens gerenciados pela AWS.
- **Correção:** inventário item a item; custo residual de ~US$ 0,01–0,10/mês (backend do state).
- **Recomendação:** pode ficar: VPC padrão e seus filhos, service-linked roles (`AWSServiceRoleFor...`), chaves KMS gerenciadas pela AWS (`aws/rds`, `aws/secretsmanager`), parameter e option groups `default.*` e o backend do state. Duas correções às anotações: a VPC padrão pode ser apagada (e recriada com `aws ec2 create-default-vpc`), só não compensa; e service-linked role sai com `aws iam delete-service-linked-role` quando nada a usa, não com `delete-role`. Role de cliente que sobra, como a dos nodes no v1, indica IAM criado fora do Terraform ou destroy interrompido.

## 11. Checklist do próximo ciclo

- Budget criado no bootstrap, com créditos excluídos se a conta usar créditos.
- Quotas de vCPU on-demand e spot conferidas.
- Versão do EKS em suporte padrão e `upgrade_policy` em `STANDARD`.
- Nodes ≥ t3.small (de preferência t3.medium), SPOT, um NAT e um ALB, com o WAF nesse ALB.
- Nada criado à mão; se acontecer, `import {}` no mesmo dia.
- OIDC sem chaves de longa duração; environments do GitHub criados antes do primeiro run.
- Senhas só em argumentos write-only e no Secrets Manager; nenhum valor real em documentação.
- Restore ensaiado ao menos uma vez.
- Destroy em três fases e checagem de remanescentes em todas as regiões usadas, no fim de cada sessão.
