# CI/CD e estratégias de deploy

## O rollback que reproduziu o bug

Numa sexta-feira à noite, as recepcionistas das seis unidades da academia Ferro & Fôlego registraram 1.140 entradas num caderno espiral, à mão, uma por uma. Tudo começou às 17h50, quando o Wanderley abriu um pull request de uma linha só. A mudança aumentava de 2 para 3 o número de check-ins por dia que um aluno pode fazer na catraca. Os testes passaram, a revisão levou quarenta segundos ("é só uma linha") e o deploy em homologação saiu às 18h02. Tudo verde.

Às 18h20, o script `deploy_final_agora_vai.sh`, que mora no notebook do Wanderley desde 2021, fez o deploy em produção. Para isso, ele fez o que sempre fez: clonou o repositório no mesmo commit, rodou `pip install -r requirements.txt` e gerou uma imagem nova. Às 18h07, treze minutos antes, uma biblioteca de validação que o `requirements.txt` declarava como `>=2.1` tinha publicado a versão 3.0, com uma mudança incompatível. Homologação recebeu a 2.9. Produção recebeu a 3.0.

Às 18h21, as catracas das seis unidades começaram a responder `ValidationError` para todo mundo. O Wanderley fez o óbvio: rodou o script de novo, apontando para o commit anterior. O script clonou o commit anterior, instalou as dependências (versão 3.0, claro, a mais nova) e gerou uma imagem tão quebrada quanto a primeira. O rollback reproduziu o bug com fidelidade admirável. O caderno espiral ficou em produção até as 21h40.

O código revisado estava certo. O que foi para produção era outra coisa, montada duas vezes a partir do mesmo commit. Como garantir que o que roda em produção seja exatamente o que foi testado e que, se der errado, dê errado para pouca gente, por pouco tempo, com uma volta que funcione?

## O pipeline, ou a esteira que desconfia de você

### Três nomes parecidos

**Integração contínua** (*continuous integration*, CI) é integrar mudanças ao branch principal com frequência, cada integração disparando build e testes automáticos. Descobre-se em minutos que duas mudanças não convivem, em vez de descobrir em três semanas, num merge com 4.000 linhas de conflito.

**Entrega contínua** (*continuous delivery*) garante que todo commit aprovado gera um artefato que pode ir para produção a qualquer momento, com um botão. **Implantação contínua** (*continuous deployment*) tira o botão. As definições vêm de *Continuous Delivery*, de Jez Humble e David Farley (2010).

O *pipeline* é um grafo acíclico dirigido de jobs: cada um só começa quando as dependências terminam com sucesso. Se algum falha, o grafo para ali e ninguém em produção fica sabendo, que é o melhor tipo de falha.

### A ordem das etapas

Um pipeline típico de backend tem estas etapas:

1. Checagens estáticas: lint, tipos, dependências vulneráveis (capítulo 32).
2. Testes unitários.
3. Build do artefato, em geral uma imagem de contêiner.
4. Testes de integração e de contrato contra esse artefato.
5. Publicação num registry.
6. Deploy em homologação e testes de fumaça (*smoke tests*: poucas requisições que confirmam que o sistema sobe e responde).
7. Deploy em produção.

A ordem segue o custo: lint leva segundos, teste de integração leva minutos, deploy em produção leva o fim de semana de alguém se der errado. Um pipeline que roda 25 minutos de testes para depois reclamar de uma vírgula no lint cobra 25 minutos por vírgula.

O tempo total do pipeline também é o tempo mínimo de uma correção pelo caminho normal. Com 50 minutos de pipeline, o problema das 18h21 é corrigido, no melhor caso, às 19h11.

## O artefato imutável

A regra que teria salvado a Ferro & Fôlego é **construir uma vez, implantar muitas**: o pipeline gera o artefato uma única vez por commit, e os mesmos bytes sobem de homologação para produção. Nenhum ambiente reconstrói nada. Três condições sustentam a regra.

