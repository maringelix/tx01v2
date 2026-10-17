# R10 — escala, capacidade e FinOps

## Estado e pré-requisitos

Construção para fork; nenhuma operação foi executada em AWS (v2).
O CI executa Docker. Os comandos cloud abaixo exigem a rodada autorizada do dono
do fork, domínio/conta e orçamento próprios. FinOps é opt-in, perfil full.
O caminho local padrão continua com um nó; o ensaio de capacidade usa três nós
kind e recomenda 12 GiB disponíveis no Docker. Não combine HA com LOCAL_SIZE=small.

## Aula local: HPA, PDB e interrupção

Em Linux/devcontainer, execute:

    make tools
    LOCAL_TOPOLOGY=ha LOCAL_FINOPS=1 make e2e

scripts/local/capacity-drill.sh cria um namespace exclusivo e recusa adotá-lo
caso já exista. Uma fixture Node fixada por digest gera CPU numa worker thread;
o HTTP fica responsivo. A sonda exige HPA 1 → 3 → 1 sob carga limitada,
recusa de eviction do último pod pelo PDB, drenagem de um worker pertencente ao
kind e redistribuição dos três pods nos nós restantes. A drenagem usa seletor
somente da fixture: não remove os pods persistentes da plataforma.

O cliente acessa o Service durante a drenagem, mede erro <= 1% e p99 <= 1 s,
sem usar port-forward para um pod. A limpeza sempre descordona o nó e remove
o namespace criado. Falhas mostram pods/HPA/PDB/VPA/eventos; não imprimem Secrets.
O relatório JSON contém as medidas e os critérios. As sondas anteriores de
mesh, backup, PITR, observabilidade, políticas e Chaos continuam obrigatórias.

O VPA precisa produzir uma recomendação, mantendo updateMode Off e os requests
originais. OpenCost precisa retornar custo positivo medido para o namespace da
fixture pela API /allocation. As tarifas locais são uma simulação determinística,
explicitamente identificada em platform/finops/pricing/local.json.

## EKS Cluster Autoscaler e Spot

O instalador instala Cluster Autoscaler oficial 9.59.0 com imagem 1.36.1, da mesma
minor do EKS, KSA kube-system/cluster-autoscaler e Pod Identity do cluster. Writes
SetDesiredCapacity/TerminateInstanceInAutoScalingGroup exigem ambas as tags de
descoberta do cluster; a role mantém a permissions boundary. Tags node-template
do pool Spot permitem descoberta a partir de zero. O controlador adiciona requests
de 50m CPU / 128Mi RAM à base, além da tabela dos charts full.

O caminho barato core mantém a opção de pool único SPOT, interrompível. Para a aula
com capacidade crítica preservada, enable_spot_pool=true (LAB_ENABLE_SPOT_POOL)
muda o pool default para ON_DEMAND e cria pool Spot tainted de 0-2 nós. A alteração
pode substituir o pool default e aumenta custo: revise o plano antes de aplicar.
Os workloads críticos não toleram a taint; o mesmo módulo governa o cluster DR.

Na rodada autorizada, aplique platform/finops/manifests/spot-job.yaml e observe
eventos/escala/nó. Sem Spot, cancele o Job e rode cópia com outro nome, removendo
a toleration e usando nodeSelector eks.amazonaws.com/capacityType=ON_DEMAND.
Preserve deadline/orçamento. O kind não comprova escala de ASGs nem economia AWS.

## Tarifas e instalação

OpenCost 2.5.33 / 1.121.3 e VPA 0.14.0 / 1.8.0 têm archives SHA256 e imagens
fixados em platform/finops/versions.env e nos values. A API é ClusterIP,
UI/MCP/cloud billing ingestion ficam desligados. O exporter usa preços configurados
e Prometheus existente; não recebe credenciais de faturamento.

Para cloud, forneça FINOPS_PRICING_FILE: JSON com cloud=aws, region da região
selecionada, currency=USD, mode=estimate, source HTTPS, asOf revisado nos últimos
31 dias, description, cpuPerCoreHour, ramPerGiBHour e storagePerGiBHour como
strings decimais positivas. Consulte os preços atuais do provedor; não reutilize
a simulação local como cotação. Spot usa a tarifa on-demand como limite conservador.

