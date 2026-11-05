# Decomposição de sistemas

O relatório de risco subiu numa quinta às 9h30 e às 10h05 derrubou a autorização de cartão, o que é uma conquista para um relatório: ele nem tinha permissão para autorizar nada.

A analista de risco clicou em "exportar 2 anos". O endpoint novo, no mesmo monólito que autoriza cartão, puxou 14 milhões de linhas do colunar (capítulo 25) para um DataFrame dentro do worker. Foram 40 segundos de CPU no event loop, o pecado exato que o capítulo 13 proibiu, com o RSS do processo indo de 160 MB a 7 GB. O OOM killer do Linux encerrou o worker, e com ele as 212 autorizações em andamento naquele processo, que viraram `processando` e foram resolvidas pela consulta ao adquirente (capítulo 15). A analista achou que tinha travado e clicou mais duas vezes. O painel interno espalhou os cliques pelas três máquinas, e cada uma perdeu um worker do mesmo jeito: um terço da capacidade de autorização evaporou em 90 segundos, por um CSV.

O Bazar abriu chamado às 10h09. O assunto era "URGENTE!!!!" e o corpo era "quem é essa analista".

A correção óbvia foi o rollback. O deploy das 9h30 levava 14 mudanças de cinco pessoas, entre elas a correção de um bug no Pix que o Hornero esperava havia uma semana. O rollback levou o relatório embora e o conserto do Pix junto. O Hornero recebeu o bug de volta às 10h20, sem ter pedido.

Por que um relatório pode matar uma autorização, e como se divide um sistema para que isso não aconteça sem criar uma dúzia de problemas novos?

## Três formas de empacotar o mesmo código

As três arquiteturas se distinguem por três fronteiras: a de deploy (o que sobe junto), a de processo (o que morre junto) e a de dados (quem pode escrever em qual tabela).

Um **monólito** tem uma unidade de deploy, um processo (replicado) e um banco. Chamar outro módulo é uma chamada de função: nanossegundos, mesma transação, mesma stack trace. Refatorar uma fronteira é um PR. O custo é o destino compartilhado: qualquer código pode consumir a memória, a CPU e o pool de conexões de qualquer outro, e todo mundo sobe e desce no mesmo deploy.

Um **monólito modular** mantém o deploy e o processo únicos, e impõe fronteiras dentro do código. Cada módulo expõe uma interface pública e esconde o resto. No Python, ferramentas de análise de imports (o import-linter é um exemplo) quebram a CI quando `pagamentos` importa algo interno de `ledger`. Cada módulo é dono das suas tabelas, de preferência num schema próprio do PostgreSQL, e nenhum outro faz `SELECT` nelas. Resolve o acoplamento de código; não resolve o destino compartilhado. O DataFrame de 7 GB do relatório mata o worker do mesmo jeito, só que agora com imports organizados.

**Microsserviços** separam as três fronteiras: cada serviço tem deploy, processo e banco próprios, e fala com os outros pela rede. O relatório pode morrer de OOM à vontade, sozinho, num processo que só serve relatório. O preço é tudo o que o resto deste capítulo descreve.

```text
                 deploy      processo     dados        chamada entre partes
monólito         1           1            1 banco      função (ns)
monólito modular 1           1            schemas      função, via interface
microsserviços   N           N            N bancos     rede (ms) + falha parcial
```

Existe uma quarta forma, que ninguém escolhe e muita gente constrói: o **monólito distribuído**. Serviços separados que precisam subir juntos, compartilham o mesmo banco e se chamam em cadeia síncrona. Ele tem a latência dos microsserviços, o acoplamento do monólito e o orçamento de infraestrutura dos dois. É o pior dos mundos com SLA de cada um deles.

## Acoplamento, coesão e a pergunta que decide a fronteira

**Acoplamento** é o quanto uma mudança numa parte obriga mudança em outra. Ele aparece em formas diferentes, e uma divisão em serviços elimina algumas e cria outras:

| Tipo | Exemplo | O que a separação em serviços faz |
|------|---------|-----------------------------------|
| De código | `import` de função interna | elimina (vira contrato de API) |
| De dados | dois módulos lendo a mesma tabela | elimina só se cada serviço tiver banco próprio |
| Temporal | A só responde se B responder agora | piora: vira dependência de rede |
| De deploy | A e B precisam subir juntos | elimina se os contratos forem compatíveis (capítulo 11) |
| Semântico | os dois precisam concordar sobre o que é "pago" | não muda nada, só muda o lugar da briga |

**Coesão** é o quanto as coisas dentro de uma parte mudam pelos mesmos motivos. A heurística útil para achar fronteira é olhar o histórico do git: arquivos que mudam no mesmo commit, repetidamente, pertencem ao mesmo lugar. Separar em dois serviços duas coisas que sempre mudam juntas transforma cada PR em dois PRs, dois deploys e uma ordem de deploy, e você vai errar a ordem numa sexta-feira.

A fronteira mais barata segue três critérios técnicos: dados que precisam de consistência transacional entre si ficam do mesmo lado; perfis de recurso muito diferentes (CPU pesada, memória grande, latência apertada) ficam de lados diferentes; e requisitos de disponibilidade diferentes ficam de lados diferentes, para que o menos crítico não arraste o mais crítico. O relatório da quinta-feira violou os dois últimos ao mesmo tempo, o que é um tipo de eficiência.

## Um banco por serviço, e o que você perde com ele

Dois serviços que leem a mesma tabela formam um serviço só, com dois deploys e o dobro de plantão. O schema da tabela vira o contrato entre eles, um contrato sem versão, sem changelog e com a Lei de Hyrum (capítulo 11) em vigor: qualquer coluna, qualquer índice, até a ordem implícita das linhas, alguém usa. Renomear uma coluna exige deploy coordenado, que é exatamente o que a separação queria evitar.

Banco por serviço significa que só o dono escreve e lê suas tabelas; os outros perguntam pela API ou recebem eventos. Pode ser um servidor por serviço ou um servidor com bancos e credenciais separados; a fronteira é a permissão, a máquina é decisão de custo.

O que se perde, e onde o livro já tratou de cada perda:

- **JOIN entre domínios.** Vira composição na aplicação (duas chamadas e uma junção em memória) ou projeção local alimentada por eventos (capítulos 19 e 21), com consistência eventual.
- **Transação entre domínios.** Vira saga com outbox (capítulo 18). Atomicidade dá lugar a compensação, e a conciliação vira a verificação final.
- **Integridade referencial.** A FK de `cobrancas.vendedor_id` para `vendedores` deixa de existir. O serviço guarda o ID e confia que ele existia quando foi gravado.

O critério que sobra é direto: se duas entidades precisam de uma restrição verificada no mesmo COMMIT, elas moram no mesmo banco, e portanto no mesmo serviço. Separar e depois reconstruir a atomicidade por saga custa uma saga para cada invariante, e você tem invariantes demais para isso.

## Quanto custa trocar uma função por uma requisição

Uma chamada de função em Python custa dezenas de nanossegundos. Uma chamada a outro serviço na mesma zona custa um RTT de rede (~0,5 ms, pelos números de referência do capítulo 14), mais serialização e desserialização do payload, mais TLS se houver, mais a fila do servidor do outro lado. Na prática, entre 1 e 5 ms no p50 e muito mais na cauda.

Uma chamada dessas se aguenta. O estrago vem da multiplicação. Uma interface fina ("me dá a tarifa", "me dá o split", "me dá o vendedor", onze vezes por cobrança, capítulo 22) que custava 11 chamadas de função passa a custar 11 requisições em série: 11 a 55 ms, onze timeouts para escolher (capítulo 15), onze pontos de falha parcial e onze lugares para o Carlos colocar `@retry(5)`. A regra que sai do mecanismo: interface entre serviços é grossa. Uma chamada carrega tudo o que o chamador precisa para aquela operação.

