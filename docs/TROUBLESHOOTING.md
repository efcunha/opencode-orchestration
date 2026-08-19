# Troubleshooting

Modos de falha observados, com o sintoma primeiro. Comece rodando
`.\scripts\Test-Orchestration.ps1` — ele cobre a maioria dos casos abaixo e
aponta o item exato.

## O estágio rodou no modelo errado

**Confirme antes de investigar.** O autorrelato do modelo não é evidência
suficiente; ele pode se identificar errado. Só o metadado de API decide:

```powershell
opencode serve --port 4599 --hostname 127.0.0.1
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
    ForEach-Object { "$($_.info.role) $($_.info.providerID)/$($_.info.modelID)" }
```

Se o metadado confirma o modelo errado, verifique nesta ordem:

1. **O estágio declara `model`?** Sem o campo, ele herda o modelo do agente.
2. **A referência existe?** `Test-Orchestration.ps1` confere cada referência
   contra a lista que o opencode resolve.
3. **Algum `opencode.json` de projeto está sobrepondo?** A config do projeto
   vence a global. Rode `opencode models` **de dentro do projeto** e compare com
   o resultado de um diretório vazio. Diferença aponta sobreposição local.
4. **`enabled_providers` no projeto filtra o provider?** É allowlist, e o
   projeto sobrepõe a global. Provider fora da lista fica definido e invisível,
   sem erro.

## O segundo estágio nunca rodou

Sintoma: a sessão para depois do primeiro estágio, geralmente com uma última
mensagem tipo "Stage `x` queued. Ending turn."

**Em headless é esperado**, cerca de 1 em 3. O despacho é diferido para o evento
`session.idle` e o cliente `opencode run` pode sair antes de ele disparar.
Contornos, em ordem de preferência:

- Rode a quest no **TUI persistente**, onde não acontece.
- Se precisar de headless, use `--attach` contra um `opencode serve` já rodando,
  para que o servidor sobreviva à saída do cliente.

Se acontecer no TUI, aí é outra coisa: verifique se o estágio anterior chamou
`quest_advance` e se o `next` do YAML aponta para um `id` que existe.

## Uma quest se dividiu em duas sessões

Sintoma: uma sessão tem só o primeiro estágio, outra só o segundo. A segunda
tipicamente reporta não ver nada do estágio anterior — e está **correta**, ela
nunca teve.

Causa: o estado da quest é global ao processo, não por sessão. Duas quests
concorrentes se atropelam.

Solução: uma quest por vez. Não há contorno melhor sem mudar o plugin.

## Um estágio relata não ver o estágio anterior

Contexto **sobrevive** ao salto de modelo, medido em 5 de 5. Então esse relato
costuma ser uma de três coisas, nesta ordem de probabilidade:

1. **Quest partida entre sessões** — ver acima. O relato está correto.
2. **Estágio perdido** — o anterior nunca rodou nesta sessão.
3. **Falso negativo do instrumento** — se você escreveu a instrução do estágio,
   verifique se ela não sugere a conclusão. Instrução dizendo que "só o texto
   entregue pelo motor vale como fonte" faz o modelo declarar ausência mesmo com
   o valor à vista. Pergunte o que ele **vê**, não o que ele **deveria** ver.

Para distinguir 1 de 2, liste quais estágios cada sessão recebeu:

```powershell
Invoke-RestMethod "http://127.0.0.1:4599/session/<id>/message" |
  Where-Object { $_.info.role -eq 'user' } |
  ForEach-Object {
      (($_.parts | Where-Object { $_.type -eq 'text' }).text -split "`n" |
       Select-String 'Stage:') -join ' '
  }