O artefato é identificado pelo conteúdo. Uma imagem OCI tem um *digest*, o SHA-256 do manifesto (`sha256:9f2c...`). Uma tag como `checkin:latest` é um ponteiro mutável: alguém empurra outra imagem com a mesma tag e o deploy seguinte puxa outra coisa sem que uma linha de configuração mude. O deploy por digest (`checkin@sha256:9f2c...`) garante que roda o que foi testado (capítulo 34).

As dependências são fixadas com hash. Um *lockfile* registra versão e hash de cada pacote, transitivos inclusive, e `uv sync --locked` ou `pip install --require-hashes` falham se o índice entregar outra coisa. A biblioteca de validação pode lançar a 3.0, a 4.0 e a 17.0 no fim de semana; o build instala a 2.9 até um commit mudar o lockfile.

A configuração fica fora do artefato. Se a URL do banco de homologação está dentro da imagem, produção precisa de outra imagem e a regra morre. Configuração entra no deploy, por variáveis de ambiente ou ConfigMaps (fator III do Twelve-Factor App), e segredos vêm de um gerenciador de segredos (capítulo 33).

Um passo além é o build reproduzível: o mesmo commit gera os mesmos bits em qualquer máquina, com imagem base fixada por digest e timestamps neutralizados (`SOURCE_DATE_EPOCH`). Serve para auditoria: provar que a imagem publicada veio daquele código. O SLSA organiza esses requisitos em níveis, e o Sigstore assina o artefato e registra a proveniência.

## Colocando a versão nova na frente do tráfego

Com o artefato pronto, falta trocar a versão que atende os usuários. As estratégias diferem em quanto tempo as duas versões convivem, quanta capacidade extra consomem e quanto demora a volta.

### Recreate

Derruba todas as instâncias antigas e sobe as novas, com indisponibilidade no meio. Nunca existem duas versões juntas, o que às vezes decide (um worker que não pode ter dois formatos consumindo a mesma fila). Foi a estratégia do `deploy_final_agora_vai.sh`, que tem o mérito da coerência: quebrou as seis unidades ao mesmo tempo, sem favorecer nenhuma.

### Rolling

Substitui as instâncias aos poucos: sobe algumas novas, espera o health check, tira algumas antigas, repete. No Kubernetes, `maxSurge` e `maxUnavailable` (25% cada, por padrão) limitam quantas sobram e quantas faltam (capítulo 35).

A capacidade extra é pequena. O preço é que, durante todo o rollout, v41 e v42 atendem juntas, e o mesmo aluno pode cair numa e depois na outra. O schema precisa servir às duas, as mensagens de uma precisam ser lidas pela outra e a API precisa ser compatível nos dois sentidos (o capítulo 12 trata do expand/contract no banco). A volta é outro rolling, tão lento quanto a ida.

### Blue-green

Mantém dois ambientes completos. O azul atende com a v41; o verde recebe a v42 e passa nos testes de fumaça sem tráfego real. Então o balanceador manda tudo para o verde. A volta é a mesma operação ao contrário, em segundos, enquanto o azul estiver de pé. Por DNS, a troca leva o TTL e mais os clientes que ignoram TTL, e nesse intervalo os dois recebem tráfego: um rolling sem controle de proporção.

Os custos são o dobro da capacidade durante a janela e um detalhe que derruba a promessa de volta instantânea: o banco é quase sempre um só. Se a v42 rodou uma migração que a v41 não entende, voltar o balanceador leva os usuários para um código que quebra no primeiro `SELECT`. O código troca em segundos; o schema exige a mesma disciplina de compatibilidade do rolling.

### Canary

Envia uma fração pequena do tráfego real para a versão nova, compara as métricas com as da estável e promove ou aborta, em passos como 1%, 5%, 25%, 100%. O nome vem dos canários das minas de carvão; no software, o canário passa muito bem, quem passa mal é o 1% de usuários.

