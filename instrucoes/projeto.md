# O projeto do livro: a Lastro

O livro acompanha a construção de um único sistema do primeiro ao último capítulo: o backend da **Lastro**, uma fintech fictícia de pagamentos. Cada capítulo ensina um assunto técnico a partir de um problema real que a Lastro enfrenta naquele momento, e termina com o projeto um passo adiante. O projeto é o fio que dá conexão ao livro; o conteúdo técnico continua sendo o centro de cada capítulo.

## O projeto é descrito, nunca implementado

- O livro **não mostra a implementação** da Lastro. Não há código dos serviços, handlers, classes, models de ORM, repositórios nem arquivos de configuração completos.
- O projeto aparece como **descrição**: requisitos, números, decisões e o motivo técnico de cada uma, fluxos, estados, esquemas conceituais (quais tabelas, quais colunas importam e por quê), contratos de API em linhas gerais, diagramas em ASCII e tabelas.
- **Trechos de código só quando forem muito importantes para exemplificar um conceito**: o `SELECT ... FOR UPDATE` que mostra o lock, a saída de um `EXPLAIN ANALYZE`, a troca de cabeçalhos de uma requisição HTTP, o payload JSON de um erro no formato da RFC 9457, a saída de um `dig`, uma probe do Kubernetes. Curtos (até ~15 linhas), focados no conceito e nunca uma peça "pronta" do sistema. Muitos capítulos podem não ter código nenhum.
- O leitor só lê. Nada no texto pede que ele rode, construa ou implemente a Lastro.

## O que a Lastro faz

A Lastro é uma plataforma de pagamentos para **marketplaces**. O marketplace (cliente da Lastro) integra a API da Lastro para:

1. **Receber pagamentos** dos compradores por **Pix** e por **cartão de crédito** (a Lastro atua como subcredenciadora: fala com um adquirente para autorizar e capturar transações de cartão).
2. **Dividir cada pagamento (split)** entre o marketplace (comissão) e os vendedores do marketplace, já descontadas as tarifas da Lastro.
3. **Guardar os saldos** de marketplaces e vendedores num **ledger de partidas dobradas**, com saldo a liberar (agenda de recebíveis de cartão, D+30 por padrão) e saldo disponível.
4. **Repassar o dinheiro**: o vendedor saca o saldo disponível por Pix para a conta bancária dele, sob demanda ou em repasses automáticos.
5. **Notificar** o marketplace de cada mudança de estado por **webhooks**.
6. **Proteger o dinheiro**: antifraude na autorização, estornos, contestações (chargebacks) e **conciliação** diária com os arquivos do adquirente e do banco liquidante.

Por que esse domínio: concentra os problemas mais difíceis e mais valorizados de backend. Dinheiro não admite perda nem duplicidade, a autorização de cartão tem orçamento de latência apertado, o Pix exige disponibilidade 24x7, o ledger cresce sem parar e é alvo de contenção, há parceiros externos que falham de formas parciais, e a segurança é exigência regulatória (PCI DSS para dados de cartão).

## Glossário do domínio

Usar sempre estes termos, com estes sentidos. Definir cada um no texto na primeira vez que aparecer no livro (os resumos registram onde).

| Termo | Sentido no livro |
|-------|------------------|
| Cobrança | Pedido de pagamento criado pelo marketplace na API da Lastro (Pix ou cartão). Tem um ciclo de estados. |
| Autorização / captura | No cartão: a autorização reserva o valor no limite do comprador; a captura confirma a cobrança. Podem ocorrer juntas ou separadas. |
| Estorno | Devolução total ou parcial de uma cobrança paga, iniciada pela Lastro ou pelo marketplace. |
| Chargeback (contestação) | Devolução iniciada pelo comprador junto ao emissor do cartão. |
| Adquirente, emissor, bandeira | Participantes do arranjo de cartões. A Lastro fala com um adquirente; nunca diretamente com emissores. |
| Pix, chave Pix, EndToEndId | Pagamento instantâneo do Banco Central do Brasil; a chave identifica a conta de destino; o EndToEndId identifica cada transação de ponta a ponta. A Lastro acessa o Pix por um banco parceiro (participante indireto). |
| Split | Divisão de um pagamento entre recebedores, definida pelo marketplace na criação da cobrança. |
| Ledger | Livro-razão de partidas dobradas: contas e lançamentos imutáveis; todo movimento debita uma conta e credita outra no mesmo valor. Saldo é derivado dos lançamentos. |
| Saldo a liberar / disponível | A liberar: recebíveis de cartão ainda não liquidados. Disponível: pode ser sacado. |
| Repasse (payout) | Transferência do saldo disponível do vendedor para a conta bancária dele. |
| Liquidação | Movimento real de dinheiro entre instituições (adquirente → banco liquidante da Lastro). |
| Conciliação | Comparação entre o que a Lastro registrou e o que os parceiros dizem que aconteceu, para achar e tratar divergências. |
| MDR / tarifa | Taxa descontada de cada pagamento. |

Detalhes regulatórios e de arranjo (prazos, regras do Banco Central, requisitos do PCI DSS) só entram quando servem a um ponto técnico, com fonte verificada. A Lastro é fictícia e seu enquadramento regulatório fica simplificado; o livro não ensina compliance.

