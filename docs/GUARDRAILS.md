# Guardrails do tx01v2

Um guardrail é uma regra mais o mecanismo que a faz valer — automático sempre que possível. Este
documento lista as regras do repositório, onde cada uma é aplicada e o que elas não garantem.
Tipos: `bloqueante` (falha o CI ou o apply), `alerta` (notifica), `processo` (disciplina humana/agente).

## Regras

| ID | Regra | Por quê | Onde é aplicada | Tipo |
|---|---|---|---|---|
| SEC-01 | Nenhum segredo no repositório | repositório público; histórico é para sempre | `gitleaks` (harness, pre-commit) | bloqueante |
| SEC-02 | Sem identificadores reais: account ID só `123456789012`/`<ACCOUNT_ID>`, e-mails `example.com`, IPs privados ou RFC 5737 | evita expor contas e pessoas | check `policy-identifiers` | bloqueante |
| SEC-03 | Senhas geradas por recurso `ephemeral` e gravadas só com argumentos write-only (`password_wo`, `secret_string_wo`) | o valor nunca entra no plan nem no state | `policy-terraform`; testes `rds_password_never_in_plan_or_state` e `admin_token_is_write_only` | bloqueante |
| SEC-04 | GitHub → AWS só por OIDC, com `sub` exato (StringEquals) e `aud` `sts.amazonaws.com`; o `sub` é o imutável (`repo:<dono>@<id>/<repo>@<id>:...`), com os IDs numéricos do dono e do repositório | sem chaves estáticas; nenhum outro repo/branch assume os papéis; um nome de conta apagado e registrado de novo não herda o lab | `terraform/bootstrap/tests/oidc_roles.tftest.hcl`; `scripts/repo-guardrails.sh` confere o `sub` do repositório | bloqueante |
| SEC-05 | `id-token: write` só no job de nuvem que precisa; nunca no `ci.yml` | limita quem obtém credenciais | check `policy-workflows` | bloqueante |
| SEC-06 | Endpoint público do EKS restrito a `endpoint_public_access_cidrs`; `0.0.0.0/0` exige `allow_endpoint_from_anywhere = true` | reduz exposição da API; a escolha fica explícita | validação de variável + `tests/validations.tftest.hcl` | bloqueante |
| SEC-07 | Papel apply: IAM só em `role/`, `policy/`, `instance-profile/` `tx01v2-*`; negado em `role/tx01v2-gha-*`; papel plan só lê os serviços do lab (Describe/Get/List), não a conta inteira | o lab não altera a própria identidade de CI nem lê dados de outros projetos da conta | `oidc_roles.tftest.hcl` (`role_permissions_follow_the_contract`) | bloqueante |
| SEC-08 | Plan só para PRs do próprio repositório (guarda `head.repo.full_name == github.repository`) | forks nunca recebem credenciais | `terraform-plan.yml` | processo |
| SEC-09 | O bootstrap não tem dono padrão: `github_owner` é obrigatório e o placeholder `your-github-user` é recusado; `budget_alert_emails` recusa o placeholder `you@example.com` | um fork que esquecesse de trocar o dono confiaria nos repositórios de outra pessoa, e sem um e-mail lido o alerta de custo não chega (`FORK.md`) | validações das variáveis; `placeholder_owner_is_refused`, `placeholder_alert_email_is_refused` | bloqueante |
| SEC-10 | Scripts só agem no que o lab criou: o alvo vem do contrato e é conferido pela tag `Project=tx01v2` antes de qualquer mudança (nenhuma variável de ambiente, como `CLUSTER_NAME`, muda o alvo); kubeconfig e repositórios do Helm em arquivos temporários (o `~/.kube/config` e o contexto atual de quem roda não mudam); os scripts de `platform/local` só falam com o contexto `kind-tx01v2-local`; o `leftovers.sh` só conta como sobra o que tem a tag do lab | quem faz fork roda os scripts na própria máquina e na própria conta, onde pode haver clusters, contextos e variáveis de outros projetos | check `policy-scripts`; `require_lab_cluster` (`scripts/lib/aws.sh`) e `require_lab_context` (`scripts/lib/local.sh`) | bloqueante |
| SEC-11 | Todo papel IAM que o apply cria leva o *permissions boundary* `tx01v2-lab-boundary` (sem mudanças de IAM, da organização e da conta); o apply só cria ou troca o boundary de um papel com ele e não pode editá-lo nem tirá-lo | o papel apply anexa políticas a papéis `tx01v2-*`: sem o boundary, daria `AdministratorAccess` a um deles | `terraform/bootstrap/tests/boundary.tftest.hcl`; `tests/eks.tftest.hcl` e `tests/network.tftest.hcl` (todo papel do lab) | bloqueante |
| SEC-12 | O secret `LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS` (de onde você opera) é mascarado, cada CIDR e cada IP, em todo workflow de nuvem; o resumo do job e os artefatos trocam os valores | os logs, o resumo e os artefatos de um repositório público são públicos | `policy-workflows` | bloqueante |
| SUP-01 | Ferramentas do harness com versão e SHA256 fixados; divergência é erro fatal | cadeia de suprimentos | `scripts/install-tools.sh`, `tools/checksums.txt` | bloqueante |
| SUP-02 | Toda action fixada por SHA de 40 caracteres com comentário `# vX.Y.Z` | tags podem ser movidas | `policy-workflows` | bloqueante |
| SUP-03 | Providers com `.terraform.lock.hcl` multi-plataforma; roots iniciam com `-lockfile=readonly` | builds reprodutíveis | `terraform-lockfiles`, `terraform-validate:*` | bloqueante |
| SUP-04 | Imagens por digest (LBC, ESO, devcontainer) e política IAM do LBC idêntica ao upstream | nada muda sem um diff | `version-consistency` (charts e política); devcontainer por revisão | bloqueante |
| SUP-05 | trivy só via `scripts/install-tools.sh` (nunca `trivy-action`/`setup-trivy`, GHSA-69fq-xp46-6x23) | incidente de cadeia de suprimentos de março de 2026 | `policy-workflows` | bloqueante |
| SUP-06 | Dependabot mensal, minor+patch agrupados, majors separados | nada apodrece em silêncio | `.github/dependabot.yml` | alerta |
| IAC-01 | Launch template sem security groups, AMI ou user data; node group sem `disk_size` | erros do v1: nós sem o SG do cluster não entram no cluster | `policy-terraform`; `tests/eks.tftest.hcl` (`nodes`) | bloqueante |
| IAC-02 | IMDSv2 obrigatório com hop limit 1 | pods comuns não leem as credenciais do nó | `tests/eks.tftest.hcl` | bloqueante |
| IAC-03 | Subnets derivadas de `vpc_cidr` e das AZs disponíveis | erro do v1: subnets fixas ignorando variáveis | `tests/network.tftest.hcl` | bloqueante |
| IAC-04 | Terraform não fala com a API do Kubernetes; sem aws-auth/`system:masters`; acesso só por access entries | separação de camadas; erro do v1 | `policy-terraform`; testes `access_entries` e `control_plane` | bloqueante |
| IAC-05 | Cluster com `upgrade_policy = STANDARD` e `authentication_mode = API` | sem cobrança de suporte estendido; sem ConfigMap de auth | `tests/eks.tftest.hcl` | bloqueante |
| IAC-06 | `trivy config` sem achados HIGH/CRITICAL (simples e com `--tf-vars` do exemplo) | segurança da IaC | `trivy-config`, `trivy-config-tfvars` | bloqueante |
| IAC-07 | tflint (preset recommended + ruleset AWS) sem nenhum issue | qualidade da IaC | `tflint` | bloqueante |
| IAC-08 | Ampliação de IAM, rede, RBAC ou CORS só com justificativa no PR | revisões conscientes | template de PR | processo |
| K8S-01 | Manifests da plataforma validados com kubeconform estrito e schemas fixados por commit | manifest inválido não chega ao cluster | `kubeconform` | bloqueante |
| K8S-02 | Namespace, RBAC e ClusterSecretStore conforme o contrato; deployer só lê secrets | menor privilégio no cluster | `contract-platform` | bloqueante |
| K8S-03 | Service mutator webhook do LBC desligado; ServiceAccounts iguais às associações de Pod Identity; imagens dos charts por digest | sem efeitos colaterais em Services; nada muda sem diff | `contract-platform`, `helm-template` | bloqueante |
| APP-01 | Contrato com o dx01v2 versionado; mudanças em PRs coordenados nos dois repos | os dois lados evoluem juntos | `docs/CONTRATO.md`, testes do contrato | processo |
| CUSTO-01 | Budget mensal (padrão 25 USD) com alertas ACTUAL 50/80/100 % e FORECASTED 100 % | quem paga é você | `terraform/bootstrap/budget.tf` + `tests/budget.tftest.hcl` | alerta |
| CUSTO-02 | Padrões baratos: SPOT, 1 NAT, RDS single-AZ, backup de 1 dia, retenção de logs de 7 dias | custo por hora mínimo | `tests/lab.tftest.hcl` (`defaults_are_lab_friendly`) | bloqueante |
| CUSTO-03 | Destroy falha alto (sem `\|\| true`/`\|\| echo`), segue para o `terraform destroy` mesmo quando o `platform/uninstall.sh` falha (apagando pela API da AWS o que o controlador criou) e sempre termina com `scripts/leftovers.sh` | erro do v1: destroy que engolia erros; um uninstall que falha não pode deixar o ALB cobrando | `scripts/destroy.sh`, `terraform-destroy.yml`; check `destroy-flow` (CLIs simuladas), `policy-workflows` | bloqueante |
| CUSTO-04 | Rodada em nuvem termina com destroy no mesmo dia e relatório `cloud_run_report` | evita custo esquecido | `docs/RUNBOOK.md` | processo |
| CI-01 | O CI é o harness: jobs só chamam `make <alvo>` | o que passa local passa no CI | revisão de PR; `ci.yml` | processo |
| CI-02 | Sem `continue-on-error: true`, `\|\| true`, `\|\| echo` em workflows; sem `sed` em arquivos Terraform | gates honestos; erro do v1 | `policy-workflows` | bloqueante |
| CI-03 | `permissions: contents: read` no topo, `timeout-minutes`, `concurrency`, `ubuntu-24.04`, `persist-credentials: false` | menor privilégio e previsibilidade | `policy-workflows` | bloqueante |
| CI-04 | `HARNESS_STRICT=1` no CI: todo SKIP vira FAIL | nada é pulado em silêncio | `ci.yml`, `scripts/harness.sh` | bloqueante |
| CI-05 | Workflows de nuvem: só `workflow_dispatch` (plan com guarda), environment `lab`, validação das variáveis, confirmação digitada no destroy | ações caras exigem intenção | `terraform-*.yml`, `platform.yml` | processo |
| CI-06 | CI semanal agendado (segunda 06:00 UTC) | detecta ignores vencidos e URLs quebradas | `ci.yml` | alerta |
| CI-07 | O job `e2e` (lab local) roda em todo PR e precisa estar verde antes do merge | a plataforma local é provada, não só renderizada | `ci.yml`; check obrigatório do ruleset | bloqueante |
| LOC-01 | O lab local nunca fala com uma nuvem: sem provider de nuvem nem backend remoto em `terraform/envs/local`; Docker só por socket local | o lab é grátis e seguro de rodar | `policy-terraform`; validação de `docker_host` (`terraform-test:envs/local`) | bloqueante |
| LOC-02 | Contêineres do lab local com o label `tx01v2.lab=local`; só o registry publica porta, e em 127.0.0.1; nada privilegiado | nada fica exposto nem esquecido | `terraform-test:envs/local`, `policy-terraform`, `scripts/leftovers-local.sh` | bloqueante |
| LOC-03 | Charts do lab local fixados por versão e SHA256 do `.tgz`; imagens por digest; Services só ClusterIP (exceto os Gateways, criados em runtime) | supply chain e nenhuma UI exposta (erro do v1: Grafana e Argo CD públicos) | `helm-template-local`, `local-versions`, `platform/local/install.sh` (recusa SHA256 diferente) | bloqueante |
| LOC-04 | Políticas do Gatekeeper em `deny`, webhook `Fail` para o app, cada política com casos aceitos e recusados | v1 deixava tudo em `dryrun` sem audit | `policy-gator`; sonda `policies` do `e2e` | bloqueante |
| LOC-05 | Toda peça da plataforma local tem uma sonda com tráfego ou chamada real; o `e2e` sempre destrói e confere sobras | só se afirma o que foi provado | `platform/local/check.sh`, `scripts/local-lab.sh e2e` | bloqueante (no job `e2e`) |
| LOC-06 | O lab local confere a máquina antes de criar algo (daemon do CLI = daemon do provider, rede do lab sem sobrepor rede ou rota da máquina, porta do registry livre) e nunca age num lab que o seu `LOCAL_STATE_DIR` não criou; `make clean` só mexe sob o diretório do Makefile | quem faz fork roda o lab na própria máquina, com VPN, outros contêineres e outro lab | check `local-preflight` (`scripts/tests/local-preflight.sh`, `docker`, `kind` e `ip` simulados); `scripts/local-lab.sh` (`preflight`, `require_own_lab`); `Makefile` | bloqueante |
| MUD-01 | `main` protegido por ruleset: PR obrigatório, checks `static` e `test` estritos, sem force-push | toda mudança passa pelo harness | `.github/rulesets/main.json` + `scripts/repo-guardrails.sh` | bloqueante (depois de publicado) |
| MUD-02 | Ignore de scanner só com `statement` e `expired_at` em até ~7 meses | exceções revisadas | `trivyignore-policy` | bloqueante |
| MUD-03 | Conventional Commits; um assunto por PR; CHANGELOG `[Unreleased]` atualizado | histórico legível | template de PR | processo |
| DOC-01 | README e docs só afirmam o que é verificado, com os rótulos exatos | honestidade (erro do v1) | `repo-structure` (rótulos e auto-elogios); revisão | bloqueante |
| DOC-02 | Docs atualizadas na mesma mudança do código | docs não envelhecem | template de PR | processo |
| AGT-01 | Agentes de IA nunca executam ações que alteram a nuvem sem pedido humano explícito na tarefa | dinheiro e segurança | `AGENTS.md` | processo |
| AGT-02 | Agentes não enfraquecem gates nem adicionam ignores sem justificativa e validade | o harness só vale se for respeitado | `AGENTS.md`; checks acima | processo |
| AGT-03 | Agentes param e perguntam nos casos listados em `AGENTS.md` | decisões caras são humanas | `AGENTS.md` | processo |

