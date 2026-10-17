# Harness do tx01v2

O harness é o conjunto de checks que prova o que este repositório afirma, sem conta na nuvem.
Ele vive em `scripts/harness.sh`; o `Makefile` e o CI só o chamam. O que passa localmente com
`HARNESS_STRICT=1` passa no CI.

## Camadas

| Camada | Comando | O que prova | O que NÃO prova | Onde roda |
|---|---|---|---|---|
| Ferramentas | `make tools` | binários nas versões de `tools/versions.env`, SHA256 conferido | — | local, CI |
| Versões | check `tool-versions` | PATH usa as versões fixadas (estrito) | — | local, CI |
| Estrutura e honestidade | `repo-structure`, `version-consistency` | arquivos obrigatórios, rótulos de status, LF, versões coerentes entre arquivos, política do LBC idêntica ao upstream | que a documentação está certa | local, CI |
| Políticas | `policy-terraform`, `policy-identifiers`, `policy-workflows`, `policy-scripts`, `trivyignore-policy`, `contract-platform` | erros do v1 não voltam; sem IDs reais; actions fixadas; scripts que só agem no lab (sem alvo vindo de variável de ambiente, kubeconfig temporário, tag `Project` conferida, contexto do kind no lab local); ignores com validade; manifests conforme o contrato | intenção de quem escreveu | local, CI |
| Formato e sintaxe | `terraform-fmt`, `terraform-validate:*` | HCL formatado e válido para o schema do provider fixado | que a AWS aceita os valores | local, CI |
| Lock de providers | `terraform-lockfiles` | hashes para linux_amd64, linux_arm64, darwin_arm64, windows_amd64 | — | local, CI |
| Lint | `tflint` | preset recommended + regras AWS sem issues | regras que dependem de chamadas à AWS (deep check desligado) | local, CI |
| Segurança da IaC | `trivy-config`, `trivy-config-tfvars` | sem HIGH/CRITICAL fora das exceções documentadas | configuração em runtime, IAM efetivo | local, CI |
| Fluxos dos scripts, offline | `destroy-flow`, `local-preflight` | um uninstall que falha ainda leva à limpeza pela API, ao `terraform destroy` e à checagem de sobras; o lab local recusa uma máquina com daemons diferentes, rede ou rota sobreposta ou porta ocupada, e nunca age num lab de outro `LOCAL_STATE_DIR` | comportamento contra a AWS ou o Docker de verdade (CLIs simuladas) | local, CI |
| Workflows e scripts | `actionlint` (com shellcheck), `shellcheck` | YAML e bash corretos | comportamento contra a nuvem | local, CI |
| Manifests | `kubeconform` | core, full e chart `platform/gitops` renderizados válidos (estrito) para Kubernetes 1.36 e CRDs fixados | admission e comportamento no cluster | local, CI (rede) |
| Charts da plataforma | `helm-template` | os charts fixados (LBC 3.6.0, ESO 2.12.0) aceitam `platform/values` e renderizam imagens por digest, service accounts do Pod Identity, feature gates e tags | instalação real e comportamento dos controllers | local, CI (rede) |
| Segredos | `gitleaks` | nenhum segredo conhecido (histórico completo quando há commits) | segredos fora dos padrões do gitleaks | local, CI |
| Testes unitários | `terraform-test:bootstrap`, `terraform-test:envs/lab` | trust OIDC, bucket, budget, EKS, nós, add-ons, Pod Identity, RDS sem senha no state, ECR, WAF, KMS, SSM do contrato, validações negativas | que os recursos sobem na AWS (provider mockado) | local, CI |
| Lab local: Terraform | `terraform-validate:envs/local`, `terraform-test:envs/local` (10 runs, só plan) | rede privada, labels em tudo, só o registry publicado e só em 127.0.0.1, banco só TLS, imagens por digest, validações negativas | que o Docker cria os contêineres (isso é o `e2e`) | local, CI |
| Lab local: plataforma | `local-versions`, `helm-template-local`, `kubeconform-local`, `policy-gator` | os 17 charts fixados por SHA256 renderizam só imagens por digest e Services ClusterIP, também com os overlays do tamanho `small` (`platform/local/values/small`), que não podem trocar imagens; manifests válidos; cada política do Gatekeeper aceita e recusa os casos de `platform/local/policies/tests` | comportamento no cluster | local, CI (rede) |
  | Plataforma AWS `full` | `helm-template-full`, `contract-platform`, `platform-sizing`, `kubeconform`, `policy-gator`, `image-admission-policy`, `full-install-order` | os 16 charts por versão/SHA256, imagens por digest, overlays AWS, PVCs gp3 e retenção dos sinais, mesh waypoint, AppProject do Argo CD, bucket Velero, policies Gatekeeper/Kyverno, manifests, soma de requests para dois nós e Pod Identity de Trivy, Kyverno e EBS CSI; admission precede a sincronização do Argo CD | instalação e comportamento na AWS; leitura de imagens privadas, assinaturas ECR e persistência após reinício em runtime | local, CI (rede) |