O ganho é o raio de impacto: um bug que quebra o check-in quebra 1% das entradas, e a análise aborta antes do resto. O preço é estatística. A versão estável erra 0,1%; para distinguir um canário que erra 0,2% com três desvios padrão, a diferença esperada (0,001 × n) precisa superar 3 × √(0,003 × n), o que dá n ≈ 27.000 requisições. Com 400 req/s e 5% no canário, são 20 req/s e 22 minutos e meio para enxergar uma regressão que dobra a taxa de erro. Um bug que derruba tudo aparece em segundos; um que piora um pouco exige paciência, e um serviço com pouco tráfego não tem amostra para canário nenhum.

Uma decisão automatizada mínima, com teste z para duas proporções:

```python
import math
from dataclasses import dataclass


@dataclass
class Amostra:
    requisicoes: int
    erros: int

    @property
    def taxa(self) -> float:
        return self.erros / self.requisicoes


def veredito(base: Amostra, canario: Amostra, minimo: int = 5_000) -> str:
    if canario.requisicoes < minimo:
        return "esperar: amostra pequena demais para acusar alguém"
    # Diferença entre duas proporções, em desvios padrão (teste z).
    p = (base.erros + canario.erros) / (base.requisicoes + canario.requisicoes)
    desvio = math.sqrt(p * (1 - p) * (1 / base.requisicoes + 1 / canario.requisicoes))
    z = (canario.taxa - base.taxa) / desvio
    if z > 3:
        return f"abortar: canário erra {canario.taxa:.3%} contra {base.taxa:.3%} (z = {z:.1f})"
    return f"promover: {canario.taxa:.3%} contra {base.taxa:.3%} (z = {z:.1f})"


print(veredito(Amostra(228_000, 230), Amostra(1_200, 24)))
print(veredito(Amostra(228_000, 230), Amostra(12_000, 41)))
print(veredito(Amostra(228_000, 230), Amostra(12_000, 14)))
```

```text
esperar: amostra pequena demais para acusar alguém
abortar: canário erra 0.342% contra 0.101% (z = 7.7)
promover: 0.117% contra 0.101% (z = 0.5)
```

O canário com 2% de erro e só 1.200 requisições parece alarmante, e a função se recusa a julgar. O segundo tem amostra para abortar com folga. O terceiro cabe no ruído. Ferramentas como Argo Rollouts e Flagger fazem essa análise contra o Prometheus e avançam ou abortam sozinhas. A linha de base vem do mesmo intervalo, para não culpar a v42 pelo pico de segunda às 6h, quando 340 pessoas tentam entrar ao mesmo tempo.

Uma sutileza: o canário divide o tráfego e compartilha o resto. Se a v42 tem uma consulta que trava uma tabela, 1% do tráfego derruba o banco de 100% dos usuários.

## Feature flags: deploy de um lado, lançamento do outro

Uma *feature flag* separa deploy de lançamento: o código vai para produção desligado, atrás de uma condição avaliada em tempo de execução, e é ligado depois, sem deploy, para quem e quando se quiser. Pete Hodgson (2017) classifica as flags pela vida útil: de lançamento (semanas), de experimento (o teste A/B), operacionais (*kill switches*, que desligam algo caro sob carga e duram anos) e de permissão (que na prática viram autorização).

O lançamento por percentual exige que o mesmo usuário caia sempre do mesmo lado, e que quem entrou com 10% continue dentro com 25%. A forma usual é um hash estável de (flag, usuário) reduzido a 0–9.999:

```python
import hashlib


def balde(flag: str, usuario_id: str) -> int:
    """Número estável entre 0 e 9.999 para o par (flag, usuário)."""
    chave = f"{flag}:{usuario_id}".encode()
    return int.from_bytes(hashlib.sha256(chave).digest()[:8], "big") % 10_000


def ligada(flag: str, usuario_id: str, percentual: float) -> bool:
    return balde(flag, usuario_id) < percentual * 100


ids = [f"aluno-{i}" for i in range(100_000)]
com_10 = {a for a in ids if ligada("checkin-por-qr", a, 10)}
com_25 = {a for a in ids if ligada("checkin-por-qr", a, 25)}
print(f"perderam a flag ao subir de 10% para 25%: {len(com_10 - com_25)}")
print(balde("checkin-por-qr", "aluno-101") == balde("checkin-por-qr", "aluno-101"))
```