E a chamada pode simplesmente não voltar. Toda a Parte III deste livro existe porque uma chamada de rede tem um terceiro resultado além de sucesso e erro. Um monólito tem um problema de falha parcial por parceiro externo. Um sistema com seis serviços tem esse problema em cada aresta do grafo de chamadas.

## Disponibilidade composta, ou por que cinco noves de vizinhos dão menos que um

Se uma requisição precisa que os componentes A e B respondam, e eles falham de forma independente, a disponibilidade do caminho é o produto:

```text
série:     A = A1 × A2 × ... × An
paralelo:  A = 1 − (1 − A1) × (1 − A2) × ... × (1 − An)
```

Cinco serviços em série, cada um com 99,9% (43,8 minutos fora por mês), dão 0,999⁵ ≈ 99,50%: cerca de 219 minutos fora por mês. Cada serviço novo no caminho síncrono pega o seu orçamento de falha e soma ao dos outros. Você não comprou cinco componentes com 99,9%; comprou um caminho com 99,5%, e pagou cinco faturas.

Duas réplicas de um componente com 99% em paralelo dão 1 − 0,01² = 99,99%, desde que falhem de forma independente. E aí está a letra miúda: a fórmula supõe independência. Réplicas na mesma zona, com o mesmo deploy e o mesmo bug, falham juntas, e o produto vira ficção otimista. O incidente desta quinta é um exemplo perfeito: três workers "redundantes", em três máquinas, morreram pela mesma causa, no mesmo minuto e meio, clicada pela mesma pessoa.

Há duas saídas da multiplicação. A primeira é tirar componentes do caminho síncrono: o que pode acontecer depois (notificar, contabilizar, atualizar projeção) sai por um log ou fila e deixa de entrar no produto. A segunda é degradação definida (capítulo 15): um componente com fallback deixa de ser série, porque a falha dele não derruba a requisição.

## Lei de Conway, a observação que ninguém revogou

Em 1968, Melvin Conway publicou que organizações que projetam sistemas tendem a produzir projetos que copiam a estrutura de comunicação da própria organização. É uma observação empírica; estudos posteriores sobre a chamada hipótese do espelhamento encontraram evidência compatível com ela em projetos de software, sem transformá-la em lei física. A consequência técnica é mensurável: interfaces entre partes mantidas pelas mesmas pessoas ficam informais e acopladas (todo mundo sabe o que o outro módulo faz, então ninguém documenta), e interfaces entre partes de grupos diferentes ficam formais, versionadas e mais lentas de mudar.

Para a arquitetura, isso significa que uma fronteira de serviço que ninguém mantém de forma separada tende a voltar a acoplar com o tempo. Seis serviços mantidos pelas mesmas poucas pessoas viram, em dois anos, um monólito distribuído com seis repositórios e o mesmo Carlos em todos eles.

## Na Lastro: a fronteira segue a transação

A decisão saiu de três requisitos: a autorização não pode compartilhar destino com cargas de outro perfil (o incidente); um deploy não pode levar mudanças de domínios alheios junto (o Pix do Hornero); e o ledger precisa continuar com transações atômicas e restrições no banco (capítulos 1 a 3).

| Serviço | Dono dos dados | Perfil | No caminho síncrono da autorização? |
|---------|----------------|--------|-------------------------------------|
| pagamentos | cobranças, `eventos_cobranca`, chaves de idempotência, outbox (`pg-pagamentos`) | I/O, latência apertada | sim |
| antifraude | sinais (`redis-sinais`), grafo, chamada ao Vigia | I/O, latência apertada | sim, com degradação |
| ledger | contas, lançamentos, saldos (`pg-ledger`) | escrita transacional | não |
| repasses | sagas de repasse, lease do job | lote, chamadas ao banco do Pix | não |
| notificações | inscrições, entregas (`pg-notificacoes`) | I/O, volume alto | não |
| relatórios | nada; lê o colunar e a `pg-ledger-relat` | CPU e memória pesadas | não |