| Teardown de observabilidade | `observability-cleanup` | claims derivados dos StatefulSets dos três releases do lab e seleção de PVs EBS pelo namespace e nome exatos do PVC; claims de outros namespaces, nomes ou drivers não entram na espera | exclusão real pelo EBS CSI | local, CI |
| Caminho do fork | `fork-references`, `fork-profiles` | scripts, alvos `make`, workflows e variáveis citados no `FORK.md` e `docs/RUNBOOK.md` existem ou estão ligados ao Terraform/workflows; render offline de `core`/`full`, substituição do dono do fork e recusa de owner, perfil e região inválidos antes de qualquer chamada cloud | se os valores da conta do operador estão corretos | local, CI |
| Lab local: ponta a ponta | `local-lab-e2e` (`make e2e`) | apply do `terraform/envs/local`, instalação do perfil `full` e as 39 sondas de `platform/local/check.sh` (`docs/LAB_LOCAL.md`), incluindo HTTP-01, renovação ACME automática, OWASP CRS para SQLi e rate limit; destroy e checagem de sobras sempre | AWS; a CA Pebble e o WAF local são gêmeos de teste, não serviços cloud homologados | local (Docker, 8 GB), CI |
| Nuvem | workflows `terraform-*`, `platform` | — | — | `não executado em nuvem (v2)` |

## Jobs do CI

| Job (`ci.yml`) | Alvo | Estágio do harness |
|---|---|---|
| `static` | `make tools && make static` | `static` |
| `test` | `make tools && make test` | `test` |
| `e2e` | `make tools && make e2e` | `e2e` (o lab local; diagnósticos como artifact em caso de falha) |

Os ids `static`, `test` e `e2e` são estáveis: são os checks exigidos pelo ruleset
(`.github/rulesets/main.json`; o `e2e`, o lab local, entrou em 2026-10-13).

## Modo estrito

`HARNESS_STRICT=1` (definido no CI) transforma todo `SKIP` em `FAIL` e exige que as versões no PATH
sejam as de `tools/versions.env`. Sem ele, um check só pode dar `SKIP` quando falta um pré-requisito
local (por exemplo, ferramenta não instalada) e sempre imprime o motivo.

Outras variáveis: `HARNESS_VERBOSE=1` mostra a saída dos checks que passam; `HARNESS_ONLY=<regex>`
roda só os checks cujo nome casa com a expressão (depuração local, por exemplo
`HARNESS_ONLY='^tflint$' scripts/harness.sh static`; o CI nunca usa).

## Como adicionar um check

1. Escreva uma função `check_<nome>` em `scripts/harness.sh` que retorna 0 (PASS) ou não-zero (FAIL);
   use `need <ferramenta>` ou `skip "<motivo>"` só para pré-requisitos ausentes.
