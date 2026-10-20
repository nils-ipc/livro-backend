# Resumo 17 — Modelos de consistência

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- modelo de consistência = histórias permitidas; invocação/resposta, concorrentes, tempo real, registrador
- linearizabilidade Herlihy/Wing 1990: ponto atômico entre invocação e resposta, tempo real; local/composicional; ReadIndex ou lease
- W+R>N sem linearizabilidade (escrita em andamento)
- sequencial Lamport 1979: ordem total + ordem do programa, sem tempo real, não composicional; ZooKeeper leituras + sync()
- serializabilidade estrita; Spanner external consistency → cap. 18
- causal: aconteceu antes, concorrentes em qualquer ordem; dependências + espera; COPS 2011; Mahajan/Alvisi/Dahlin 2011 teto disponível; sticky
- eventual Vogels 2009; LWW perde escrita; eventual forte Shapiro 2011, CRDT
- garantias de sessão Terry 1994: RYW, leituras/escritas monotônicas, writes follow reads; causal implica as 4; token de sessão; MongoDB 3.6 clusterTime
- CAP Gilbert/Lynch 2002: C=linearizável, A=todo nó vivo responde sem prazo, P inevitável; Kleppmann 2015
- PACELC Abadi 2012; Dynamo/Cassandra/Riak PA/EL
- tabela Bailis HAT 2014: total/sticky/indisponível
- DynamoDB leitura forte = 2× eventual
- verificação NP-completa (Gibbons/Korach 1997), Knossos, Porcupine

## Termos e traduções adotados
- linearizability → linearizabilidade; strict serializability → serializabilidade estrita
- read your writes → ler as próprias escritas; monotonic reads/writes → leituras/escritas monotônicas; writes follow reads → escritas seguem leituras
- sticky, lease, last write wins, CRDT em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: app condomínio, cachorro Paçoca, resposta do 1204 antes da pergunta do 302, reações 14→9→14, síndico removido lê reclamação do 507
- verificador Python H1/H2 (força bruta permutations)
- token de sessão sp-1 v42 / sp-2 v37
- Jepsen etcd/Consul jun/2014 leituras velhas
- S3 consistência forte 01/12/2020, S3Guard, EMRFS Consistent View
