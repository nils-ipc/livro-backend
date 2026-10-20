# Resumo 07 — Modelagem relacional

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- superchave, chave candidata (mínima), primária; outras candidatas → UNIQUE
- chave natural: única + obrigatória + imutável; ISBN 10→13 dígitos 01/01/2007
- identity SQL:2003 (PG 10+), GENERATED ALWAYS; sequência não transacional, buracos, até 32 valores perdidos no crash
- integer 2.147.483.647 (248 dias a 100/s); bigint ~292 mil anos a 1 mi/s
- UUIDv4 122 bits aleatórios, folha aleatória, páginas pela metade; UUIDv7 RFC 9562, 48 bits ms, PG 18 uuidv7(), Python 3.14 uuid7() com contador; vaza momento de criação
- Snowflake 41/10/12 bits
- dependência funcional X → Y, determinante; 1FN, 2FN (parcial), 3FN (transitiva), BCNF (determinante = superchave); BCNF pode perder dependência (exemplo monitor)
- anomalias de atualização, inserção, exclusão
- desnormalização: tabela aplicação/trigger/coluna gerada (STORED; VIRTUAL PG 18)/view materializada/CDC
- preço no item = fato histórico
- restrições: NOT NULL, UNIQUE (lower(email)), FK sem índice automático no lado que referencia, ON DELETE, DEFERRABLE, CHECK só a linha, EXCLUDE gist + btree_gist + tstzrange [ )
- NULLS NOT DISTINCT PG 15; NOT VALID + VALIDATE

## Termos e traduções adotados
- surrogate key → chave substituta; natural key → chave natural
- functional dependency → dependência funcional; 1FN/2FN/3FN, BCNF
- fillfactor em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: Ricardo, 3 cupons, `pedidos_v2_final` 47→51 colunas
- status `quase pago`; id 7 perdido no ROLLBACK
- trigger qtd_pedidos, 40 mil pedidos/h
- Basecamp 3 nov/2018 int 32 bits
- placa `NULL`, Joseph Tartaro, DEF CON 27
