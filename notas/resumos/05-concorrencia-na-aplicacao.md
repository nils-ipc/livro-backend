# Resumo 05 — Concorrência na aplicação

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- condição de corrida: resultado depende da intercalação; data race = modelo de memória (UB em C/C++)
- GIL não impede corrida lógica; `+=` = carregar/somar/gravar
- read-modify-write (lost update) e check-then-act (TOCTOU)
- 2 sequências de 3 passos → C(6,3)=20 intercalações
- seção crítica, exclusão mútua, mutex; CAS (LOCK CMPXCHG, ARMv8.1 CAS); futex só chama kernel com disputa
- throughput máx. trecho travado = 1/tempo_seção (10 ms → 100/s)
- atomicidade CPython (append, d[k]=v, setdefault) = detalhe de implementação, FAQ
- UPDATE condicional READ COMMITTED reavalia WHERE → UPDATE 0; UNIQUE; Redis thread única
- Coffman 1971: 4 condições; ordem global, timeout, detector PG deadlock_timeout 1 s; livelock + jitter
- asyncio: cada await = ponto de troca; asyncio.Lock só no loop
- réplicas: atômico no armazenamento > lock no banco (advisory xact) > lock distribuído
- Redis SET NX PX + token + Lua/DELEX (8.4); lease; limites: pausa, failover assíncrono, relógio de parede
- Redlock 5 primários; Kleppmann 2016 vs antirez; eficiência vs corretude; fencing token → cap. 18

## Termos e traduções adotados
- race condition → condição de corrida; data race em inglês
- critical section → seção crítica; mutual exclusion → exclusão mútua
- hold and wait → posse e espera; lease, fencing token, livelock em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: voucher BEMVINDO50 resgatado 14×, 4 pods × 2 workers
- asyncio 5 resgates R$ 250 vs Lock R$ 50
- deadlock contas ana/bia, timeout 2 s, ordem por nome
- lock Redis fechamento mensal, TTL 10 min
- lock criado dentro da função; get_or_create sem UNIQUE
- Starbucks cartões-presente 2015 (Homakov)
- apagão EUA 14/08/2003, XA/21 alarme silencioso
