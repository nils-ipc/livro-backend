# Backup e recuperação de desastres

## O backup de 20 bytes

Quarta-feira, 15h41. Na escola de natação Braçada Firme, um script chamado `limpa_dados_de_teste.py` faz exatamente o que o nome promete, só que no banco errado: a variável `DATABASE_URL` do terminal ainda apontava para produção desde a manhã. Em 0,8 segundo, 14.212 matrículas deixam de existir. A tabela `alunos` continua lá, intacta e inútil, cheia de pessoas que não estão matriculadas em nada.

Ninguém entra em pânico: existe backup. Às 3h, um cron faz isto:

```bash
pg_dump -h db-prod natacao | gzip > /backups/natacao-$(date +%F).sql.gz
```

A pessoa de plantão abre a pasta `/backups` e encontra 214 arquivos, um por dia, todos com exatamente 20 bytes. Vinte bytes é o tamanho de um arquivo gzip vazio: cabeçalho, um bloco comprimido sem conteúdo e o rodapé com CRC e tamanho. Em agosto, alguém atualizou o banco para o PostgreSQL 16, e o servidor de backup continuou com o `pg_dump` 15:

```text
pg_dump: error: aborting because of server version mismatch
pg_dump: detail: server version: 16.4; pg_dump version: 15.8
```

O `pg_dump` falhou com código 1. O `gzip` comprimiu com sucesso o nada que recebeu e saiu com código 0. Num pipeline do bash, o código de saída é o do último comando, então o cron registrou 214 sucessos seguidos. O backup estava funcionando perfeitamente; só não continha nada.

A escola perdeu sete meses de matrículas? Depende de coisas que ninguém tinha decidido: quanto dado a empresa aceita perder, quanto tempo aceita ficar parada e se alguém algum dia restaurou um backup para ver se ele volta. O resto deste capítulo responde a essas três perguntas, e a última é a que mais dói.

## RPO e RTO, os dois números que ninguém escreveu

Toda decisão de backup se reduz a dois números.

O **RPO** (*recovery point objective*) é a quantidade máxima de dados que você aceita perder, medida em tempo. RPO de 24 horas quer dizer que, depois de um desastre, voltar ao estado de ontem às 3h é aceitável. RPO de 5 minutos quer dizer que perder mais que os últimos 5 minutos de escritas é inaceitável.

O **RTO** (*recovery time objective*) é o tempo máximo entre o desastre e o sistema funcionando de novo. Inclui perceber o problema, decidir o que fazer, provisionar máquinas, copiar dados, reaplicar logs, validar e redirecionar o tráfego.

```text
          último ponto          desastre                       sistema
          recuperável           15h41                          de volta
   ───────────┼───────────────────┼──────────────────────────────┼────────▶ tempo
              │◀───── perda ─────▶│◀──────── indisponível ──────▶│
                (comparar com RPO)        (comparar com RTO)
```

Cada um tem duas versões: a meta escrita e o valor que o sistema entrega. A Braçada Firme tinha como meta implícita "a gente tem backup", e o RPO real era de sete meses. O RTO real era desconhecido (restaurar 20 bytes é rápido; a parte demorada viria depois).

O RPO depende da frequência com que os dados saem do servidor. O RTO depende do volume, da banda e da quantidade de passos manuais. Um backup diário de 2 TB tem RPO de até 24 horas, e restaurá-lo a 500 MB/s leva uns 70 minutos só de cópia, antes de qualquer validação. Essa conta, feita antes do desastre, costuma mudar a meta de alguém.

## Completo, incremental e diferencial

Um **backup completo** copia todos os dados. Ele é autossuficiente: restaurá-lo exige só ele. O custo é copiar tudo toda vez, inclusive os 98% que não mudaram desde ontem.

