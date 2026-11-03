# O livro: público, proposta, tamanho e sumário

## Público-alvo

Dev **sênior full stack** que sempre trabalhou na implementação: recebe a tarefa, escreve o código, entrega. Nunca foi líder técnico, nunca tomou decisões de arquitetura e nunca precisou pensar o backend como um sistema inteiro (dados, rede, falhas, segurança, infraestrutura, operação).

O que o leitor **já sabe** (não explicar):
- Python, frameworks web (FastAPI, Django ou Flask), JavaScript/TypeScript e React.
- HTTP no nível da aplicação, REST, JSON, SQL do dia a dia, ORMs, git, terminal, variáveis de ambiente, Docker no nível de "rodar um `docker compose up`".
- Testes, debugging, organização de código dentro de uma aplicação.

O que o leitor **não sabe** (explicar do zero, sem condescendência):
- O que acontece abaixo do framework: rede, TLS, sistema operacional, modelos de concorrência.
- O que acontece dentro do banco: índices, planos de execução, isolamento, locks, replicação.
- Sistemas distribuídos: consistência, falhas parciais, mensageria, transações entre serviços.
- Arquitetura e APIs como decisão: propriedades e custos de cada opção.
- Segurança de backend, infraestrutura, deploy e operação.
- O domínio de pagamentos (ledger, cartão, Pix, conciliação): o livro ensina o que o projeto precisa, como conteúdo técnico.

Regra de ouro: tratar o leitor como um colega experiente que nunca precisou olhar para fora do próprio código. Nada de explicar o que é uma função ou um `JOIN`. Mas também nada de pular um conceito de sistemas assumindo que ele já conhece.

O leitor é inteligente e entende de tecnologia: o livro explica o mecanismo diretamente, no nível técnico, sem analogias de cotidiano. Sempre que houver uma **relação técnica real** com algo que ele já domina, usá-la (ex.: a busca numa B-tree é uma busca binária generalizada para nós com muitas chaves; uma migração expand/contract segue a mesma sequência de deprecar um parâmetro de função antes de removê-lo).

O livro é para ser lido, não executado: o leitor não roda os exemplos nem implementa o projeto.

## Proposta

O livro ensina o **conhecimento técnico** de que esse dev precisa para ser o líder técnico do backend: tomar decisões de arquitetura, entender o banco e a rede, lidar com a infraestrutura e responder pelo sistema em produção.

- **Um projeto conduz o livro**: o backend da Lastro, uma fintech fictícia de pagamentos para marketplaces, definida em `instrucoes/projeto.md`. Cada capítulo parte de um problema da Lastro, ensina o assunto técnico que resolve esse problema e deixa o projeto um passo adiante. O projeto é descrito, nunca implementado.
- **Só conteúdo técnico e objetivo**: conhecimento definido, verificável, com mecânica, números, especificações e comportamentos conhecidos. Nada de capítulos sobre liderança de pessoas, comunicação, processos de equipe, "mentalidade" ou filosofia de trabalho.
- **Sem opinião.** Quando houver mais de uma opção (REST ou gRPC, fila ou log, lock otimista ou pessimista), o capítulo apresenta as propriedades e os custos mensuráveis de cada uma e as condições em que cada propriedade importa. A Lastro escolhe uma delas por um requisito concreto do projeto, e o texto diz em que condições a outra seria a escolha certa (ver "Regras de continuidade" em `instrucoes/projeto.md`).
- **Técnico não significa só código.** Mecanismos, protocolos, algoritmos, fórmulas, especificações (RFCs, padrões), garantias formais e trade-offs quantificáveis são todos conteúdo técnico.

## Capítulos em sequência

O livro é lido em ordem. A ordem do sumário segue a vida da Lastro: do monólito com um banco ao sistema distribuído operado em produção.

- Cada capítulo começa do estado em que o anterior deixou a Lastro e pode retomar decisões, componentes e piadas recorrentes de capítulos anteriores. Sem recapitulação longa: uma ou duas frases bastam para situar o leitor.
- Cada capítulo ensina o seu assunto por inteiro. Um conceito que é tema de outro capítulo já escrito pode ser usado com uma remissão curta ("como no capítulo 3, a transferência roda numa transação serializable"); um conceito que só será aprofundado adiante é explicado no mínimo necessário, com a remissão para frente.
- O capítulo termina com o estado da Lastro e uma frase que aponta o problema do capítulo seguinte (ver `instrucoes/estrutura-do-capitulo.md`).
- Exemplos fora da Lastro são permitidos quando ensinam melhor (casos reais, contraexemplos), mas a aplicação do conceito acontece no projeto.