Na rodada autorizada, o instalador aceita --profile full --finops. O workflow
platform tem input finops e obtém as tarifas da variável LAB_FINOPS_PRICING_JSON.
Secondary precisa de tarifas da região secondary. Valores errados/stale falham.
O dashboard Grafana "Lab FinOps" mostra CPU/RAM por namespace e explica idle/shared.
Compare /allocation?window=1h&aggregate=namespace&includeIdle=true e
aggregate=label:cost_lab_owner para showback. Labels de owner/ambiente são obrigatórios
nas aulas; os DX verificam os próprios manifests e fazem rightsizing sob SLO.

## Estimativa antes do apply e expiração

Os workflows terraform-plan e terraform-apply chamam scripts/cost-workflow.sh
depois de salvar tfplan; apply só ocorre se o gate passar.
Configure LAB_FINOPS_PRICING_JSON, LAB_COST_BUDGET_USD, LAB_COST_HOURS (<=24)
e LAB_COST_EXPIRES_AT (UTC nas próximas 24h). Atualize o prazo a cada rodada.
O prazo precisa caber na duração orçada. São entradas públicas sem identificadores.

Para preparar a planilha de revisão fora do CI:

    umask 077
    terraform -chdir=terraform/envs/lab show -json tfplan > /tmp/plan-private.json
    bash scripts/cost-pricing-template.sh aws us-east-1 /tmp/plan-private.json /tmp/rates.json

A planilha é deliberadamente incompleta: preencha todos os tipos com custo por
recurso/hora na MAIOR configuração prevista (HA/DR, nós máximos, tamanhos de DB).
Use zero somente para tipos sem cobrança ou já incluídos, registrando a justificativa.
O gate recusa qualquer tipo sem preço. Também exige as categorias externas backup,
controlPlane, database, dr, egress, loadBalancer, nat, storage e waf, inclusive zero justificado para evitar
dupla contagem. Isso cobre custos dos controladores fora do Terraform.
As tarifas de CPU/RAM/disco do OpenCost e o inventário do plano são complementares:
não some os dois relatórios como se fossem faturas independentes.

O JSON do plano pode conter segredos e nunca é artefato público. O relatório
mostra apenas tipos, contagens, tarifas, fonte/data, total, budget e expiração.
As fixtures do CI provam aritmética, rejeição de cenário caro, tarifas antigas e
recursos não precificados. Não são preços de GCP.

Budget é alerta e este gate é estimativa: nenhum deles limita faturamento.
A expiração bloqueia novos plans/applies com prazo vencido e exige destruir ao fim
da aula; não cria um robô com credencial para destruir contas. Use o teardown
existente, verifique o inventário de sobras e registre retenções de backup/state
que continuam cobrando. Interrompa carga no deadline mesmo se o exercício falhar.

## Diagnóstico e limites

Sem HPA: veja metrics-server, requests e ScalingActive. Sem rescheduling: veja
cordon, PDB, afinidade, quotas e eventos. VPA Off nunca atualiza requests sozinho.
Sem alocação: confira ServiceMonitor, targets do Prometheus, janela com amostras,
permissões de leitura do exporter e preços. Sem preço regional revisado, o gate falha.
Compare carga/SLO antes e depois; não declare economia apenas reduzindo requests.

Leia [OpenCost Helm](https://opencost.io/docs/installation/helm/),
[API de alocação](https://opencost.io/docs/integrations/api-examples/),
[Cluster Autoscaler EKS](https://docs.aws.amazon.com/eks/latest/best-practices/cas.html)
e [Spot no EKS](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html).

### Custo externo, idle e owner no dashboard

O arquivo de tarifas também exige externalHourly com backup, controlPlane, database,
dr, egress, loadBalancer, nat, storage e waf (USD/h). Zero exige justificativa de
inclusão/ausência; evite contar o mesmo custo no recurso Terraform e na categoria
externa. O instalador cria a recording rule lab_external_hourly_estimate; o dashboard
mostra as categorias, owner/ambiente, infraestrutura compartilhada e idle estimado.
Kube-state-metrics expõe somente as duas labels de showback adicionais. A simulação
local tem externos zero; tarifas cloud são preenchidas pelo dono do fork.

LimitRange preenche limites ausentes antes da quota (CPU 1, RAM 512Mi por container;
requests padrão 10m/64Mi). Requests/limits explícitos são preservados, incluindo os
recursos dos proxies. A quota continua bloqueante.

Para o plano com DR, estime o maior SKU e a maior tarifa entre as regiões abrangidas;
registre essa escolha na descrição da fonte. No Autopilot, idle de nós é um modelo
de capacidade e não cobrança de VM ociosa: a alocação usa requests dos pods.
