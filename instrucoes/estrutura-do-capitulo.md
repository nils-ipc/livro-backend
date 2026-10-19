# Estrutura obrigatória de cada capítulo

Todo capítulo é independente e segue este esqueleto, nesta ordem:

1. **`# Título`**: título do capítulo (único `#` do arquivo).
2. **O problema**: abrir com uma situação concreta em que o assunto do capítulo decide o resultado, **antes** de qualquer explicação. Um sintoma real (uma consulta que passou de 40 ms para 9 segundos, um pagamento cobrado duas vezes, um certificado que expirou às 3h da manhã) ou um caso real conhecido. A primeira frase põe o leitor dentro de uma cena engraçada, e a seção termina com uma pergunta que o resto do capítulo responde. O humor continua em todas as seções seguintes, inclusive no mecanismo (ver "Humor" em `instrucoes/estilo.md`). Sem recapitular outro capítulo e sem apresentar o livro.
3. **O mecanismo**: como a coisa funciona por dentro. Definições precisas, o algoritmo, o protocolo, a fórmula, a especificação. Esta é a parte mais longa do capítulo.
4. **Na prática**: exemplos concretos para ler, em Python 3.12+ ou em comandos de terminal (`curl`, `dig`, `openssl`, `psql`, `kubectl` etc.), com a saída que eles produzem. O leitor não vai rodar nada: o texto mostra o código e a saída e comenta o que eles revelam. Nada de "rode", "instale", "experimente", "abra um terminal", pré-requisitos ou instruções de instalação. Exemplos pequenos, criados só para este capítulo.
5. **Propriedades e custos**: quando o capítulo apresenta mais de uma opção, comparar o que cada uma garante e o que custa (latência, consistência, operação, complexidade, dinheiro), de preferência com números ou uma tabela. Dizer em que condições cada propriedade importa, sem declarar vencedor.
6. **Armadilhas e casos reais**: erros comuns, limites que surpreendem, incidentes públicos conhecidos.
7. **Resumo**: lista curta do que ficou.
8. **Referências**: especificações (RFCs, padrões), documentação oficial, artigos técnicos de referência e fontes dos casos reais citados, com links. Só links de que você tenha certeza.

Não há recapitulação do capítulo anterior nem ponte para o próximo. Remissões a outros capítulos são permitidas, mas o texto precisa fazer sentido sem eles.

Seções intermediárias (`##`, `###`) podem ter títulos próprios; não precisam se chamar literalmente "O problema" ou "Na prática". As seções 4 e 5 podem se misturar com a 3 quando isso deixar a explicação mais clara.