## Tamanho

- **40 capítulos**, em 6 partes.
- Cada capítulo: **2.000 a 3.000 palavras** (contando o texto e excluindo blocos de código).
- Com esse tamanho, os temas amplos (Kubernetes, autenticação, mensageria) cobrem o que um líder técnico precisa para decidir e operar, sem virar manual completo. Escolher o que importa e cortar o resto.

## Sumário

A coluna **Na Lastro** é o roteiro do projeto: o problema que abre o capítulo e o que muda no projeto ao final. Os detalhes (números, nomes, o cenário exato) ficam a critério de quem escreve, desde que coerentes com os resumos anteriores.

### Parte I — O núcleo: dinheiro no banco de dados

A primeira versão da Lastro: um monólito, um PostgreSQL e o primeiro cliente, o marketplace Bazar Bem-te-vi.

| # | Arquivo | Título | Conteúdo técnico | Na Lastro |
|---|---------|--------|------------------|-----------|
| 01 | `01-modelagem-relacional.md` | Modelagem relacional | Representação de dinheiro (inteiro em unidades mínimas, `NUMERIC`, por que não ponto flutuante, arredondamento), ledger de partidas dobradas, chaves (naturais, substitutas, UUID e sequências), formas normais até a 3FN e BCNF, anomalias de atualização, desnormalização e o custo de manter cópias, restrições de integridade no banco. | O protótipo de `temp-01` guarda o saldo como um `float` numa coluna e diverge da planilha da conciliação. O ledger é modelado: contas, transações, lançamentos imutáveis que somam zero, saldo derivado, estorno como novo lançamento. |
| 02 | `02-concorrencia-na-aplicacao.md` | Concorrência na aplicação | Condições de corrida, seções críticas, locks e mutex, deadlock (condições de Coffman), operações atômicas, check-then-act, concorrência entre processos e réplicas, locks distribuídos e seus limites. | Um vendedor dispara dois saques ao mesmo tempo e saca o dobro do saldo. Um lock em memória resolve com um processo e falha com três réplicas; a verificação de saldo sai do código Python e vai para o banco. |
| 03 | `03-transacoes-e-isolamento.md` | Transações e isolamento | ACID, níveis de isolamento do padrão SQL, anomalias (dirty read, non-repeatable read, phantom, lost update, write skew), MVCC, snapshot isolation, serializable no PostgreSQL. | Lançar um pagamento com split toca várias contas e precisa ser atômico. O limite diário de saque sofre write skew em repeatable read. A Lastro define o isolamento de cada operação do ledger e o tratamento de falhas de serialização. |
| 04 | `04-locks-contencao-e-pools-de-conexao.md` | Locks, contenção e pools de conexão | Locks de linha e de tabela, `SELECT ... FOR UPDATE`, `SKIP LOCKED`, controle otimista com versão, deadlocks no banco, custo de uma conexão, pools na aplicação e externos (PgBouncer), dimensionamento do pool. | A conta de comissão do Bazar recebe um lançamento em cada venda e vira uma conta quente: as transações fazem fila no lock e o pool de conexões esgota. Estratégias para contas quentes e o dimensionamento do pool. |
| 05 | `05-indices.md` | Índices | B-tree por dentro, hash, GIN e GiST, índices compostos e ordem das colunas, índices de cobertura, índices parciais e de expressão, seletividade e cardinalidade, custo de escrita de cada índice. PostgreSQL como referência. | O extrato do vendedor por período fica lento com 40 milhões de lançamentos. Os índices do ledger são escolhidos pelos padrões de acesso, pesando o custo em cada escrita. |
| 06 | `06-planos-de-execucao.md` | Planos de execução | `EXPLAIN` e `EXPLAIN ANALYZE`, seq scan, index scan e index-only scan, nested loop, hash join e merge join, estatísticas e estimativas de linhas, problema N+1 gerado por ORM, paginação por offset e por cursor. | O painel do marketplace com as vendas do dia gera centenas de consultas por tela e a página 4.000 do extrato leva segundos. Leitura de planos, correção do N+1 e paginação por cursor na API. |
| 07 | `07-migracoes-sem-downtime.md` | Migrações de schema sem downtime | Locks de DDL, operações seguras e perigosas no PostgreSQL, padrão expand/contract, backfill em lotes, criação de índice concorrente, compatibilidade entre versões do código durante o deploy. | Suporte a múltiplas moedas exige mudar a tabela de lançamentos, já com centenas de milhões de linhas, sem parar o Pix, que funciona 24x7. A migração é planejada em fases. |

