# Instalação

Instalar a orquestração numa máquina nova. Funciona offline — o `payload/` é
completo e não depende de rede nem de remoto git.

## 1. Pré-requisitos

Obrigatórios. O instalador aborta se faltar algum:

| Ferramenta | Para quê |
|---|---|
| `opencode` | O que consome a configuração |
| `node` | Runtime do plugin de quests e dos MCP em Node |
| `git` | O `Sync-Payload.ps1` lê a lista de arquivos com `git ls-files` |

Opcionais. Ausência não bloqueia a instalação, mas MCP específicos deixam de
subir:

| Ferramenta | O que perde |
|---|---|
| `npm` | Desenvolvimento do plugin de quests |
| `uvx` | MCP `code-review-graph` |
| `docker` | MCP `github` em modo container (usado no cip) |

## 2. Variáveis de ambiente

O instalador **não grava** variáveis de ambiente, de propósito: gravar por
script faria a chave passar por linha de comando e por histórico de shell. Ele
checa presença e reporta o que falta, sem nunca imprimir valor.

Obrigatórias — sem elas o provider carrega mas falha na primeira chamada:

| Variável | Provider |
|---|---|
| `MINIMAX_API_KEY` | `minimax-coding-plan` (MiniMax M3) |
| `DEEPSEEK_API_KEY` | `deepseek` (V4 Pro e V4 Flash) |

Opcionais, usadas pelos MCP dos projetos:

| Variável | MCP |
|---|---|
| `CONTEXT7_API_KEY` | context7 |
| `GITHUB_API_KEY` | github |
| `JIRA_API_TOKEN` | jira |

Persistir no escopo de usuário no Windows:

```powershell
[Environment]::SetEnvironmentVariable('MINIMAX_API_KEY',  '<valor>', 'User')
[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', '<valor>', 'User')
```

Abra um shell novo depois. Processos já rodando não veem variável definida
depois de terem iniciado.

## 3. Instalar

```powershell
cd D:\opencode-orchestration
.\scripts\Install-Orchestration.ps1
```

Isso **simula**. Leia o relatório: ele mostra quantos arquivos seriam copiados,
para onde, se o destino já existe e se faltam pré-requisitos ou variáveis.

Se o relatório estiver limpo:

```powershell
.\scripts\Install-Orchestration.ps1 -Force
```

O que acontece nessa ordem:

1. Se `~/.config/opencode` já existir, o conteúdo é copiado para
   `_backup-<timestamp>/` dentro deste repo, **antes** de qualquer escrita.
   `node_modules` fica de fora por volume.
2. Os arquivos do payload são copiados para `~/.config/opencode`.
3. Symlinks esperados são reportados, com indicação de se o alvo existe. Não
   são criados — ver seção 5.
4. Os `opencode.json` de projeto são restaurados nos projetos que existirem na
   máquina.
5. `Test-Orchestration.ps1` roda e reporta o resultado.

Instalar em outro destino, por exemplo para testar sem tocar na config em uso:

```powershell
.\scripts\Install-Orchestration.ps1 -Force -TargetRoot D:\tmp\oc-teste
```

Pular a restauração dos configs de projeto:

```powershell
.\scripts\Install-Orchestration.ps1 -Force -SkipProjectConfigs
```

## 4. Verificar

```powershell
.\scripts\Test-Orchestration.ps1
```

Sai com código 0 se tudo passar, 1 em qualquer falha obrigatória. O que ele
checa:

- `opencode.jsonc` existe e parseia.
- Plugin de quests e quests globais presentes.
- Variáveis de ambiente presentes (obrigatórias como falha, opcionais como
  aviso).
- `opencode models` **rodado de um diretório vazio** — isso é o ponto: prova
  que a resolução vem da config global e não de algum `opencode.json` de
  projeto que estivesse no diretório atual.
- O whitelist declarado na config corresponde exatamente aos modelos que o
  opencode resolve, em ambas as direções.
- Cada referência de modelo — `model`, `small_model`, `agent.*.model` e o
  `model:` de cada estágio de quest — aponta para um modelo que existe.
- Chamada real de API ao DeepSeek e ao MiniMax.

Sem rede:

```powershell
.\scripts\Test-Orchestration.ps1 -SkipNetwork
```

A checagem de referências de modelo merece uma nota. Ela existe porque o
`small_model` global apontou para `deepseek-v4-flash-free`, um modelo que nunca
existiu na API do DeepSeek. Referência inválida **não** falha ao carregar a
config: falha na primeira chamada, em silêncio, e o slot afetado era o de maior
frequência — título de sessão, sumarização, compaction.

## 5. Dependências que a instalação não resolve

**Symlinks.** `payload-symlinks.json` lista os links que a configuração espera.
Recriá-los no Windows exige Developer Mode ou shell elevado, o que não se pode
assumir numa máquina nova, então o instalador reporta em vez de tentar. Hoje há
um: `skills/archify` → `~/.agents/skills/archify`. Se o alvo não existir, a
skill não carrega. Para criar:

```powershell
New-Item -ItemType SymbolicLink -Path "$env:USERPROFILE\.config\opencode\skills\archify" `
         -Target "$env:USERPROFILE\.agents\skills\archify"
```

**Plugin de quests como fonte.** O payload traz `plugins/opencode-quests.ts`, o
arquivo achatado que o opencode carrega — autocontido, suficiente para a
orquestração funcionar. O diretório de fonte `plugins/opencode-quests/` **não**
vem: é clone de um upstream de terceiro
([lirrensi/opencode-quests](https://github.com/lirrensi/opencode-quests)) com
patches locais na branch `fork/stage-routing`. Só é necessário para desenvolver
o plugin, não para usá-lo.

**Binários de MCP.** Os `opencode.json` de projeto referenciam caminhos
absolutos de máquina, tipo `C:/nvm4w/nodejs/node_modules/...`. Numa máquina com
layout diferente, esses caminhos precisam ser ajustados à mão depois do
restore.

## 6. Depois de instalar

Confirme que o roteamento por estágio chega ao modelo certo, em vez de
confiar na configuração:

```powershell
opencode
# no TUI:
quest(file: "routing-probe")
```

O probe roda dois estágios em modelos diferentes e o segundo repete um token
que o primeiro inventou. Como conferir o modelo real por metadado de API, e não
pelo que o modelo diz de si: [`MEASUREMENTS.md`](MEASUREMENTS.md).

Rode uma quest por vez. O estado da quest é global ao processo, não por sessão
— duas concorrentes se dividem entre sessões. Detalhe em
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
