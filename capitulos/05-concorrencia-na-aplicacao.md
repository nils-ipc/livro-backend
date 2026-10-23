# Concorrência na aplicação

## O voucher que deu as boas-vindas 14 vezes

Nunca um cliente foi tão bem-vindo. O voucher `BEMVINDO50`, de uso único, que dá R$ 50 de crédito a cada cliente novo, foi resgatado 14 vezes pela mesma conta, em 0,3 segundo, e o financeiro só descobriu na segunda de manhã, numa linha curiosa do relatório semanal. (A situação é hipotética; a conta corrente da empresa é que nunca acha graça.)

O código do endpoint passou por revisão, tem teste e parece impecável:

```python
@app.post("/vouchers/{codigo}/resgatar")
async def resgatar(codigo: str, cliente: Cliente = Depends(cliente_atual)):
    voucher = await repo.buscar(codigo, cliente.id)
    if voucher.usado:
        raise HTTPException(status_code=409, detail="Voucher já utilizado")
    await carteira.creditar(cliente.id, voucher.valor)
    await repo.marcar_usado(codigo, cliente.id)
    return {"ok": True}
```

O `if` está lá, bem visível. O teste que resgata o voucher duas vezes seguidas recebe `409` na segunda, como manda o figurino. O cliente, porém, mandou 14 requisições ao mesmo tempo, com um script de dez linhas, e o balanceador as espalhou entre 4 pods com 2 workers cada.

Como um `if` correto, testado e revisado deixa passar 14 requisições? E onde a garantia de "uso único" precisa morar para continuar valendo com 8 processos em 4 máquinas?

## Condição de corrida, ou quando a ordem dos fatores altera o produto

Uma **condição de corrida** (*race condition*) acontece quando o resultado depende da ordem em que operações concorrentes se intercalam. Cada operação, sozinha, está certa; a combinação, numa ordem que ninguém previu, produz um estado que nenhuma execução sequencial produziria.

O termo vizinho, ***data race***, vem do modelo de memória: duas threads acessam o mesmo endereço, pelo menos uma escreve, sem sincronização. Em C e C++ isso é comportamento indefinido, e o compilador fica autorizado a fazer literalmente qualquer coisa. No CPython, o GIL quase elimina *data races*, mas troca de thread entre instruções de bytecode (o capítulo 4 trata do GIL), e `saldo += 1` são três instruções: carregar, somar, gravar. Uma troca no meio, e um incremento some. No CPython *free-threaded* (PEP 703), sem GIL, a janela só aumenta.

As corridas de aplicação aparecem quase sempre em duas formas:

- **Ler, modificar, gravar** (*read-modify-write*): duas execuções leem o mesmo valor, calculam o novo e gravam. A última vence e a outra se perde: o *lost update*.
- **Verificar e depois agir** (*check-then-act*): a condição verificada muda antes da ação. Em segurança, o nome é **TOCTOU** (*time-of-check to time-of-use*).

O voucher é um *check-then-act* de livro-texto. Veja duas das 14 requisições:

```text
tempo  requisição A                    requisição B
t1     SELECT usado → false
t2                                     SELECT usado → false
t3     credita R$ 50
t4                                     credita R$ 50
t5     UPDATE usado = true
t6                                     UPDATE usado = true
```

Cada linha está correta. O `UPDATE` de B grava `true` por cima de um `true`, sem erro nenhum, com a serenidade de quem cumpriu o dever. O problema está no intervalo entre t1 e t5, em que a resposta "o voucher está livre" já envelheceu e ninguém avisou o código.

Por que o teste não pegou? Duas sequências de 3 passos se intercalam de C(6, 3) = 20 maneiras, e o teste exercita uma: A inteira antes de B. Em homologação, com um usuário só (você), o bug não aparece. Ele espera a produção, onde o tráfego tem a gentileza de testar as outras 19.

## Seção crítica e exclusão mútua

Uma **seção crítica** é um trecho que acessa estado compartilhado e precisa executar sem se intercalar com outros trechos que mexem no mesmo estado. **Exclusão mútua** é a garantia de que no máximo uma execução está lá dentro. O ***mutex***, ou ***lock***, implementa essa garantia com duas operações, adquirir e liberar; quem tenta adquirir um lock ocupado espera.

