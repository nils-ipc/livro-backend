# Tom e estilo

## A voz

- **Cada capítulo é um show de stand-up que, por acaso, ensina backend.** O narrador é um comediante no palco que passou quinze anos de plantão e voltou para contar. O leitor é a plateia. O texto precisa fazer rir alto, não sorrir de canto: rir sozinho no ônibus, engasgar com o café, mandar foto da página para o grupo da empresa. A seção "Humor" abaixo tem o mesmo peso das regras de rigor técnico, e "foi engraçadinho" é reprovação.
- **Linguagem falada, de palco.** O texto soa como alguém falando ao microfone: direto, solto, com ritmo, pausa e virada. Nada formal, acadêmico ou engessado. O registro oral ("pra", "tá", "né") é permitido quando ajuda o ritmo da piada ou a fala de um personagem; no mecanismo, o português continua correto e limpo.
- **Palavrão liberado, com função.** Um palavrão bem colocado é uma punchline; palavrão em toda frase é só barulho. Use quando ele for a palavra mais engraçada disponível, não como pontuação.
- **Sem gíria de internet, meme ou referência que envelhece em seis meses.** O livro precisa ser engraçado daqui a cinco anos.
- **Frases curtas na maior parte do tempo**, com ritmo de palco: preparação, pausa, golpe. Parágrafos curtos. A palavra que faz rir vai no fim da frase.
- **Direto ao ponto.** Nada de introdução genérica do tipo "No mundo atual da tecnologia...". Cada parágrafo entrega uma informação, uma risada ou, de preferência, as duas.
- **Preciso e rigoroso.** O comediante pode mentir sobre tudo, menos sobre o mecanismo. A piada nunca sacrifica a exatidão técnica.
- **O leitor é inteligente e entende de tecnologia.** Escrever para um colega sênior, nunca para uma criança ou um leigo. Explicar o mecanismo diretamente, no nível técnico, sem simplificar com historinhas e sem repetir a mesma ideia de três jeitos. Se um conceito é novo para ele, defini-lo com precisão uma vez e seguir em frente. A plateia é esperta: piada que precisa ser explicada morreu.
- **O leitor lê, não executa.** O livro é para ser lido do começo ao fim, sem computador por perto. O projeto da Lastro é descrito, nunca implementado, e o código aparece só em trechos curtos que exemplificam um conceito (ver `instrucoes/projeto.md`). O texto nunca pede ao leitor que rode, instale, teste, implemente, abra um terminal ou "experimente na sua máquina".

## Humor

### O alvo: escracho, não simpatia

O humor anterior deste livro falhou por ser educado demais: muitos momentos de graça, todos fracos, do tipo que se reconhece como piada sem rir dela. Ironia suave, personificação fofa e "o que, como você vai ver, não é verdade" não bastam mais. O alvo agora é o humor escrachado de stand-up:

- **Piada idiota é bem-vinda.** Trocadilho horrível, piada de tiozão, a piada tão ruim que fica boa. O narrador pode assumir o crime ("eu sei, eu sei, essa foi péssima, e vou fazer de novo daqui a duas páginas") ou fingir que foi genial.
- **Humor negro é bem-vindo.** Backend é um assunto mórbido: o kernel mata processos, os filhos ficam órfãos e são adotados pelo `init`, os zumbis ficam na tabela de processos porque o pai não leu o atestado de óbito, o OOM killer escolhe a vítima por pontuação, o `kill -9` não dá direito a últimas palavras, a carreira do dev termina num `DROP TABLE` em produção, o plantão das 3h da manhã envelhece o engenheiro em dobro.
- **Humor adulto é bem-vindo.** Duplo sentido e malícia de palco, que a terminologia entrega de bandeja: handshake, inserção, penetração (o *pen test*), conexão persistente, *keep-alive*, rapidinha que dá timeout, cliente que fecha a conexão sem avisar, relação de muitos para muitos, chave estrangeira, *master* e *slave* (e por que o mercado trocou os nomes). Malícia sim, descrição sexual explícita não.
- **Humor ofensivo é bem-vindo, com mira.** Roast pesado do leitor, do próprio narrador, da profissão, do fundador da Lastro, do gerente que pede estimativa, do arquiteto que desenha caixinhas, do consultor que cobra por hora, do microsserviço que só existe para chamar outro microsserviço, das tecnologias (o YAML, o JavaScript, o Java e seus `AbstractSingletonProxyFactoryBean`, o PHP, o próprio SQL), do mercado e das modas. Ver os limites abaixo.
- **Exagero sem freio.** Levar uma má decisão até a consequência mais absurda e ainda matematicamente correta, e depois passar dela.

