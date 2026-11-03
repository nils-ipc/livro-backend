# Resumo 01 — Modelagem relacional

## A Lastro ao fim do capítulo
- contexto: monólito em `temp-01` (2 anos e 3 meses de uptime), 1 PostgreSQL; cliente único Bazar Bem-te-vi: 1.200 vendedores, ~3.000 cobranças/dia, ~12 mil lançamentos/dia
- coluna `saldo double precision` eliminada → divergia da planilha (34 vendedores por 1 centavo, 3 por retry duplicado tipo R$ 412,30)
- ledger partidas dobradas: contas, transações, lançamentos; valores em centavos `BIGINT`; sinal: + débito, − crédito (passivo/receita negativos; extrato inverte)
- soma zero por transação → constraint trigger `DEFERRABLE INITIALLY DEFERRED`
- imutabilidade → role app só INSERT/SELECT + trigger BEFORE UPDATE OR DELETE; superusuário (fundador) ainda escapa → cap. 31
- estorno = transação nova invertida, referencia original
- saldo derivado por `SUM` (requisito: conciliação explicável); materializado só se virar gargalo, sempre como cache
- taxas em `NUMERIC` 4 casas; tarifa arredondada 1 vez, half-even; parcela do vendedor fechada por diferença; tarifa aplicada gravada na cobrança
- tarifas exemplo: Pix 0,99% (descontada do vendedor); comissão Bazar 12%; cartão D+30 (não detalhado)
- chaves: `BIGINT` identity internas; cobranças UUIDv7 = ID público; CNPJ/CPF `TEXT UNIQUE`; EndToEndId `UNIQUE`
- só BRL, sem coluna de moeda (cap. 07)
- nenhuma verificação de saldo antes de saque → cap. 02: dois saques de R$ 500,00 simultâneos com saldo R$ 500,00

## Conceitos aprofundados aqui
- binary64, não associatividade, `NUMERIC` vs inteiro, `round` Python (half-even) vs PostgreSQL (afasta do zero)
- half-up, half-even, truncamento, maiores restos
- anomalias; 1FN, 2FN, 3FN, BCNF (perda de dependência)
- chaves naturais/substitutas, sequência com buracos, UUIDv4 vs v7
- desnormalização: derivado, materializado, projeção

## Termos
- lançamento, transação, conta; cobrança e split definidos aqui

## Casos reais usados
- índice Bolsa de Vancouver 1982–83 (524,811 → 1.098,892)
- CNPJ alfanumérico (IN RFB 2.229/2024, julho 2026)

## Piadas recorrentes
- Carlos: tentou UPDATE no ledger, "-870100" com dois zeros a mais; acha caminho que não passa pela função
- financeiro: centavo às 23h de sábado; dormiu um sábado
- ledger "tabelião"; "partida dobrada, saque dobrado"