Por baixo, o hardware oferece uma instrução atômica, em geral o ***compare-and-swap*** (CAS): "se o endereço X contém E, grave N; diga se gravou" (`LOCK CMPXCHG` no x86, `CAS` no ARMv8.1). No Linux, os locks se apoiam no ***futex***: com o lock livre, adquirir custa um CAS, dezenas de nanossegundos, sem chamada de sistema. Com o lock ocupado, a thread chama `futex(FUTEX_WAIT)` e dorme até alguém liberar e chamar `FUTEX_WAKE`. O kernel só entra na história quando há disputa, que é quando alguém precisa mesmo de um juiz.

Um lock protege o estado só se todo trecho que mexe nele adquire o mesmo lock. O `threading.Lock` não bloqueia o acesso ao dicionário; ele só impede que dois trechos que pediram o lock entrem juntos. A função que esqueceu de pedir passa direto, de cabeça erguida.

O custo aparece no throughput: o máximo de um trecho travado é `1 / tempo_na_secao_critica`. Uma seção crítica com uma consulta de 10 ms ao banco limita aquele caminho a 100 operações por segundo, com 1 worker ou com 400. Mais máquinas, nesse caso, só aumentam a fila educada na porta. O capítulo 6 trata disso com a Lei de Amdahl.

## Operações atômicas

Uma operação é **atômica** quando acontece por inteiro ou não acontece, sem estado intermediário visível. Com CAS dá para escrever contadores sem lock (*lock-free*): lê, calcula, tenta o CAS e repete se outro núcleo chegou antes.

No CPython, algumas operações sobre tipos nativos são atômicas como detalhe de implementação (`lista.append(x)`, `d[k] = v`, `d.setdefault(k, v)`; a FAQ oficial lista quais). Operações compostas nunca são: `if k not in d: d[k] = v` tem uma janela no meio.

Fora do processo, a atomicidade útil mora no sistema que todas as réplicas compartilham:

- Um `UPDATE ... WHERE` condicional no PostgreSQL. Em `READ COMMITTED`, o segundo `UPDATE` na mesma linha espera o lock de linha do primeiro e, depois do *commit*, reavalia o `WHERE` contra a versão nova. Se a condição deixou de valer, atualiza zero linhas. O banco faz o CAS por você.
- Uma restrição `UNIQUE`: das duas inserções da mesma chave, uma entra e a outra recebe erro, porque checagem e inserção acontecem dentro do índice.
- Comandos do Redis, que executa um de cada vez numa única thread, com a calma de quem nunca precisou de um lock: `INCR`, `SET ... NX` e scripts Lua são atômicos.

O capítulo 10 trata de isolamento e anomalias; o capítulo 11, de locks de linha e controle otimista.

## Deadlock, ou duas threads educadas demais

Um ***deadlock*** é um conjunto de execuções bloqueadas para sempre, cada uma esperando um recurso que outra segura. Coffman, Elphick e Shoshani descreveram em 1971 as quatro condições que precisam valer **ao mesmo tempo**:

1. **Exclusão mútua**: um usuário por recurso.
2. **Posse e espera** (*hold and wait*): quem segura um recurso pode esperar outro sem soltar o primeiro.
3. **Não preempção**: ninguém tira um recurso à força de quem o segura.
4. **Espera circular**: A espera B, B espera C, ..., alguém espera A.

Quebrar qualquer uma impede o deadlock:

- Contra a espera circular: uma **ordem global de aquisição**. Se todos adquirem em ordem crescente de ID, o ciclo exigiria pegar um ID menor depois de um maior.
- Contra a posse e espera: adquirir tudo de uma vez, ou soltar tudo ao falhar.
- Contra a não preempção: timeout. `trava.acquire(timeout=2)` devolve `False` em vez de esperar para sempre. O PostgreSQL usa um detector: depois de `deadlock_timeout` (1 s por padrão), procura ciclos e aborta uma transação com `ERROR: deadlock detected`.
- Contra a exclusão mútua: não compartilhar o estado.

O `threading` não tem detector: um deadlock produz CPU em 0% e nenhum erro no log. Se o health check não precisa do lock, segue respondendo `200`, e o processo vira o funcionário mais tranquilo do cluster: presente, saudável e sem fazer absolutamente nada. O primo inquieto, o ***livelock***, tem execuções que desistem e tentam de novo em sincronia, colidindo para sempre; um atraso aleatório (*jitter*) antes de cada nova tentativa desfaz a coincidência.

