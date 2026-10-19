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

Regra de ouro: tratar o leitor como um colega experiente que nunca precisou olhar para fora do próprio código. Nada de explicar o que é uma função ou um `JOIN`. Mas também nada de pular um conceito de sistemas assumindo que ele já conhece.

O leitor é inteligente e entende de tecnologia: o livro explica o mecanismo diretamente, no nível técnico, sem analogias de cotidiano. Sempre que houver uma **relação técnica real** com algo que ele já domina, usá-la (ex.: a busca numa B-tree é uma busca binária generalizada para nós com muitas chaves; uma migração expand/contract segue a mesma sequência de deprecar um parâmetro de função antes de removê-lo).

O livro é para ser lido, não executado: o leitor não roda os exemplos na própria máquina.

## Proposta

O livro ensina o **conhecimento técnico** de que esse dev precisa para ser o líder técnico do backend: tomar decisões de arquitetura, entender o banco e a rede, lidar com a infraestrutura e responder pelo sistema em produção.

- **Só conteúdo técnico e objetivo**: conhecimento definido, verificável, com mecânica, números, especificações e comportamentos conhecidos. Nada de capítulos sobre liderança de pessoas, comunicação, processos de equipe, "mentalidade" ou filosofia de trabalho.
- **Sem opinião.** Quando houver mais de uma opção (REST ou gRPC, fila ou log, lock otimista ou pessimista), o capítulo apresenta as propriedades e os custos mensuráveis de cada uma e as condições em que cada propriedade importa. Não declara vencedores nem dá "a melhor prática" sem justificar com um mecanismo ou um número.
- **Técnico não significa só código.** Mecanismos, protocolos, algoritmos, fórmulas, especificações (RFCs, padrões), garantias formais e trade-offs quantificáveis são todos conteúdo técnico.

## Capítulos independentes

**Não há projeto-fio.** Cada capítulo é um texto autônomo, que pode ser lido sozinho e fora de ordem.

- Nenhum capítulo depende do estado deixado por outro. Não há recapitulação do capítulo anterior nem ponte para o próximo.
- Se um capítulo precisa de um conceito que é tema de outro, explica o mínimo necessário em uma ou duas frases e pode indicar o capítulo onde o assunto é aprofundado ("o capítulo 10 trata dos níveis de isolamento em detalhe"). Nunca pressupor que o leitor leu o outro capítulo.
- Os exemplos são próprios de cada capítulo: pequenos, isolados e escolhidos para aquele conceito (uma tabela de pedidos, uma API de pagamentos, um worker de e-mails). Não reaproveitar um mesmo sistema fictício ao longo do livro.
- A ordem do sumário ainda é intencional: vai do mais baixo nível (rede, SO) ao mais alto (arquitetura, operação), para quem quiser ler do início ao fim.

## Tamanho

- **40 capítulos**, em 6 partes.
- Cada capítulo: **2.000 a 3.000 palavras** (contando o texto e excluindo blocos de código).
- Com esse tamanho, os temas amplos (Kubernetes, autenticação, mensageria) cobrem o que um líder técnico precisa para decidir e operar, sem virar manual completo. Escolher o que importa e cortar o resto.

## Sumário

### Parte I — Fundamentos de sistemas

| # | Arquivo | Título | Conteúdo principal |
|---|---------|--------|--------------------|
| 01 | `01-tcp-ip-e-dns.md` | TCP/IP e DNS | Camadas, IP, portas, TCP (handshake, controle de fluxo e de congestionamento, TIME_WAIT) e UDP, latência de rede (RTT), NAT, IP público e privado, CIDR. DNS: resolvers, servidores autoritativos, tipos de registro, TTL, cache. |
| 02 | `02-http-em-profundidade.md` | HTTP em profundidade | HTTP/1.1, HTTP/2 (multiplexação, HPACK) e HTTP/3 (QUIC), keep-alive e reuso de conexão, semântica dos métodos (segurança e idempotência), códigos de status, cabeçalhos de cache (`Cache-Control`, `ETag`, validação condicional), CORS. |
| 03 | `03-tls-e-certificados.md` | TLS e certificados | Handshake do TLS 1.3, troca de chaves, cadeia de confiança, autoridades certificadoras, SNI, terminação TLS em proxy, renovação automática (ACME), mTLS. |
| 04 | `04-processos-threads-e-io-assincrono.md` | Processos, threads e I/O assíncrono | Processo e thread, troca de contexto, I/O bloqueante e não bloqueante, epoll, event loop, `asyncio`, GIL, modelos de servidor (prefork, workers, ASGI), dimensionamento de workers para carga de CPU e de I/O. |
| 05 | `05-concorrencia-na-aplicacao.md` | Concorrência na aplicação | Condições de corrida, seções críticas, locks e mutex, deadlock (condições de Coffman), operações atômicas, check-then-act, concorrência entre processos e réplicas, locks distribuídos e seus limites. |
| 06 | `06-desempenho-mensuravel.md` | Desempenho mensurável | Latência e throughput, percentis (p50, p99) e por que médias enganam, Lei de Little, Lei de Amdahl, utilização e filas (por que a latência explode perto de 100%), números de latência de referência, testes de carga (open e closed model, coordinated omission). |

