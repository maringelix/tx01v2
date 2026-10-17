# Lab local

O lab v1 tinha uma plataforma completa — Istio, Prometheus/Grafana/Alertmanager, Loki, Argo CD,
Gatekeeper, Trivy Operator, backup, Chaos Mesh — mas só existia na nuvem, e boa parte nunca funcionou
de verdade (`docs/LICOES_APRENDIDAS.md`). O lab local constrói essa plataforma inteira no Docker da sua
máquina, com Terraform, e prova cada peça com tráfego ou chamadas reais. Nada aqui fala com a AWS.

Status: `implementado; CI pendente` (job `e2e`, 39 sondas esperadas) e `verificado localmente`
(2026-10-14: os perfis `observability`, 22 sondas, e `operations`, 24 sondas, cada um do zero até o
destroy). O tamanho
`small` (abaixo) é `verificado no CI` pelo job `e2e-platform-small` do dx01v2: a plataforma `full` com
o app, com o Docker limitado a 7 GB.

O v1 parou nos "próximos passos" (DR multi-região, FinOps, chaos, observabilidade com OpenTelemetry).
Aqui dois deles existem e são provados: traces com OpenTelemetry (Collector, Tempo, spans dos Gateways
do Istio, spanmetrics com exemplars, Grafana ligando logs, métricas e traces) e experimentos de chaos
com hipótese (pod kill, latência de rede, stress de CPU e memória). Os alertas também vão para o
Slack, como no v1, mas o webhook nunca fica em arquivo versionado.

## O que é criado

`terraform/envs/local` (providers `kreuzwerker/docker` 4.6, `hashicorp/tls` 4.4, `hashicorp/random`
3.9; state local fora do repositório, em `~/.local/state/tx01v2-local`):

| Na AWS | No lab local | Endereço |
|---|---|---|
| VPC | rede Docker `tx01v2-local` (`10.250.0.0/24`; metade de cima para o nó e os load balancers) | — |
| EKS 1.36 | cluster kind `tx01v2-local` (Kubernetes 1.36, kindnet com NetworkPolicy) | API em 127.0.0.1 (porta aleatória) |
| ECR | registry (CNCF Distribution 3.1.2) | push em `localhost:5001`, pull como `registry.tx01v2.local` |
| RDS PostgreSQL 17 com `rds.force_ssl` | PostgreSQL 17, `hostssl` + SCRAM, texto puro recusado, certificado da CA do lab | `10.250.0.11`, `db.tx01v2.local` |
| ACM / RDS CA bundle | CA do lab (ECDSA P-256, 30 dias), gerada pelo provider `tls` | — |
| S3 | Versity S3 Gateway 1.8.0 (buckets `tx01v2-local-velero`, `tx01v2-local-db-backups`) | `http://10.250.0.12:7070` |
| ALB / NLB (AWS Load Balancer Controller) | cloud-provider-kind 0.12.0: um Envoy por Service `LoadBalancer` | metade de cima da rede |
| GitHub (origem do GitOps) | Soft Serve 0.12.3: push por SSH com a chave do state, leitura anônima por HTTP | `10.250.0.13` |

Todos os contêineres e volumes levam o label `tx01v2.lab=local`. Só o registry publica porta, e só em
127.0.0.1. As credenciais (senha do banco, token de admin, chaves do S3, senha do Grafana, chave SSH)
são geradas pelo Terraform e ficam no state local: valem só para esta máquina e somem no destroy.

`platform/local/install.sh` instala, nesta ordem (versões e SHA256 em `platform/local/versions.env`,
imagens por digest em `platform/local/values/`):

| Camada | Componentes | Perfil |
|---|---|---|
| core | Gateway API 1.6.3 (experimental retries), Istio 1.31.1 ambient (istiod, istio-cni, ztunnel, GatewayClass `istio` and the dx01v2 waypoint), cert-manager 1.21.2 + ClusterIssuer `lab-ca`, External Secrets 2.12.0 + ClusterSecretStore `local-secrets`, metrics-server 0.9.0, contrato `lab-system/lab-contract` | todos |
| observability | kube-prometheus-stack 92.3.0 (Prometheus 3.15 com exemplars, Alertmanager 0.34 → `alert-sink` e Slack, Grafana 13.2 só ClusterIP, kube-state-metrics, node-exporter), Loki 3.6 (single binary), Alloy 1.20, Tempo 3.1 (single binary), OpenTelemetry Collector 0.162 (OTLP → Tempo + spanmetrics), `Telemetry` do Istio (spans dos Gateways) | `observability`, `full` |
| operations | Argo CD 3.5.5, Gatekeeper 3.23.1 + políticas, Trivy Operator 0.35, Velero 1.18 (plugin AWS → S3 emulado), Chaos Mesh 2.8.4 | `operations`, `full` |

