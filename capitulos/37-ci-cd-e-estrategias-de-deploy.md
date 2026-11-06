# CI/CD e estratégias de deploy

## O pull request que não mudava nada

O pull request se chamava "refatora cálculo de tarifa (sem mudança de comportamento)", e os dois aprovadores aprovaram o título. Era terça, 9h40. O gerente de produto queria mostrar a tarifa no checkout antes do pagamento ("é só um número na tela, não?"), e o Carlos extraiu o cálculo para uma função compartilhada. No caminho, trocou o modo de arredondamento. Com um comentário, para ninguém dizer que ele não documenta:

```python
>>> from decimal import Decimal, ROUND_HALF_EVEN, ROUND_UP
>>> bruto = Decimal("34990") * Decimal("0.0099")  # R$ 349,90 a 0,99%, em centavos
>>> bruto
Decimal('346.4010')
>>> bruto.quantize(Decimal("1"), ROUND_HALF_EVEN)  # o que o capítulo 1 decidiu
Decimal('346')
>>> bruto.quantize(Decimal("1"), ROUND_UP)  # "pra nunca cobrar menos"
Decimal('347')
```

`ROUND_UP`, no `decimal` do Python, arredonda para longe do zero: qualquer fração vira um centavo inteiro. Os testes passaram, porque todos os fixtures usavam R$ 100,00, cuja tarifa dá 99 centavos exatos. A CI ficou verde. A ferramenta mais rigorosa do pipeline continuava sendo o título do PR.

O deploy saiu às 10h02. O rolling update do capítulo 35 trocou os 30 pods de pagamentos em quatro minutos, sem perder uma autorização. Os pods passaram em todas as probes: saudáveis, rápidos e cobrando um centavo a mais de quase todo mundo, com latência excelente.

Às 10h51, o vendedor 42, que confere cada venda numa planilha própria desde o saque duplo, achou R$ 0,01 de diferença. Às 10h58, o Bazar abriu chamado: "URGENTE!!!! VOCÊS ESTÃO COBRANDO CENTAVO ESCONDIDO???". O rollback terminou às 11h06. Saldo: 131 mil das 140 mil cobranças da hora com tarifa um centavo acima, R$ 1.310,00 tirados de vendedores, em 131 mil lançamentos imutáveis que nenhum rollback desfaz. A conciliação das 6h teria achado no dia seguinte. O vendedor 42 achou em 49 minutos, de graça, e pela primeira vez na vida estava do lado certo de uma divergência.

Como uma mudança chega à produção expondo pouca gente primeiro, com a métrica certa olhando, e o que se faz com o dinheiro que a versão errada já gravou?

## O pipeline: compile uma vez, promova o mesmo artefato

**Integração contínua** (CI) é integrar cada mudança à branch principal com build e testes automáticos. **Entrega contínua** (CD) é manter essa branch sempre implantável, com a ida à produção dependendo de uma decisão; **implantação contínua** dispensa a decisão. O pipeline é a sequência de estágios entre commit e produção, cada um barrando uma classe de defeito:

```text
commit ─► build ─► testes ─► análise ─► publica ─► homologação ─► produção
          (imagem   (unidade,  (lint,     (registry,  (mesmo digest)  (mesmo digest,
          OCI)      contrato,  pip-audit, digest,                     canary)
                    integração) SBOM)     assinatura)
```

A regra que segura o pipeline inteiro é o **artefato imutável**: a imagem é construída uma vez, identificada pelo digest (capítulo 34), e esse mesmo digest passa por homologação e chega à produção. Reconstruir por ambiente parece inofensivo até o `pip install` da produção baixar uma dependência que a homologação nunca viu. Aí você testou um binário e implantou o primo dele, aquele que ninguém convida para o churrasco.

Por isso o que muda entre ambientes fica fora da imagem: configuração e segredos (capítulo 33). Migrações são estágio próprio, na ordem do capítulo 7: *expand* antes da versão que depende dele, *contract* num deploy posterior.

Por último, a **proveniência**: o pipeline assina a imagem e registra de que commit ela saiu (o SLSA descreve níveis disso; Sigstore é um exemplo de assinatura), e o cluster só admite imagem assinada e por digest. Sem isso, o Kubernetes executa o que aparecer no registry com a obediência de um estagiário no primeiro dia.