### Parte II — A API no mundo

A Lastro abre a API para os marketplaces integrarem e se prepara para a primeira Black Friday.

| # | Arquivo | Título | Conteúdo técnico | Na Lastro |
|---|---------|--------|------------------|-----------|
| 08 | `08-tcp-ip-e-dns.md` | TCP/IP e DNS | Camadas, IP, portas, TCP (handshake, controle de fluxo e de congestionamento, TIME_WAIT) e UDP, latência de rede (RTT), NAT, IP público e privado, CIDR. DNS: resolvers, servidores autoritativos, tipos de registro, TTL, cache. | Um novo marketplace reclama que cada chamada à API leva 300 ms a mais do que o processamento; a troca de `temp-01` por um servidor novo esbarra no TTL do DNS e no IP fixo que um parceiro exige liberar no firewall. |
| 09 | `09-http-em-profundidade.md` | HTTP em profundidade | HTTP/1.1, HTTP/2 (multiplexação, HPACK) e HTTP/3 (QUIC), keep-alive e reuso de conexão, semântica dos métodos (segurança e idempotência), códigos de status, cabeçalhos de cache (`Cache-Control`, `ETag`, validação condicional), CORS. | A API de cobranças é desenhada sobre a semântica do HTTP: método e status certos para criar, consultar e estornar cobranças, `202` para o que termina depois, reuso de conexão com o adquirente, CORS no checkout que roda no navegador do comprador. |
| 10 | `10-tls-e-certificados.md` | TLS e certificados | Handshake do TLS 1.3, troca de chaves, cadeia de confiança, autoridades certificadoras, SNI, terminação TLS em proxy, renovação automática (ACME), mTLS. | O certificado da API expira de madrugada e as cobranças param. TLS na API pública com renovação automática; mTLS com o banco parceiro que dá acesso ao Pix. |
| 11 | `11-contratos-de-api.md` | Contratos de API | Compatibilidade retroativa e o que a quebra, estratégias de versionamento, paginação, filtros, formato de erros (RFC 9457), OpenAPI, testes de contrato. | Um campo novo no payload quebra a integração do Bazar. A Lastro define regras de compatibilidade, versionamento, formato de erros e o contrato dos webhooks. |
| 12 | `12-estilos-de-comunicacao.md` | Estilos de comunicação | REST, gRPC (Protocol Buffers, streaming), GraphQL (resolvers, N+1, custo de consulta), WebSocket e SSE, webhooks: propriedades, formato no fio, suporte a cache e a streaming, requisitos de infraestrutura. | Marketplaces pedem GraphQL para o painel, o checkout quer saber em tempo real quando o Pix foi pago e o fornecedor de antifraude só oferece gRPC. Cada canal da Lastro recebe o estilo que suas propriedades pedem. |
| 13 | `13-processos-threads-e-io-assincrono.md` | Processos, threads e I/O assíncrono | Processo e thread, troca de contexto, I/O bloqueante e não bloqueante, epoll, event loop, `asyncio`, GIL, modelos de servidor (prefork, workers, ASGI), dimensionamento de workers para carga de CPU e de I/O. | Cada autorização de cartão espera ~800 ms pelo adquirente e os workers síncronos ficam todos parados esperando rede. O modelo de servidor da API é redimensionado para carga de I/O. |
| 14 | `14-desempenho-mensuravel.md` | Desempenho mensurável | Latência e throughput, percentis (p50, p99) e por que médias enganam, Lei de Little, Lei de Amdahl, utilização e filas (por que a latência explode perto de 100%), números de latência de referência, testes de carga (open e closed model, coordinated omission). | O Bazar exige p99 abaixo de um limite na autorização durante a Black Friday. Orçamento de latência do fluxo de pagamento, teste de carga correto e a capacidade necessária calculada antes do evento. |

### Parte III — Dinheiro entre sistemas

O adquirente, o banco do Pix e os webhooks dos clientes: fluxos que atravessam fronteiras e falham pela metade.