```text
perderam a flag ao subir de 10% para 25%: 0
True
```

O zero sai da construção: balde abaixo de 1.000 também está abaixo de 2.500. O nome da flag na chave impede que os mesmos 10% de alunos sejam cobaias de todas as flags da empresa, uma honra que nenhum deles pediu. O `hash()` embutido do Python não serve, porque é randomizado por processo (`PYTHONHASHSEED`) e cada réplica sortearia um grupo diferente.

O custo é combinatório: dez flags booleanas dão 2^10 = 1.024 caminhos, e a suíte de testes cobre alguns. Flags que chegaram a 100% e ficaram viram ramos mortos, ao lado do `TODO: remover depois do lançamento` de três lançamentos atrás. Se a flag vem de um serviço remoto, o SDK precisa de cache local e valor padrão para quando ele não responde; o OpenFeature, da CNCF, padroniza essa API.

## Rollback e roll forward

**Rollback** é voltar ao artefato anterior. **Roll forward** é corrigir com um artefato novo, pelo pipeline normal.

O rollback depende de duas condições. A primeira é o artefato anterior existir; com artefato imutável, voltar é implantar um digest que já esteve em produção. Na Ferro & Fôlego, o rollback era um build novo de código velho com dependências novas: um roll forward disfarçado, e mal disfarçado.

A segunda é a v41 conviver com o que a v42 deixou, e algumas coisas não voltam com o código:

- Migrações destrutivas: a coluna removida não reaparece.
- Dados no formato novo: linhas, mensagens e entradas de cache que a v41 não sabe ler.
- Efeitos externos: e-mails enviados, cobranças feitas.

O expand/contract (capítulo 12) cuida do banco, e o leitor tolerante (capítulo 25) cuida das mensagens.

O roll forward compensa quando o rollback é impossível, e custa o tempo do pipeline mais o tempo de escrever a correção com seis gerentes de unidade no telefone. Uma flag operacional é mais rápida que os dois: desliga só a funcionalidade problemática, sem deploy.

## O pipeline sem chave no bolso

Para publicar e implantar, o pipeline precisa de credenciais da nuvem. A forma antiga é guardar uma chave de longa duração como segredo do CI: vale por anos e fica disponível para todo job que lê segredos, inclusive o que baixa um script de terceiros a cada build.

Com **OIDC** (o capítulo 30 trata do protocolo), não há segredo guardado. O provedor de CI atua como emissor de identidade e, a cada execução, assina um JWT de vida curta que descreve o job. A nuvem busca as chaves públicas do emissor (JWKS), valida assinatura, `aud` e `exp`, compara as claims com uma política e devolve credenciais temporárias. No GitHub Actions, as claims de um job de produção ficam assim:

```json
{
  "iss": "https://token.actions.githubusercontent.com",
  "aud": "sts.amazonaws.com",
  "sub": "repo:ferro-e-folego/checkin:environment:producao",
  "repository": "ferro-e-folego/checkin",
  "ref": "refs/heads/main",
  "environment": "producao",
  "workflow": "entrega"
}
```

O `sub` diz exatamente qual repositório e qual ambiente pedem acesso. A política de confiança do papel na nuvem (aqui no formato da AWS, como exemplo; a Workload Identity Federation do Google Cloud e as credenciais federadas do Azure seguem o mesmo mecanismo) só aceita esse `sub`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:ferro-e-folego/checkin:environment:producao"
      }
    }
  }]
}
```

As credenciais devolvidas expiram (uma hora por padrão no STS) e só valem para aquele papel. Outro branch, um fork ou outro repositório recebe outro `sub` e leva `AccessDenied`. O pipeline completo, com build único e promoção por digest:

```yaml
name: entrega
on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write  # autoriza o job a pedir o token OIDC; nenhuma chave guardada