## Credenciais de curta duração: o pipeline sem chave no bolso

O pipeline publica imagens, altera infraestrutura e implanta em produção: tem mais poder que o fundador desde o capítulo 31, e por anos foi autenticado com uma chave permanente nas variáveis secretas da CI. A chave vazava por log, por dependência comprometida ou pelo fornecedor da CI, e funcionava para quem a achasse. Chave de CI é o único funcionário que nunca tira férias, nunca é desligado e nunca passou por entrevista.

A alternativa é **federação por OIDC**. O fornecedor da CI atua como provedor de identidade: em cada job, emite um ID token JWT (capítulo 30) assinado por ele, descrevendo quem está pedindo. No GitHub Actions, por exemplo:

```json
{
  "iss": "https://token.actions.githubusercontent.com",
  "sub": "repo:lastro/pagamentos:environment:producao",
  "aud": "sts.amazonaws.com",
  "ref": "refs/heads/main",
  "sha": "4e1f0c2a9b...",
  "exp": 1793872920
}
```

O job apresenta o token ao serviço de credenciais da nuvem (o AWS STS é um exemplo; Google Cloud e Azure têm federação equivalente). A nuvem busca as chaves públicas do emissor pelo JWKS, valida assinatura, `iss`, `aud` e `exp`, e confere a **política de confiança** do papel, que só aceita um `sub` exato. Passou, devolve credenciais que expiram em minutos. Não há segredo guardado na CI; o que vaza num log morre antes do café esfriar.

A segurança inteira mora na condição sobre o `sub`. Uma política que aceita `repo:lastro/*` entrega a produção a qualquer branch de qualquer repositório da organização, inclusive o `teste-do-estagiario-nao-apagar`. O OIDC troca o problema "guardar a chave" pelo problema "escrever a condição", e a condição, ao contrário da chave, aparece num `plan` revisado.

## Estratégias de deploy: quanto tráfego a versão nova machuca primeiro

| Estratégia | Versões juntas | Capacidade extra | Exposição antes da decisão | Tempo de rollback |
|------------|----------------|------------------|----------------------------|-------------------|
| Recreate (para tudo, sobe tudo) | nenhuma | nenhuma | 100%, com indisponibilidade | um deploy inteiro |
| Rolling update | 2, por minutos | `maxSurge` | cresce até 100% sem critério além das probes | outro rolling (minutos) |
| Blue-green | 2 ambientes, 1 recebe | 100% | 100% de uma vez | segundos (troca de rota) |
| Canary | 2, por dezenas de minutos | pequena | 1%, 5%, 25%... com análise em cada passo | segundos (peso 0) |

**Recreate** derruba a versão velha e sobe a nova, com indisponibilidade no meio. Exige janela de manutenção, e o Pix 24x7 não deu janela nem para o velório do `temp-01`.

**Rolling update** é o que o Kubernetes já faz: troca pods em lotes e só avança quando o pod novo passa na readiness. O critério é "o processo responde", e um processo que cobra errado responde perfeitamente. O rolling protege contra versão que não sobe. Contra versão que sobe e erra, ele é um distribuidor com logística de primeiro mundo.

**Blue-green** mantém dois ambientes completos; o verde recebe a versão nova e, num instante, o balanceador aponta tudo para ele. Rollback é apontar de volta, em segundos. Custa o dobro da capacidade durante a troca, e a exposição é total: o bug atinge todo mundo ao mesmo tempo, só que com um botão de desfazer melhor. É o paraquedas reserva de quem pula sem olhar a altura.

**Canary** manda uma fração pequena do tráfego para a versão nova, compara as métricas dela com as da versão estável (a *baseline*) no mesmo período e só aumenta a fração se empatarem. Mesmo tráfego, mesma hora, mesma carga: acabou o "às 10h é sempre assim". O nome vem do canário que os mineiros levavam para a mina, e a ideia continua a mesma, só que o bicho agora é um pod e ninguém fica triste quando ele morre.

### O canary é um teste estatístico com tráfego de verdade

