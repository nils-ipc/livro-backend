from itertools import permutations
from typing import NamedTuple


class Op(NamedTuple):
    cliente: str
    tipo: str       # "w" (escrita) ou "r" (leitura)
    valor: int
    inicio: float   # instante da chamada, em ms
    fim: float      # instante da resposta, em ms


def respeita_registrador(ordem: tuple[Op, ...], inicial: int = 0) -> bool:
    atual = inicial
    for op in ordem:
        if op.tipo == "w":
            atual = op.valor
        elif op.valor != atual:
            return False  # leitura devolveu algo que ninguém tinha escrito ainda
    return True


def precede(a: Op, b: Op, tempo_real: bool) -> bool:
    if tempo_real:
        return a.fim < b.inicio  # a terminou antes de b começar
    return a.cliente == b.cliente and a.fim < b.inicio  # só a ordem do programa


def achar_ordem(historico: list[Op], tempo_real: bool) -> tuple[Op, ...] | None:
    for ordem in permutations(historico):  # força bruta: honesta para 3 operações
        pos = {op: i for i, op in enumerate(ordem)}
        if all(pos[a] < pos[b] for a in historico for b in historico
               if precede(a, b, tempo_real)) and respeita_registrador(ordem):
            return ordem
    return None


def relatorio(nome: str, historico: list[Op]) -> None:
    print(nome)
    for modelo, tempo_real in [("linearizável", True), ("sequencial", False)]:
        ordem = achar_ordem(historico, tempo_real)
        if ordem:
            passos = " -> ".join(f"{o.cliente}:{o.tipo}({o.valor})" for o in ordem)
            print(f"  {modelo:<13} sim  {passos}")
        else:
            print(f"  {modelo:<13} NÃO")


relatorio("H1: C lê 0 depois que B já leu 1", [
    Op("A", "w", 1, 0, 10),
    Op("B", "r", 1, 2, 4),
    Op("C", "r", 0, 6, 8),
])
relatorio("H2: C lê 0 enquanto B lê 1", [
    Op("A", "w", 1, 0, 10),
    Op("B", "r", 1, 2, 4),
    Op("C", "r", 0, 1, 3),
])
