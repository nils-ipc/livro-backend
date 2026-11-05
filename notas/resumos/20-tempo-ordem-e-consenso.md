# Resumo 20 — Tempo, ordem e consenso

## A Lastro ao fim do capítulo
- incidente terça meia-noite: fundador copiou crontab temp-01 → api-02 ("alta disponibilidade"); api-02 +3 min 40 s (firewall "tudo menos 443" bloqueia UDP 123, 6 semanas, ~60 ppm); temp-01 −2 min 10 s (NTP morto ano passado); disparos 23h56min20s e 00h02min10s reais
- script: UUID novo por repasse, Pix antes do débito, trigger recusou 2º débito, `except: pass` do Carlos (2024) → 380 vendedores pagos 2×, R$ 186.420,00; conciliação 6h achou 380 Pix sem lançamento; recuperados 377; vendedor 42 devolveu em 10 min ("dessa vez não fui eu")
- fechamento por `criado_em < hoje 00:00` local → 2 fechamentos diferentes; planilha certa
- decisão lease no primário (descartados Redis, etcd/ZooKeeper/Consul): `lideranca_jobs (job, dono, epoca, expira_em)`; assumir = UPDATE se expirado → `epoca + 1`; prazo 30 s pelo `now()` do banco; renova 10 s; para se não renovou em 20 s (monotônico)
- fencing: cada transação de repasse `SELECT epoca ... FOR SHARE`, token diferente → ROLLBACK; troca de dono espera repasses em andamento
- ID repasse determinístico `(vendedor, dia contábil)` → banco recusa repetido
- script vira agendador de sagas cap. 18 (débito antes do Pix); nome mantido; roda temp-01 + api-02
- dia contábil: toda transação ledger advisory lock compartilhado + carimba `dia_contabil` de `periodo_aberto`; corte = advisory exclusivo, avança período, COMMIT; fechamento `WHERE dia_contabil = D`; relógio só decide quando
- sem Lamport/vetores (1 primário ordena); multi-líder cap. 23
- NTP (chrony ex.) todas máquinas, porta 123 saída, alerta deslocamento > 100 ms
- próximo: chargeback pede estado da cobrança 14/set 15h; só estado atual; Carlos quer restaurar backup inteiro (cap. 21)

## Conceitos aprofundados aqui
- deriva ppm (1 ppm = 86 ms/dia; Google 200 ppm), NTP θ/δ, erro δ/2, slew 500 ppm/step, monotônico, segundo bissexto, leap smear, CGPM 2022 → 2035
- happens-before, concorrente, Lamport clock, vector clock (Fidge/Mattern 1988); Spanner TrueTime
- consenso (acordo, validade, terminação), FLP 1985, Raft (mandatos, 150–300 ms, voto log atualizado, commit maioria, `2f+1`), ZAB
- lease, pausa processo, fencing token (Kleppmann 2016 × Redlock)
- `now()` = início da transação → lançamento órfão de dia

## Casos reais usados
- Linux leap second 30/6/2012; Cloudflare RRDNS 1/1/2017 (Go 1.9 monotônico); Cassandra LWW timestamp

## Piadas recorrentes
- fundador: "alta disponibilidade" = roda nas duas
- Carlos: `except: pass` 2h; backup inteiro "rapidinho" p/ ler 1 linha, reservou sala + pizza
- vendedor 42 fase vítima, devolve com bilhete
- NTP = horóscopo com RFC; nome do script mantido ("crontab, monitoramento e fé")
- Raft act-out "estamos no 8, querido"
