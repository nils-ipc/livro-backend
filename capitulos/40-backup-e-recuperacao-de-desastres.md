# Backup e recuperação de desastres

## O mês em que tudo aconteceu duas vezes

O Carlos tinha duas aprovações, um chamado legítimo e a melhor das intenções, que é exatamente o kit completo de todo desastre em banco de dados.

Terça, 14h03. A analista de risco pediu o bloqueio da conta 8812, ponta de um anel de fraude achado pelo grafo do capítulo 25. A coluna `contas.bloqueada` existe desde então, e o trigger de débito recusa saque de conta bloqueada. O Carlos abriu o papel `quebra_vidro` (capítulo 31: uma hora, duas aprovações, auditado), escreveu o comando em duas linhas no cliente gráfico, selecionou a primeira com o mouse e apertou Ctrl+Enter:

```text
lastro_shard0=> UPDATE contas SET bloqueada = true
UPDATE 61300
-- a segunda linha, "WHERE id = 8812;", segue no editor até hoje, intacta, inocente
```

Autocommit ligado. Em 1,5 ms, as duas réplicas síncronas do capítulo 23 receberam o erro e o confirmaram com a diligência com que confirmariam um pagamento. Nenhuma zona de disponibilidade ficou sem o seu próprio desastre.

Às 14h11 o Bazar abriu "URGENTE!!!! BLOQUEARAM GERAL???", dois minutos depois de o vendedor 42 tentar sacar. Os alertas por burn rate do capítulo 39 ficaram quietos: saque recusado por conta bloqueada é um `422` impecável, fora do SLI. O Bazar venceu o monitoramento de novo, por regulamento.

O Carlos propôs `UPDATE contas SET bloqueada = false`, também sem `WHERE`, por simetria. Só que 212 contas já estavam bloqueadas antes, por ordem judicial e por fraude. A aba "bloqueados" da planilha do financeiro tinha 209. O backup diário das 3h tinha as 212 e restaurava em 6 horas. A Lastro restaurou numa instância separada, achou nos logs do capítulo 38 os três bloqueios da manhã e corrigiu à mão. Saques parados das 14h03 às 20h05.

Dez dias depois, sábado 9h20, a região do provedor onde a Lastro inteira mora teve uma falha de rede entre zonas e no plano de controle, por 5 horas e 40 minutos. Zonas, etcd, cluster, broker, bucket de backups: tudo na mesma região, que é onde se guarda tudo quando se tem fé. O banco do Pix desistiu de 3.400 notificações. O SLA do Tuiuiú tolera 21,6 minutos por mês; foram 340, 99,21%, multa de 50%. A exclusão cobre adquirente e banco do Pix. O provedor de nuvem não estava nela, porque ninguém achou que ele fosse um parceiro. Ele também não achou.

O fundador disse "no meu tempo era só um servidor e funcionava", e desta vez ninguém conseguiu discordar com números.

Quanto dado a Lastro pode perder em cada caso, quanto tempo pode ficar parada, e o que precisa existir antes do desastre para que essas duas respostas sejam verdade?

## RPO e RTO, ou quanto você perde e quanto você espera

São duas metas, definidas antes do incidente.

O **RPO** (*recovery point objective*) é a perda máxima aceitável, medida em tempo: o ponto de recuperação mais antigo que você tolera. RPO de 24 horas significa que voltar com os dados de ontem é aceitável. RPO zero significa que nenhuma transação confirmada pode sumir. O **RTO** (*recovery time objective*) é o tempo máximo entre a falha e o serviço funcionando de novo.

RPO é propriedade do dado; RTO, do serviço. O cache do Redis tem RPO infinito, porque perdê-lo é aceitável por definição. O ledger tem RPO zero, porque lançamento perdido é dinheiro sem explicação. Baixar o RPO custa latência em toda escrita, todos os dias, para um desastre que talvez nunca venha. Baixar o RTO custa infraestrutura ociosa esperando o fim do mundo, o modelo de negócio das seguradoras e do bunker do fundador.

## Replicação copia o erro com perfeição