O `full` do EKS acrescenta o chart Kyverno para verificar a attestation de promoção no ECR e usa
PVCs gp3 criptografados para os sinais. O perfil local não simula as credenciais AWS nem o runtime
de admissão do ECR; esses manifests e identidades passam por render, schema e testes Terraform no CI.

Pod Security: `restricted` em todos os namespaces, menos `istio-system`, `monitoring-agents` e
`chaos-mesh` (`privileged`: mexem na rede ou nos processos do nó) e `trivy-system` (`baseline`, com
aviso de `restricted`). O namespace do app, `dx01v2`, é `restricted`, faz parte do mesh ambient e tem
as constraints do Gatekeeper em `deny`.

## Como rodar

Precisa de Docker com 8 GB de memória para o perfil `full`, ou 7 GB com `LOCAL_SIZE=small` (abaixo; o
perfil `core` cabe em 3 GB), além das ferramentas de `make tools`. Linux, WSL 2 ou o devcontainer.

```bash
make e2e                          # up + sondas + down (sempre destrói, também depois de falha)
LOCAL_PROFILE=core make local-up  # só a base; observability e operations são as outras camadas
LOCAL_SIZE=small make local-up    # a plataforma inteira com menos memória (7 GB de Docker, abaixo)
make local-check                  # sondas do que estiver instalado
make local-down                   # destroy + scripts/leftovers-local.sh
scripts/local-lab.sh status       # contêineres e nós do lab
export KUBECONFIG="$(scripts/local-lab.sh kubeconfig)"   # kubectl contra o lab
```

O kubeconfig do lab é um arquivo próprio (`$LOCAL_STATE_DIR/kubeconfig`): o `~/.kube/config` da
máquina nunca é usado nem alterado. Os scripts de `platform/local` recusam qualquer contexto que não
seja `kind-tx01v2-local`, também quando rodam sozinhos, porque o `uninstall.sh` apaga todo Gateway e
todo Service `LoadBalancer` do cluster que alcança (check `policy-scripts`).

O devcontainer tem Docker próprio (Docker-in-Docker): lá dentro, os comandos acima funcionam sem
ajuste (`LOCAL_PROFILE=core make e2e` verificado localmente em 2026-10-14). Dentro de um contêiner
que usa o Docker do host (docker.sock montado), exporte `LOCAL_KIND_INTERNAL=1`: o script entra na
rede do lab e usa o endereço interno da API.

