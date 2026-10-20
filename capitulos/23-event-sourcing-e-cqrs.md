# Event sourcing e CQRS

## Os 4.380 pontos do Seu Arlindo

Seu Arlindo chegou ao balcão da Café Coado às 7h02 de uma segunda-feira, pediu o pão de queijo de sempre e anunciou que ia pagar com os 4.380 pontos que juntou em seis anos de cafezinho. A atendente olhou a tela. O saldo dele era 12.

O chamado chegou à equipe de backend às 7h40, com o assunto "URGENTE: cliente idoso muito educado e muito bravo". A tabela `contas_fidelidade` tinha uma coluna `saldo`, e a coluna dizia 12 com a convicção de quem nunca guarda o passado. Seu Arlindo perguntava para onde tinham ido os pontos. O sistema respondia, em essência, "sei lá, mas agora são 12".

A investigação levou três dias. Sete trechos de código faziam `UPDATE contas_fidelidade SET saldo = ...`, incluindo um `job_expiracao_v2_NAO_RODAR.py` que, contrariando o próprio nome, estava no cron desde março. O log de auditoria registrava só "saldo alterado", sem valor anterior, motivo ou autor.

E se o sistema, em vez de guardar o saldo, guardasse tudo o que aconteceu com ele e calculasse o saldo a partir disso? O que esse modelo resolve, quanto custa e que problemas novos ele inventa?

## O mecanismo

### Eventos, ou o passado no pretérito perfeito

No modelo tradicional, o banco guarda o estado atual e cada escrita destrói o estado anterior. Um `UPDATE` sobrescreve; o valor velho some (o MVCC guarda versões antigas por um tempo, mas o `VACUUM` passa e leva tudo).

Em *event sourcing*, a fonte da verdade é a sequência de **eventos**: registros imutáveis de fatos do domínio, com nome no passado (`PontosCreditados`, `PontosResgatados`, `PontosExpirados`), dados do fato e metadados (horário, requisição de origem, versão do schema). Evento gravado ninguém altera nem apaga. Fato errado se corrige com outro fato: `PontosEstornados`. A contabilidade faz isso há séculos; no livro razão, lançamento errado se corrige com estorno, nunca com borracha.

O próprio PostgreSQL funciona assim por dentro: o WAL é um log só de acréscimo, e as tabelas são o resultado de aplicá-lo (uma réplica física reconstrói o banco reaplicando o WAL, como mostra o capítulo 13). Event sourcing leva a ideia para o domínio: em vez de "página 4.812 alterada no byte 312", o log diz "Seu Arlindo resgatou 300 pontos num pão de queijo".

### O estado é uma redução

Se os eventos são a verdade, o estado atual é derivado: começa num estado inicial e aplica cada evento, em ordem, com uma função pura `aplicar(estado, evento) -> novo_estado`. Isso é um `functools.reduce` sobre a lista de eventos, com a mesma assinatura de um reducer do React, `(state, action) => newState`. A diferença é que o event sourcing guarda as ações para sempre, e o Redux esquece todas quando o usuário fecha a aba.

A função `aplicar` tem duas obrigações. Ser determinística: nada de relógio, API ou configuração dentro dela; tudo o que o cálculo precisa está no evento. E nunca recusar um evento, porque ele já aconteceu. Se um evento antigo deixa o saldo negativo, o saldo fica negativo, e a discussão acontece em outro lugar.

### Comandos, decisões e a versão esperada

Esse outro lugar é o tratamento de **comandos**. Um comando é um pedido no imperativo (`ResgatarPontos`) e pode ser recusado. O fluxo de escrita é sempre o mesmo:

1. Carregar os eventos da entidade e reduzi-los até o estado atual.
2. Validar o comando contra esse estado (tem saldo? a conta está ativa?).
3. Se passar, produzir um ou mais eventos novos.
4. Anexar os eventos ao final da sequência da entidade.

A sequência de eventos de uma entidade se chama *stream* (`conta-4417`). A entidade cujas regras são garantidas dentro de um stream é o **agregado**, termo do Domain-Driven Design: a fronteira de consistência. O que precisa ser verdade ao mesmo tempo mora no mesmo stream.

