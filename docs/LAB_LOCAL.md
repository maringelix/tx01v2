# Lab local

O lab v1 tinha uma plataforma completa — Istio, Prometheus/Grafana/Alertmanager, Loki, Argo CD,
Gatekeeper, Trivy Operator, backup, Chaos Mesh — mas só existia na nuvem, e boa parte nunca funcionou
de verdade (`docs/LICOES_APRENDIDAS.md`). O lab local constrói essa plataforma inteira no Docker da sua
máquina, com Terraform, e prova cada peça com tráfego ou chamadas reais. Nada aqui fala com a AWS.

Status: `verificado localmente` (rodada completa em 2026-10-13, 25 sondas) e no job `e2e` do CI.

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
| core | Gateway API 1.6.3 (standard), Istio 1.31.1 ambient (istiod, istio-cni, ztunnel, GatewayClass `istio`), cert-manager 1.21.2 + ClusterIssuer `lab-ca`, External Secrets 2.12.0 + ClusterSecretStore `local-secrets`, metrics-server 0.9.0, contrato `lab-system/lab-contract` | todos |
| observability | kube-prometheus-stack 92.3.0 (Prometheus 3.15, Alertmanager 0.34 → `alert-sink`, Grafana 13.2 só ClusterIP, kube-state-metrics, node-exporter), Loki 3.6 (single binary), Alloy 1.20 | `observability`, `full` |
| operations | Argo CD 3.5.5, Gatekeeper 3.23.1 + políticas, Trivy Operator 0.35, Velero 1.18 (plugin AWS → S3 emulado), Chaos Mesh 2.8.4 | `operations`, `full` |

Pod Security: `restricted` em todos os namespaces, menos `istio-system`, `monitoring-agents` e
`chaos-mesh` (`privileged`: mexem na rede ou nos processos do nó) e `trivy-system` (`baseline`, com
aviso de `restricted`). O namespace do app, `dx01v2`, é `restricted`, faz parte do mesh ambient e tem
as constraints do Gatekeeper em `deny`.

## Como rodar

Precisa de Docker com 8 GB de memória para o perfil `full` (o perfil `core` cabe em 3 GB), além das
ferramentas de `make tools`. Linux, WSL 2 ou o devcontainer.

```bash
make e2e                          # up + sondas + down (sempre destrói, também depois de falha)
LOCAL_PROFILE=core make local-up  # só a base; observability e operations são as outras camadas
make local-check                  # sondas do que estiver instalado
make local-down                   # destroy + scripts/leftovers-local.sh
scripts/local-lab.sh status       # contêineres e nós do lab
export KUBECONFIG="$(scripts/local-lab.sh kubeconfig)"   # kubectl contra o lab
```

Dentro de um contêiner que usa o Docker do host (devcontainer, docker.sock montado), exporte
`LOCAL_KIND_INTERNAL=1`: o script entra na rede do lab e usa o endereço interno da API.

Para abrir o Grafana: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`,
usuário `admin`, senha `terraform -chdir=terraform/envs/local output -raw grafana_admin_password` (com o
`TF_DATA_DIR` de `scripts/local-lab.sh`). O Argo CD não tem usuário admin local: inspecione as
`Application` com kubectl.

## O que as sondas provam (`platform/local/check.sh`)

| Área | Sonda |
|---|---|
| Banco | conexão `verify-full` com a CA do lab funciona; texto puro é recusado |
| Mesh | cliente com identidade permitida chega ao serviço (mTLS pelo ztunnel); outra identidade é recusada pela `AuthorizationPolicy`; cliente fora do mesh é recusado pelo `STRICT` |
| Borda | Gateway `Programmed` com endereço do load balancer emulado; HTTPS verificado contra a CA do lab; HTTP → 301 |
| Segredos | ExternalSecret no namespace `dx01v2` vira Secret com as cinco chaves do contrato |
| Métricas | `kubectl top nodes` (metrics-server) |
| Observabilidade | alvos de kube-state-metrics, node-exporter, apiserver e kubelet coletados; `PrometheusRule` sintética chega ao `alert-sink` pelo Alertmanager; logs do namespace da sonda aparecem no Loki; Grafana saudável e só ClusterIP |
| GitOps | commit no servidor git sincronizado pelo Argo CD; segundo commit reconciliado; objeto apagado recriado (self-heal) |
| Políticas | pod fora das regras recusado pelas cinco constraints de pod; pod conforme aceito; Service NodePort recusado |
| Registry e scan | imagem enviada ao registry é baixada pelo nó; o Trivy Operator gera ConfigAuditReport e VulnerabilityReport |
| Backup | backup Velero de um namespace, namespace apagado, restore com os dados |
| Chaos | hipótese: com 2 réplicas, matar um pod não derruba o serviço (pelo menos 38 de 40 requisições) |

## Limites (o que o lab local não prova)

- Nada da AWS: IAM, Pod Identity, ALB/WAF reais, RDS, quotas e custo continuam `não executado em nuvem
  (v2)`. O lab local mostra o alvo da plataforma; a camada de plataforma em nuvem ainda instala só o
  AWS Load Balancer Controller e o ESO (`planejado` para os demais add-ons no EKS).
- Um nó só: sem alta disponibilidade, sem PodDisruptionBudget testado contra drenagem de nó.
- O cloud-provider-kind precisa do socket do Docker (cria contêineres Envoy): rode o lab só numa
  máquina descartável ou no CI.
- O mirror do Trivy Operator e o mapeamento `registry.tx01v2.local` existem só no lab local.
- Logs, métricas e backups vivem dentro do lab (retenções de horas) e somem no destroy.