env:
  IMAGEM: 111122223333.dkr.ecr.sa-east-1.amazonaws.com/checkin

jobs:
  build:
    runs-on: ubuntu-24.04
    outputs:
      digest: ${{ steps.imagem.outputs.digest }}
    steps:
      - uses: actions/checkout@v4  # em produção, fixar pelo SHA do commit
      - uses: astral-sh/setup-uv@v6
      - run: uv sync --locked && uv run pytest -q
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111122223333:role/ci-publica-imagem
          aws-region: sa-east-1
      - uses: aws-actions/amazon-ecr-login@v2
      - id: imagem
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: ${{ env.IMAGEM }}:${{ github.sha }}

  homologacao:
    needs: build
    environment: homologacao
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111122223333:role/ci-implanta-homologacao
          aws-region: sa-east-1
      - run: ./implantar.sh "$IMAGEM@${{ needs.build.outputs.digest }}"

  producao:
    needs: [build, homologacao]
    environment: producao  # aprovação manual e regras de branch ficam aqui
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111122223333:role/ci-implanta-producao
          aws-region: sa-east-1
      - run: ./implantar.sh "$IMAGEM@${{ needs.build.outputs.digest }}"
```

Só o job `build` constrói. Os jobs de deploy recebem o mesmo digest e assumem papéis diferentes, cada um aceitando só o `sub` do próprio ambiente. Homologação não implanta em produção nem com um `implantar.sh` reescrito por alguém muito criativo.

## Propriedades e custos

| Estratégia | Indisponibilidade | Versões juntas | Capacidade extra | Tempo de volta | Raio de impacto de um bug |
|---|---|---|---|---|---|
| Recreate | Sim, durante a troca | Nunca | Nenhuma | Outro recreate | 100% |
| Rolling | Não | Durante todo o rollout | `maxSurge` (ex.: 25%) | Outro rolling | Cresce com o rollout |
| Blue-green | Não | Só na drenagem | 100% durante a janela | Segundos (troca no balanceador) | 100% após a troca |
| Canary | Não | Durante toda a análise | Pequena | Segundos (tráfego volta para a estável) | A fração do canário |
| Feature flag | Não | O código é um só | Nenhuma | Segundos, sem deploy | O percentual da flag |

Indisponibilidade pesa conforme o tráfego do horário; um job noturno convive bem com recreate. Convivência de versões pesa conforme o acoplamento (schema, mensagens, sessões, caches). O blue-green dobra a conta da nuvem enquanto os dois ambientes existem. O canário depende de tráfego: com 2 req/s, as 27.000 requisições levam mais de três horas e meia. E flags cobrem a lógica da funcionalidade, mas um erro de importação derruba o processo antes de qualquer flag ser avaliada.

## Armadilhas e casos reais

> **Na vida real:** em 1º de agosto de 2012, a Knight Capital implantou código novo de roteamento de ordens em oito servidores e, segundo a SEC, um técnico deixou de copiá-lo para um deles. O código novo reaproveitava uma flag que, no servidor esquecido, ativava uma funcionalidade aposentada desde 2003, a Power Peg. Ligada a flag, sete servidores se comportaram e o oitavo executou mais de 4 milhões de negócios em 154 ações em cerca de 45 minutos, com perda de mais de US$ 460 milhões. Nada verificava que os oito rodavam o mesmo artefato.

> **Na vida real:** em 19 de julho de 2024, às 04h09 UTC, a CrowdStrike distribuiu o Channel File 291 para o sensor Falcon em Windows. Segundo a análise de causa raiz, o template definia 21 campos de entrada e o sensor fornecia 20, e a leitura fora dos limites travou o sistema. A atualização foi revertida às 05h27; a Microsoft estimou cerca de 8,5 milhões de máquinas afetadas, muitas com recuperação manual. Esse tipo de conteúdo ia para todos os sensores de uma vez, e a correção anunciada inclui implantação escalonada em anéis.

> **Armadilha:** tags mutáveis existem no próprio pipeline. Em março de 2025, as tags da action `tj-actions/changed-files` foram reapontadas para um commit malicioso que imprimia os segredos do runner nos logs (CVE-2025-30066); quem fixava a action por SHA de commit escapou. Em 2021, o script de upload da Codecov enviou variáveis de ambiente de CI a um servidor externo por cerca de dois meses, e em janeiro de 2023 a CircleCI pediu que os clientes trocassem todos os segredos guardados na plataforma. Credenciais OIDC de minutos reduzem o que esses vazamentos entregam.

> **Armadilha:** o health check só diz que o processo responde. Uma v42 que devolve `200` em `/pronto` e recusa todos os check-ins atravessa o rolling inteiro sem objeção.

> **Armadilha:** um `sub` com curinga (`repo:ferro-e-folego/*`) dá o papel de produção a qualquer repositório da organização, inclusive o que o estagiário criou para aprender YAML.

## Resumo

- CI integra e testa cada mudança; entrega contínua mantém todo commit aprovado pronto para produção; implantação contínua leva sozinha o que passa.
- O pipeline ordena as etapas da mais barata para a mais cara, e o tempo dele é o tempo mínimo de uma correção.
- Construir uma vez e implantar muitas: o mesmo artefato, identificado por digest, sobe de ambiente em ambiente. Lockfile com hash, configuração fora da imagem e nenhum build no notebook de ninguém.
- Recreate tem indisponibilidade; rolling e canary exigem convivência entre versões; blue-green dobra a capacidade e troca o código em segundos, mas o banco continua sendo um só.
- O canário limita o raio de impacto e custa tempo de amostra: regressões pequenas exigem dezenas de milhares de requisições.
- Feature flags separam deploy de lançamento; o percentual usa hash estável de (flag, usuário); flags velhas multiplicam caminhos.
- Rollback exige o artefato anterior e compatibilidade com o que a versão nova deixou; roll forward custa o tempo do pipeline.
- OIDC troca chaves de longa duração por tokens de minutos, presos ao repositório e ao ambiente pelo `sub`.

## Referências

- Jez Humble e David Farley, *Continuous Delivery* (Addison-Wesley, 2010).
- Martin Fowler, "BlueGreenDeployment": <https://martinfowler.com/bliki/BlueGreenDeployment.html>
- Danilo Sato, "CanaryRelease": <https://martinfowler.com/bliki/CanaryRelease.html>
- Pete Hodgson, "Feature Toggles (aka Feature Flags)": <https://martinfowler.com/articles/feature-toggles.html>
- OpenFeature: <https://openfeature.dev/>
- The Twelve-Factor App, III. Config: <https://12factor.net/config>
- SLSA: <https://slsa.dev/>
- Reproducible Builds, `SOURCE_DATE_EPOCH`: <https://reproducible-builds.org/docs/source-date-epoch/>
- Kubernetes, Deployments (estratégia de rolling update): <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
- Argo Rollouts: <https://argoproj.github.io/rollouts/>
- GitHub Docs, "About security hardening with OpenID Connect": <https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect>
- AWS STS, `AssumeRoleWithWebIdentity`: <https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html>
- SEC, Release No. 34-70694 (Knight Capital Americas LLC, 2013): <https://www.sec.gov/litigation/admin/2013/34-70694.pdf>
- CrowdStrike, "Channel File 291 Incident: Root Cause Analysis" (agosto de 2024): <https://www.crowdstrike.com/wp-content/uploads/2024/08/Channel-File-291-Incident-Root-Cause-Analysis-08.06.2024.pdf>
- CISA, "Supply Chain Compromise of Third-Party tj-actions/changed-files (CVE-2025-30066)" (março de 2025): <https://www.cisa.gov/news-events/alerts/2025/03/18/supply-chain-compromise-third-party-tj-actionschanged-files-cve-2025-30066-and-reviewdogaction>