Réplica protege contra falha física: disco, máquina, zona. Contra erro lógico (o `UPDATE` sem `WHERE`, o deploy que grava tarifa errada, o ransomware que cifra tudo com o seu usuário), a réplica síncrona é cúmplice: replica a destruição em milissegundos, com garantia de durabilidade. É a única parte do sistema que nunca atrasa quando você mais queria que atrasasse.

Erro lógico exige uma cópia do passado: backup, réplica atrasada ou histórico versionado. A pergunta é "como estava às 14h02?", e nenhuma réplica em tempo real sabe responder.

## Tipos de backup

Um **backup lógico** (`pg_dump`) exporta o conteúdo a partir de um snapshot MVCC consistente. É portável entre versões e restaura reconstruindo tudo, índices inclusive: para um ledger de terabytes, um feriado prolongado.

Um **backup físico** copia os arquivos do banco (`pg_basebackup`, ou ferramentas como pgBackRest e WAL-G). Os arquivos copiados durante a escrita ficam inconsistentes; na restauração, o PostgreSQL reaplica o WAL gerado durante a cópia até um ponto consistente. A cadência:

| Tipo | O que copia | Restauração |
|------|-------------|-------------|
| Completo | tudo | só ele |
| Diferencial | o que mudou desde o último completo | completo + último diferencial |
| Incremental | o que mudou desde o último backup de qualquer tipo | completo + todos os incrementais da cadeia |
| Contínuo (arquivamento de WAL) | cada segmento de WAL, assim que fecha | base + WAL até o instante desejado |

O PostgreSQL 17 trouxe incremental nativo no `pg_basebackup`, com sumarização de WAL e o `pg_combinebackup` para montar a cadeia. Incremental economiza disco e faz a restauração depender de todos os elos: um elo corrompido e o resto da cadeia vira peça de museu.

O contínuo é o que importa para dinheiro. Com um backup base e todo o WAL desde ele arquivado, você reconstrói o banco em qualquer instante entre a base e o último segmento arquivado. Isso é o **point-in-time recovery** (PITR):

```text
# postgresql.conf da instância restaurada + arquivo recovery.signal
restore_command           = '<ferramenta de backup> busca %f para %p'
recovery_target_time      = '2026-10-20 14:03:00-03'
recovery_target_inclusive = off      # para antes do commit do desastre
recovery_target_action    = 'pause'  # espera você conferir antes de abrir
```

O RPO do backup contínuo é o atraso do arquivamento: o segmento de WAL (16 MB) vai para o repositório quando fecha, e o `archive_timeout` força o fechamento em tráfego baixo. O RTO é a cópia da base mais a reaplicação do WAL desde ela: reaplicar 23 horas de WAL leva horas, durante as quais o seu currículo também está sendo reaplicado.

A **réplica atrasada** é uma standby com `recovery_min_apply_delay = '1h'`: recebe o WAL na hora e só o aplica uma hora depois. Diante de um erro lógico, você pausa a reaplicação (`pg_wal_replay_pause()`), lê o passado e copia o que precisa. É PITR já restaurado, esperando o desastre com a paciência de quem sabe que ele vem.

### A regra 3-2-1 e a cópia que ninguém apaga

Três cópias, em dois tipos de mídia, uma fora do local (a formulação é atribuída ao fotógrafo Peter Krogh). Hoje, "fora do local" é outra região e, de preferência, outra conta: quem tem as credenciais de produção apaga a produção e, se puder, o backup, como na Code Spaces do capítulo 36. A defesa é a cópia imutável: armazenamento de objetos com retenção travada (*object lock*, ou WORM), numa conta separada, em que a produção escreve e ninguém apaga antes do prazo. Nem o fundador. Principalmente o fundador.

## Estratégias de recuperação de desastres

Para perda de região, há quatro arranjos clássicos (o documento de recuperação de desastres da AWS usa estes nomes, e eles valem para qualquer provedor):

| Estratégia | Na região secundária | RPO típico | RTO típico | Custo |
|------------|----------------------|------------|------------|-------|
| Backup e restauração | só os backups | horas | horas a dias | armazenamento |
| Pilot light | dados replicados, computação desligada | segundos a minutos | dezenas de minutos | bancos de réplica |
| Warm standby | tudo rodando em escala reduzida | segundos ou zero | minutos | uma fração da produção |
| Ativo-ativo | tudo rodando e servindo tráfego | zero ou quase | perto de zero | produção dobrada + conflitos |

