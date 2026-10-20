import asyncio
import math

consultas_ao_banco = 0
cache: dict[str, list[str]] = {}
em_voo: dict[str, asyncio.Task] = {}


async def buscar_ofertas_no_banco() -> list[str]:
    global consultas_ao_banco
    consultas_ao_banco += 1
    await asyncio.sleep(0.8)
    return ["geladeira", "air fryer", "outra air fryer"]


async def ofertas_ingenuo() -> list[str]:
    if "ofertas" in cache:
        return cache["ofertas"]
    valor = await buscar_ofertas_no_banco()
    cache["ofertas"] = valor
    return valor


async def _carregar(chave: str) -> list[str]:
    valor = await buscar_ofertas_no_banco()
    cache[chave] = valor
    return valor


async def ofertas_coalescido() -> list[str]:
    chave = "ofertas"
    if chave in cache:
        return cache[chave]
    tarefa = em_voo.get(chave)
    if tarefa is None:
        tarefa = asyncio.create_task(_carregar(chave))
        em_voo[chave] = tarefa
        tarefa.add_done_callback(lambda _: em_voo.pop(chave, None))
    return await asyncio.shield(tarefa)


async def main() -> None:
    global consultas_ao_banco
    await asyncio.gather(*(ofertas_ingenuo() for _ in range(1000)))
    print(f"ingênuo:    {consultas_ao_banco} consultas ao banco")
    cache.clear()
    consultas_ao_banco = 0
    await asyncio.gather(*(ofertas_coalescido() for _ in range(1000)))
    print(f"coalescido: {consultas_ao_banco} consulta ao banco")


asyncio.run(main())
delta = 0.8
for falta in (8, 5, 2, 1, 0.5, 0.1):
    p = math.exp(-falta / delta)
    print(f"faltando {falta:>4} s: {p:9.5%} por requisição")