## Pilha técnica da Lastro

Fixa ao longo do livro, para que as decisões façam sentido juntas:

- Python 3.12+ com FastAPI nos serviços; PostgreSQL 16+ como banco do ledger e dos demais dados transacionais; Redis (ou Valkey) para cache e contadores; um broker de mensagens (escolhido no capítulo de mensageria).
- Começa como **um monólito com um único PostgreSQL** e evolui conforme os capítulos pedem. Nenhuma peça aparece antes do capítulo que a justifica.
- Contêineres e Kubernetes na Parte VI; nuvem neutra (ver `instrucoes/rigor-e-formatacao.md`).

## Como o projeto evolui

O sumário em `instrucoes/livro.md` tem, para cada capítulo, a coluna **Na Lastro**: o problema do projeto que abre o capítulo e o que muda no projeto ao final dele. Ela é o roteiro. Em linhas gerais:

| Partes | Fase da Lastro |
|--------|----------------|
| I | Primeira versão: o monólito, o ledger e o banco. Um cliente, o marketplace Bazar Bem-te-vi. |
| II | A API exposta ao mundo: integração dos clientes, rede, HTTP, TLS, contratos, desempenho para a primeira Black Friday. |
| III | Parceiros externos e falhas parciais: adquirente, Pix, webhooks, fluxos que atravessam sistemas. |
| IV | Escala: dezenas de marketplaces, o ledger crescendo, o monólito dividido em serviços. |
| V | Segurança: dinheiro atrai atacante; dados de cartão e isolamento entre clientes. |
| VI | Infraestrutura e operação: contêineres, Kubernetes, deploy, observabilidade, SLOs e recuperação de desastres. |

## Regras de continuidade

- **Decisões do projeto não são opinião.** Cada decisão da Lastro vem de um requisito concreto do projeto (um número, uma restrição, uma exigência de parceiro) ligado a uma propriedade técnica explicada no capítulo. O capítulo mostra as alternativas com suas propriedades e custos e diz em que condições outra escolha seria a certa. "A Lastro escolheu X porque precisa de Y, e X garante Y ao custo Z" é objetivo; "X é melhor" não é.
- **Coerência com o que já foi decidido.** Antes de escrever, ler os resumos em `notas/resumos/`: eles registram o estado da Lastro (componentes, decisões, números). Um capítulo não contradiz decisão anterior; se o projeto precisar mudar uma decisão, o capítulo diz que está mudando e por quê.
- **Números do projeto.** Volumes, latências e metas da Lastro (TPS, tamanho do ledger, metas de p99) são fictícios, mas plausíveis e consistentes entre capítulos. Ao introduzir um número novo, registrá-lo no resumo. Números apresentados como reais do mercado continuam precisando de fonte.
- **O conceito é maior que o projeto.** O mecanismo é ensinado em termos gerais, valendo para qualquer sistema; a Lastro mostra a aplicação. Exemplos fora da Lastro são permitidos quando ensinam melhor (um caso real, um contraexemplo).
- **O leitor é o novo líder técnico do backend da Lastro.** O texto fala com ele em segunda pessoa e o coloca diante dos problemas do projeto. Isso é só o enquadramento: o livro continua sem conteúdo de liderança de pessoas, processo ou carreira.

## Piadas recorrentes

O projeto contínuo permite *running gags* e callbacks que atravessam o livro, como num especial de stand-up em 40 partes (ver "Humor" em `instrucoes/estilo.md`). Pontos de partida, a retomar sempre numa situação nova e pior:

- `temp-01`, o servidor provisório onde o fundador subiu a primeira versão num fim de semana e que ninguém tem coragem de desligar.
- A planilha de conciliação da equipe financeira, que todo mundo sabe ser a verdadeira fonte da verdade.
- O job agendado chamado `repasse_final_v2_agora_vai.py`.
- O Bazar Bem-te-vi, primeiro cliente, que sempre descobre o bug antes do monitoramento e abre todo chamado com o assunto "URGENTE!!!!".

### Elenco fixo

Personagens fictícios da Lastro, para act-out e roast. Ninguém da equipe é baseado em pessoa real. O roast mira as decisões, os hábitos e os cargos deles (ver "Limites" em `instrucoes/estilo.md`):

- **O fundador**, ex-dev que escreveu a primeira versão num fim de semana, em `temp-01`, e ainda tem acesso de administrador a tudo. Acredita que "no meu tempo era só um servidor e funcionava". Tecnicamente, funcionava.
- **O Carlos**, o dev mais antigo da equipe, autor de todo comentário `não mexa` do código e réu confesso de metade dos incidentes. Sobreviveu a todos, como uma barata com acesso de escrita em produção.
- **O financeiro**, dono da planilha de conciliação, que fala de centavos com a serenidade de quem já achou R$ 0,01 de divergência às 23h de um sábado.
- **O gerente de produto**, que pergunta "mas é só um botão, não?" e pede a estimativa em horas, de preferência ontem.

Novas piadas recorrentes e novos personagens podem nascer em qualquer capítulo; registrá-los no resumo para que os seguintes possam retomá-los. Nunca fazer roast de pessoas reais nem rir de clientes reais afetados.
