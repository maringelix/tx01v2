# Publicação do tx01v2

Checklist para tornar o repositório público com as proteções do padrão v2. Siga na ordem; cada item
tem o comando ou o lugar onde é verificado.

## Antes de publicar

- [ ] `HARNESS_STRICT=1 make verify` verde no devcontainer ou em Linux.
- [ ] Primeiro commit feito e enviado para `main` (privado) e CI verde (`static`, `test`).
- [ ] `gitleaks git` limpo no histórico completo (o check `gitleaks` faz isso quando há commits).
- [ ] Nenhum identificador real: `policy-identifiers` verde e uma leitura humana de `docs/`.
- [ ] `docs/LICOES_APRENDIDAS.md` presente (produzido à parte; o README e este índice já apontam
      para ele).
- [ ] Matriz de status do README conferida: `verificado localmente` só vira `verificado no CI` depois
      do primeiro CI verde; tudo de nuvem continua `não executado em nuvem (v2)` até um
      `cloud_run_report`.
- [ ] Descrição e tópicos do repositório (`gh repo edit maringelix/tx01v2 --description ... --add-topic terraform`).

## Publicar

- [ ] `gh repo edit maringelix/tx01v2 --visibility public --accept-visibility-change-consequences`
- [ ] `scripts/repo-guardrails.sh maringelix/tx01v2`: alertas de vulnerabilidade, security updates do
      Dependabot, squash-only, `delete_branch_on_merge`, `GITHUB_TOKEN` só leitura por padrão (sem
      aprovar PRs), ruleset `main`, secret scanning + push protection, private vulnerability
      reporting e environment `lab` (revisor: o dono; só `main`). O script imprime o que foi
      aplicado, pulado e o que falhou.
- [ ] Settings > Actions > General: aprovação obrigatória para workflows de PRs de forks de
      colaboradores externos (manual).

## Ruleset `main` (`.github/rulesets/main.json`)

- Bloqueia deleção e force-push; exige PR (0 aprovações para mantenedor solo, `dismiss_stale_reviews_on_push`,
  `required_review_thread_resolution`), merge só squash.
- Checks obrigatórios (modo estrito, app GitHub Actions): `static` e `test`.
- Bypass: papel de admin do repositório, modo `pull_request` — **só para emergência** (por exemplo,
  um check quebrado por fator externo bloqueando uma correção de segurança). Registre o motivo no PR.

## Ids de jobs estáveis

Mudar um id quebra a proteção. Ids atuais:

| Workflow | Job | Exigido pelo ruleset |
|---|---|---|
| `ci.yml` | `static` | sim |
| `ci.yml` | `test` | sim |
| `terraform-plan.yml` | `plan` | não (só roda com `AWS_PLAN_ROLE_ARN`) |
| `terraform-apply.yml` | `apply` | não |
| `platform.yml` | `platform` | não |
| `terraform-destroy.yml` | `destroy` | não |

## Depois de publicar

- [ ] CI verde em `main` público e badge funcionando; atualize a matriz (`verificado no CI`).
- [ ] Variáveis de repositório só depois do bootstrap (`docs/RUNBOOK.md`, seção 3).
- [ ] Primeira rodada em nuvem registrada com `cloud_run_report`.
