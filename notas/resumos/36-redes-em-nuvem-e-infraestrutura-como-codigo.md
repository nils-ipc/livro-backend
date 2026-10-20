# Resumo 36 — Redes em nuvem e infraestrutura como código

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- rede virtual (VPC/VNet) = bloco CIDR isolado, SDN no hipervisor (Andromeda NSDI 2018); sobreposição impede peering/VPN
- região vs zona de disponibilidade (1–2 ms, AWS <100 km); sub-rede zonal AWS, regional GCP/Azure; reservados 5 AWS/Azure, 4 GCP; AZ ID estável (`sae1-az1`)
- tabela de rotas: longest prefix match, rota `local` irremovível
- pública = `0.0.0.0/0` → internet gateway (NAT 1:1); privada → NAT gateway por zona, 55.000 conexões/destino, ocioso 350 s; endpoints privados evitam NAT
- com estado (security group, GCP firewall, NSG) vs sem estado (NACL, portas efêmeras 1024–65535); SG origem = outro SG; conexão rastreada sobrevive à remoção da regra
- Terraform/OpenTofu (BSL 1.6, 2023): grafo, parallelism 10; estado = endereço → ID, segredos em claro, backend remoto, `use_lockfile` 1.10, serial/lineage
- plan `+ - ~ -/+`, forces replacement, plano salvo + `Saved plan is stale`, `show -json` actions, prevent_destroy, create_before_destroy
- drift: refresh-only, `-detailed-exitcode` 2; só visível no estado (ingress inline vs recurso separado); `import` 1.5, ignore_changes
- módulo = função, `?ref=`; `moved` 1.1; count vs for_each

## Termos e traduções adotados
- stateful/stateless → com estado/sem estado; longest prefix match, drift, backend, lock, peering, endpoint em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: Roque Rápido (xadrez), `prod-nova-2-usar-essa`, `libera-geral-so-hoje` 5432 14/03/2021, backup 900 GB pelo NAT
- cidrsubnet 4→3 recria 6 sub-redes; guarda Python plano JSON; diálogo NACL SYN-ACK porta 41873
- AWS S3 us-east-1 28/02/2017 comando digitado; AWS us-east-1 07/12/2021 rede interna