### Parte II — Dados

| # | Arquivo | Título | Conteúdo principal |
|---|---------|--------|--------------------|
| 07 | `07-modelagem-relacional.md` | Modelagem relacional | Chaves (naturais, substitutas, UUID e sequências), formas normais até a 3FN e BCNF, anomalias de atualização, desnormalização e o custo de manter cópias, restrições de integridade no banco. |
| 08 | `08-indices.md` | Índices | B-tree por dentro, hash, GIN e GiST, índices compostos e ordem das colunas, índices de cobertura, índices parciais e de expressão, seletividade e cardinalidade, custo de escrita de cada índice. PostgreSQL como referência. |
| 09 | `09-planos-de-execucao.md` | Planos de execução | `EXPLAIN` e `EXPLAIN ANALYZE`, seq scan, index scan e index-only scan, nested loop, hash join e merge join, estatísticas e estimativas de linhas, problema N+1 gerado por ORM, paginação por offset e por cursor. |
| 10 | `10-transacoes-e-isolamento.md` | Transações e isolamento | ACID, níveis de isolamento do padrão SQL, anomalias (dirty read, non-repeatable read, phantom, lost update, write skew), MVCC, snapshot isolation, serializable no PostgreSQL. |
| 11 | `11-locks-contencao-e-pools-de-conexao.md` | Locks, contenção e pools de conexão | Locks de linha e de tabela, `SELECT ... FOR UPDATE`, `SKIP LOCKED`, controle otimista com versão, deadlocks no banco, custo de uma conexão, pools na aplicação e externos (PgBouncer), dimensionamento do pool. |
| 12 | `12-migracoes-sem-downtime.md` | Migrações de schema sem downtime | Locks de DDL, operações seguras e perigosas no PostgreSQL, padrão expand/contract, backfill em lotes, criação de índice concorrente, compatibilidade entre versões do código durante o deploy. |
| 13 | `13-replicacao.md` | Replicação | Replicação síncrona e assíncrona, WAL e replicação lógica, réplicas de leitura, lag de replicação, read-your-writes, failover e split-brain, replicação multi-líder e sem líder (quórum). |
| 14 | `14-particionamento-e-sharding.md` | Particionamento e sharding | Particionamento de tabelas no banco, sharding por faixa e por hash, consistent hashing, hot spots, consultas entre shards, rebalanceamento, escolha da chave de partição. |
| 15 | `15-modelos-nao-relacionais.md` | Modelos não relacionais | Chave-valor, documento, colunar, grafo e séries temporais: modelo de dados, padrões de acesso suportados, garantias de consistência e o que cada um não faz. Modelar a partir dos padrões de acesso. |
| 16 | `16-cache.md` | Cache | Cache-aside, read-through, write-through e write-behind, invalidação, TTL, políticas de despejo (LRU, LFU), cache stampede e suas soluções, cache em camadas (processo, Redis, HTTP, CDN), consistência entre cache e banco. |

### Parte III — Sistemas distribuídos

| # | Arquivo | Título | Conteúdo principal |
|---|---------|--------|--------------------|
| 17 | `17-modelos-de-consistencia.md` | Modelos de consistência | Teorema CAP com a definição precisa, PACELC, linearizabilidade, consistência sequencial, causal e eventual, garantias de sessão. |
| 18 | `18-tempo-ordem-e-consenso.md` | Tempo, ordem e consenso | Relógios físicos e desvio, NTP, relógios lógicos de Lamport, vector clocks, o problema do consenso, eleição de líder, Raft no essencial, leases e fencing tokens. |
| 19 | `19-falhas-parciais.md` | Falhas parciais | Tipos de falha, timeouts (como escolher o valor), retries com backoff exponencial e jitter, retry storms, circuit breaker, bulkhead, deadlines propagados, degradação controlada. |
| 20 | `20-idempotencia-e-semantica-de-entrega.md` | Idempotência e semântica de entrega | At-most-once, at-least-once e exactly-once (e o que esse último significa de fato), chaves de idempotência em APIs, deduplicação, operações naturalmente idempotentes. |
| 21 | `21-mensageria.md` | Mensageria | Fila e log, consumidores concorrentes, consumer groups, offsets e acknowledgments, ordenação e partições, DLQ, visibility timeout, backlog. Kafka, RabbitMQ e Amazon SQS como exemplos de cada modelo. |
| 22 | `22-transacoes-distribuidas.md` | Transações distribuídas | O problema da escrita dupla, two-phase commit e seus bloqueios, sagas (orquestração e coreografia) e ações compensatórias, padrão outbox, change data capture. |
| 23 | `23-event-sourcing-e-cqrs.md` | Event sourcing e CQRS | Eventos como fonte da verdade, event store, projeções, snapshots, versionamento de eventos, separação de leitura e escrita, consistência das projeções, custos operacionais. |

### Parte IV — Arquitetura e APIs