Ativo-ativo parece a resposta óbvia até a primeira escrita. Duas regiões aceitando débitos da mesma conta são o capítulo 23 de novo: multi-líder com conflito, e conflito em saldo se chama saque dobrado. O vendedor 42 abriria uma aba em cada região. Ativo-ativo funciona para dado que admite fusão, ou com cada registro tendo dono numa região só.

## Na Lastro

### RPO e RTO por dado

| Dado | RPO | RTO (região) | Mecanismo |
|------|-----|--------------|-----------|
| Ledger (shards) e `pg-pagamentos` | zero | 30 min | síncrona nas zonas e na região secundária; réplica atrasada 1 h; PITR 35 dias |
| `pg-cofre` | ≤ 5 s | 30 min | assíncrona para o CDE secundário |
| `pg-notificacoes` | ≤ 1 min | 1 h | assíncrona; projeções reconstruíveis (capítulo 21) |
| Broker | reconstruído | 30 min | republicação da outbox (7 dias), dedupe por `id` |
| Redis (cache, sinais, sessões) | sem cópia | aquecimento | degradação dos capítulos 15 e 25; vendedores refazem login |
| Colunar e grafo | 24 h | 1 dia | backup diário na região secundária |

O RPO zero do ledger vem do requisito do capítulo 23, agora estendido à região: nenhum lançamento confirmado pode sumir. `pg-pagamentos` entra junto porque é a origem dos eventos que o ledger consome; perder a cauda dele é perder pagamentos que o banco já considera notificados. Só replicação síncrona entrega RPO zero, e o custo é aritmética: a região secundária fica a ~400 km, com RTT medido de ~8 ms (hipótese do projeto, coerente com 1 ms por 100 km de fibra do capítulo 8, mais roteamento). Todo COMMIT ganha 8 ms. A conta quente do Tuiuiú, que segurava o balde por ~3,5 ms, passa a segurar por ~11,5 ms; com 32 baldes, o teto cai para ~2.800 créditos/s, abaixo dos ~4.000 do dobro do pico. O shard do Tuiuiú vai a 64 baldes (~5.600/s). O Carlos pediu 1.024 no capítulo 4, recebeu 64 trinta e seis capítulos depois e trata isso como vitória moral. A autorização paga 16 ms das duas transações curtas em `pg-pagamentos`, dentro da folga de 120 ms.

A regra de confirmação passa a exigir a réplica da outra região mais uma das zonas:

```text
synchronous_standby_names = 'FIRST 2 (pg-dr, pg-ledger-2, pg-ledger-3)'
```

Com `FIRST 2`, o COMMIT espera as duas de maior prioridade conectadas: normalmente `pg-dr` e `pg-ledger-2`. Se o enlace entre regiões cair, `pg-ledger-3` toma o lugar e as escritas continuam com RPO zero só dentro da região; um alerta dispara se `pg-dr` ficar fora do conjunto por mais de 60 s. É uma escolha explícita: piscada de rede entre regiões não para pagamento, e por esses minutos a perda da região custaria segundos de dados, que a conciliação recupera.

`pg-cofre` fica assíncrono porque a perda é recuperável: um cartão salvo nos últimos segundos some, e o comprador digita de novo.

### Contra o erro humano

Cada shard do ledger e `pg-pagamentos` ganharam:

- **Arquivamento contínuo de WAL** com base completa diária e PITR de 35 dias, num repositório na região secundária, conta de backup separada, retenção travada e chave própria no KMS. A cópia mensal vai para o armazenamento frio de outro provedor: três cópias, dois provedores, fora do local.
- **Réplica atrasada** de 1 hora, `nofailover`, em cada shard. A terça-feira teria levado uns 15 minutos: pausa, `SELECT id FROM contas WHERE bloqueada` na réplica, correção com `WHERE id IN (...)`.
- **Histórico em `contas`**, pelo mesmo trigger que vendedores e tarifas já têm (capítulo 21).
- **`quebra_vidro` somente leitura por padrão** (`ALTER ROLE ... SET default_transaction_read_only = on`): escrever exige `BEGIN READ WRITE` explícito, e o `UPDATE 61300` aparece antes do COMMIT, quando ainda dá para dizer ROLLBACK em vez de palavrão.