## Exceções

Uma exceção é um ignore de scanner. Para adicionar uma:

1. Confirme que o achado é uma escolha deliberada do lab (não um defeito a corrigir).
2. Adicione a entrada em `.trivyignore.yaml` com `id`, `paths` (o mais restrito possível),
   `statement` (por que é aceitável e o que compensa o risco) e `expired_at` em até ~7 meses.
3. Explique a exceção no PR. O check `trivyignore-policy` rejeita entradas sem justificativa, sem
   validade, vencidas ou longas demais; o trivy deixa de aplicar uma entrada vencida.

Exceções atuais (verificado em 2026-10-10): `AWS-0040` e `AWS-0041` (endpoint público restrito por
CIDR), `AWS-0132` (bucket de state com SSE-S3 em vez de CMK), `KSV-0056` (deployer cria Services,
Ingresses e NetworkPolicies, exigido pelo contrato). Achados MEDIUM/LOW conhecidos e aceitos, que não
falham o scan: backup de 1 dia (`AWS-0077`), deletion protection desligada (`AWS-0177`), Performance
Insights desligado (`AWS-0133`), access logging do bucket de state (`AWS-0089`) e leitura de secrets
pelo deployer (`KSV-0113`).

## Limites (o que NÃO é garantido)

- Nada do v2 rodou na AWS: os testes usam um provider AWS mockado e provam a configuração, não que a
  AWS aceita cada chamada nem que os recursos funcionam juntos.