A pergunta de cada degrau é se a diferença entre canary e baseline é maior que o ruído. Com aprovação de cartão de 85%, o desvio padrão da proporção medida em `n` autorizações é `√(0,85 × 0,15 / n)`. Com 100 autorizações, 3,6 pontos percentuais: uma queda de 5 pontos some no ruído. Com 2.000, 0,8 ponto, e a queda aparece com folga. Por isso o canary tem degraus: 1% pega o desastre grosso (erro 500, crash), 5% e 25% pegam as quedas sutis. Canary de cinco minutos com 1% do tráfego mede a sorte, e a sorte tem variância alta.

Com o Service do Kubernetes, a fração é o número de pods (1 novo em 30 dá 3,3%); um mesh com pesos por requisição, como o do capítulo 35, manda 1% com quantos pods existirem. Controladores de entrega progressiva (Argo Rollouts e Flagger são exemplos) sobem os degraus, consultam as métricas e voltam o peso a zero sozinhos quando a análise reprova. O controlador não tem chefe, não tem medo de postmortem e não acha que "deve ser só ruído".

E a mesma cobrança pode ser criada pela versão nova e capturada pela velha: a matriz de compatibilidade do capítulo 7 passa a valer por uma hora, e não por quarenta segundos.

## Feature flags: deploy é uma coisa, lançamento é outra

Uma **feature flag** é uma condição no código cujo valor vem de configuração em tempo de execução. Ela separa **deploy** (o código novo está nos processos) de **lançamento** (o comportamento novo está ligado para alguém): o código vai desligado, liga para um marketplace, depois para todos, sem deploy no meio.

Pelo tempo de vida, há flags de lançamento (dias), operacionais ou *kill switch* (permanentes, desligam uma peça cara sob carga), de experimento e de permissão. A avaliação é em memória, com a configuração empurrada aos processos; um serviço de flags consultado por requisição vira dependência síncrona do caminho do dinheiro, com a disponibilidade composta do capítulo 26 cobrando a conta.

O custo é combinatório: dez flags booleanas dão 1.024 comportamentos, e a CI testa uns cinco. Flag de lançamento que não morre vira código morto com interruptor, um zumbi esperando alguém reaproveitar o nome dele. A seção de armadilhas tem um zumbi que custou mais de 460 milhões de dólares.

Em sistema de dinheiro, a decisão tomada sob uma flag fica registrada junto do efeito. Se a cobrança foi tarifada pelo cálculo novo, a cobrança diz isso, e a conciliação refaz a conta com a regra certa daqui a três anos, quando a flag já tiver sido apagada e o autor dela estiver vendendo curso.

## Rollback, roll forward e o dinheiro que já foi gravado

**Rollback** é voltar à versão anterior; **roll forward** é corrigir e implantar uma nova. O rollback é mais rápido (peso zero em segundos, `rollout undo` em minutos) e só exige reconhecer o bug. O roll forward é o caminho quando voltar quebra algo: a versão nova gravou um estado que a antiga não sabe ler. Pipeline de onze minutos torna o roll forward viável; pipeline de duas horas transforma cada bug em duas horas de bug, mais o tempo de alguém achar o crachá.

E nenhum dos dois desfaz efeitos. Rollback volta o código; os lançamentos continuam no ledger, os eventos no tópico, os webhooks entregues e o Pix no banco de destino. Rollback é pedir desculpas ao vivo: interrompe a ofensa, não desdiz nada. Num ledger imutável (capítulo 1), dado errado se corrige com transação compensatória, referenciando a original, idempotente como no capítulo 16. O rollback estanca a sangria; a correção dos dados é um segundo projeto, com dono, contagem e conferência.

## Na Lastro

### A limpeza da terça

A correção foram 131 mil transações de ajuste: débito na receita da Lastro, crédito de um centavo ao vendedor (a liberar, no cartão; disponível, no Pix), origem `ajuste`, referência `ajuste-tarifa:{cobranca_id}` UNIQUE (capítulo 16), para o job parar e recomeçar sem duplicar centavo. O extrato mostra "Ajuste de tarifa (devolução)"; o evento novo `cobranca.tarifa_ajustada` é mudança aditiva (capítulo 11). O financeiro conferiu pela soma: R$ 1.310,00. O tabelião registrou 131 mil pedidos de desculpas com firma reconhecida.