| # | Arquivo | Título | Conteúdo técnico | Na Lastro |
|---|---------|--------|------------------|-----------|
| 15 | `15-falhas-parciais.md` | Falhas parciais | Tipos de falha, timeouts (como escolher o valor), retries com backoff exponencial e jitter, retry storms, circuit breaker, bulkhead, deadlines propagados, degradação controlada. | A chamada ao adquirente estoura o timeout: o comprador foi cobrado ou não? Timeouts, retries seguros, circuit breaker por parceiro e o deadline do fluxo de autorização. |
| 16 | `16-idempotencia-e-semantica-de-entrega.md` | Idempotência e semântica de entrega | At-most-once, at-least-once e exactly-once (e o que esse último significa de fato), chaves de idempotência em APIs, deduplicação, operações naturalmente idempotentes. | O marketplace reenvia a criação de cobrança após um timeout e o comprador paga duas vezes. Chave de idempotência na API, EndToEndId como chave natural do Pix, deduplicação no ledger. |
| 17 | `17-mensageria.md` | Mensageria | Fila e log, consumidores concorrentes, consumer groups, offsets e acknowledgments, ordenação e partições, DLQ, visibility timeout, backlog. Kafka, RabbitMQ e Amazon SQS como exemplos de cada modelo. | Os webhooks saem dentro da requisição e um cliente lento derruba a API. Eventos de pagamento passam por um broker; entrega de webhooks com retentativas, ordem por cobrança e DLQ. A Lastro escolhe o broker. |
| 18 | `18-transacoes-distribuidas.md` | Transações distribuídas | O problema da escrita dupla, two-phase commit e seus bloqueios, sagas (orquestração e coreografia) e ações compensatórias, padrão outbox, change data capture. Conciliação como verificação final entre sistemas. | O ledger registra o pagamento e o evento nunca é publicado (ou o contrário). O fluxo de pagamento vira uma saga com outbox e estorno como compensação; a conciliação diária com o arquivo do adquirente fecha o que escapou. |
| 19 | `19-modelos-de-consistencia.md` | Modelos de consistência | Teorema CAP com a definição precisa, PACELC, linearizabilidade, consistência sequencial, causal e eventual, garantias de sessão. | O vendedor vê um saldo no painel e o saque é recusado por saldo insuficiente. Cada leitura da Lastro recebe a garantia de que precisa: saque exige linearizabilidade, painel aceita consistência eventual com garantias de sessão. |
| 20 | `20-tempo-ordem-e-consenso.md` | Tempo, ordem e consenso | Relógios físicos e desvio, NTP, relógios lógicos de Lamport, vector clocks, o problema do consenso, eleição de líder, Raft no essencial, leases e fencing tokens. | O `repasse_final_v2_agora_vai.py` roda em duas réplicas e paga os vendedores duas vezes; o corte diário de liquidação depende de qual relógio. Lease com fencing token para o job de repasse e ordem dos lançamentos sem depender do relógio de parede. |
| 21 | `21-event-sourcing-e-cqrs.md` | Event sourcing e CQRS | Eventos como fonte da verdade, event store, projeções, snapshots, versionamento de eventos, separação de leitura e escrita, consistência das projeções, custos operacionais. | Um chargeback exige reconstruir o estado de uma cobrança em qualquer instante passado. O ciclo de vida das cobranças vira um log de eventos e o extrato vira projeção; o ledger, que já é append-only, mostra o que a Lastro tinha de event sourcing sem saber. |

### Parte IV — Escala

Dezenas de marketplaces, o ledger crescendo sem parar e o monólito ficando pequeno.