Um **backup incremental** copia só o que mudou desde o backup anterior, de qualquer tipo. Ele é pequeno e rápido de fazer, e caro de restaurar: voltar a sexta-feira exige o completo de domingo e os incrementais de segunda a sexta, aplicados em ordem. Se o de quarta estiver corrompido, quinta e sexta viram arquivos decorativos.

Um **backup diferencial** copia tudo o que mudou desde o último completo. Cresce ao longo da semana, mas a restauração exige no máximo dois arquivos: o completo e o diferencial mais recente.

| Tipo | Tamanho de cada cópia | Arquivos para restaurar | Risco da cadeia |
|------|----------------------|-------------------------|-----------------|
| Completo | Tudo | 1 | Nenhum |
| Diferencial | Cresce desde o completo | 2 | Depende só do completo |
| Incremental | Só a mudança do dia | 1 + N | Qualquer elo corrompido quebra o resto |

O PostgreSQL 17 trouxe incremental físico nativo: com `summarize_wal = on`, o `pg_basebackup --incremental` copia só os blocos alterados, e o `pg_combinebackup` junta a cadeia num diretório restaurável. pgBackRest, Barman e WAL-G fazem isso há anos, com compressão e envio para armazenamento de objetos.

### Lógico ou físico

O `pg_dump` faz um **backup lógico**: gera o SQL (ou um formato próprio) que recria schema e dados, dentro de uma transação `REPEATABLE READ`, consistente no instante em que começou. É portável entre versões e permite restaurar uma tabela só. O preço aparece na restauração, que reinsere cada linha e reconstrói cada índice: um banco de 500 GB leva horas para sair e bem mais horas para voltar.

O **backup físico** (`pg_basebackup`, snapshot de disco) copia os arquivos do diretório de dados, bloco a bloco. Restaurar é copiar arquivos e iniciar o servidor. Só serve para a mesma versão principal do PostgreSQL e a mesma arquitetura, e é ele que permite o backup contínuo da próxima seção.

### Consistência

Copiar os arquivos de um banco em funcionamento produz uma cópia em que o arquivo A foi lido às 3h00 e o B às 3h07, com escritas no meio. O PostgreSQL tolera isso porque o backup físico registra o ponto do WAL (*write-ahead log*, onde toda alteração é gravada antes de ir para as tabelas) em que começou, e a restauração reaplica o WAL desde ali. Sem os segmentos de WAL do período da cópia, o backup físico é inútil; o `pg_basebackup` os inclui por padrão.

Snapshots de disco da nuvem são **consistentes em caso de queda** (*crash-consistent*): equivalem ao disco de um servidor que perdeu a energia naquele instante, e o PostgreSQL se recupera com o mesmo replay, desde que todos os volumes do banco entrem no mesmo snapshot atômico. Dados num volume e WAL em outro, fotografados com dois segundos de diferença, produzem um banco que não sabe que dia é hoje.

## Backup contínuo e point-in-time recovery

No backup diário, o RPO é o intervalo entre backups. Para baixar de 24 horas para minutos, guarda-se também o WAL que vem depois da fotografia.

O mecanismo do **point-in-time recovery** (PITR) tem duas partes:

1. Um backup físico base, feito de tempos em tempos (todo dia ou toda semana).
2. O arquivamento contínuo do WAL. A cada segmento de WAL completo (16 MB por padrão), o PostgreSQL chama o `archive_command` (ou o módulo de `archive_library`) para copiá-lo para fora do servidor. O segmento só é reciclado depois que o comando retorna 0.

Para restaurar, você parte do backup base, configura um `restore_command` que busca segmentos no arquivo e um alvo de recuperação: `recovery_target_time`, `recovery_target_xid`, `recovery_target_lsn` ou `recovery_target_name`. O servidor reaplica cada transação do log, em ordem, até chegar ao alvo, e para. Qualquer instante entre o backup base e o último segmento arquivado vira recuperável, inclusive "um segundo antes do `DELETE`".