O passo 4 tem uma condição de corrida clássica. Dois caixas atendem Seu Arlindo ao mesmo tempo, ambos leem 12 pontos, ambos validam um resgate de 10 e ambos anexam. Saldo final: −8, e um cliente que agora deve café à empresa.

A solução é o controle otimista do capítulo 11, aplicado ao stream. Cada evento tem uma versão dentro do stream, e quem anexa informa a **versão esperada**: "gravo a 4 porque li até a 3". Se a 4 já existe, o armazenamento recusa, o comando recomeça do passo 1 e descobre que o saldo é 2. Em PostgreSQL, `UNIQUE (stream_id, versao)` faz esse trabalho sozinha.

### O event store

O armazenamento de eventos (*event store*) precisa de poucas operações, e elas determinam tudo:

- anexar eventos a um stream, condicionado à versão esperada;
- ler um stream inteiro, em ordem, a partir de uma versão;
- ler todos os eventos de todos os streams numa ordem global, a partir de uma posição;
- assinar o fluxo para receber eventos novos à medida que chegam.

Há bancos especializados (o KurrentDB, antes EventStoreDB, é um exemplo), e uma tabela em PostgreSQL com índice único também resolve, com transações de brinde. Um log como o Kafka atende bem as duas últimas operações e mal as duas primeiras: não tem anexo condicional por chave, e ler o histórico de uma conta exige varrer a partição inteira onde ela caiu.

A ordem global merece cuidado. Dentro do stream, a versão ordena sem ambiguidade. Entre streams, a posição costuma vir de uma sequência, atribuída no `INSERT`, e não no `COMMIT`. A transação que pegou a posição 1001 pode confirmar depois da que pegou a 1002; quem lê "tudo depois de 1000" no intervalo vê a 1002, avança o marcador e nunca mais encontra a 1001. É o defeito do relay de outbox que lê `id > ultimo_id`, descrito no capítulo 22.

### Projeções, ou quem responde às perguntas

Reduzir um stream responde "qual é o estado desta conta?". Já "quais clientes têm mais de mil pontos?" exigiria reduzir todas as contas a cada consulta, e o relatório mensal viraria um projeto de vida.

Para isso existem as **projeções**: processos que leem o fluxo global em ordem e mantêm um modelo de leitura (*read model*) pronto para uma consulta: a tabela `saldos(conta, saldo)`, o ranking dos maiores bebedores de café, um índice de busca. Cada uma guarda um **checkpoint**, a posição do último evento processado.

Checkpoint e modelo de leitura vão na mesma transação. Separados, uma queda entre os dois reaplica eventos (saldo contado duas vezes) ou os pula. Juntos, o reprocessamento é idempotente por construção, o padrão inbox do capítulo 20. Se o modelo mora em outro sistema (um Redis, um índice de busca), a projeção precisa ser idempotente pelo conteúdo: gravar "saldo = 12 na versão 3" em vez de "somar −10".

E projeções são descartáveis. Bug no modelo de leitura? Apaga, zera o checkpoint, reprocessa desde o primeiro evento. Pergunta que ninguém previu ("quantos pontos de bônus de aniversário cada loja deu desde 2019?")? Projeção nova sobre o histórico inteiro. No modelo que guarda só o estado, essa informação morreu num `UPDATE` qualquer de uma terça-feira.

### Snapshots para streams que não param de crescer

Carregar um agregado custa reduzir o stream inteiro. Para 30 eventos, nada. Para um sensor com um evento por segundo, são 86.400 por dia, e o comando número 10 milhões começa lendo os 9.999.999 anteriores.

Um **snapshot** é o estado reduzido até a versão N, gravado à parte; carrega-se o snapshot e só os eventos depois de N. Ele é cache: pode ser apagado e recalculado, e carrega a versão do código que o gerou, para ser descartado quando a forma do estado mudar.

Muitas vezes o stream nem precisa ser infinito: uma conta de pontos pode fechar o ano com um evento `PeriodoEncerrado` contendo o saldo e começar um stream novo, o que a contabilidade chama de balanço de abertura.

### Versionamento de eventos que vão viver para sempre