2. Registre-a em `register_checks` no estágio certo (`static` ou `test`).
3. Rode `scripts/harness.sh list` e `HARNESS_STRICT=1 make verify`.
4. Atualize esta tabela, `docs/GUARDRAILS.md` (se for um guardrail) e o CHANGELOG.

Ferramenta nova: adicione-a a `scripts/lib/tools.sh` (URLs oficiais), a `tools/versions.env` e rode
`scripts/update-tool-checksums.sh <ferramenta> <versão>`.

## Windows e macOS

- Windows: use o devcontainer (`.devcontainer/devcontainer.json`, imagem fixada por digest) ou WSL 2
  com Ubuntu. Git Bash não é suportado (as ferramentas são binários Linux/macOS).
- macOS (Apple Silicon): `brew install bash` (o bash 3.2 do sistema não serve; o harness exige
  bash >= 4.4) ou o devcontainer. Plataformas suportadas pelo `install-tools.sh`: linux_amd64,
  linux_arm64, darwin_arm64.
- Container avulso (como a verificação local deste repositório):
  `docker run --rm -e HARNESS_STRICT=1 -v "$PWD:/work" -w /work ubuntu:24.04 bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates curl unzip git xz-utils make >/dev/null && make tools && make verify"`
  (adicione `-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=*` se o dono dos arquivos for outro usuário).

## Dados fora do repositório

O harness grava dados do Terraform (`TF_DATA_DIR`), logs e caches em `HARNESS_WORK_DIR` (padrão
`$TMPDIR/tx01v2-harness`) e usa o cache de plugins `TF_PLUGIN_CACHE_DIR` (padrão
`~/.terraform.d/plugin-cache`, também cacheado no CI). No repositório ficam só `.tools/` e os lock
files dos módulos (ignorados pelo git). `make clean` remove tudo isso.

## Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `SKIP tool-versions - missing tools` | `make tools` não rodou | `make tools` |
| `FAIL terraform-validate:terraform/envs/lab` com erro de lock | provider mudou sem atualizar o lock | `terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=windows_amd64` no root |
| `FAIL trivyignore-policy ... expired` | ignore venceu | revise a exceção: corrija o código ou renove com nova justificativa |
| `FAIL kubeconform ... could not find schema` | sem rede, ou schema do catálogo que o kubeconform não compila | confira a rede; veja a nota abaixo |
| `FAIL gitleaks` | segredo ou falso positivo | remova o segredo e gire a credencial; falso positivo vai para `.gitleaksignore` com justificativa no PR. Antes do primeiro commit o check roda `gitleaks dir .`, que também lê arquivos ignorados pelo git (`terraform.tfvars`, `.env`): mantenha credenciais locais fora da pasta do repositório |
| `FAIL policy-identifiers` | ID de conta, e-mail ou IP real | use `123456789012`, `you@example.com`, `203.0.113.10/32` |

Nota sobre o kubeconform (verificado em 2026-10-10): a revisão de 2026-10-08 de
`external-secrets.io/clustersecretstore_v1.json` no datreeio/CRDs-catalog (gerada do ESO 2.12) contém
`"additionalProperties": false` dentro de um mapa `properties` (provider `crd`), e o kubeconform não
consegue compilá-la ("could not find schema"). O harness usa a revisão anterior (commit
`f3e4382`, 2026-06-02), que valida o ClusterSecretStore deste repositório em modo estrito (um campo
com erro de digitação é rejeitado). Reavalie a cada atualização trimestral do harness
(`docs/SUSTENTACAO.md`).

## R10: capacidade e FinOps

Veja [FinOps e escala](FINOPS.md) para kind HA, carga/HPA/PDB, Cluster Autoscaler, OpenCost, VPA Off, Spot opt-in, pre?os regionais, or?amento/expira??o e limpeza. O perfil com pool Spot dedicado preserva on-demand e altera custo; defaults baratos permanecem. Nada executado na nuvem (v2).