## asyncio e réplicas: onde o lock deixa de valer

O event loop do `asyncio` é cooperativo: trecho sem `await` é atômico em relação às outras corrotinas, e cada `await` pode passar a vez. O voucher tem um `await` entre verificação e marcação, e ali o event loop, muito prestativo, atende as outras 13 requisições.

Um `threading.Lock` ou `asyncio.Lock` vive na memória de um processo. Com 2 workers por pod em 4 pods, existem 8 locks independentes, cada um protegendo com rigor absoluto o seu oitavo do problema. Com várias réplicas, a garantia vai para o componente que todas compartilham, em ordem crescente de peças móveis:

1. **Operação atômica no armazenamento**: `UPDATE` condicional, `UNIQUE`, `INSERT ... ON CONFLICT DO NOTHING`. Não há lock para adquirir, liberar ou esquecer.
2. **Lock no banco**: `SELECT ... FOR UPDATE` ou *advisory locks* do PostgreSQL (`pg_advisory_xact_lock(chave)`), locks com chave numérica definida pela aplicação. O banco os libera se a transação ou a conexão acabar.
3. **Lock distribuído num serviço externo** (Redis, etcd, ZooKeeper), para coordenar trabalho que não cabe numa transação. É a opção com os limites mais traiçoeiros.

## Locks distribuídos e o problema do tempo

O lock distribuído mais comum usa um único Redis:

```text
SET lock:fechamento-mensal 3f9a1c... NX PX 30000
```

`NX` grava só se a chave não existir; `PX 30000` a faz expirar em 30 s. O valor é um token aleatório por aquisição, e a liberação apaga a chave só se ela ainda guardar o seu token (com um script Lua ou, desde o Redis 8.4, com `DELEX key IFEQ token`). Sem essa checagem, um cliente atrasado apaga o lock que já pertence a outro.

A expiração existe porque o dono pode morrer. Só que ela transforma o lock num ***lease***: a exclusão mútua vale até o prazo vencer, no relógio do servidor, sem consultar o cliente. Daí saem três limites:

- **Pausas.** O processo adquire o lock com 30 s de prazo e para por 40 s (pausa de *garbage collector*, VM migrada, contêiner congelado). Outro processo adquire, e o primeiro acorda convicto de que ainda é o dono. Verificar o lock antes de gravar não resolve, porque a pausa pode cair entre a verificação e a gravação: é um *check-then-act* de novo, agora com um Redis no meio.
- **Failover.** A replicação do Redis é assíncrona; se o primário cai antes de replicar o `SET`, a réplica promovida entrega o mesmo lock a outro cliente.
- **Relógio.** A expiração usa o relógio de parede, e um ajuste brusco vence o lock antes da hora.

O **Redlock**, proposto na documentação do Redis, exige o lock na maioria de 5 primários independentes. Em 2016, Martin Kleppmann argumentou que ele depende de pausas, atrasos e desvios de relógio limitados, e que não dá ao armazenamento um jeito de recusar o cliente atrasado; Salvatore Sanfilippo, criador do Redis, respondeu. Hoje a página do Redis recomenda *fencing tokens*.

Um ***fencing token*** é um número crescente entregue com o lock; o recurso recusa escritas com token menor que o maior já visto. O cliente que acordou da pausa com o token 33 é recusado, porque alguém já escreveu com o 34. O capítulo 18 trata de leases, fencing tokens e consenso.

A distinção de Kleppmann que decide o caso: o lock serve à **eficiência** (se duas réplicas gerarem o mesmo relatório, alguém recebe dois e-mails) ou à **corretude** (dois donos simultâneos corrompem dados ou dinheiro)? Para eficiência, um Redis único com TTL atende. Para corretude, o lock vem de um sistema de consenso (etcd e ZooKeeper fornecem números de revisão que servem de fencing token) e o recurso checa o token.

## Na prática

### O voucher em asyncio

O endpoint do problema, enxugado, com um `asyncio.sleep` de 10 ms no lugar do banco:

