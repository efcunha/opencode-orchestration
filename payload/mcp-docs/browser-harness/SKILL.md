---
name: browser-harness
description: "browser-harness — controle direto do browser via CDP. Self-healing harness que permite LLMs completarem qualquer task no browser real do usuario."
---

# browser-harness

CLI que conecta um LLM diretamente ao browser real do usuario via CDP (Chrome DevTools Protocol). O agente escreve helpers conforme trabalha, entao o harness melhora a cada task.

## Instalacao

```bash
uv tool install --python 3.12 --upgrade --force browser-harness
```

Requer `uv` (Python package manager). Instale uv com:
```bash
# Windows
irm https://astral.sh/uv/install.ps1 | iex

# macOS/Linux
curl -LsSf https://astral.sh/uv/install.sh | sh
```

## Setup Inicial

```bash
# Registrar skill no opencode
mkdir -p ~/.config/opencode/skills/browser-harness
browser-harness skill > ~/.config/opencode/skills/browser-harness/SKILL.md

# Testar conexao
browser-harness <<'PY'
print(page_info())
PY
```

Se `page_info()` retornar dados, a conexao esta OK.

## Comandos Essenciais

| Comando | Descricao |
|---------|-----------|
| `browser-harness <<'PY' ... PY` | Executar codigo Python com helpers pre-importados |
| `browser-harness --doctor` | Diagnostico de conexao |
| `browser-harness skill` | Emitir SKILL.md atualizado |
| `browser-harness --update -y` | Atualizar para ultima versao |
| `browser-harness recordings enable` | Habilitar gravacao local |
| `browser-harness recordings disable` | Desabilitar gravacao |
| `browser-harness telemetry disable` | Desabilitar telemetria |
| `browser-harness auth login` | Autenticar para browsers cloud |
| `browser-harness mac-approve` | Aprovar remote debugging no macOS |

## Helpers Pre-Importados

Os helpers estao disponiveis automaticamente dentro do heredoc Python:

- `page_info()` — info da pagina atual
- `new_tab(url)` — abrir nova aba (primeira navegacao)
- `switch_tab(target)` — trocar aba ativa (background)
- `activate_tab(target)` — trazer aba para frente
- `click_at_xy(x, y)` — click por coordenadas
- `js(code)` — executar JavaScript na pagina
- `cdp(method, **kwargs)` — chamada CDP raw
- `wait_for_load()` — esperar pagina carregar
- `ensure_real_tab()` — garantir tab valida
- `start_recording(name, title=...)` — iniciar gravacao
- `stop_recording()` — parar gravacao
- `start_remote_daemon(name)` — iniciar browser cloud
- `stop_remote_daemon(name)` — parar browser cloud

## Workflow de Pagina

1. Usar accessibility tree para encontrar elementos: `cdp("Accessibility.getFullAXTree")["nodes"]`
2. Obter coordenadas: `cdp("DOM.getBoxModel", backendNodeId=n)["model"]["content"]`
3. Clicar: `click_at_xy(x, y)`
4. Verificar: `js(...)` ou `page_info()`
5. Apos navegacao: `wait_for_load()`

## Conexao Local (Chrome)

1. Abrir `chrome://inspect/#remote-debugging`
2. Marcar checkbox "Allow remote debugging for this browser instance"
3. Testar: `browser-harness <<'PY'\nprint(page_info())\nPY`

Se falhar:
```bash
browser-harness --doctor
```

## Browsers Cloud (Browser Use)

Opcional. Para tasks paralelas ou sites com CAPTCHA/bloqueio:

```bash
browser-harness auth login
browser-harness <<'PY'
start_remote_daemon("meu-browser")
PY

BU_NAME=meu-browser browser-harness <<'PY'
new_tab("https://example.com")
print(page_info())
PY
```

## Troubleshooting

| Problema | Solucao |
|----------|---------|
| chrome running FAIL | Abrir Chrome ou usar browser cloud |
| daemon alive FAIL | Habilitar remote debugging em chrome://inspect |
| Permission macOS | `browser-harness mac-approve` |
| Versao antiga | `browser-harness --update -y` |

## Referencia

- Repo: https://github.com/browser-use/browser-harness
- Install guide: https://github.com/browser-use/browser-harness/blob/main/install.md
- Interaction skills: https://github.com/browser-use/browser-harness/tree/main/interaction-skills
- Browser Use Cloud: https://cloud.browser-use.com

## Notas de Integracao com opencode-orchestration

- Instalado automaticamente pelo `Install-Orchestration.ps1` (secao 0.4)
- Verificado pelo `Test-Orchestration.ps1` (secao 8)
- Skill clonada em `~/.agents/skills/browser-harness/` via git
- Symlink criado em `~/.config/opencode/skills/browser-harness/`
- Requer `uv` no PATH (nao-bloqueante se ausente)
- Recordings e telemetria desabilitados por default na instalacao