### Contra a perda da região

A região secundária roda em warm standby: os bancos acima replicando, um cluster Kubernetes com 25% da capacidade mínima, pods de lastro (capítulo 35) e as mesmas imagens, criados pelos mesmos módulos Terraform com `for_each` por região. Ativo-ativo foi descartado pelo motivo do vendedor 42. Pilot light foi descartado porque subir o cluster do zero estoura os 30 minutos.

Failover de região é decisão humana, com até 10 minutos entre o alerta e a declaração. Falha de região quase nunca é limpa: metade das zonas responde, alguns marketplaces alcançam a região e outros não. Promover automaticamente nesse estado é o split-brain do capítulo 23 em escala continental. O etcd do Patroni passa a ter cinco nós: dois na principal, dois na secundária e um numa terceira região testemunha. Um primário isolado não consegue renovar a liderança e o Patroni o rebaixa em 30 s: o fencing do capítulo 20, entre regiões. O custo é que uma partição longa entre regiões derruba as escritas da principal saudável. Para dinheiro, a Lastro prefere parar de escrever a escrever duas vezes.

O que mais precisa existir antes, porque não está em backup nenhum:

- **IPs liberados nos parceiros.** O adquirente aceitava até 2 IPs (capítulo 36). Um aditivo contratual levou o limite a 4, e os NATs do CDE secundário estão cadastrados. O banco do Pix recebeu o formulário com firma reconhecida dos IPs novos, prazo de 10 dias úteis.
- **Certificados mTLS** do banco para as máquinas da região secundária, com os mesmos alertas de 60, 30 e 14 dias.
- **Chaves do KMS multirregião.** Backup do cofre cifrado com uma chave que só existe na região perdida é crypto-shredding involuntário.
- **Segredos, imagens e estado do Terraform** replicados. Estado do Terraform guardado só no bucket da região que caiu deixa você com o código da infraestrutura e sem saber o que ele já criou.
- **DNS** de `api` e `webhooks-pix` com TTL de 300 s (capítulo 8), trocado por Terraform da região secundária.

### Depois do failover: a conciliação

O failover termina quando o dinheiro fecha. Com RPO zero no ledger e em `pg-pagamentos`, o que fica para trás são as conversas interrompidas com parceiros:

```text
1. relay CDC na secundária republica a outbox da última hora; consumidores descartam `id` repetido
2. resolução (cap. 15) retoma cobranças `processando` consultando o adquirente
3. saga de repasse (cap. 18) consulta o banco sobre todo repasse `enviando`
4. conciliação extraordinária D0 com o extrato do banco do Pix, por EndToEndId:
   Pix recebido sem notificação aceita -> credita pelo fluxo normal (referência UNIQUE)
5. fechamento do dia contábil só depois do item 4 zerar
```

O item 4 é o que teria salvo as 3.400 notificações abandonadas pelo banco no sábado. A conciliação do capítulo 18 virou procedimento de recuperação de desastre, e a planilha do financeiro ganhou status de plano de contingência.

### Testes de restauração

Backup que nunca foi restaurado é uma hipótese com custo de armazenamento. A Lastro testa três coisas:

- **Toda semana, automático:** restaura a base mais recente de cada banco numa conta isolada, aplica PITR até um instante sorteado dos últimos 7 dias e confere soma zero por transação e moeda, `saldos_fechados` contra o ledger e contagem por partição contra o primário no mesmo LSN. Mede o tempo. Alerta se passar de 4 horas ou se uma conferência falhar.
- **Todo mês:** pausa a réplica atrasada e recupera uma linha escolhida.
- **Todo semestre:** troca planejada de região em produção, madrugada de domingo. Na troca planejada, as escritas pausam até a secundária confirmar o último LSN, e a pausa medida é de ~3 minutos, dentro dos 13 do orçamento do capítulo 39.

O primeiro teste de região levou 47 minutos: um módulo Terraform com as zonas da principal escritas à mão, um gateway sem certificado do banco e a cota de máquinas da secundária que ninguém pediu para aumentar. O segundo levou 26.

## Armadilhas e casos reais