```python
import asyncio

vouchers = {"BEMVINDO50": {"usado": False}}
creditos: list[int] = []


async def consultar_banco() -> None:
    await asyncio.sleep(0.01)  # a ida e volta ao banco: 10 ms


async def resgatar(codigo: str, req: int) -> str:
    voucher = vouchers[codigo]
    if voucher["usado"]:                 # check
        return f"req {req}: recusado"
    await consultar_banco()              # o event loop vai atender os outros
    voucher["usado"] = True              # act
    creditos.append(50)
    return f"req {req}: R$ 50 creditados"


async def main() -> None:
    pedidos = (resgatar("BEMVINDO50", i) for i in range(1, 6))
    print(*await asyncio.gather(*pedidos), sep="\n")
    print(f"Creditado por um voucher de uso único: R$ {sum(creditos)}")

asyncio.run(main())
```

```text
req 1: R$ 50 creditados
req 2: R$ 50 creditados
req 3: R$ 50 creditados
req 4: R$ 50 creditados
req 5: R$ 50 creditados
Creditado por um voucher de uso único: R$ 250
```

A saída é determinística: as cinco corrotinas fazem o *check* antes que qualquer uma chegue ao *act*, porque cada uma cede a vez no `await`. Com uma seção crítica cobrindo os dois:

```python
trava = asyncio.Lock()


async def resgatar(codigo: str, req: int) -> str:
    async with trava:                    # check + act na mesma seção crítica
        voucher = vouchers[codigo]
        if voucher["usado"]:
            return f"req {req}: recusado"
        await consultar_banco()
        voucher["usado"] = True
        creditos.append(50)
        return f"req {req}: R$ 50 creditados"
```

```text
req 1: R$ 50 creditados
req 2: recusado
req 3: recusado
req 4: recusado
req 5: recusado
Creditado por um voucher de uso único: R$ 50
```

Funciona, num processo. Em 8 processos, o `BEMVINDO50` continua sendo resgatado até 8 vezes, uma por lock.

### Duas transferências e um deadlock

Duas contas, cada uma com seu lock, e duas transferências em sentidos opostos:

```python
import threading
import time


class Conta:
    def __init__(self, nome: str, saldo: int) -> None:
        self.nome = nome
        self.saldo = saldo
        self.trava = threading.Lock()


def transferir(origem: Conta, destino: Conta, valor: int) -> None:
    with origem.trava:
        time.sleep(0.05)  # antifraude: 50 ms de muita desconfiança
        if not destino.trava.acquire(timeout=2):
            print(f"{origem.nome} -> {destino.nome}: desisti após 2 s")
            return
        try:
            origem.saldo -= valor
            destino.saldo += valor
            print(f"{origem.nome} -> {destino.nome}: ok")
        finally:
            destino.trava.release()


ana, bia = Conta("ana", 100), Conta("bia", 100)
inicio = time.perf_counter()
t1 = threading.Thread(target=transferir, args=(ana, bia, 30))
t2 = threading.Thread(target=transferir, args=(bia, ana, 10))
t1.start(); t2.start(); t1.join(); t2.join()
print(f"Saldos: ana={ana.saldo}, bia={bia.saldo} ({time.perf_counter() - inicio:.2f} s)")
```

```text
ana -> bia: desisti após 2 s
bia -> ana: desisti após 2 s
Saldos: ana=100, bia=100 (2.05 s)
```

Uma thread segura `ana` e espera `bia`; a outra, o contrário. Só o timeout impede a espera eterna. Sem ele, o processo ficaria parado até alguém reiniciá-lo, em geral de madrugada, por causa de um alerta que ninguém entende. Com uma ordem global (o nome da conta):

```python
def transferir(origem: Conta, destino: Conta, valor: int) -> None:
    primeira, segunda = sorted((origem, destino), key=lambda c: c.nome)
    with primeira.trava, segunda.trava:
        time.sleep(0.05)
        origem.saldo -= valor
        destino.saldo += valor
        print(f"{origem.nome} -> {destino.nome}: ok")
```

```text
ana -> bia: ok
bia -> ana: ok
Saldos: ana=80, bia=120 (0.10 s)
```

As duas disputam primeiro `ana`, e quem perde espera sem segurar nada.

### O voucher no banco, com 8 processos

A versão que vale para qualquer número de réplicas troca o *check-then-act* por um comando condicional:

```sql
UPDATE resgates
   SET usado_em = now()
 WHERE codigo = 'BEMVINDO50'
   AND cliente_id = 81723
   AND usado_em IS NULL;
```