### Quanto humor

Muito, e com risada de verdade. O humor é contínuo, do título da primeira seção ao resumo (as referências ficam sem piada). Como régua:

- **Densidade:** pelo menos uma piada a cada parágrafo ou dois, em **todas** as seções, inclusive as mais densas do mecanismo, as tabelas de custos e os exemplos de código. Algo entre 40 e 60 piadas por capítulo.
- **Força:** cada seção `##` precisa de pelo menos um *bit* forte, aquele trecho que o leitor mandaria para alguém. Um capítulo inteiro de piadas médias está reprovado, mesmo que tenha sessenta delas.
- **Teste da risada:** releia cada piada e pergunte se alguém riria alto disso num bar de comédia. Se a resposta é "dá um sorrisinho", reescreva mais pesada, mais absurda, mais específica ou mais idiota, ou corte. Ironia que só se reconhece como ironia não conta como piada.
- O mecanismo é exatamente onde o humor mais ajuda. Explicar o handshake do TCP, o MVCC ou o Raft como um número de stand-up é o que diferencia este livro de uma RFC.

### O capítulo como um show

Cada capítulo é um *set* de stand-up, com a estrutura de um:

- **Abertura (opener):** a primeira frase já é piada, dentro da cena da Lastro. Nada de aquecimento. O comediante entra no palco falando do desastre.
- **Bits:** cada seção é um *bit*, um bloco com premissa cômica própria que carrega o conceito técnico. A premissa é uma observação verdadeira e absurda sobre o mecanismo ("o TCP é o único protocolo que pede confirmação de que você recebeu a confirmação"), e as piadas saem dela em sequência.
- **Tags:** depois de uma piada que funcionou, emendar mais uma ou duas em cima da mesma premissa, cada uma mais pesada. O riso cresce na terceira.
- **Escalada:** a situação da Lastro piora a cada parágrafo até o ponto mais absurdo, e só então vem a explicação de como evitar.
- **Callbacks:** retomar uma piada de seções anteriores (ou de capítulos anteriores) no momento mais inesperado. O callback mais forte fica no fim.
- **Fechamento (closer):** "A Lastro agora" termina com o melhor callback do capítulo ou com uma piada que já prepara o desastre do capítulo seguinte.

### Técnicas

Usar todas, variando ao longo do capítulo:

- **Observacional:** "vocês já repararam que..." aplicado à vida de quem opera sistemas. O que todo dev viu e nunca disse em voz alta.
- **Act-out (encenação):** o narrador dá voz aos componentes e às pessoas, em diálogo curto. O kernel burocrata, o garbage collector que para o mundo para limpar o quarto, o load balancer que manda tudo para o único servidor doente, o banco de dados passivo-agressivo:

  ```text
  Cliente:  Recebeu meu pagamento?
  Servidor: Talvez.
  Cliente:  Vou mandar de novo, por garantia.
  Servidor: (cobra duas vezes)
  Cliente:  Recebeu?
  Servidor: Duas vezes. Quer recibo das duas?
  Bazar:    (abre chamado com o assunto "URGENTE!!!!")
  ```

  A personalidade é uma camada de graça sobre o comportamento real, descrito com exatidão; ela não substitui a explicação nem serve de analogia.
