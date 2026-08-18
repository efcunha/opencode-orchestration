# opencode-orchestration

Instalador e documentação da orquestração multi-LLM do opencode: **MiniMax M3**
para implementação, **DeepSeek V4 Pro** para planejamento e diagnóstico,
**DeepSeek V4 Flash** para volume barato — com roteamento por estágio de quest,
medido e verificável.

## O problema que isto resolve

Cada projeto declarava seus próprios providers e agentes. `agent: plan`
resolvia para `deepseek-v4-pro` no cloudpilot, `9router/smart` no ameg e
`nvidia-nim/nemotron` no cip. O mesmo arquivo de quest pedia o mesmo agente e
recebia modelos diferentes conforme o diretório de onde rodava, o que torna
roteamento por estágio impossível de raciocinar sobre.

A configuração foi consolidada num único lugar global. Este repo é o que torna
essa configuração instalável e verificável em outra máquina.

## Quickstart

```powershell
git clone <este-repo> D:\opencode-orchestration
cd D:\opencode-orchestration

.\scripts\Install-Orchestration.ps1           # simula, não escreve nada
.\scripts\Install-Orchestration.ps1 -Force    # efetiva, com backup antes
.\scripts\Test-Orchestration.ps1              # verifica ponta a ponta
```

O instalador simula por default. Ele nunca escreve sem `-Force`, e quando
escreve faz backup do destino primeiro.

Passo a passo completo, incluindo variáveis de ambiente e dependências
externas: [`docs/INSTALL.md`](docs/INSTALL.md).

## O que está aqui

| Caminho | O que é |
|---|---|
| `payload/` | Cópia offline da configuração. É o que permite instalar sem rede e sem remoto. **Derivado** — não edite à mão |
| `payload-symlinks.json` | Symlinks que a config espera. Não são copiados; são reportados como dependência |
| `scripts/Install-Orchestration.ps1` | Instala o payload, restaura configs de projeto, verifica |
| `scripts/Test-Orchestration.ps1` | Verificação independente, sai 1 em falha. Serve de gate em CI |
| `scripts/Sync-Payload.ps1` | Regenera o payload a partir da config viva |
| `docs/` | Instalação, arquitetura, medições e troubleshooting |

## Onde mora a verdade

A configuração **viva** fica em `~/.config/opencode`, que é onde o opencode lê
e que já é um repositório git próprio. É a fonte de verdade.

O `payload/` deste repo é **derivado** dela por `Sync-Payload.ps1`, sempre na
direção viva → payload. Editar o payload à mão é erro: o próximo sync
sobrescreve. Para mudar a orquestração, edite a config viva, valide com
`Test-Orchestration.ps1`, e só então sincronize.

```powershell
.\scripts\Sync-Payload.ps1 -Check   # há divergência? sai 1 se sim
.\scripts\Sync-Payload.ps1          # sincroniza
```

O `-Check` existe para ser usado antes de commitar. Sem ele, o payload
silenciosamente envelhece e a instalação numa máquina nova entrega uma
configuração que não é a que você está usando.

A lista de arquivos do payload vem de `git ls-files` na config viva, não de uma
lista mantida aqui. Assim as regras de ignore de lá — `node_modules`, manifests
npm, estado de UI por máquina — valem automaticamente, sem serem
reimplementadas e sem chance de divergirem.

## Estado medido

Verificado em 2026-08-18 por metadado de API (`providerID`/`modelID` por
mensagem), não por autorrelato do modelo:

- Roteamento por estágio acertou o modelo alvo em **5 de 5** rodadas.
- Contexto sobreviveu ao salto entre modelos em **5 de 5**.
- O `model` do estágio sobrepõe o modelo declarado no agente.

Método, sessões e os falsos negativos que o instrumento produzia antes de ser
corrigido: [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md).

Dois defeitos conhecidos e não corrigidos do plugin de quests — estado global
ao processo e perda de estágio em headless — estão em
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Leitura

| Documento | Quando |
|---|---|
| [`docs/INSTALL.md`](docs/INSTALL.md) | Instalar numa máquina nova |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Entender como o roteamento funciona antes de mexer |
| [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md) | Conferir a evidência em vez de acreditar |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Algo não roteou, ou um estágio não rodou |
