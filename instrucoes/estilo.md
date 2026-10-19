# Tom e estilo

## A voz

- **Um livro técnico que faz rir.** Este é o traço mais marcante do livro. O leitor precisa se divertir de verdade, rir sozinho no ônibus e mandar trechos para os colegas. O texto deve soar como o colega mais engraçado da empresa explicando, com toda a precisão do mundo, por que o sistema caiu de novo. A seção "Humor" abaixo tem o mesmo peso das regras de rigor técnico.
- **Linguagem natural, como se fosse falada.** Clara, fluida, próxima e descontraída. Nada formal, acadêmico ou engessado.
- **Sem gírias**, sem expressões de internet, sem palavrões, sem abreviações de conversa ("pra", "tá", "vc"). Português correto, com a naturalidade da fala. A graça vem das ideias e das situações, nunca do vocabulário.
- **Frases curtas na maior parte do tempo**, com ritmo variado, como numa conversa real. Parágrafos curtos.
- **Direto ao ponto.** Nada de introdução genérica do tipo "No mundo atual da tecnologia...". Cada parágrafo entrega uma informação, uma risada ou, de preferência, as duas.
- **Preciso e rigoroso.** A piada nunca sacrifica a exatidão técnica.
- **O leitor é inteligente e entende de tecnologia.** Escrever para um colega sênior, nunca para uma criança ou um leigo. Explicar o mecanismo diretamente, no nível técnico, sem simplificar com historinhas e sem repetir a mesma ideia de três jeitos. Se um conceito é novo para ele, defini-lo com precisão uma vez e seguir em frente.
- **O leitor lê, não executa.** O livro é para ser lido do começo ao fim, sem computador por perto. Código, comandos e saídas aparecem como exemplos para ler. O texto nunca pede ao leitor que rode, instale, teste, abra um terminal ou "experimente na sua máquina" (ver `instrucoes/estrutura-do-capitulo.md`).

## Humor

### Quanto humor

Muito, e mais do que parece razoável para um livro técnico. O humor é contínuo, do título da primeira seção ao resumo (as referências ficam sem piada). Como régua:

- Pelo menos um momento engraçado a cada dois ou três parágrafos, em **todas** as seções, inclusive as mais densas do mecanismo, as tabelas de custos e os exemplos de código. Uma seção `##` sem várias risadas está incompleta.
- Algo entre 25 e 40 momentos de humor por capítulo, de tamanhos variados: uma palavra bem escolhida, uma frase, um parêntese, um comentário de código, um diálogo de quatro linhas, uma cena inteira.
- O mecanismo é exatamente onde o humor mais ajuda. Explicar o handshake do TCP, o MVCC ou o Raft com graça é o que diferencia este livro de uma RFC.
- Se uma releitura do capítulo não arranca nenhum sorriso numa seção, reescrever essa seção.

### De onde vem a graça

As melhores piadas de um livro de backend vêm da vida real de quem constrói e opera sistemas. Exemplos do tipo de material:

- O deploy de sexta-feira às 17h50, que "é só uma linha".
- O índice criado em produção no horário de pico.
- O cache que "resolveu" o problema escondendo o bug por seis meses.
- O `TODO: remover antes de subir` que completou cinco anos em produção.
- O log que diz `Erro: sucesso`.
- O servidor chamado `temp-01`, o mais antigo e o mais crítico da empresa.
- O timeout de 30 segundos que ninguém sabe quem configurou, e que ninguém tem coragem de mudar.
- A planilha que, no fundo, é o banco de dados oficial da empresa.
- A reunião de postmortem em que todo mundo descobre que o alerta disparou, sim, e foi silenciado em 2019.

### Técnicas

Usar todas, variando ao longo do capítulo:

- **Ironia e understatement**: descrever um desastre em tom calmo ("o banco continuou funcionando perfeitamente; só não aceitava mais escritas").
- **Exagero com lógica**: levar uma má decisão até a consequência absurda, mas matematicamente correta ("nesse ritmo, em 2031 o backup vai levar mais tempo do que o intervalo entre backups").
- **Personificação cômica dos componentes**: o kernel que segue o regulamento à risca, o garbage collector que escolhe o pior momento possível para trabalhar, o TCP que retransmite um SYN para uma máquina desligada com uma paciência de dois minutos, o pacote perdido que ninguém procura. A personalidade é uma camada de graça sobre o comportamento real, descrito com exatidão; ela não substitui a explicação nem serve de analogia.
- **Diálogos curtos** entre componentes ou pessoas, quando explicarem o protocolo melhor que um parágrafo:

  ```text
  Cliente:  Recebeu meu pagamento?
  Servidor: Talvez.
  Cliente:  Vou mandar de novo, por garantia.
  Servidor: (cobra duas vezes)
  ```