- **Crowd work:** falar com a plateia e acusá-la. "Você aí, que já rodou um `UPDATE` sem `WHERE`: eu sei que foi você. A tabela também sabe." O leitor é cúmplice de todos os pecados da profissão.
- **Autodepreciação do narrador:** o comediante conta os próprios crimes (o `git push --force` na `main`, o índice criado no pico, o "é só uma linha" de sexta às 17h50) e as sequelas emocionais que deixaram.
- **Piada infame assumida:** o trocadilho terrível, seguido de comentário do narrador sobre a própria piada ("essa piada tem a mesma qualidade do código legado da Lastro: ninguém sabe quem escreveu e ninguém tem coragem de tirar").
- **Anti-piada e quebra de expectativa:** montar a preparação para uma punchline óbvia e entregar outra, seca e literal.
- **Regra de três cômica:** dois itens normais e o terceiro absurdo. Só para piada, e não em toda lista (ver "Grupos de três" nas marcas de IA).
- **Exagero com lógica:** "nesse ritmo, em 2031 o backup vai levar mais tempo do que o intervalo entre backups, e em 2033 o backup vai ter um backup próprio, que também vai falhar".
- **Humor negro técnico:** mortes, órfãos, zumbis, execuções sumárias, autópsias (o postmortem), heranças malditas (o código legado), cemitérios (o bucket de logs que ninguém abre).
- **Piadas recorrentes** (*running gags*) e personagens fixos: `instrucoes/projeto.md` lista os de partida e os resumos registram os que nasceram depois. Retomar uma piada recorrente exige uma situação nova e pior; repetir a mesma piada é tique.
- **Títulos de seção com punchline**, desde que digam do que a seção trata ("O handshake, ou como dois computadores dizem oi três vezes e mesmo assim um deles não estava ouvindo").
- **Código e saídas com graça**: nomes, comentários e mensagens de log escrachados, com o código tecnicamente correto (`-- não rode isso. sério. o Carlos rodou.`). Descrições do projeto também: o nome de um job, o estado de uma cobrança, a mensagem de erro que o Bazar recebeu.
- **Apartes e notas de rodapé faladas:** parênteses em que o narrador interrompe a si mesmo para fazer outra piada.
- **Destaques com humor**: os blocos `> **Armadilha:**` e `> **Na vida real:**` também levam piada, de preferência a mais cruel da seção.

### De onde vem a graça

As melhores piadas vêm da vida real de quem constrói e opera sistemas, contada sem pudor:

- O deploy de sexta-feira às 17h50, que "é só uma linha", e o fim de semana que ele custou.
- O índice criado em produção no horário de pico, e o silêncio no canal logo depois.
- O cache que "resolveu" o problema escondendo o bug por seis meses, como um corpo no porão.
- O `TODO: remover antes de subir` que completou cinco anos em produção e já pode votar.
- O log que diz `Erro: sucesso`.
- O servidor chamado `temp-01`, o mais antigo e o mais crítico da empresa.
- O timeout de 30 segundos que ninguém sabe quem configurou, e que ninguém tem coragem de mudar, porque o último que tentou foi transferido.
- A planilha que, no fundo, é o banco de dados oficial da empresa.
- A reunião de postmortem em que todo mundo descobre que o alerta disparou, sim, e foi silenciado em 2019.
- A estimativa de "duas semanas" que virou dois trimestres e um divórcio.

### Limites

O escracho tem poucos limites, e eles valem sempre:

- **Exatidão primeiro.** A piada nunca altera o fato. Se um exagero puder ser lido como dado real, deixar claro que é exagero. Números apresentados como reais continuam reais e verificáveis.
- **O ofensivo mira escolhas, nunca identidades.** Pode ofender o leitor, o narrador, a profissão, os cargos, as decisões, as tecnologias, as modas e os personagens fictícios da Lastro, à vontade. Não pode ter como alvo raça, etnia, origem regional, religião, gênero, orientação sexual, deficiência, doença, idade ou aparência de ninguém. Piada preconceituosa é a piada mais preguiçosa que existe, e este livro tem padrão.
- **Pessoas e empresas reais.** Nada de roast de pessoa real identificável. Empresas e tecnologias reais podem levar piada sobre fatos públicos e verificados (um incidente documentado, uma decisão de design conhecida), nunca sobre fatos inventados. Nos incidentes reais, o humor vai para o mecanismo da falha e para a ironia da situação, nunca para quem foi afetado; tragédia real com vítimas (mortes, ferimentos) fica sem piada.
- **Humor negro fica com as máquinas e com a ficção.** Processos, servidores, carreiras fictícias, o sofrimento do próprio narrador. Não com tragédias reais nem com temas como suicídio, abuso ou violência real.
- **Humor adulto é malícia, não pornografia.** Duplo sentido sim; descrição sexual explícita não.
- **O roast de tecnologia é bit, não veredito.** A piada pode zombar do YAML; a comparação técnica, logo em seguida, continua objetiva: o que cada opção garante e quanto custa (ver "Conteúdo objetivo"). A decisão da Lastro nunca é justificada pela piada.
- **A piada não pode atrapalhar a explicação.** Se o leitor precisar reler a frase para entender o conceito, a piada foi para o lugar errado. Piada no parágrafo do mecanismo vai antes ou depois da frase que define, não dentro dela.
- **Variar.** A mesma estrutura de piada repetida vira tique e denuncia texto de IA. Alternar técnicas, tamanhos, alvos e posições no parágrafo.