A primeira requisição recebe:

```text
UPDATE 1
```

As outras 13, todas:

```text
UPDATE 0
```

A aplicação credita só quando a contagem é 1, na mesma transação do `UPDATE`, para que crédito e marcação façam *commit* juntos. Se cada resgate for uma inserção numa tabela com `UNIQUE (codigo, cliente_id)`, a segunda falha no índice:

```text
ERROR:  duplicate key value violates unique constraint "resgates_codigo_cliente_id_key"
DETAIL:  Key (codigo, cliente_id)=(BEMVINDO50, 81723) already exists.
```

Não há lock na aplicação. O `BEMVINDO50`, enfim, dá as boas-vindas uma vez só.

### Um lock no Redis para o fechamento mensal

Um job de fechamento contábil, agendado em todas as réplicas, deve executar em uma só. É um lock de eficiência: o fechamento é idempotente, e duplicá-lo desperdiça 4 minutos de CPU.

```python
import os
import secrets

import redis

r = redis.Redis.from_url(os.environ["REDIS_URL"])

LIBERAR = r.register_script("""
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
else
    return 0
end
""")

CHAVE = "lock:fechamento-mensal"
token = secrets.token_hex(16)

if r.set(CHAVE, token, nx=True, px=600_000):   # 10 min para um job de ~4 min
    try:
        print(f"[{os.environ['HOSTNAME']}] fechando o mês")
        fechar_mes()
    finally:
        LIBERAR(keys=[CHAVE], args=[token])
else:
    print(f"[{os.environ['HOSTNAME']}] outra réplica já está fechando o mês")
```

Nos logs das quatro réplicas, às 00h00 do dia 1:

```text
[api-7c9f-2xkq] fechando o mês
[api-7c9f-8mzt] outra réplica já está fechando o mês
[api-7c9f-q4wd] outra réplica já está fechando o mês
[api-7c9f-v6rn] outra réplica já está fechando o mês
```

O TTL de 10 minutos é mais que o dobro da duração típica, para que uma execução lenta não perca o lease no meio. As outras três desistem educadamente e só voltam a se interessar pelo assunto no mês que vem.

## Propriedades e custos

| Mecanismo | Escopo | Sobrevive à morte do dono | Custo por operação | Garantia |
|-----------|--------|---------------------------|--------------------|----------|
| `threading.Lock` / `asyncio.Lock` | Um processo | Sim, morre junto com ele | ~dezenas de ns sem disputa | Exclusão mútua no processo |
| `UPDATE` condicional / `UNIQUE` | Todas as réplicas | Sim, é o próprio dado | Uma ida ao banco (~1 ms na mesma zona) | Atomicidade da linha ou da chave |
| `SELECT ... FOR UPDATE` / advisory lock | Todas as réplicas | Sim, liberado com a transação ou a sessão | Ida ao banco + espera pelo lock + conexão presa | Exclusão mútua enquanto a conexão existir |
| Redis único com TTL | Todas as réplicas | Sim, pelo TTL | Um RTT ao Redis (~0,2 a 1 ms) | Exclusão mútua só sem pausas longas, sem failover e sem salto de relógio |
| etcd / ZooKeeper + fencing token | Todas as réplicas | Sim, pelo lease da sessão | Consenso: escrita em quórum, alguns ms | Corretude, se o recurso checar o token |

Se o estado está num banco, a atomicidade dele cobre o caso sem infraestrutura nova. Locks no banco seguram uma conexão do pool durante a seção crítica: com 20 conexões e seções de 500 ms, o teto é 40 seções por segundo, e o resto da aplicação disputa as mesmas conexões. O Redis único atende quando errar custa trabalho repetido e um e-mail em dobro. Quando custa dinheiro ou dado corrompido, consenso mais fencing token dá uma garantia que não depende de pausas e relógios, ao preço de operar um cluster de consenso e adaptar o recurso protegido.

## Armadilhas e casos reais

> **Armadilha:** o lock criado dentro da função. `trava = threading.Lock()` na primeira linha de `resgatar()` cria um lock novo a cada chamada. Cada requisição adquire o próprio lock, sem disputa, sem espera, com sucesso absoluto. O código parece protegido, o teste passa, e a exclusão mútua é exatamente zero.