- **Autoironia da profissão**: o que todo dev já fez e não conta em entrevista (o `UPDATE` sem `WHERE`, o `git push --force` na branch errada, o "funciona na minha máquina").
- **Piadas recorrentes dentro do capítulo** (*running gags*): um personagem, um servidor ou um número que volta em seções diferentes, cada vez numa situação pior. Fica dentro do capítulo, que precisa continuar independente.
- **Títulos de seção engraçados**, desde que digam do que a seção trata ("O handshake, ou como dois computadores dizem oi três vezes").
- **Código com graça**: nomes de variáveis, comentários e mensagens de log divertidos, com o código tecnicamente correto. Como o leitor só lê o código, o exemplo é um ótimo lugar para piada.
- **Parênteses e apartes** como comentário do narrador ("o que, como você vai ver, não é verdade").
- **Destaques com humor**: os blocos `> **Armadilha:**` e `> **Na vida real:**` também podem (e devem) ter graça.

### Limites

O humor tem só estes limites, e eles valem sempre:

- **Exatidão primeiro.** A piada nunca altera o fato. Se um exagero puder ser lido como dado real, deixar claro que é exagero. Números apresentados como reais continuam reais e verificáveis.
- **Sem gírias, palavrões, memes ou referências de época** que envelhecem em seis meses.
- **Rir de situações, de máquinas e da profissão**, nunca de pessoas, grupos, empresas ou tecnologias específicas. Nos incidentes reais, o humor vai para o mecanismo da falha e para a ironia da situação, nunca para quem foi afetado nem para a equipe que errou.
- **A piada não pode atrapalhar a explicação.** Se o leitor precisar reler a frase para entender o conceito, a piada foi para o lugar errado.
- **Variar.** A mesma estrutura de piada repetida vira tique e denuncia texto de IA. Alternar técnicas, tamanhos e posições no parágrafo.

### Atenção do leitor

O humor já faz boa parte desse trabalho. Além dele:

- A primeira frase do capítulo coloca o leitor dentro de uma cena concreta, de preferência engraçada.
- Uma pergunta deixada no ar no começo e respondida mais adiante dá motivo para continuar lendo. Toda pergunta aberta é respondida no capítulo.
- Depois de três ou quatro parágrafos de mecanismo, entra um exemplo, uma cena ou uma piada.

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
- Mostrar o erro antes do acerto quando isso ensinar algo ("veja o que acontece se...").
- Usar destaques curtos:
  - `> **Armadilha:** ...` para erros comuns e custos escondidos.
  - `> **Na vida real:** ...` para casos reais e práticas de mercado.
  - `> **Dica:** ...` para atalhos e boas práticas.

## Não faça

- Gírias, linguagem coloquial demais ou tom de rede social.
- Parágrafos longos ou blocos de teoria sem exemplo.
- Jargão sem explicação na primeira aparição.
- Linguagem de marketing ("serviço altamente escalável e resiliente que..."). Explicar o que faz, sem vender.
- Listas enormes de recursos. Escolher o que importa para quem precisa decidir e operar.
- Apresentar uma tecnologia sem os custos e limites dela.

## Evitar marcas de texto escrito por IA

O texto precisa parecer escrito por uma pessoa. Os padrões abaixo denunciam texto gerado por IA e **não devem aparecer** no livro. Escrever já evitando esses padrões; a checagem mecânica abaixo pega o que escapar.

### Pontuação e construções

- **Travessão (—) para intercalar explicação no meio da frase.** Usar vírgula, parênteses ou dois-pontos. Travessão só em diálogo, se houver.
- **"Não é X, é Y"** e variações: "isso não é um bug, é uma feature", "não se trata de X, mas de Y", "X não é apenas Y". Afirmar diretamente o que a coisa é.
- **"Não apenas X, mas também Y."**
- **Pergunta seguida de resposta de efeito**: "O resultado? Caos.", "A solução? Simples.", "O motivo? ...". No máximo uma ocorrência rara por capítulo.
- **Sequências de frases-fragmento para dar drama**: "Rápido. Barato. Seguro.", "Sem servidor. Sem dor de cabeça."
- **Grupos de três** recorrentes (três adjetivos, três exemplos, três itens em toda lista). Usar a quantidade que o conteúdo pedir: dois, quatro, um.
- **Fechar todo parágrafo ou seção com uma frase de efeito** ou moral da história. Uma piada no fim de um parágrafo, de vez em quando, é diferente: o que denuncia IA é a moral solene repetida.
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
