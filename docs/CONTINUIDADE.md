# Continuidade de dados no lab AWS (R9)

## Prova adicional de PVC pelo Velero

O CI local executa `scripts/local/volume-restore-drill.sh`: grava bytes num volume
`local` do kind por um Pod restrito, exige `PodVolumeBackup Completed`, remove o
namespace/PVC/PV e os dados originais, e restaura. Só passa com PVC de novo UID,
`PodVolumeRestore Completed` e SHA256 idêntico. Restaurar apenas um ConfigMap ou um
PVC vazio não atende a esse check. A execução pesada fica no GitHub Actions.

O FSB precisa de root/hostPath no namespace Velero local; o servidor continua non-root
e a aplicação mantém Pod Security `restricted`. A senha aleatória do repositório
Kopia é criada antes do primeiro backup e preservada nas reinstalações. Não publique
essa senha nem os backups de Secrets. EKS usa FSB/data mover para cópias portáveis;
o resultado kind não certifica a recuperação gerenciada nem a durabilidade regional.

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

## Runtime e recuperação regional

O perfil `dr` provisiona outra VPC/EKS, RDS read replica privado e criptografado,
ECR, WAF, ACM regional, contrato SSM e Velero em us-west-2 (configurável). A origem
continua Multi-AZ. Antes do incidente, instale ambas as plataformas, promova os
digests assinados ao registry secundário e confirme a réplica e os segredos atuais.
Secrets Manager replica valores existentes com KMS regional, mantendo os nomes;
o DX usa o endpoint RDS do contrato v7 para substituir somente DB_HOST.

O S3 de origem e o destino de recuperação têm versioning. A role de replicação
acessa apenas um bucket de origem, um destino e as chaves regionais respectivas;
delete markers não são propagados. A identidade Velero DR lê o bucket de recuperação
e grava apenas no seu bucket próprio. A BSL `primary-recovery` é ReadOnly.
Live replication copia objetos novos, não o histórico anterior à configuração:
execute um backup novo, aguarde ReplicationStatus COMPLETED e confira o checksum
no destino antes de declarar recuperação possível. Não prometa RPO zero.

Defina `enable_state_dr=true` no bootstrap para uma segunda cópia versionada do
state, protegida contra remoção automática. A cópia assíncrona não cria outro
backend ativo. Recupere a versão escolhida em diretório privado, compare lineage/
serial e faça fencing do apply anterior antes de migrar o backend. Nunca publique
state nem faça state push sem revisão.

Configure `LAB_VELERO_REPOSITORY_PASSWORD` no environment com 64 caracteres hex
aleatórios e mantenha escrow privado fora das regiões. O mesmo segredo é exigido
na primeira instalação das duas regiões; uma chave divergente é recusada. Não
rotacione a chave Kopia depois de criar o repositório. O namespace Velero permite
root/hostPath apenas para o node agent; aplicação continua restricted. FSB copia
arquivos vivos: quiesça aplicações que precisam de consistência transacional ou use
seus mecanismos nativos. PostgreSQL gerenciado continua com RDS/PITR separado.
Lifecycle por idade limita-se a `backups/`; os chunks Kopia dependem de seu GC.

Instale `platform/install.sh --profile full --github-owner OWNER --target secondary`
com AWS_REGION da região DR. O GitOps usa `gitops/aws-dr`; ExternalDNS nasce com
zero réplicas. Após fencing comprovado do primário, promoção humana do RDS e smoke
HTTPS/escrita no endereço secundário, repita com `--activate-dns` (ou o input do
workflow). Um segundo deploy não deve reativar o escritor primário.

O uninstall pausa seu ExternalDNS e remove A/TXT somente se o alias ainda aponta
para um ALB daquele cluster. Um alias de outra região e mudanças concorrentes são
preservados. O destroy trata os dois clusters/regiões antes da IaC e inventaria
sobras nos dois destinos. Para failback, faça reseed a partir do escritor atual,
confira lag/dados, congele escrita e cerque o secundário antes de trocar a rota.
Revise a topologia Terraform após promoção; não reaplique cegamente a configuração
de réplica sobre a nova principal.

Os alertas Velero de idade (>30 h) e restore malsucedido seguem o Slack configurado.
CloudWatch acompanha ReplicaLag >60 s por cinco períodos; associe a notificação
desejada no exercício cloud. Ausência de telemetria não prova recuperação possível.
Registre um restore isolado recente com checksum, registros e RPO/RTO. Os destinos
de recuperação usam force_destroy=false: antes do teardown, decida o que arquivar/
apagar e preserve também suas chaves KMS. Um bucket retido perde utilidade se a
chave que o cifra for excluída. Nenhuma ação gerenciada desta rodada rodou na AWS.

Fontes: [backups/PITR do RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html),
[replicação entre regiões](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReplicateBackups.html),
[custos RDS](https://aws.amazon.com/rds/pricing/).