A mudança mais séria é a fronteira entre pagamentos e ledger, e ela muda uma decisão do capítulo 21. Lá, `eventos_cobranca` e os lançamentos iam no mesmo COMMIT do primário do ledger. Agora, pagamentos grava o evento e a outbox no `pg-pagamentos`, e o ledger consome `cobrancas.eventos` e registra a transação contábil com `referencia` UNIQUE (capítulo 16): at-least-once mais deduplicação, efeito único. O motivo é a disponibilidade: com o ledger fora do caminho síncrono, a autorização deixa de depender dele. O custo é uma janela de milissegundos a segundos em que a cobrança está paga e o saldo ainda não. A conciliação ganhou uma classe nova, "cobrança paga sem transação no ledger após 5 minutos", e o alerta de atraso do consumidor fica em 30 segundos.

O débito continua síncrono e transacional. Repasses chama a API do ledger para debitar, e o lock, o serializable e o trigger dos capítulos 2 e 3 continuam dentro de um banco só. O ledger é o único serviço que escreve em `pg-ledger`, e o tabelião agora tem um cliente só, o que ele considera uma promoção.

A conta do caminho da autorização, com disponibilidades por componente assumidas como hipótese de projeto (o SLO formal fica para o capítulo 39):

```text
                       proxy   pagam.  banco   antifr. sinais  ledger  pg-ledger adquir.
tudo síncrono         .9999 × .9995 × .9995 × .999 × .999 × .9995 × .9995 × .999  ≈ 99,49%  (~223 min/mês)
ledger assíncrono,
antifraude degradável .9999 × .9995 × .9995 ×  -   ×  -   ×   -   ×   -    × .999  ≈ 99,79%  (~92 min/mês)
```

A segunda linha vale para cobranças de até R$ 300,00; acima disso, o antifraude fora ainda recusa (capítulo 15) e volta ao produto. O monólito de hoje (proxy, monólito, banco, adquirente) também dá ~99,79%. A divisão bem feita preserva a disponibilidade do caminho e ganha isolamento; a divisão ingênua, com todo mundo chamando todo mundo, dobraria os minutos fora. A diferença entre as duas linhas é uma decisão sobre o que pode acontecer depois.

Pagamentos chama o antifraude uma vez por autorização, com interface grossa: `avaliar` recebe a cobrança e devolve a decisão, e o antifraude calcula os sinais e chama o Vigia por dentro. O deadline (capítulo 15) é propagado, e o antifraude responde com a degradação do capítulo 15 se estourar. Um salto de rede a mais, ~1 ms, sai da folga de 120 ms do orçamento do capítulo 14.

Mais processos significa mais conexões. O capítulo 4 adiou o PgBouncer para cá, e ele entra em modo transaction na frente de `pg-ledger` e `pg-pagamentos`. As conexões de `LISTEN` (capítulo 12) continuam diretas, porque `LISTEN` precisa de sessão, e os advisory locks do dia contábil (capítulo 20) ficam no nível da transação (`pg_advisory_xact_lock_shared`), que o modo transaction suporta; um advisory lock de sessão sobreviveria ao COMMIT preso a uma conexão que o PgBouncer já entregou a outro cliente.

A ordem da migração é a do risco: primeiro o monólito vira modular, com schemas por módulo e import-linter na CI; depois saem relatórios (sem dados próprios, risco zero), notificações (já tinha banco próprio desde o capítulo 17), antifraude e repasses; a separação dos bancos de pagamentos e ledger vai por último, com replicação lógica e fencing (capítulo 24). Cada serviço roda em processos próprios nas mesmas três máquinas, por enquanto, e o relatório tem limite de memória, então morre sozinho.

