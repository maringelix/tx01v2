# Continuidade de dados no lab AWS (R9)

Este exercício separa quatro coisas que têm modos de falha diferentes: HA do RDS, backups nativos do
banco, backup de objetos/volumes do Kubernetes e recuperação da aplicação. O Velero não restaura um
RDS gerenciado. Nenhuma operação desta página foi executada numa conta AWS v2; os testes Terraform
usam provedores simulados, e o exercício de PostgreSQL roda somente no Docker/Actions.

## Perfis do banco

| `db_profile` | Banco principal | Backup/PITR | Destino |
|---|---|---|---|
| `core` (padrão) | RDS single-AZ | 1 dia por padrão | nenhum |
| `ha` | RDS Multi-AZ | pelo menos 7 dias | mesma região |
| `dr` | RDS Multi-AZ | pelo menos 7 dias; snapshots e logs replicados | `dr_region`, diferente da primária |

O perfil é opt-in pela variável de repositório `LAB_DB_PROFILE`. `LAB_DR_REGION` seleciona o destino;
as variáveis `LAB_DB_BACKUP_RETENTION_DAYS`, `LAB_DB_DELETION_PROTECTION`,
`LAB_DB_SKIP_FINAL_SNAPSHOT` e `LAB_DB_DELETE_AUTOMATED_BACKUPS` controlam retenção e teardown.
Use o mesmo conjunto no plan, apply e destroy. O código rejeita `dr` com origem e destino iguais.
`terraform test` verifica os três perfis, a chave KMS de destino, a replicação, a retenção mínima e
os valores recusados.

`ha` e `dr` não ligam a proteção contra exclusão por padrão: este é um lab temporário que deve poder
ser destruído. Se `LAB_DB_DELETION_PROTECTION=true`, primeiro planeje/aplique a desativação para
`false`, confirme que ela entrou em vigor e só depois execute o destroy. Se optar por snapshot final
ou manter backups automatizados depois da exclusão, inventarie e remova esses itens quando não forem
mais necessários; eles continuam faturáveis e fora do ciclo normal do lab.

## Exercício local de PITR físico

`scripts/local-lab.sh e2e` chama `platform/local/check.sh`, que executa
`scripts/local/pitr-drill.sh`. Ele usa a imagem PostgreSQL 17 fixada por digest e os volumes
rotulados do lab para:

1. Gravar `baseline`, tirar `pg_basebackup` físico e validar `backup_manifest` com `pg_verifybackup`.
2. Gravar `keep`, criar um restore point no WAL e aguardar a cópia do segmento arquivado.
3. Gravar `lost` e apagar `keep` na origem, provando que o estado atual foi danificado.
4. Corromper uma cópia do backup e exigir que `pg_verifybackup` a recuse.
5. Restaurar uma instância isolada com backup + WAL até o restore point, promover e exigir
   `baseline,keep` sem `lost`, medindo o tempo de recuperação (meta local: 180 s).

A sonda apaga apenas sua tabela e o contêiner/volume temporários. Os volumes de backup e WAL do lab
são apagados pelo `scripts/local-lab.sh down`; `scripts/leftovers-local.sh` acusa qualquer sobra.
Este teste mede restauração de dados, não a duração de um failover Multi-AZ da AWS.

## Restore gerenciado e troca de endpoint

No RDS, PITR cria **outra instância** a partir dos backups nativos. Antes de qualquer troca, o
operador deve conferir a região, o intervalo restaurável, o ARN da origem, a chave KMS, a rede privada
do destino e uma amostra dos registros. Durante a troca, mantenha um único escritor: interrompa
escritas no primário, restaure para uma instância isolada e valide a aplicação contra ela antes de
alterar o segredo/endpoint usado pelo deploy. Se a validação falhar, mantenha o endpoint anterior e
não promova um banco divergente. Depois da troca, registre o último commit disponível, o momento da
falha e da recuperação para medir RPO/RTO observados, e trate o primário antigo como somente leitura
até a reconciliação. Os comandos e gates de aplicação entram no par `dx01v2` R9.

A replicação automatizada entre regiões no perfil `dr` é um pilot light de dados: ela **não** cria
um cluster EKS ou banco em execução no destino. Para DR completo ainda são necessários runtime,
artefatos, segredos/configuração, roteamento e um ensaio de perda da região primária seguido de
failback. O planejamento e o custo dessa etapa estão no [roadmap](https://github.com/maringelix/tx00v2/blob/main/ROADMAP.md).

Fontes: [backups/PITR do RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html),
[replicação entre regiões](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReplicateBackups.html),
[custos RDS](https://aws.amazon.com/rds/pricing/).
