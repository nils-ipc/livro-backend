# Resumo 25 — Contratos de API

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- contrato = formato + status + cabeçalhos + semântica; Lei de Hyrum: todo comportamento observável vira dependência
- compatibilidade retroativa: todo cliente real continua funcionando sem mudar código
- variância: requisição contravariante (aceitar mais), resposta covariante (devolver menos); `strictFunctionTypes`; tabela de mudanças
- enum novo na resposta quebra tratamento exaustivo; `x-extensible-enum` (Zalando)
- leitor tolerante: Pydantic `extra="ignore"` padrão vs `forbid`; `StrEnum._missing_`
- Postel RFC 761 vs RFC 9413
- mudanças semânticas: unidade, tamanho padrão de página, 201→202
- versionamento: caminho, cabeçalho (padrão vira contrato), tipo de mídia (`Vary: Accept`, 406), data por conta (Stripe, módulos de transformação), GraphQL `@deprecated`
- `Deprecation` RFC 9745 (`@timestamp`, RFC 9651), `Sunset` RFC 8594, `rel="deprecation"`
- paginação como contrato: offset desloca, cursor opaco + HMAC, ordenação total, fim explícito (`Link` RFC 8288), teto `limite`, `count(*)` caro (MVCC)
- filtros: lista explícita, RFC 3339, parâmetro desconhecido → 400
- RFC 9457 problem+json: type/title/status/detail/instance, `about:blank`, extensões
- OpenAPI 3.1 (JSON Schema 2020-12), code-first vs design-first; oasdiff, Schemathesis, Pact/Broker, consumer-driven contracts (Robinson 2006)

## Termos e traduções adotados
- backward compatibility → compatibilidade retroativa; tolerant reader → leitor tolerante
- consumer-driven contracts → contratos dirigidos pelo consumidor; problem details, code-first, design-first em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: Pétala Express, Dia das Mães 7h02, `"agendado"`, Válter, app 3.2.1 (31%), 4.200 mensagens
- `?stauts=pendente` cancela tudo; 24 APIs em 6 anos
- Twitter `id_str`, 2^53 − 1, `1234567890123456800`