| # | Arquivo | Título | Conteúdo técnico | Na Lastro |
|---|---------|--------|------------------|-----------|
| 22 | `22-cache.md` | Cache | Cache-aside, read-through, write-through e write-behind, invalidação, TTL, políticas de despejo (LRU, LFU), cache stampede e suas soluções, cache em camadas (processo, Redis, HTTP, CDN), consistência entre cache e banco. | Tarifas e configurações de split são lidas em toda cobrança. O que a Lastro põe em cache, como invalida, e por que o saldo usado no saque fica fora dele. |
| 23 | `23-replicacao.md` | Replicação | Replicação síncrona e assíncrona, WAL e replicação lógica, réplicas de leitura, lag de replicação, read-your-writes, failover e split-brain, replicação multi-líder e sem líder (quórum). | Os relatórios dos marketplaces disputam o primário com o ledger. Réplicas de leitura para relatórios e painel, read-your-writes após um saque, failover sem perder lançamento confirmado. |
| 24 | `24-particionamento-e-sharding.md` | Particionamento e sharding | Particionamento de tabelas no banco, sharding por faixa e por hash, consistent hashing, hot spots, consultas entre shards, rebalanceamento, escolha da chave de partição. | A tabela de lançamentos passa de bilhões de linhas. Particionamento por tempo, escolha da chave de sharding do ledger e o que acontece com transferências entre contas de shards diferentes. |
| 25 | `25-modelos-nao-relacionais.md` | Modelos não relacionais | Chave-valor, documento, colunar, grafo e séries temporais: modelo de dados, padrões de acesso suportados, garantias de consistência e o que cada um não faz. Modelar a partir dos padrões de acesso. | O antifraude precisa de contadores por cartão e por dispositivo em milissegundos, de um grafo de contas ligadas para achar fraude em anel e de agregações analíticas. Cada padrão de acesso recebe o modelo de dados que o suporta; o ledger continua relacional. |
| 26 | `26-decomposicao-de-sistemas.md` | Decomposição de sistemas | Monólito, monólito modular e microsserviços, acoplamento e coesão, fronteiras de dados (um banco por serviço), custo de uma chamada de rede, disponibilidade composta de serviços em série, Lei de Conway como observação empírica. | O deploy do relatório derruba a autorização. O monólito é dividido (ledger, pagamentos, antifraude, repasses, notificações) com fronteiras de dados, e a conta da disponibilidade composta do caminho da autorização. |
| 27 | `27-balanceamento-e-proxies.md` | Balanceamento e proxies | Balanceamento em camada 4 e 7, algoritmos (round robin, least connections, hash consistente), health checks, sticky sessions, reverse proxy, API gateway, service mesh, CDN. | Os serviços novos precisam de um ponto de entrada e de tráfego interno. API gateway na borda, balanceamento entre réplicas, health checks que não derrubam tudo junto, IP de saída fixo para os parceiros. |
| 28 | `28-controle-de-carga.md` | Controle de carga | Rate limiting (token bucket, leaky bucket, janela fixa e deslizante), rate limiting distribuído, backpressure, load shedding, filas limitadas, cabeçalhos `Retry-After` e `429`. | A integração com bug de um marketplace dispara milhares de consultas por segundo e atrasa as cobranças de todos. Rate limiting por cliente e load shedding que sacrifica relatórios antes de autorizações. |
| 29 | `29-escalabilidade-e-capacidade.md` | Escalabilidade e capacidade | Escala vertical e horizontal, serviços stateless e onde fica o estado, autoscaling (métricas, histerese, tempo de reação), estimativa de capacidade com cálculos de ordem de grandeza (requisições, armazenamento, banda). | A Lastro fecha contrato com um marketplace dez vezes maior que o Bazar. Estimativa de capacidade (TPS de pico, crescimento do ledger com retenção de anos, banda dos webhooks) e autoscaling dos serviços stateless. |

### Parte V — Segurança

Dinheiro atrai atacante, e dado de cartão atrai auditor.

| # | Arquivo | Título | Conteúdo técnico | Na Lastro |
|---|---------|--------|------------------|-----------|
| 30 | `30-autenticacao.md` | Autenticação | Sessões com cookie, tokens opacos e JWT (estrutura, assinatura, expiração, revogação), OAuth 2.0 (fluxos atuais, PKCE), OpenID Connect, MFA, passkeys (WebAuthn). | Uma chave de API do Bazar aparece num repositório público. Credenciais dos marketplaces (chaves de API, client credentials, mTLS), login do painel dos vendedores com MFA e passkeys, revogação. |
| 31 | `31-autorizacao-e-multitenancy.md` | Autorização e multitenancy | RBAC, ABAC e ReBAC, onde aplicar a checagem, IDOR, modelos de isolamento entre tenants (banco por tenant, schema por tenant, coluna de tenant, row-level security). | Trocar o ID na URL mostra a cobrança de outro marketplace. Marketplaces como tenants, vendedores dentro deles, permissões por papel e row-level security no banco. |
| 32 | `32-vulnerabilidades-de-backend.md` | Vulnerabilidades de backend | OWASP Top 10 e OWASP API Security Top 10 aplicados a um backend Python: injeção, SSRF, deserialização insegura, falhas de autorização por objeto, exposição de dados, dependências vulneráveis. | A URL de webhook cadastrada por um cliente aponta para o endpoint de metadados da nuvem (SSRF). Revisão da superfície de ataque da Lastro pelas listas da OWASP. |
| 33 | `33-criptografia-aplicada-e-segredos.md` | Criptografia aplicada e segredos | Hash de senhas (Argon2, bcrypt), criptografia simétrica autenticada (AES-GCM) e assimétrica, assinaturas, HMAC, envelope encryption e KMS, gestão e rotação de segredos. Tokenização. | O número do cartão aparece em log, e o escopo do PCI DSS passa a cobrir quase tudo. Tokenização do cartão num cofre isolado, envelope encryption com KMS, HMAC na assinatura dos webhooks, rotação de segredos. |