**TTL menor que o trabalho.** Um lock de 30 s num job que leva 45 s nos dias de pico garante dois donos justamente nos dias em que mais importa. Renovar o lease periodicamente ajuda, e a renovação também pode falhar numa pausa.

**`get_or_create` sem restrição.** O do Django faz `SELECT` e depois `INSERT`, e a documentação avisa que ele só é atômico com unicidade imposta pelo banco. Sem `UNIQUE`, nascem duas linhas, e o `.get()` seguinte levanta `MultipleObjectsReturned` meses depois, numa tela sem relação nenhuma com o cadastro.

> **Na vida real:** em maio de 2015, o pesquisador Egor Homakov descreveu uma condição de corrida nos cartões-presente da Starbucks: duas transferências simultâneas de US$ 5 entre os mesmos dois cartões deixaram o destino com US$ 15. Ele usou o saldo numa compra, depositou US$ 10 do próprio bolso para cobrir a diferença e reportou o problema. É o voucher deste capítulo, com dinheiro de verdade e um café no fim.

> **Na vida real:** no apagão de 14 de agosto de 2003 no nordeste dos Estados Unidos e em Ontário, o sistema de alarmes da sala de controle da FirstEnergy, em Ohio, parou sem avisar ninguém, e os operadores passaram mais de uma hora sem alarmes enquanto a falha se espalhava. A investigação do software (o XA/21, da GE) encontrou uma condição de corrida: dois processos obtinham acesso de escrita à mesma estrutura de dados, que se corrompia e levava o processador de alarmes a um laço infinito. A janela era de milissegundos. O bug não causou o apagão, mas tirou dos operadores o aviso de que ele começava. Um alarme que falha em silêncio é o tipo de ironia que só uma condição de corrida produz com tanta discrição.

## Resumo

- Condição de corrida: o resultado depende da intercalação. Formas comuns: *read-modify-write* (lost update) e *check-then-act* (TOCTOU). O GIL não impede nenhuma das duas.
- O lock só protege se todo acesso ao estado usa o mesmo lock. Throughput máximo de um trecho travado: `1 / tempo_na_secao_critica`.
- Deadlock exige as quatro condições de Coffman ao mesmo tempo; ordem global de aquisição e timeout quebram uma delas.
- Locks em memória valem para um processo. Com réplicas, a garantia vai para o armazenamento compartilhado: `UPDATE` condicional, `UNIQUE`, locks do banco.
- Lock distribuído com TTL é um lease: pausas, failover e relógio podem produzir dois donos. Para eficiência, um Redis único basta; para corretude, consenso mais fencing token.

## Referências

- Coffman, E. G.; Elphick, M.; Shoshani, A. "System Deadlocks". *ACM Computing Surveys*, 3(2), 1971. <https://doi.org/10.1145/356586.356588>
- Python, documentação do módulo `threading`. <https://docs.python.org/3/library/threading.html>
- Python, FAQ de bibliotecas e extensões, "What kinds of global value mutation are thread-safe?". <https://docs.python.org/3/faq/library.html#what-kinds-of-global-value-mutation-are-thread-safe>
- PEP 703, "Making the Global Interpreter Lock Optional in CPython". <https://peps.python.org/pep-0703/>
- PostgreSQL, "Explicit Locking" (locks de linha e advisory locks). <https://www.postgresql.org/docs/current/explicit-locking.html>
- PostgreSQL, "Transaction Isolation" (comportamento de `UPDATE` concorrente em `READ COMMITTED`). <https://www.postgresql.org/docs/current/transaction-iso.html>
- Redis, "Distributed Locks with Redis". <https://redis.io/docs/latest/develop/clients/patterns/distributed-locks/>
- Kleppmann, M. "How to do distributed locking", 2016. <https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html>
- Sanfilippo, S. "Is Redlock safe?", 2016. <http://antirez.com/news/101>
- Django, documentação de `get_or_create`. <https://docs.djangoproject.com/en/stable/ref/models/querysets/#get-or-create>
- Homakov, E. "Hacking Starbucks for unlimited coffee", 2015. <https://sakurity.com/blog/2015/05/21/starbucks.html>
- Poulsen, K. "Tracking the blackout bug", SecurityFocus, republicado por The Register, 2004. <https://www.theregister.com/2004/04/08/blackout_bug_report/>