Para abrir o Grafana: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`,
usuário `admin`, senha `terraform -chdir=terraform/envs/local output -raw grafana_admin_password` (com o
`TF_DATA_DIR` de `scripts/local-lab.sh`). Em Explore, o datasource Tempo abre um trace pelo id; num
trace, "Logs for this span" leva às linhas do Loki com o mesmo `trace_id`, e os exemplars dos gráficos
do Prometheus levam ao trace. O Argo CD não tem usuário admin local: inspecione as `Application` com
kubectl.

Alertas no Slack: crie um incoming webhook no seu workspace e suba o lab com
`LOCAL_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/... make local-up`. Os alertas `warning` e
`critical` vão para o canal; sem a variável, o receptor Slack posta no `alert-sink` (é o que o CI testa).
O webhook vai para o Secret `monitoring/alertmanager-slack` pelo stdin do kubectl, nunca para arquivos
ou logs.

## Tamanhos (`LOCAL_SIZE`)

`LOCAL_SIZE=small` (o padrão é `default`) instala os mesmos componentes com menos memória: o
`helm_install` põe `platform/local/values/small/<chart>.yaml` por último, então os tamanhos dele valem
sobre os outros values. Os componentes continuam os mesmos (as sondas dos apps usam quase todos), e o
padrão já tem uma réplica de cada.

| Chart | No tamanho `small` |
|---|---|
| kube-prometheus-stack | Prometheus com retenção de 2 h (padrão 6 h), 20 mil exemplars (padrão 100 mil) e limite de 640 MiB; sem os endpoints cAdvisor e probes do kubelet, sem os histogramas do apiserver e sem os grupos de regras padrão que leem essas séries (os alvos que as sondas procuram continuam); Grafana sem o alerting unificado (o lab alerta pelo Alertmanager) e sem instalar plugins na partida, limite de 512 MiB |
| Loki, Tempo, Alloy | limites de 320, 320 e 200 MiB; Tempo com retenção de 1 h (padrão 6 h) |
| OpenTelemetry Collector | limite de 192 MiB (o chart deriva dele o `GOMEMLIMIT` e o `memory_limiter`) |
| Argo CD | menos workers (5 de status, 2 de operação, um render por vez no repo-server; o lab tem uma Application) e limites de 320, 256 e 192 MiB |
| Gatekeeper | auditoria a cada 5 minutos (padrão 1) e só dos tipos que as constraints usam (sem isso, cada rodada lista pelo apiserver todos os tipos do cluster), limite de 384 MiB |
| Trivy Operator | um scan job por vez, limite de 320 MiB no operador |
| Velero | limite de 256 MiB |

Os componentes em Go recebem `GOMEMLIMIT` abaixo do limite (o Prometheus 3 e o chart do Collector já o
derivam do limite), para o coletor de lixo trabalhar antes do OOM kill. O plano de controle também:
o `scripts/local/kind-cluster.sh` acrescenta `terraform/envs/local/kind-config-small.yaml` à config do
kind (`GOMEMLIMIT` no apiserver, no controller-manager e no etcd, pelo `extraEnvs` do kubeadm v1beta4).
Trocar o tamanho de um lab de pé pede `make local-down` antes, porque o cluster existente é
reaproveitado. O check `helm-template-local` renderiza cada chart também com o overlay, aplica as
mesmas regras e falha se o overlay trocar uma imagem ou citar um chart que não existe.

Quanto a plataforma `full` com o app do dx01v2 precisa (memória do Docker, sem swap):

| Tamanho | Docker | Resultado |
|---|---|---|
| `default` | 7 GB (local, 2026-10-15) | falha: a memória bateu no limite cerca de 825 mil vezes (thrashing), o apiserver reiniciou e os controllers entraram em CrashLoop; nenhum OOM kill |
| `default` | runner do CI, 16 GB | passa (jobs `e2e` daqui e `e2e-platform` do dx01v2) |
| `small` | 6 GB (CI, Docker-in-Docker, 2026-10-15) | falha: 14 das 18 sondas passam, e a de rollout perde 7 de 376 requisições; memória anônima de 4,25 GiB, limite atingido 468 mil vezes, 4 OOM kills (a cópia do plugin do Velero) |
| `small` | 7 GB (CI, Docker-in-Docker, 2026-10-15) | passa: as 18 sondas em cerca de 14 minutos, memória anônima de 4,4 GiB. Em uma das quatro rodadas dos três pares, o kernel matou duas vezes a cópia do plugin do Velero na instalação (init container BestEffort, que o kubelet roda de novo) |
| `small` | 8 GB (CI, Docker-in-Docker, 2026-10-15) | passa no mesmo tempo, memória anônima de 4,37 GiB |

O tamanho `small` fica em 7 GB, decisão do Bruno em 2026-10-15 (a meta da R1.8 era 6 GB): abaixo dos
7,65 GiB do Docker Desktop de desenvolvimento e 1 GB a menos que o padrão. O job
`e2e-platform-small` do dx01v2 repete a prova em todo PR. O maior consumidor é o apiserver, que passa de
1 GiB com os CRDs da plataforma inteira mesmo com `GOMEMLIMIT` de 768 MiB. Picos de memória no job
(working set, 2026-10-15): apiserver 1248 MiB, controller do Argo CD 306 MiB, Grafana 299 MiB mais
163 MiB dos dois sidecars, Prometheus 236 MiB, Trivy Operator 208 MiB, etcd 150 MiB e os dois pods do
Gatekeeper, 271 MiB.

Os perfis `observability` e `operations`, sem o app, passaram no tamanho padrão com os 7,65 GiB do
Docker Desktop de desenvolvimento (2026-10-14).

## O que as sondas provam (`platform/local/check.sh`)

| Área | Sonda |
|---|---|
| Banco | conexão `verify-full` com a CA do lab funciona; texto puro é recusado |
| Mesh | cliente com identidade permitida chega ao serviço (mTLS pelo ztunnel); outra identidade é recusada pela `AuthorizationPolicy`; cliente fora do mesh é recusado pelo `STRICT` |
| Borda | Gateway `Programmed` com endereço do load balancer emulado; HTTPS verificado contra a CA do lab; um `X-Request-Id` externo (texto livre ou UUID) chega intacto ao backend (como no ALB; `EnvoyFilter` `gateway-preserve-request-id`); HTTP → 301 |
| ACME | Pebble/challtestsrv executam HTTP-01 no Gateway local; cert-manager emite certificado de teste de 20 minutos e o renova automaticamente, com revisão e serial novos |
| WAF | ModSecurity com OWASP CRS 4.30.0 encaminha requisição benigna e bloqueia SQLi; o limite local do NGINX devolve HTTP 429 numa rajada |
| Segredos | ExternalSecret no namespace `dx01v2` vira Secret com as cinco chaves do contrato |
| Métricas | `kubectl top nodes` (metrics-server) |
| Observabilidade | alvos de kube-state-metrics, node-exporter, apiserver e kubelet coletados; `PrometheusRule` sintética chega ao `alert-sink` pelo Alertmanager e ao receptor Slack no formato de mensagem do Slack (com `LOCAL_SLACK_WEBHOOK_URL`: notificações entregues, nenhuma com falha); logs do namespace da sonda aparecem no Loki; Grafana saudável e só ClusterIP |
| Traces (OpenTelemetry) | um span OTLP/HTTP enviado ao Collector aparece no Tempo; o Gateway continua um `traceparent` W3C de entrada, passa o próprio span ao backend e o reporta ao Tempo; o spanmetrics gera as séries RED no Prometheus com um exemplar que carrega o trace id; o Grafana alcança o Tempo e liga logs → traces (campo derivado do Loki) e métricas → traces (exemplars) |
| GitOps | commit no servidor git sincronizado pelo Argo CD; segundo commit reconciliado; objeto apagado recriado (self-heal) |
| Políticas | pod fora das regras recusado pelas cinco constraints de pod; pod conforme aceito; Service NodePort recusado |
| Registry e scan | imagem enviada ao registry é baixada pelo nó; o Trivy Operator (modo ClientServer, com o Trivy server embutido) gera ConfigAuditReport e VulnerabilityReport |
| Backup | backup Velero de um namespace, namespace apagado, restore com os dados |
| Chaos | hipóteses: com 2 réplicas, matar um pod não derruba o serviço (pelo menos 38 de 40 requisições); com 100 ms a mais de latência de rede em todos os pods (`NetworkChaos`), pelo menos 19 de 20 requisições passam e a mediana sobe pelo menos 80 ms (a falha é real); com stress de CPU e memória dentro de cada contêiner (`StressChaos`), pelo menos 38 de 40 requisições passam, nenhum contêiner reinicia e o pico de CPU aparece no metrics-server |

## Limites (o que o lab local não prova)

- Nada da AWS: IAM, Pod Identity, ALB/WAF reais, RDS, quotas e custo continuam `não executado em nuvem
  (v2)`. O lab local mostra o alvo da plataforma; a camada de plataforma em nuvem ainda instala só o
  AWS Load Balancer Controller e o ESO (`planejado` para os demais add-ons no EKS).
- Um nó só: sem alta disponibilidade, sem PodDisruptionBudget testado contra drenagem de nó.
- O cloud-provider-kind precisa do socket do Docker (cria contêineres Envoy): rode o lab só numa
  máquina descartável ou no CI.
- O mirror do Trivy Operator e o mapeamento `registry.tx01v2.local` existem só no lab local.
- Logs, métricas, traces e backups vivem dentro do lab (retenções de horas) e somem no destroy.
- O tamanho `small` foi provado com as 18 sondas do dx01v2. As 39 sondas daqui rodam no CI só no
  tamanho padrão: `LOCAL_SIZE=small make e2e` não é verificado.
- Sem `LOCAL_SLACK_WEBHOOK_URL` o CI prova o receptor Slack e o formato da mensagem, não a entrega a um
  workspace de verdade.
