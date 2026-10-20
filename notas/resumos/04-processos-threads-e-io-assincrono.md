# Resumo 04 — Processos, threads e I/O assíncrono

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- processo = memória isolada + descritores; thread = unidade escalonada; Linux: ambos task via clone()
- fork copy-on-write; refcount + GC do CPython quebram CoW; gc.freeze() 3.7
- troca de contexto voluntária (I/O) vs involuntária (CPU); /proc/PID/status; custo µs + caches/TLB
- bloqueante vs O_NONBLOCK/EAGAIN; select O(n), FD_SETSIZE 1.024; poll; epoll (create1/ctl/wait, só prontos); kqueue, IOCP
- epoll inútil para arquivo regular → aiofiles usa thread
- event loop cooperativo; bloqueio em async def trava processo; debug 100 ms
- correções: httpx.AsyncClient, asyncio.to_thread (pool min(32, cpu+4)), def no FastAPI (AnyIO 40 threads)
- GIL: switch interval 5 ms; threads p/ I/O, processos p/ CPU; free-threaded PEP 703 (3.13 exp., 3.14 suportado, 5–10% perda)
- Gunicorn sync/gthread, backlog 2.048, timeout 30 s; ASGI Uvicorn/Hypercorn/Granian, uvicorn-worker
- dimensionamento: Little L=λW; CPU = λ × t_cpu; Goetz núcleos×(1+espera/cpu); (2×núcleos)+1
- os.cpu_count ignora cgroup; /sys/fs/cgroup/cpu.max
- fork com threads → lock herdado; 3.12 DeprecationWarning; 3.14 forkserver padrão Linux

## Termos e traduções adotados
- context switch → troca de contexto
- copy-on-write, event loop, free-threaded, backlog em inglês
- coroutine → corrotina

## Casos reais e exemplos usados (não repetir)
- hipotético: async def + requests.post, gateway boletos 2 s, /health 2 s, 11 reinícios, CPU 2%
- asyncio.sleep vs time.sleep: 1,00 s vs 10,02 s
- soma de quadrados: sequencial 1,21 / threads 1,24 / processos 0,36 s
- API 300 req/s, 20 ms CPU + 100 ms banco → 36 workers, 6 núcleos; 36×10 conexões vs max_connections 100
- 129 workers em contêiner de 2 CPUs
- C10K Dan Kegel 1999; Instagram GC 2017 (~10%)