### Pagamentos: canary com métricas de negócio

Blue-green dobraria os 30 a 60 pods a cada troca e exporia 100% das cobranças de uma vez; seria a escolha se as versões não pudessem conviver, o que o expand/contract já evita. Probe não sabe quanto custa uma tarifa. A Lastro escolheu canary para pagamentos pelo requisito de que um erro de cálculo atinja uma fração pequena das cobranças antes de ser detectado, ao custo de cerca de uma hora por deploy até 100%. O mesh faz a divisão por peso; um controlador de entrega progressiva conduz os degraus:

| Degrau | Peso | Duração | Cobranças na versão nova (manhã típica, ~39/s) |
|--------|------|---------|------------------------------------------------|
| 1 | 1% | 10 min | ~230 |
| 2 | 5% | 15 min | ~1.750 |
| 3 | 25% | 15 min | ~8.800 |
| 4 | 50% | 15 min | ~17.500 |
| 5 | 100% | | |

Toda cobrança grava `versao_servico` (o digest da imagem), e as métricas se dividem por versão. A análise volta o peso a zero se o canary piorar em relação à baseline em: taxa de `5xx`; p99 da autorização (orçamento do capítulo 14); fração de cartão em `processando`; aprovação de cartão, a partir do degrau 2, quando a amostra tem poder estatístico; e recusas do consumidor do ledger para cobranças daquela versão.

A métrica que teria pegado a terça é o **resíduo de arredondamento**, `tarifa_cobrada − valor × taxa` em centavos: com half-even, fica entre −0,5 e +0,5, média zero; com `ROUND_UP`, entre 0 e 1, média 0,5. O desvio padrão de uma uniforme de largura 1 é ~0,29; com as 230 cobranças do degrau 1, o erro padrão da média é 0,29/√230 ≈ 0,02, e o deslocamento vira 25 erros padrão. O bug do Carlos morreria aos dez minutos, com uns 2 reais de prejuízo. O vendedor 42 nem teria tido tempo de abrir a planilha.

Consumidores (ledger, entregador) não recebem requisição: neles, comportamento novo vai por flag, com deploy rolling e as mesmas métricas.

### Flags com recibo

As flags são versionadas no banco de configuração e chegam aos processos pelo caminho das tarifas do capítulo 22: cache em memória, TTL de 60 s, `NOTIFY` para urgência. Toda mudança de regra de dinheiro (tarifa, split, arredondamento, antifraude) vai atrás de flag por marketplace, ligada primeiro para a "Lastro Interna", um marketplace de produção da própria empresa que faz Pix reais de R$ 1,00 (o único cliente que nunca abriu chamado URGENTE), depois para um marketplace pequeno, depois para todos. A cobrança grava `regras_aplicadas` (versão da tabela de tarifas e versão do cálculo), e a conciliação das 6h refaz a conta com as duas. Flag de lançamento nasce com data de expiração, a CI falha se o código usa flag vencida, e nome de flag morta não se reaproveita: vai para a lápide, como os campos `reserved` do capítulo 12.

### O pipeline sem chave permanente

A CI usava uma chave permanente de administrador chamada `ci-temporario`, criada em 2021 e compartilhada por todos os repositórios: temporária no mesmo sentido em que o `temp-01` era provisório. Foi apagada e trocada por papéis federados por OIDC, um por função, com `sub` exato:

| Papel | Pode | `sub` aceito |
|-------|------|--------------|
| `ci-publica-imagem` | push no registry, assinar | `repo:lastro/<serviço>:ref:refs/heads/main` |
| `ci-terraform-plan` | leitura | qualquer PR dos repositórios de infra |
| `ci-terraform-apply` | escrita na camada | `repo:lastro/infra:environment:producao` |