```

## Provider carrega mas a chamada falha

Sintoma: `opencode models` lista o modelo, mas usá-lo dá erro de autenticação.

A variável de ambiente referenciada por `{env:...}` não está definida **no
processo que está rodando**. Variável definida depois de o processo iniciar não
é vista por ele. Abra um shell novo.

```powershell
.\scripts\Test-Orchestration.ps1   # checa presença sem imprimir valor
```

## Um modelo "existe" na config mas a API o rejeita

Sintoma: erro tipo `The supported API model names are X or Y, but you passed Z`.

Foi exatamente o caso do `deepseek-v4-flash-free`, que ficou no `small_model`
global apontando para um modelo inexistente. Referência inválida **não** falha
ao carregar a config — falha na primeira chamada, em silêncio.

`Test-Orchestration.ps1` pega isso comparando o whitelist declarado com os
modelos resolvidos, nas duas direções, e validando cada referência individual.
Se ele passa e a API ainda rejeita, o whitelist está declarando um modelo que o
provider não serve mais: confirme direto contra a API.

## `opencode models` não lista nada, ou lista o conjunto errado

Rode de um **diretório vazio**. É o único jeito de saber se a resolução vem da
config global:

```powershell
$d = Join-Path $env:TEMP "oc-check"; New-Item -ItemType Directory $d -Force | Out-Null
Push-Location $d; opencode models; Pop-Location
Remove-Item $d -Recurse -Force
```

Vazio ou incompleto aponta para `opencode.jsonc` que não parseia, ou
`enabled_providers` filtrando. O verificador cobre os dois.

## Mudei a config e a instalação numa outra máquina veio velha

O `payload/` é derivado da config viva e não se atualiza sozinho:

```powershell
.\scripts\Sync-Payload.ps1 -Check   # sai 1 se divergente
.\scripts\Sync-Payload.ps1          # sincroniza
```

Use o `-Check` antes de commitar. Sem ele o payload envelhece em silêncio.

Se você editou o `payload/` à mão, perdeu: o sync sobrescreve na direção viva →
payload. Edite a config viva.

## Mudei o plugin e nada aconteceu

Três coisas, todas necessárias:

1. `npm run deploy` no diretório do plugin — gera o `.ts` achatado que o
   opencode carrega. Editar só a fonte não muda nada.
2. **Reinicie o opencode.** Sessões de TUI já abertas seguem com o plugin
   antigo.
3. `Sync-Payload.ps1` para o achatado novo chegar ao payload.

Vale lembrar que o plugin tem dois repositórios, e o `src/` pode estar com
alteração não commitada mesmo com o achatado atualizado — ou o contrário.

## Uma skill não carrega

Provavelmente é o symlink. `payload-symlinks.json` lista os que a config espera,
e o instalador reporta se o alvo existe. Git guarda o link, não o conteúdo.

```powershell
Get-Item "$env:USERPROFILE\.config\opencode\skills\archify" -Force |
    Select-Object LinkType, Target
```

Se o alvo não existir, crie o link — exige Developer Mode ou shell elevado:

```powershell
New-Item -ItemType SymbolicLink `
         -Path "$env:USERPROFILE\.config\opencode\skills\archify" `
         -Target "$env:USERPROFILE\.agents\skills\archify"
```

## Um MCP nao sobe

Quatro motivos, em ordem de probabilidade.

**1. Binario npm nao instalado.** O config global aponta `{{nodeModules}}/<pkg>`,
que o instalador resolve para o `npm root -g` local. Se voce sobrescreveu o
caminho com `ORCH_NPM_GLOBAL_NODE_MODULES` e ele nao bate onde o npm realmente
instalou as deps, o comando `node <path>` do MCP falha com ENOENT. Use
`npm root -g` no mesmo shell onde o opencode vai rodar para confirmar.

**2. Binario externo nao esta no PATH.** Quando um MCP usar `npx`, `uvx` ou
binarios CLI proprios, eles precisam estar no PATH. `uvx` em particular e o
que habilita o LSP Python via `pyright-langserver`.

**3. Versao de pacote mudou.** O `opencode`/`mcp` que estamos roteando para
um `node <path>/dist/index.js` assume uma estrutura de pasta que o pacote npm
original entrega. Se um upgrade quebrar isso, o instalador vai conseguir
passar o template mas o binario nao vai estar onde esperamos — compare
`npm ls -g <pkg> <pkg>@<version>` com o que o `command` da config aponta.

Para gerar um MCP novo ou atualizar um existente, veja a secao
"Adicionar um novo MCP" em [`INSTALL.md`](INSTALL.md).

## "Placeholder {{...}} nao foi resolvido"

Sintoma: a config instalada em `~/.config/opencode/opencode.jsonc` ainda
contem a string literal `{{nodeModules}}` ou similar.

Causa: a deteccao local (em `Install-Orchestration.ps1:Resolve-Paths`) nao
conseguiu `npm root -g` e nao havia `ORCH_NPM_GLOBAL_NODE_MODULES` definido.
Sem caminho, nada substitui.

Conferir:

```powershell
$env:ORCH_NPM_GLOBAL_NODE_MODULES = (npm root -g)
.\scripts\Install-Orchestration.ps1 -Force
```

## O que o verificador não cobre

- **Quests de projeto.** Ele só valida as globais em
  `~/.config/opencode/agents`. Quaisquer quests em `.agents/` de projeto
  (locais ou externos) nao sao verificadas — o verificador so ve as globais.
- **Alcançabilidade de MCP.** Presença de binário é checada; se o servidor sobe
  e responde, não.
- **Roteamento de ponta a ponta.** Ele confere que as referências resolvem, não
  que um estágio realmente foi atendido pelo modelo alvo. Para isso, rode o
  `routing-probe` e leia o metadado — ver [`MEASUREMENTS.md`](MEASUREMENTS.md).