O RPO do PITR é o tempo que um segmento leva para encher e ser arquivado. Num banco movimentado, 16 MB enchem em segundos. Num banco com três matrículas por hora, um segmento passa a tarde aberto, e o conteúdo dele só existe no disco que acabou de pegar fogo. O `archive_timeout` força a troca de segmento depois de N segundos (com 60 s, RPO perto de um minuto, ao custo de segmentos quase vazios, que a compressão encolhe). Para chegar perto de zero, o `pg_receivewal` recebe o WAL por streaming, como uma réplica, e grava em outro lugar.

O RTO do PITR também tem conta. O replay do WAL roda num único processo. Com backup base de seis dias atrás e 40 GB de WAL por dia, a recuperação reaplica 240 GB antes de abrir as portas. Backups base mais frequentes diminuem o RTO; arquivamento mais frequente diminui o RPO. São botões diferentes, e confundi-los rende reuniões longas.

> **Armadilha:** a replicação copia o `DELETE FROM matriculas` para a réplica em milissegundos, com a mesma dedicação com que copia todo o resto. Réplica protege contra a perda de uma máquina (capítulo 13). Contra erro humano, bug ou ransomware, só um ponto no passado ajuda: PITR ou uma réplica com `recovery_min_apply_delay`, que aplica o WAL com atraso proposital.

## A regra 3-2-1 e o atacante com permissão de apagar

A regra **3-2-1**: **3** cópias dos dados (produção e mais duas), em **2** tipos de mídia ou sistemas de armazenamento diferentes, com **1** fora do local principal. Três cópias toleram a perda de duas. Dois meios impedem que um único bug de firmware ou um único fornecedor leve todas. A cópia externa sobrevive ao incêndio e ao datacenter que some do mapa.

Na nuvem, "outro local" é outra região, de preferência em outra conta, com credenciais que produção não possui. Um atacante (ou um script) com as credenciais de produção apaga o banco e, em seguida, os backups, quando a mesma chave pode as duas coisas. Daí a variação **3-2-1-1-0**: uma cópia imutável ou desconectada, e zero erros na verificação.

Imutabilidade, no armazenamento de objetos, é o modo WORM (*write once, read many*): o objeto recebe uma data de retenção e nem o dono da conta consegue apagá-lo antes dela. O S3 Object Lock em modo *compliance* e o armazenamento imutável do Azure Blob são exemplos. O custo é literal: um backup gravado com retenção de 90 dias será cobrado por 90 dias, mesmo que alguém mude de ideia no dia 2.

Backup criptografado traz mais uma dependência. Se ele foi cifrado com uma chave de um KMS (o capítulo 33 trata de *envelope encryption*), a chave precisa existir na região de recuperação e sobreviver ao incidente. Uma chave apagada, ou presa numa região indisponível, transforma o backup em ruído de alta entropia, cuidadosamente armazenado em três lugares.

## Quatro estratégias de recuperação de desastres

**Recuperação de desastres** (DR, *disaster recovery*) é o plano para pôr o sistema inteiro de pé em outro lugar quando o original deixa de existir: região fora do ar, conta comprometida, datacenter em chamas. A classificação mais usada, do whitepaper de DR da AWS e válida para qualquer provedor, tem quatro estratégias, em ordem crescente de custo:

- **Backup e restauração.** Na região secundária só existem backups. Num desastre, você cria rede, bancos e servidores do zero e restaura os dados.
- **Pilot light.** Uma réplica do banco recebe WAL na região secundária; a aplicação está com zero instâncias. Num desastre, você liga a aplicação e promove a réplica.
- **Warm standby.** O sistema completo roda na região secundária, em tamanho reduzido. Num desastre, você escala e redireciona o tráfego.
- **Ativo-ativo** (*multi-site*). As duas regiões atendem tráfego o tempo todo, e o balanceamento global tira a que tiver problema.