### Parte VI — Infraestrutura e operação

Do `temp-01` a um sistema que roda, muda e se recupera sem perder um centavo.

| # | Arquivo | Título | Conteúdo técnico | Na Lastro |
|---|---------|--------|------------------|-----------|
| 34 | `34-conteineres.md` | Contêineres | Namespaces e cgroups, imagens e camadas, build em múltiplos estágios, imagens mínimas, PID 1 e sinais, limites de memória e CPU, registries, OCI. | Um deploy mata processos no meio de autorizações e o contêiner é morto por falta de memória sem log. Imagens dos serviços, encerramento gracioso e limites. |
| 35 | `35-kubernetes.md` | Kubernetes | Arquitetura (control plane e nós), pods, deployments, services, ingress, ConfigMaps e Secrets, requests e limits, probes, rolling update, HPA. | Os serviços da Lastro vão para o Kubernetes. Probes que não matam pods sob carga, requests e limits, rolling update sem derrubar autorizações; o banco do ledger fica fora do cluster. |
| 36 | `36-redes-em-nuvem-e-infraestrutura-como-codigo.md` | Redes em nuvem e infraestrutura como código | Rede virtual, sub-redes públicas e privadas, tabelas de rota, NAT, firewalls com estado e sem estado, regiões e zonas de disponibilidade. Infraestrutura como código com Terraform: estado, plan e apply, drift, módulos. | O ambiente de dados de cartão precisa ficar segmentado do resto, e `temp-01` finalmente é desligado. Rede da Lastro em sub-redes, NAT com IP fixo para os parceiros, tudo em Terraform. |
| 37 | `37-ci-cd-e-estrategias-de-deploy.md` | CI/CD e estratégias de deploy | Pipeline de build, teste e deploy, artefatos imutáveis, rolling, blue-green e canary, feature flags, rollback e roll forward, credenciais de curta duração no pipeline (OIDC). | Uma mudança no cálculo de tarifa erra centavos em todas as cobranças por uma hora. Canary no serviço de pagamentos com métricas de negócio, feature flags e rollback de código que já gravou lançamentos. |
| 38 | `38-observabilidade.md` | Observabilidade | Logs estruturados, métricas (contadores, gauges, histogramas, cardinalidade), tracing distribuído e propagação de contexto, OpenTelemetry, métodos RED e USE. | O Bazar avisa antes do monitoramento que a taxa de aprovação caiu. Trace de uma cobrança da API ao webhook, métricas técnicas e de negócio, logs sem dados de cartão. |
| 39 | `39-sli-slo-e-sla.md` | SLI, SLO e SLA | Definições, como medir um SLI, metas em "noves" e o tempo de indisponibilidade de cada uma, error budget, alertas por taxa de consumo do error budget (burn rate). | O novo contrato traz um SLA com multa. SLIs da autorização e do Pix, SLOs internos mais rígidos que o SLA, alertas por burn rate. |
| 40 | `40-backup-e-recuperacao-de-desastres.md` | Backup e recuperação de desastres | RPO e RTO, backup completo, incremental e contínuo (point-in-time recovery), regra 3-2-1, estratégias de recuperação de desastres (backup e restauração, pilot light, warm standby, ativo-ativo), testes de restauração. | Um `UPDATE` sem `WHERE` atinge a tabela de contas e a região principal fica indisponível no mesmo mês. RPO zero para o ledger, point-in-time recovery, região secundária, testes de restauração e a conciliação depois do failover. |
