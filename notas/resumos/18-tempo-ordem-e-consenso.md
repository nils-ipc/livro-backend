# Resumo 18 — Tempo, ordem e consenso

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- relógio de parede (time.time, CLOCK_REALTIME, pode voltar) vs monotônico (time.monotonic, só intervalos locais)
- drift em ppm: 1 ppm = 86,4 ms/dia; servidores dezenas de ppm
- NTP RFC 5905: stratum, t1–t4, δ=(t4−t1)−(t3−t2), θ=((t2−t1)+(t3−t4))/2, supõe simetria; slew (ntpd ≤500 ppm) vs step (>128 ms); PTP IEEE 1588; chronyc tracking
- leap second: kernel repete segundo; leap smear Google 24 h ~11,6 ppm; CGPM 2022 abolição até 2035; último fim 2016
- TrueTime ε 1–7 ms, commit wait ~2ε → external consistency; HLC 2014, CockroachDB max offset 500 ms
- aconteceu antes (Lamport 1978); relógio de Lamport max+1, ordem total (contador, id)
- vector clock Fidge/Mattern 1988, concorrência; Dynamo 2007
- consenso: acordo, validade, terminação; FLP 1985; maioria 2f+1; nó par inútil
- Raft: termos, RequestVote, timeout sorteado 150–300 ms, etcd 100/1.000 ms, restrição de eleição, AppendEntries (índice, termo), correspondência do log, figura 8, ReadIndex vs leitura com lease
- lease + pausa (GC, VM, SIGSTOP); fencing token (etcd revision, zxid, termo) checado pelo recurso

## Termos e traduções adotados
- wall clock → relógio de parede; drift → deriva; offset → desvio
- leap second → segundo bissexto; leap smear, commit wait, fencing token, lease, term → termo

## Casos reais e exemplos usados (não repetir)
- hipotético: leilão bicicleta ergométrica, Marta R$ 310 / Jorge R$ 320, `leilao-b` 400 ms atrasado
- worker tokens 33/34, GC 15 s, lease 10 s
- leap second 2012 kernel Linux (Reddit, Mozilla); Cloudflare DNS 31/12/2016 rand.Int63n, Go 1.9; Cloudflare etcd 02/11/2020