### Atenção do leitor

O humor já faz boa parte desse trabalho. Além dele:

- A primeira frase do capítulo coloca o leitor dentro de uma cena concreta e já é piada.
- Uma pergunta deixada no ar no começo e respondida mais adiante dá motivo para continuar lendo. Toda pergunta aberta é respondida no capítulo.
- Depois de três ou quatro parágrafos de mecanismo, entra um act-out, uma cena da Lastro ou um callback.

## Analogias

Evitar. Analogias costumam ser forçadas, explicam pior que o mecanismo e tratam o leitor como leigo ("imagine que o banco de dados é uma biblioteca e o índice é o fichário"). Um leitor que entende de tecnologia aprende mais com o mecanismo descrito diretamente, com um número e um exemplo real.

- Padrão: explicar o mecanismo sem analogia nenhuma.
- Exceção rara: uma analogia muito boa, que seja precisa, curta, surpreendente e engraçada, e que diga algo que a explicação direta não diz tão bem. No máximo uma ou duas por capítulo, e sempre seguida da explicação exata. Na dúvida, cortar.
- Relação técnica real não é analogia e é bem-vinda: dizer que a busca numa B-tree é uma busca binária generalizada para nós com muitas chaves é explicar o mecanismo pelo que o leitor já conhece.
- Proibido: analogias com o cotidiano para explicar conceitos básicos (correio, envelope, carteiro, biblioteca, restaurante, garçom, rodovia, fila de banco, lista telefônica), analogias encadeadas e analogias que precisam de um parágrafo para se sustentar.

## Conteúdo objetivo

O livro ensina conhecimento técnico definido, nunca opinião.

- Toda afirmação precisa ser verificável: por uma especificação, pela documentação oficial, por um mecanismo explicado no texto, por uma medição ou por um caso documentado.
- Nada de "a melhor prática é...", "o ideal é...", "prefira sempre..." sem o motivo técnico logo em seguida. Se o motivo existe, apresentar o motivo; a recomendação fica implícita nele.
- Em comparações, descrever o que cada opção garante, o que custa e em que condição cada propriedade pesa. Não eleger vencedor nem dizer que uma tecnologia é "moderna", "ultrapassada", "elegante" ou "feia".
- Termos com definição formal (linearizabilidade, idempotência, serializable) são usados no sentido exato da definição, mesmo quando o mercado os usa de forma frouxa. Se o uso de mercado difere, dizer qual é a diferença.
- Observações empíricas (Lei de Conway, números de latência de referência) são apresentadas como observações ou medições, com a fonte, e não como leis da natureza.
- Nada de conselhos de carreira, liderança, comunicação ou processo de equipe.

## Faça

- Falar com o leitor em segunda pessoa ("você").
- Usar perguntas retóricas de vez em quando para conduzir o raciocínio, como em uma conversa (com moderação; ver a seção sobre marcas de texto de IA).
- Explicar o conceito novo pela relação técnica real com algo que o leitor já domina (Python, React, git, ORM, SQL), sem recorrer a analogias (ver a seção "Analogias").
- Contar casos reais (incidentes públicos, postmortems conhecidos), sempre verificados.
- Ancorar o conceito na Lastro: depois do mecanismo geral, mostrar o que ele muda no projeto, com números do projeto.
- Mostrar o erro antes do acerto quando isso ensinar algo ("veja o que acontece se...").
- Usar destaques curtos:
  - `> **Armadilha:** ...` para erros comuns e custos escondidos.
  - `> **Na vida real:** ...` para casos reais e práticas de mercado.
  - `> **Dica:** ...` para atalhos e boas práticas.

## Não faça

- Gíria de internet, meme ou tom de rede social (o registro oral de palco é outra coisa e está liberado; ver "A voz").
- Humor educado: a ironia de canto de boca, o trocadilho tímido, a piada que pede licença. Se é para fazer piada, faça inteira.
- Parágrafos longos ou blocos de teoria sem exemplo.
- Jargão sem explicação na primeira aparição.
- Linguagem de marketing ("serviço altamente escalável e resiliente que..."). Explicar o que faz, sem vender.
- Listas enormes de recursos. Escolher o que importa para quem precisa decidir e operar.
- Apresentar uma tecnologia sem os custos e limites dela.
- Implementar o projeto: nada de código dos serviços da Lastro, nem "passo a passo" de construção. Descrever decisões, fluxos e esquemas.
- Deixar o projeto engolir o conceito: o mecanismo é ensinado em termos gerais, e não só no recorte que a Lastro usa.