| # | Arquivo | Título | Conteúdo principal |
|---|---------|--------|--------------------|
| 24 | `24-estilos-de-comunicacao.md` | Estilos de comunicação | REST, gRPC (Protocol Buffers, streaming), GraphQL (resolvers, N+1, custo de consulta), WebSocket e SSE: propriedades, formato no fio, suporte a cache e a streaming, requisitos de infraestrutura. |
| 25 | `25-contratos-de-api.md` | Contratos de API | Compatibilidade retroativa e o que a quebra, estratégias de versionamento, paginação, filtros, formato de erros (RFC 9457), OpenAPI, testes de contrato. |
| 26 | `26-decomposicao-de-sistemas.md` | Decomposição de sistemas | Monólito, monólito modular e microsserviços, acoplamento e coesão, fronteiras de dados (um banco por serviço), custo de uma chamada de rede, disponibilidade composta de serviços em série, Lei de Conway como observação empírica. |
| 27 | `27-balanceamento-e-proxies.md` | Balanceamento e proxies | Balanceamento em camada 4 e 7, algoritmos (round robin, least connections, hash consistente), health checks, sticky sessions, reverse proxy, API gateway, service mesh, CDN. |
| 28 | `28-controle-de-carga.md` | Controle de carga | Rate limiting (token bucket, leaky bucket, janela fixa e deslizante), rate limiting distribuído, backpressure, load shedding, filas limitadas, cabeçalhos `Retry-After` e `429`. |
| 29 | `29-escalabilidade-e-capacidade.md` | Escalabilidade e capacidade | Escala vertical e horizontal, serviços stateless e onde fica o estado, autoscaling (métricas, histerese, tempo de reação), estimativa de capacidade com cálculos de ordem de grandeza (requisições, armazenamento, banda). |

### Parte V — Segurança

| # | Arquivo | Título | Conteúdo principal |
|---|---------|--------|--------------------|
| 30 | `30-autenticacao.md` | Autenticação | Sessões com cookie, tokens opacos e JWT (estrutura, assinatura, expiração, revogação), OAuth 2.0 (fluxos atuais, PKCE), OpenID Connect, MFA, passkeys (WebAuthn). |
| 31 | `31-autorizacao-e-multitenancy.md` | Autorização e multitenancy | RBAC, ABAC e ReBAC, onde aplicar a checagem, IDOR, modelos de isolamento entre tenants (banco por tenant, schema por tenant, coluna de tenant, row-level security). |
| 32 | `32-vulnerabilidades-de-backend.md` | Vulnerabilidades de backend | OWASP Top 10 e OWASP API Security Top 10 aplicados a um backend Python: injeção, SSRF, deserialização insegura, falhas de autorização por objeto, exposição de dados, dependências vulneráveis. |
| 33 | `33-criptografia-aplicada-e-segredos.md` | Criptografia aplicada e segredos | Hash de senhas (Argon2, bcrypt), criptografia simétrica autenticada (AES-GCM) e assimétrica, assinaturas, HMAC, envelope encryption e KMS, gestão e rotação de segredos. |

### Parte VI — Infraestrutura e operação

| # | Arquivo | Título | Conteúdo principal |
|---|---------|--------|--------------------|
| 34 | `34-conteineres.md` | Contêineres | Namespaces e cgroups, imagens e camadas, build em múltiplos estágios, imagens mínimas, PID 1 e sinais, limites de memória e CPU, registries, OCI. |
| 35 | `35-kubernetes.md` | Kubernetes | Arquitetura (control plane e nós), pods, deployments, services, ingress, ConfigMaps e Secrets, requests e limits, probes, rolling update, HPA. |
| 36 | `36-redes-em-nuvem-e-infraestrutura-como-codigo.md` | Redes em nuvem e infraestrutura como código | Rede virtual, sub-redes públicas e privadas, tabelas de rota, NAT, firewalls com estado e sem estado, regiões e zonas de disponibilidade. Infraestrutura como código com Terraform: estado, plan e apply, drift, módulos. |
| 37 | `37-ci-cd-e-estrategias-de-deploy.md` | CI/CD e estratégias de deploy | Pipeline de build, teste e deploy, artefatos imutáveis, rolling, blue-green e canary, feature flags, rollback e roll forward, credenciais de curta duração no pipeline (OIDC). |
| 38 | `38-observabilidade.md` | Observabilidade | Logs estruturados, métricas (contadores, gauges, histogramas, cardinalidade), tracing distribuído e propagação de contexto, OpenTelemetry, métodos RED e USE. |
| 39 | `39-sli-slo-e-sla.md` | SLI, SLO e SLA | Definições, como medir um SLI, metas em "noves" e o tempo de indisponibilidade de cada uma, error budget, alertas por taxa de consumo do error budget (burn rate). |
| 40 | `40-backup-e-recuperacao-de-desastres.md` | Backup e recuperação de desastres | RPO e RTO, backup completo, incremental e contínuo (point-in-time recovery), regra 3-2-1, estratégias de recuperação de desastres (backup e restauração, pilot light, warm standby, ativo-ativo), testes de restauração. |