> **Na vida real:** em 10 de março de 2021, um incêndio destruiu o datacenter SBG2 da OVHcloud em Estrasburgo e danificou parte do SBG1 vizinho. Clientes que guardavam o backup no mesmo complexo perderam produção e backup no mesmo incêndio. O "fora do local" da regra 3-2-1 existe por causa de manhãs assim.

> **Na vida real:** durante a produção de *Toy Story 2*, em 1998, um `rm` recursivo apagou a maior parte dos arquivos do filme num servidor da Pixar, e os backups vinham falhando sem que ninguém soubesse. O filme foi salvo por uma cópia que uma pessoa da equipe mantinha em casa para trabalhar remotamente. O plano de recuperação de desastres de uma das maiores produções da época foi um computador doméstico.

> **Armadilha:** medir o RTO no slide. O RTO real inclui decidir e achar a senha do console.

- **Backup sem as chaves.** Backup cifrado com chave apagada ou presa na região morta é ruído aleatório com metadados.
- **Restaurar por cima da produção.** A terça precisava de 212 linhas, e não do banco de 14h02: voltar a produção inteira apagaria horas de pagamentos legítimos para desfazer uma coluna. Restaura-se ao lado e copia-se o necessário.

## Resumo

- RPO é a perda máxima aceitável, por dado; RTO, o tempo máximo até voltar, por serviço.
- Replicação protege contra falha física e copia erro lógico.
- Backup físico com WAL arquivado permite PITR; réplica atrasada é PITR pronto.
- 3-2-1 com uma cópia imutável em outra conta e outra região.
- Backup e restauração, pilot light, warm standby e ativo-ativo trocam custo por RTO e RPO.
- RPO zero entre regiões custa o RTT em todo COMMIT.
- Failover de região exige fencing e o que não está em backup: IPs, certificados, chaves, estado.
- Restauração só existe se testada, com tempo medido.

## A Lastro agora

O ledger e `pg-pagamentos` confirmam cada COMMIT numa zona e na região secundária, a ~8 ms, com RPO zero, e o shard do Tuiuiú tem 64 baldes para pagar essa conta. Cada shard tem réplica atrasada de uma hora, WAL arquivado com PITR de 35 dias num repositório imutável em outra conta e outra região, e cópia mensal em outro provedor. A região secundária roda em warm standby, com etcd em três regiões, IPs cadastrados nos parceiros, certificados do banco, chaves multirregião e RTO medido de 26 minutos. Depois de um failover, a conciliação fecha o que ficou no ar. `contas` tem histórico, e o `quebra_vidro` começa somente leitura.

O segundo teste semestral de região rodou num domingo às 3h, com três minutos de escrita pausada. Nenhum lançamento perdido, nenhuma notificação abandonada, nenhum centavo de diferença na planilha, que o financeiro conferiu às 3h40 por esporte. Na segunda de manhã, pela primeira vez em quarenta capítulos, chegou um chamado do Bazar sobre um incidente que ele não percebeu. Assunto: "URGENTE!!!! tá tudo bem aí? tá quieto demais".

## Referências

- PostgreSQL. "Continuous Archiving and Point-in-Time Recovery (PITR)". <https://www.postgresql.org/docs/current/continuous-archiving.html>
- PostgreSQL. "Write Ahead Log" (arquivamento e alvos de recuperação). <https://www.postgresql.org/docs/current/runtime-config-wal.html>
- PostgreSQL. `pg_basebackup` e `pg_combinebackup` (backup incremental, versão 17). <https://www.postgresql.org/docs/current/app-pgbasebackup.html>
- PostgreSQL. "Replication" (`synchronous_standby_names`, `recovery_min_apply_delay`). <https://www.postgresql.org/docs/current/runtime-config-replication.html>
- Patroni. Documentação. <https://patroni.readthedocs.io/>
- AWS. "Disaster Recovery of Workloads on AWS: Recovery in the Cloud" (estratégias de DR). <https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html>
- Data Center Knowledge. "Fire Has Destroyed OVH's Strasbourg Data Center (SBG2)", março de 2021. <https://datacenterknowledge.com/uptime/fire-has-destroyed-ovh-s-strasbourg-data-center-sbg2>