Eventos são imutáveis e eternos, então o `PontosCreditados` de 2019, gravado com `{"qtd": "10"}` (string, porque alguém achou "mais flexível"), continua assim em 2035, e o código precisa saber lê-lo. As técnicas, da mais barata para a mais cara:

1. **Leitor tolerante (*weak schema*)**: só acrescentar campos opcionais, com padrão na leitura (`loja_id` ausente vira `None`).
2. ***Upcasting***: o evento guarda a versão do schema nos metadados, e uma função converte versões antigas para a atual na leitura, antes de `aplicar`.
3. **Tipo novo de evento**: quando o significado muda (`PontosCreditadosPorCampanha`).
4. **Copiar e transformar**: gerar um event store novo com o histórico convertido e trocar o antigo, com o sistema escrevendo enquanto isso.

Renomear campo, mudar unidade ou dividir um evento exigem as técnicas 2 a 4. O capítulo 25 trata de compatibilidade de contratos; aqui o consumidor mais antigo do evento é o próprio sistema, daqui a dez anos, relendo o passado.

### CQRS: um modelo para escrever, outros para ler

CQRS (*Command Query Responsibility Segregation*) separa o modelo que processa comandos do modelo que responde consultas. Greg Young cunhou o nome por volta de 2010, a partir do princípio CQS de Bertrand Meyer (um método ou altera estado ou devolve dados, nunca os dois), levando a separação do método para o sistema: escrita valida e grava; leitura tem modelos por tela ou relatório, talvez em bancos diferentes.

As ideias são independentes. CQRS sem event sourcing é um PostgreSQL normalizado para escrita e um índice de busca alimentado por CDC. O contrário quase não existe: sem modelo de leitura, toda consulta reduz streams, e o primeiro filtro por data faz o sistema pedir socorro.

### Consistência das projeções

O preço da separação é atraso. O comando grava o evento, responde `201 Created`, e a projeção o processa milissegundos (ou minutos, num dia ruim) depois. Seu Arlindo resgata o pão de queijo, a tela recarrega, e o saldo ainda mostra 312. É consistência eventual no sentido do capítulo 17. As saídas conhecidas:

- **Devolver o estado na resposta do comando**, que acabou de reduzir o stream. Resolve só a tela que comandou.
- **Devolver a posição e esperar a projeção**: a consulta seguinte envia a posição, e a leitura espera, com prazo, o checkpoint alcançá-la. É a espera por LSN do capítulo 13, e garante ler as próprias escritas.
- **Ler do stream** quando a pergunta é sobre uma entidade só.

O atraso de cada projeção (posição mais recente menos checkpoint, e a idade do evento no checkpoint) precisa de métrica e alerta. Uma projeção travada num evento venenoso serve dados de ontem com a mesma cara de sempre.

## Na prática

O núcleo do modelo cabe em poucas linhas. Eventos como dataclasses imutáveis, `aplicar` como função pura, estado como redução:

```python
from dataclasses import dataclass
from functools import reduce


@dataclass(frozen=True)
class PontosCreditados:
    pontos: int
    motivo: str


@dataclass(frozen=True)
class PontosResgatados:
    pontos: int
    item: str


@dataclass(frozen=True)
class PontosExpirados:
    pontos: int
    origem: str


@dataclass(frozen=True)
class Conta:
    saldo: int = 0
    versao: int = 0


def aplicar(conta: Conta, evento) -> Conta:
    match evento:
        case PontosCreditados(pontos=p):
            return Conta(conta.saldo + p, conta.versao + 1)
        case PontosResgatados(pontos=p) | PontosExpirados(pontos=p):
            return Conta(conta.saldo - p, conta.versao + 1)
    raise ValueError(f"evento desconhecido: {evento!r}")


historico = [
    PontosCreditados(4380, "seis anos de cafezinho"),
    PontosResgatados(300, "pão de queijo"),
    PontosExpirados(4068, "job_expiracao_v2_NAO_RODAR.py"),
]

for n in range(1, len(historico) + 1):
    print(reduce(aplicar, historico[:n], Conta()))
```

```text
Conta(saldo=4380, versao=1)
Conta(saldo=4080, versao=2)
Conta(saldo=12, versao=3)
```