A alternativa que fica registrada: se a Lastro tivesse um único perfil de carga e um deploy por semana sem incidentes cruzados, o monólito modular resolveria o acoplamento de código sem pagar rede, sagas e PgBouncer. Ele é o primeiro passo da migração justamente porque continua sendo uma arquitetura válida se o resto parar no meio.

## Armadilhas e casos reais

> **Armadilha:** dividir por entidade em vez de por transação. Um "serviço de vendedores", um "serviço de contas" e um "serviço de saldos" separados fazem do saque uma saga de três passos, e o vendedor 42 vai achar a janela entre o segundo e o terceiro antes do monitoramento.

> **Armadilha:** o serviço que só repassa a chamada. Um "serviço de tarifas" que recebe a requisição, chama o banco e devolve o resultado adiciona um salto de rede, um fator no produto da disponibilidade e um plantão, em troca de nada. A tarifa continua em cache dentro de pagamentos (capítulo 22), versionada.

> **Na vida real:** em 2023, a equipe do Prime Video publicou que juntou num único processo uma ferramenta de monitoramento de qualidade de vídeo construída antes com componentes distribuídos (funções serverless e uma máquina de estados), porque o custo de passar cada quadro entre componentes pela rede e por armazenamento intermediário dominava o sistema; o relato fala em redução de custo de infraestrutura acima de 90%. O caso mostra o custo de uma fronteira posta onde o dado trafega em volume, e diz pouco sobre microsserviços em geral, que é como a internet resolveu ler.

> **Armadilha:** relógios, IDs e configuração "compartilhados" por cópia. Seis serviços copiando a tabela de tarifas em seis caches, com seis TTLs diferentes, fazem o sorteio de tarifas do capítulo 22 renascer em escala. Configuração tem um dono, e os outros recebem eventos dele.

## Resumo

- Monólito, monólito modular e microsserviços diferem nas fronteiras de deploy, de processo e de dados.
- Acoplamento tem tipos (código, dados, temporal, deploy, semântico); serviços eliminam alguns e pioram o temporal.
- Banco por serviço: o schema deixa de ser contrato; JOIN vira composição ou projeção, transação vira saga, FK desaparece.
- Chamada de rede custa milissegundos e falha parcial; interfaces entre serviços são grossas.
- Disponibilidade em série é o produto; em paralelo, 1 − produto das indisponibilidades; ambas supõem independência.
- Assíncrono e degradação tiram componentes do produto.
- Lei de Conway: observação empírica de que a estrutura do sistema acompanha a de comunicação de quem o mantém.

## A Lastro agora

A Lastro tem seis serviços (pagamentos, antifraude, ledger, repasses, notificações, relatórios), cada um com deploy próprio e dono único dos seus dados. O ledger saiu do caminho da autorização: consome os eventos de cobrança com referência única e só atende débitos síncronos de repasses. O caminho da autorização segue em ~99,79% na conta de projeto, o PgBouncer finalmente chegou, e o relatório de risco morre agora num processo com limite de memória, sem levar ninguém junto. O Hornero recebeu a correção do Pix num deploy só dele, com uma mudança, de uma pessoa.

Falta um detalhe. Seis serviços em três máquinas, cada um com várias réplicas, e por enquanto cada chamador tem uma lista de IPs e portas num arquivo de configuração que o Carlos mantém à mão, "porque são só seis". Na primeira vez que uma réplica de pagamentos morrer, o antifraude vai continuar mandando requisições para ela com a fidelidade de um cachorro esperando na estação.

## Referências

- Conway, M. E., "How Do Committees Invent?", Datamation, abril de 1968: https://www.melconway.com/Home/Committees_Paper.html
- import-linter, documentação: https://import-linter.readthedocs.io/
- PgBouncer, documentação (modos de pool e recursos suportados): https://www.pgbouncer.org/features.html
- Prime Video Tech, "Scaling up the Prime Video audio/video monitoring service and reducing costs by 90%", 2023: https://www.primevideotech.com/video-streaming/scaling-up-the-prime-video-audio-video-monitoring-service-and-reducing-costs-by-90
