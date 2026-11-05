# Resumo 13 — Processos, threads e I/O assíncrono

## A Lastro ao fim do capítulo
- incidente quinta 20h03: campanha Bazar "12x sem juros em tudo, até em capinha"; cartão 1 → 7 autorizações/s; Vigia (~60 ms) + adquirente (~800 ms) síncronos em `async def` → loop parado 0,9 s; teto 6/0,9 ≈ 6,7/s; POST 14 s, Bazar desiste aos 10 s (cap. 15); SSE cortado pelo proxy 60 s; Pix morreu junto; CPU 4%; URGENTE 20h11
- temp-01 e api-01: 4 vCPU cada; worker ~160 MB RSS
- decisão: clientes assíncronos (`grpc.aio` Vigia; HTTP/2 assíncrono adquirente, ex. `httpx.AsyncClient`), 1 conexão/processo → trabalho 99% espera
- teto autorização: 100 streams/conexão × 6 = 600 / 0,8 s = 750/s (CPU ~1.000/s, C ≈ 6 ms); semáforo 100/processo
- 3 workers/máquina mantidos (4º núcleo: proxy TLS, SO, repasse job em temp-01)
- pool banco `pool_size` 5 → 3 (6 × 3 = 18 ≤ teto 17–20)
- nenhuma conexão do banco atravessa `await` externo: tx curta → Vigia/adquirente → tx curta
- CPU > 20 ms/requisição → processo separado
- lag do event loop (Task dorme 100 ms) métrica, alerta > 50 ms; CI regras `ASYNC` do Ruff; lib só síncrona via `asyncio.to_thread`
- resultado: CPU 9%, lag 2 ms, autorização segue 0,9 s
- descartados: `--workers 64` (20 GB RAM, 128 conexões vs limite 20 do adquirente), rotas `def` (~266/s)
- próximo: Carlos relata média 0,9 s "tranquilo"; contrato Bazar exige p99 < 1,5 s na Black Friday; ninguém sabe o p99 (cap. 14)

## Conceitos aprofundados aqui
- processo × thread, `clone`, fork copy-on-write, zumbi, órfão
- troca de contexto voluntária/involuntária, `/proc/PID/status`, EEVDF (6.6)
- bloqueante, `O_NONBLOCK`/`EAGAIN`, select/poll/epoll, level/edge, kqueue, IOCP, io_uring; arquivo regular `EPERM`
- event loop, corrotina, Task, cooperativo, `slow_callback_duration` 100 ms, `to_thread`
- GIL, switch interval 5 ms, free-threaded 3.14 (PEP 779)
- prefork, gthread, event loop, híbrido; WSGI × ASGI; FastAPI `def` → AnyIO 40 threads; Gunicorn `--timeout` 30
- Goetz `núcleos × U × (1 + W/C)`

## Casos reais usados
- C10K (Kegel 1999); Cloudflare 2/7/2019 regex WAF 27 min

## Piadas recorrentes
- Carlos: "é só uma chamada"; `--workers 64` "teste de carga"; errou pela metade e teria funcionado
- fundador: `--workers 3` acertou número com modelo errado (relógio parado)
- timeout 30 s agora "com licença para matar" (Gunicorn)
- GIL "protege o interpretador, você ele deixa morrer"
- worker dorme o dia todo = estilo de vida do fundador