A pergunta de três dias se responde em três linhas: 4.068 pontos expiraram, e o evento diz quem expirou. Reduzir prefixos dá, de graça, o estado em qualquer momento do passado.

O event store em PostgreSQL:

```sql
CREATE TABLE eventos (
    posicao    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stream_id  text        NOT NULL,
    versao     integer     NOT NULL,
    tipo       text        NOT NULL,
    dados      jsonb       NOT NULL,
    metadados  jsonb       NOT NULL DEFAULT '{}',
    gravado_em timestamptz NOT NULL DEFAULT now(),
    UNIQUE (stream_id, versao)
);
```

O anexo condicionado à versão esperada vira um `INSERT` que pode violar a restrição:

```python
import psycopg
from psycopg import errors
from psycopg.types.json import Jsonb


class ConflitoDeVersao(Exception):
    pass


def anexar(conn: psycopg.Connection, stream_id: str,
           versao_esperada: int, eventos: list[tuple[str, dict]]) -> None:
    try:
        with conn.transaction(), conn.cursor() as cur:
            for i, (tipo, dados) in enumerate(eventos, start=1):
                cur.execute(
                    "INSERT INTO eventos (stream_id, versao, tipo, dados)"
                    " VALUES (%s, %s, %s, %s)",
                    (stream_id, versao_esperada + i, tipo, Jsonb(dados)),
                )
    except errors.UniqueViolation:
        raise ConflitoDeVersao(
            f"{stream_id}: alguém gravou depois da versão {versao_esperada}"
        ) from None


# Dois caixas leram a conta na versão 3, com 12 pontos, e os dois querem um café.
cafe = [("PontosResgatados", {"pontos": 10, "item": "café"})]
anexar(conn_caixa_1, "conta-4417", 3, cafe)
anexar(conn_caixa_2, "conta-4417", 3, cafe)
```

```text
Traceback (most recent call last):
  ...
ConflitoDeVersao: conta-4417: alguém gravou depois da versão 3
```

Em transações simultâneas, a segunda espera no índice único até a primeira confirmar e então recebe a violação. O caixa 2 recarrega, encontra saldo 2 e recusa com uma mensagem educada, que é tudo o que Seu Arlindo pediu desde o começo.

A projeção de saldos grava o modelo de leitura e o checkpoint na mesma transação:

```python
def projetar_saldos(conn: psycopg.Connection, limite: int = 500) -> int:
    with conn.transaction(), conn.cursor() as cur:
        cur.execute(
            "SELECT posicao FROM checkpoints WHERE projecao = 'saldos' FOR UPDATE"
        )
        (checkpoint,) = cur.fetchone()
        cur.execute(
            "SELECT posicao, stream_id, tipo, dados FROM eventos"
            " WHERE posicao > %s ORDER BY posicao LIMIT %s",
            (checkpoint, limite),
        )
        lote = cur.fetchall()
        for posicao, stream_id, tipo, dados in lote:
            delta = dados["pontos"] if tipo == "PontosCreditados" else -dados["pontos"]
            cur.execute(
                "INSERT INTO saldos (conta, saldo) VALUES (%s, %s)"
                " ON CONFLICT (conta) DO UPDATE SET saldo = saldos.saldo + EXCLUDED.saldo",
                (stream_id, delta),
            )
            checkpoint = posicao
        cur.execute(
            "UPDATE checkpoints SET posicao = %s WHERE projecao = 'saldos'",
            (checkpoint,),
        )
    print(f"{len(lote)} eventos aplicados, checkpoint agora em {checkpoint}")
    return len(lote)
```

```text
4 eventos aplicados, checkpoint agora em 4
```

O `FOR UPDATE` impede duas instâncias no mesmo lote; se o processo morrer, tudo volta ao checkpoint antigo. A corrida das posições confirmadas fora de ordem continua aberta. Uma solução no PostgreSQL é gravar `pg_current_xact_id()` numa coluna `xid8` e ler só eventos de transações anteriores a `pg_snapshot_xmin(pg_current_snapshot())`, que com certeza já terminaram. Outra é serializar os anexos com um lock, trocando vazão por simplicidade.

Por fim, o upcaster que mantém vivo o evento de 2019:

```python
def upcast(tipo: str, versao_schema: int, dados: dict) -> tuple[str, dict]:
    # v1 (2019): {"qtd": "10"}. String. "Mais flexível", disse alguém, e foi embora.
    if tipo == "PontosCreditados" and versao_schema == 1:
        return tipo, {
            "pontos": int(dados["qtd"]),
            "motivo": dados.get("motivo", "desconhecido"),
        }
    return tipo, dados


print(upcast("PontosCreditados", 1, {"qtd": "10"}))
print(upcast("PontosCreditados", 2, {"pontos": 10, "motivo": "aniversário"}))
```

```text
('PontosCreditados', {'pontos': 10, 'motivo': 'desconhecido'})
('PontosCreditados', {'pontos': 10, 'motivo': 'aniversário'})
```

A cadeia de upcasters (v1 → v2 → v3) roda em toda leitura de evento antigo e é código de produção para sempre: um bug nela altera o passado inteiro de uma vez.

## Propriedades e custos

Guardar estado, guardar estado com tabela de auditoria e guardar eventos têm garantias e custos diferentes:

| Propriedade | Só estado (CRUD) | Estado + auditoria | Event sourcing |
|-------------|------------------|--------------------|----------------|
| Fonte da verdade | Linha atual | Linha atual | Eventos |
| Histórico completo e confiável | Não | Depende de todo código gravar a auditoria | Sim, por construção |
| Estado em data passada | Não | Reconstrução manual | Redução até a data |
| Consulta nova sobre o passado | Só do que restou | Só do que foi auditado | Projeção nova sobre todo o histórico |
| Consulta ad hoc com SQL | Direta | Direta | Só nos modelos de leitura |
| Mudança de schema | Migração | Migração | Eventos imutáveis: upcasting ou cópia |
| Leitura após escrita | Imediata | Imediata | Imediata no stream; atrasada nas projeções |
| Armazenamento | Proporcional às entidades | Entidades + log | Proporcional a tudo o que já aconteceu |

A tabela de auditoria depende de cada caminho de código gravá-la, a fraqueza que derrubou a Café Coado. No event sourcing, o evento é a própria escrita.

Numa situação hipotética de 2 milhões de contas com 30 eventos de 400 bytes por mês, o event store cresce 24 GB por mês, cerca de 290 GB por ano antes dos índices, e nunca diminui. Reprocessar 300 milhões de eventos a 20 mil por segundo leva 15.000 segundos, pouco mais de quatro horas. E cada projeção é mais um processo para monitorar.

Para consultas logo depois de um comando:

| Estratégia | Garante | Custo |
|------------|---------|-------|
| Estado na resposta do comando | Ler as próprias escritas na tela que comandou | Outras telas e abas continuam vendo atraso |
| Posição + espera pela projeção | Ler as próprias escritas em qualquer consulta da sessão | Latência da consulta inclui o atraso da projeção; precisa de prazo |
| Ler do stream | Estado sempre atual da entidade | Só serve para uma entidade; custo cresce com o stream |
| Aceitar o atraso | Nada além de convergência | Zero, até alguém clicar em "atualizar" sete vezes |

Essas propriedades pesam quando o histórico tem valor próprio (dinheiro, pontos, estoque, prontuários) e "como chegamos aqui?" é pergunta frequente, auditada ou regulada. O histórico de quem desligou o e-mail de promoções às 3h da manhã costuma interessar a pouca gente.

## Armadilhas e casos reais

> **Armadilha:** projeção que manda e-mail. Uma projeção de "pontos resgatados" que também envia o recibo funciona por meses, até o dia do reprocessamento, quando o histórico inteiro é aplicado de novo e Seu Arlindo recebe, em quatro minutos, 1.312 recibos de pão de queijo desde 2019. Efeitos externos ficam em consumidores separados (às vezes chamados de *reactors*), que guardam o próprio checkpoint, nunca são reprocessados do zero e deduplicam pelo ID do evento.

**Evento CRUD disfarçado.** Um evento `ContaAtualizada` com o estado inteiro da conta grava o resultado e perde o motivo. Ele tem os custos do event sourcing e as respostas do `UPDATE`. A informação útil está no verbo: `PontosExpirados` com `origem` diz o que aconteceu; `ContaAtualizada {"saldo": 12}` diz o mesmo que a coluna dizia.