| Estratégia | RPO típico | RTO típico | Custo fixo na região secundária |
|------------|-----------|------------|--------------------------------|
| Backup e restauração | Horas (ou minutos com PITR entre regiões) | Horas | Armazenamento |
| Pilot light | Segundos a minutos (lag da réplica) | Dezenas de minutos | Banco replicado |
| Warm standby | Segundos a minutos | Minutos | Banco + aplicação reduzida |
| Ativo-ativo | Próximo de zero | Próximo de zero | Sistema inteiro, duas vezes |

O RPO das três primeiras com replicação assíncrona é o lag de replicação no momento do desastre: tudo o que foi confirmado no principal e ainda não chegou à réplica se perde. Replicação síncrona entre regiões zera essa perda e cobra um RTT entre regiões em cada commit (de São Paulo a Virgínia, uns 120 ms medidos).

O ativo-ativo tem um custo fora da fatura: duas regiões escrevendo no mesmo dado exigem replicação multi-líder com resolução de conflitos, ou dados particionados por região (capítulos 13 e 17). A alternativa comum, aplicação ativa nas duas e banco com líder único, é um warm standby com melhor marketing.

Em todas, o RTO depende de peças que ninguém lembrou de replicar: imagens no registry da região que caiu, segredos, certificados, o TTL do DNS (com 86.400 s, clientes procuram a região morta até amanhã). O código de infraestrutura (capítulo 36) encurta o "recriar a rede do zero" de dias para minutos, se já tiver sido aplicado alguma vez fora da região original.

## Na prática: voltando para 15h40

Suponha agora uma versão da Braçada Firme que fez o dever de casa: backup base diário com pgBackRest e arquivamento contínuo de WAL. A configuração do servidor:

```ini
# postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'pgbackrest --stanza=natacao archive-push %p'
archive_timeout = 60      # nenhum segmento fica aberto mais de 1 minuto
summarize_wal = on        # habilita backup incremental (PostgreSQL 17+)
```

O primeiro monitor de verdade é o `pg_stat_archiver`. Ele diz se o arquivamento está funcionando, o que o `ls` de 214 arquivos de 20 bytes não dizia:

```sql
SELECT archived_count, last_archived_wal, last_archived_time,
       failed_count, last_failed_time
FROM pg_stat_archiver;
```

```text
 archived_count |    last_archived_wal     |      last_archived_time       | failed_count | last_failed_time
----------------+--------------------------+-------------------------------+--------------+------------------
          48211 | 000000010000002A00000031 | 2026-03-18 15:40:52.018-03    |            0 |
```

O último segmento foi arquivado às 15h40m52s. Esse é o RPO real deste instante: menos de um minuto. Um alerta sobre `now() - last_archived_time` acima de alguns minutos, ou sobre `failed_count` crescendo, teria denunciado o backup de 20 bytes no primeiro dia de agosto (e também denuncia o disco de arquivamento cheio, a credencial expirada e a pessoa que trocou o nome do bucket "só para organizar").

Às 15h41 o `DELETE` acontece. A restauração cria um servidor novo a partir do backup base, com este alvo:

```ini
# postgresql.conf do servidor restaurado (+ arquivo vazio recovery.signal no diretório de dados)
restore_command = 'pgbackrest --stanza=natacao archive-get %f "%p"'
recovery_target_time = '2026-03-18 15:40:00-03'
recovery_target_action = 'promote'
```

O log mostra a recuperação parando no ponto pedido:

```text
LOG:  starting point-in-time recovery to 2026-03-18 15:40:00-03
LOG:  restored log file "000000010000002A0000001C" from archive
LOG:  redo starts at 2A/1C000028
LOG:  restored log file "000000010000002A0000001D" from archive
...
LOG:  recovery stopping before commit of transaction 918274, time 2026-03-18 15:40:03.512-03
LOG:  redo done at 2A/30FF1A90
LOG:  selected new timeline ID: 2
LOG:  archive recovery complete
LOG:  database system is ready to accept connections
```