- O papel `tx01v2-gha-apply` é, na prática, equivalente a administrador da conta: pode criar papéis e
  políticas `tx01v2-*` com qualquer permissão. Por isso: conta AWS dedicada, environment `lab` com
  revisor obrigatório e deploy só a partir de `main`. Um permission boundary está `planejado`.
- O ID da conta aparece em logs públicos de workflows (ARN do papel como input, nome do bucket).
  A AWS não trata account IDs como segredo, mas use uma conta dedicada. `mask-aws-account-id` mascara
  o que vem depois da autenticação, e o resumo do plan troca o ID por `<ACCOUNT_ID>`.
- Variáveis de repositório (`LAB_*`) aparecem nos logs. Não coloque nelas nada privado.
- O budget só avisa; ele não para recursos. Interrupções Spot podem derrubar nós.
- A política IAM do LBC é a do upstream, com recursos `*` limitados por condições de tag.
- `scripts/leftovers.sh` cobre os serviços que o lab usa; recursos criados à mão fora disso não.
- O schema do ClusterSecretStore no kubeconform é de 2026-06-02 (ver `docs/HARNESS.md`).
- O lab local prova a plataforma num nó kind, não na AWS; o cloud-provider-kind usa o socket do Docker
  (cria contêineres): rode o lab local só numa máquina descartável ou no CI (`docs/LAB_LOCAL.md`).
- Os namespaces `istio-system`, `monitoring-agents` e `chaos-mesh` do lab local são `privileged` por
  necessidade dos componentes; o webhook do Gatekeeper não avalia os namespaces da plataforma (para que
  ela suba mesmo com o Gatekeeper fora do ar).

## Como verificar

```bash
make tools                 # ferramentas fixadas em .tools/
HARNESS_STRICT=1 make verify
scripts/harness.sh list    # todos os checks e estágios
AWS_REGION=us-east-1 scripts/leftovers.sh   # depois de um destroy (precisa de credenciais)
```