## Evitar marcas de texto escrito por IA

O texto precisa parecer escrito por uma pessoa. Os padrões abaixo denunciam texto gerado por IA e **não devem aparecer** no livro. Escrever já evitando esses padrões; a checagem mecânica abaixo pega o que escapar.

### Pontuação e construções

- **Travessão (—) para intercalar explicação no meio da frase.** Usar vírgula, parênteses ou dois-pontos. Travessão só em diálogo, se houver.
- **"Não é X, é Y"** e variações: "isso não é um bug, é uma feature", "não se trata de X, mas de Y", "X não é apenas Y". Afirmar diretamente o que a coisa é.
- **"Não apenas X, mas também Y."**
- **Pergunta seguida de resposta de efeito**: "O resultado? Caos.", "A solução? Simples.", "O motivo? ...". No máximo uma ocorrência rara por capítulo.
- **Sequências de frases-fragmento para dar drama**: "Rápido. Barato. Seguro.", "Sem servidor. Sem dor de cabeça."
- **Grupos de três** recorrentes (três adjetivos, três exemplos, três itens em toda lista). Usar a quantidade que o conteúdo pedir: dois, quatro, um. A regra de três cômica (dois itens normais e o terceiro absurdo) é técnica de palco e pode aparecer, sem virar padrão.
- **Fechar todo parágrafo ou seção com uma frase de efeito** ou moral da história. Terminar o parágrafo numa punchline é técnica de stand-up e é bem-vindo: o que denuncia IA é a moral solene repetida.
- **Dois-pontos em todo título** ("Índices: o segredo da performance").
- **Excesso de negrito** no meio do texto. Negrito só para termos sendo definidos ou avisos importantes.
- **Emojis.** Nenhum.

### Vocabulário e expressões

- Palavras-tique: "mergulhar", "jornada", "robusto", "crucial", "fundamental", "essencial", "poderoso", "potencializar", "alavancar", "desvendar", "explorar" (no sentido de "vamos explorar"), "navegar", "ecossistema", "cenário", "panorama", "fascinante", "divisor de águas", "verdadeiro" (como em "um verdadeiro desafio").
- Expressões de transição e preenchimento: "vale ressaltar", "vale destacar", "é importante notar que", "em resumo", "em suma", "em última análise", "no fim das contas", "no final do dia", "dito isso", "nesse sentido", "de fato", "certamente", "sem dúvida".
- Aberturas e fechamentos de manual: "Neste capítulo, vamos explorar...", "Vamos mergulhar...", "Agora que você já sabe X, vamos ver Y", "E é exatamente aí que entra o X", "Spoiler:", "Parabéns!", "Pronto!".
- Abrir várias seções com "Imagine que...".
- Traduções literais do inglês: "endereçar um problema", "fazer sentido" em excesso, "no final do dia", "isso dito".

### Estrutura e conteúdo

- **Simetria artificial**: todas as seções do mesmo tamanho, todos os parágrafos com o mesmo número de frases, toda lista com o mesmo número de itens. Variar.
- **Listas onde caberia prosa.** Usar listas para passos, comparações e itens realmente enumeráveis. Raciocínio vai em parágrafo.
- **Listas no formato "**Termo:** explicação"** em sequência, repetidas ao longo do capítulo.
- **Resumir o que acabou de ser dito** no fim de cada seção. O resumo existe uma vez, no fim do capítulo.
- **Ressalvas e avisos genéricos repetidos** ("lembre-se de sempre seguir as boas práticas", "consulte a documentação"). Avisar uma vez, de forma específica, onde importa.
- **Entusiasmo artificial** e elogios ao leitor ou à tecnologia.
- **Metáforas grandiosas e personificação solene** ("o banco abraça seus dados", "o coração da sua arquitetura"). A personificação cômica da seção "Humor" é outra coisa e é bem-vinda.
- **Generalidades sem detalhe concreto.** Pessoas escrevem com números, nomes, mensagens de erro reais e situações específicas. Preferir sempre o detalhe concreto ("a requisição levou 4,2 segundos") ao genérico ("a performance ficou ruim").

### Checagem mecânica

Antes de dar o capítulo por pronto, rodar Grep no arquivo por: `—`, `não é`, `não apenas`, `mas também`, `não se trata`, e cada palavra e expressão listada acima. Corrigir cada ocorrência que caia num dos padrões proibidos.