A transação 918274 foi a primeira com commit depois de 15h40 e ficou de fora. Se o banco restaurado substituir produção, perdem-se as escritas legítimas entre 15h40 e a troca; por isso, quando o estrago é numa tabela só, o comum é copiar as 14.212 matrículas do servidor restaurado para produção. A *timeline* 2 marca que este servidor seguiu outra história, e o PostgreSQL usa esse número para não misturar o WAL das duas.

## Testes de restauração

Um backup que nunca foi restaurado é uma hipótese. A única forma de saber o RPO e o RTO reais é restaurar, de forma automática e periódica, e medir. Um teste mínimo, agendado toda madrugada, restaura o backup mais recente num banco descartável e confere se o resultado tem cara de banco de produção:

```python
import os
import subprocess
import time
from datetime import datetime, timezone

import psycopg

DESTINO = os.environ["RESTORE_TEST_URL"]  # banco descartável; nunca produção
ARQUIVO = "/backups/natacao-2026-03-18.dump"  # formato custom do pg_dump (-Fc)

inicio = time.monotonic()
subprocess.run(
    ["pg_restore", "--clean", "--if-exists", "--no-owner",
     "--jobs", "4", "--dbname", DESTINO, ARQUIVO],
    check=True,  # falha do pg_restore vira exceção, não "sucesso" silencioso
)
duracao_min = (time.monotonic() - inicio) / 60

with psycopg.connect(DESTINO) as conn:
    matriculas = conn.execute("SELECT count(*) FROM matriculas").fetchone()[0]
    mais_recente = conn.execute("SELECT max(criado_em) FROM matriculas").fetchone()[0]

idade_h = (datetime.now(timezone.utc) - mais_recente).total_seconds() / 3600
print(f"restauração: {duracao_min:.1f} min")
print(f"matrículas: {matriculas}")
print(f"dado mais recente: {idade_h:.1f} h atrás")
assert matriculas > 10_000, "backup suspeitamente magro"
assert idade_h < 26, "backup velho demais para o RPO de 24 h"
```

```text
restauração: 11.4 min
matrículas: 14212
dado mais recente: 3.2 h atrás
```

11,4 minutos é o piso do RTO (o resto é provisionamento, DNS e gente acordando), e 3,2 horas é o RPO que este backup entrega. Os dois viram métricas, com alerta quando o teste falha ou deixa de acontecer. As verificações conferem conteúdo, porque um arquivo de 20 bytes passa em qualquer teste que só pergunta se o arquivo existe. Com `initdb --data-checksums` (padrão desde o PostgreSQL 18), o servidor também detecta páginas corrompidas na leitura.

Restaurar o banco ainda deixa o plano de DR sem teste. Para ele existem exercícios periódicos que seguem o procedimento escrito numa região secundária, cronometrando cada passo. Esses exercícios costumam revelar que o documento manda acessar um painel que exige a VPN que roda na região que caiu.

## Armadilhas e casos reais

> **Na vida real:** em 31/01/2017, combatendo um problema de replicação, um engenheiro do GitLab.com executou `rm -rf` no diretório de dados do banco principal, achando que estava no secundário. Cerca de 300 GB sumiram antes da interrupção. O postmortem lista cinco mecanismos de backup e replicação, e nenhum funcionou quando foi preciso: o `pg_dump` agendado usava binários do PostgreSQL 9.2 contra um servidor 9.6 e não produzia nada, e os e-mails de erro eram rejeitados pelo DMARC; os snapshots de disco não estavam habilitados para o banco. A salvação foi um snapshot LVM feito à mão umas 6 horas antes, para popular o staging. Cerca de 6 horas de dados se perderam, e a restauração levou umas 18 horas, em parte por causa dos discos lentos do staging.

Outras armadilhas que merecem nome próprio:

- **Falha silenciosa no pipeline.** `pg_dump | gzip` sem `set -o pipefail` reporta o código do `gzip`. Mais seguro: `pg_dump -Fc -f arquivo.dump`, sem pipe, conferindo o código de saída.
- **Alerta que não chega.** E-mail rejeitado pelo DMARC é um alerta que disparou e foi silenciado ao mesmo tempo.
- **Backup no mesmo lugar dos dados.** Em 10/03/2021, um incêndio destruiu o datacenter SBG2 da OVHcloud em Estrasburgo. Clientes com backups no mesmo site perderam as duas cópias juntas, como a regra 3-2-1 previa com bastante antecedência.
- **Credencial que apaga tudo.** Em junho de 2014, o atacante que extorquia a Code Spaces tinha acesso ao painel da conta de nuvem e apagou máquinas, dados e backups, todos na mesma conta. A empresa anunciou o encerramento dias depois.
- **Retenção curta demais.** Um bug que grava preços errados desde o deploy de três semanas atrás só é recuperável se existir um ponto anterior a ele. Com retenção de 7 dias, o backup mais antigo contém o bug, fielmente preservado.

E a Braçada Firme do começo do capítulo? A salvação veio do lugar menos provável: a réplica do painel de relatórios estava com a replicação parada desde 15h12, por um problema que ninguém tinha percebido. As matrículas foram copiadas de lá. Nenhuma parte disso se repete como estratégia.

## Resumo

- RPO: quanto dado se aceita perder; RTO: quanto tempo se aceita ficar parado. Meta e valor real diferem, e só um teste mede o real.
- Completo restaura sozinho; incremental depende da cadeia; diferencial, só do último completo. PostgreSQL 17 tem incremental físico nativo.
- Lógico (`pg_dump`) é portável e lento de restaurar; físico é rápido e preso à versão.
- PITR = backup base + WAL arquivado. Arquivamento define o RPO; WAL a reaplicar pesa no RTO.
- Réplica copia o erro junto; contra erro humano, só um ponto no passado.
- 3-2-1, mais uma cópia imutável em outra conta e chaves que sobrevivem ao incidente.
- DR em quatro degraus, trocando custo fixo por RPO e RTO menores.
- Restaurar automaticamente, verificar conteúdo, medir, e monitorar o `pg_stat_archiver`.

## Referências

- PostgreSQL, "Continuous Archiving and Point-in-Time Recovery (PITR)": https://www.postgresql.org/docs/current/continuous-archiving.html
- PostgreSQL, "pg_basebackup": https://www.postgresql.org/docs/current/app-pgbasebackup.html
- PostgreSQL, "pg_combinebackup": https://www.postgresql.org/docs/current/app-pgcombinebackup.html
- PostgreSQL, "Write Ahead Log" (configurações de arquivamento e de alvo de recuperação): https://www.postgresql.org/docs/current/runtime-config-wal.html
- PostgreSQL, "The Cumulative Statistics System" (`pg_stat_archiver`): https://www.postgresql.org/docs/current/monitoring-stats.html
- AWS, "Disaster Recovery of Workloads on AWS: Recovery in the Cloud" (whitepaper): https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html
- NIST SP 800-34 Rev. 1, "Contingency Planning Guide for Federal Information Systems": https://csrc.nist.gov/pubs/sp/800/34/r1/upd1/final
- GitLab, "Postmortem of database outage of January 31": https://about.gitlab.com/blog/2017/02/10/postmortem-of-database-outage-of-january-31/
- GNU Bash Reference Manual, "Pipelines" (`pipefail`): https://www.gnu.org/software/bash/manual/bash.html#Pipelines
- pgBackRest, documentação: https://pgbackrest.org/
- OVHcloud, comunicados sobre o incêndio no site de Estrasburgo (SBG), março de 2021.
- Code Spaces, comunicado de encerramento, junho de 2014.