As credenciais duram 15 minutos. O deploy no cluster é por pull: o pipeline grava o digest novo num repositório de manifestos e um controlador dentro do cluster reconcilia (o princípio do capítulo 35; Argo CD e Flux são exemplos). A CI não tem credencial do cluster, e um vazamento dela não alcança os pods. O segmento de cartão tem pipeline e papéis próprios, para que uma credencial que publica no cofre não arraste o escopo do PCI DSS para tudo o que a usa. Do merge ao degrau 1 são 11 minutos, o que mantém o roll forward como opção real.

## Armadilhas e casos reais

> **Na vida real:** em 1º de agosto de 2012, a Knight Capital implantou código novo de roteamento de ordens em oito servidores, e um deles ficou com a versão antiga. A versão nova reaproveitava uma flag que, no código antigo, ativava uma funcionalidade abandonada havia anos, a "Power Peg". No servidor esquecido, a flag ressuscitou o código morto, que passou a enviar ordens sem parar. Em cerca de 45 minutos, a empresa perdeu mais de 460 milhões de dólares, segundo a SEC. Deploy manual sem conferir se todas as máquinas convergiram, mais um nome de flag reaproveitado: duas linhas deste capítulo, cobradas em nove dígitos.

> **Na vida real:** em janeiro de 2023, a CircleCI informou que um malware no notebook de um engenheiro roubou uma sessão autenticada, usada para acessar segredos de clientes, e recomendou que todos girassem tudo o que guardavam lá. Quem usava OIDC girou menos: não guardava nada.

> **Armadilha:** configuração também é deploy. Tabela de tarifas, regra de antifraude ou flag mudada para 100% de uma vez tem a exposição de um recreate, sem pipeline nenhum. Na Lastro, flag também sobe em degraus, com a mesma análise.

> **Armadilha:** canary com a métrica errada. Taxa de `5xx` e latência aprovam com louvor um código que cobra errado. Sem métrica de negócio, o canary é um rolling update com cerimônia de formatura.

## Resumo

- Artefato imutável promovido pelo digest; configuração fora da imagem; imagem assinada.
- OIDC na CI: token por job, `sub` exato, credenciais de minutos.
- Estratégias diferem em versões juntas, capacidade extra, exposição e tempo de rollback.
- Canary é teste estatístico em degraus, com baseline e métrica de negócio.
- Flags separam deploy de lançamento, expiram e deixam recibo no dado.
- Rollback estanca; dado gravado se corrige com transação compensatória.

## A Lastro agora

Pagamentos sai em canary de cinco degraus, com métricas por digest, inclusive o resíduo de arredondamento. Regras de dinheiro vão atrás de flag por marketplace, começando pela Lastro Interna, com `regras_aplicadas` conferido pela conciliação. A CI não guarda credencial: OIDC, 15 minutos, deploy por pull, imagem assinada. Os 131 mil centavos voltaram, e o vendedor 42 conferiu o dele antes do financeiro.

O PR seguinte do Carlos se chamou "ajusta arredondamento (COM mudança de comportamento)", em maiúsculas, e foi o primeiro título de PR da Lastro a dizer a verdade. O canary agora vigia cada métrica que alguém pensou em medir. O problema são as que ninguém pensou: na sexta seguinte, a taxa de aprovação vai cair sem nenhum deploy, e quem vai perceber primeiro, de novo, é o Bazar.

## Referências

- Humble, J.; Farley, D. *Continuous Delivery*. Addison-Wesley, 2010.
- Kubernetes. *Deployments*. https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- GitHub. *About security hardening with OpenID Connect*. https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect
- OpenID Foundation. *OpenID Connect Core 1.0*. https://openid.net/specs/openid-connect-core-1_0.html
- SLSA. *Supply-chain Levels for Software Artifacts*. https://slsa.dev/
- Sigstore. https://www.sigstore.dev/
- Argo Rollouts. https://argoproj.github.io/argo-rollouts/
- Python. *decimal: Decimal fixed point and floating point arithmetic*. https://docs.python.org/3/library/decimal.html
- SEC. *In the Matter of Knight Capital Americas LLC*, Release No. 70694, 2013. https://www.sec.gov/litigation/admin/2013/34-70694.pdf
- CircleCI. *CircleCI incident report for January 4, 2023 security incident*. https://circleci.com/blog/jan-4-2023-incident-report/