**Unicidade entre streams.** O agregado garante regras dentro do próprio stream e nada fora dele. Duas contas criadas ao mesmo tempo com o mesmo e-mail passam, cada uma no seu stream novinho. A solução usual é uma tabela de reserva com `UNIQUE`, gravada antes do evento ou na mesma transação.

**Kafka como única cópia dos eventos.** O `retention.ms` padrão é 7 dias: com a configuração padrão, a fonte da verdade se apaga toda semana, sem erro e sem alarde. E compactação (`cleanup.policy=compact`) guarda só o último valor por chave, a definição de jogar o histórico fora.

**Direito ao esquecimento.** LGPD e GDPR permitem pedir a eliminação de dados pessoais, e eventos são imutáveis. A técnica conhecida é *crypto-shredding*: dados pessoais cifrados com uma chave por titular, guardada fora do event store; apagar a chave os torna ilegíveis em todos os eventos e backups de uma vez (o capítulo 33 trata de gestão de chaves).

**Reprocessar sobre a tabela em uso.** Zerar `saldos` para reconstruí-la deixa todo mundo com saldo zero por quatro horas. O caminho é construir `saldos_v2` lado a lado, deixar alcançar o fim do fluxo e trocar a leitura.

> **Na vida real:** a LMAX, uma bolsa de câmbio de varejo de Londres, teve a arquitetura descrita por Martin Fowler em 2011: lógica de negócio numa única thread, estado em memória reconstruído a partir de um log de eventos de entrada, cerca de 6 milhões de pedidos por segundo. Do lado dos custos, Overeem, Spoor e Jansen ("The dark side of event sourcing", SANER 2017) estudaram sistemas em produção e apontaram a evolução de schema dos eventos como dificuldade recorrente, a mesma do `{"qtd": "10"}` de 2019.

## Resumo

- Fonte da verdade: sequência imutável de eventos; estado = redução determinística. Erro se corrige com estorno.
- Comandos podem ser recusados; eventos já aconteceram.
- Agregado = fronteira de consistência; anexo com versão esperada.
- Posições globais de sequência podem ser confirmadas fora de ordem.
- Projeções: checkpoint na mesma transação, descartáveis, sem efeitos externos.
- Snapshots são cache; fechamentos de período encurtam streams.
- Versionamento: leitor tolerante, upcasting, tipo novo, cópia e transformação.
- CQRS independe de event sourcing; o preço é o atraso das projeções.
- Custos: armazenamento que só cresce, reprocessamento de horas, unicidade entre streams, crypto-shredding.

## Referências

- Martin Fowler, "Event Sourcing" (2005): <https://martinfowler.com/eaaDev/EventSourcing.html>
- Martin Fowler, "CQRS" (2011): <https://martinfowler.com/bliki/CQRS.html>
- Martin Fowler, "The LMAX Architecture" (2011): <https://martinfowler.com/articles/lmax.html>
- Greg Young, "CQRS Documents" (2010): <https://cqrs.files.wordpress.com/2010/11/cqrs_documents.pdf>
- Greg Young, *Versioning in an Event Sourced System*: <https://leanpub.com/esversioning>
- Bertrand Meyer, *Object-Oriented Software Construction*, Prentice Hall, 1988 (princípio CQS).
- Michiel Overeem, Marten Spoor, Slinger Jansen, "The dark side of event sourcing: Managing data conversion", IEEE SANER 2017.
- Microsoft, padrões de arquitetura "Event Sourcing" e "CQRS": <https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing> e <https://learn.microsoft.com/en-us/azure/architecture/patterns/cqrs>
- Documentação do PostgreSQL, funções de ID de transação e snapshot (`pg_current_xact_id`, `pg_snapshot_xmin`): <https://www.postgresql.org/docs/current/functions-info.html>
- Documentação do Apache Kafka, configuração de tópicos (`retention.ms`, `cleanup.policy`): <https://kafka.apache.org/documentation/#topicconfigs>
- Documentação do KurrentDB: <https://docs.kurrent.io/>
