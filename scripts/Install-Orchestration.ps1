<#
.SYNOPSIS
    Instala a orquestracao multi-LLM do opencode nesta maquina.

.DESCRIPTION
    Pipeline:
      1. Detecta caminhos locais (npm global node_modules, $env:USERPROFILE,
         ~/.agents) - passa pelo env ORCH_* quando vem do npm install.js,
         senao autodetecta em runtime.
      2. Instala pacotes npm faltantes (declarados em mcp-packages.json,
         espelho do package.json raiz) usando npm install -g.
      3. Renderiza templates: payload/opencode.jsonc e
         payload-symlinks.template.json - substituindo {{nodeModules}},
         {{userAgents}}, {{userHome}}.
      4. Copia payload/ para TargetRoot (default: ~/.config/opencode).
      5. Cria symlinks esperados (best-effort: exige Developer Mode no Windows).
      6. Roda Test-Orchestration.ps1.

    SIMULA POR DEFAULT. Sem -Force nada e escrito - o script relata o que faria
    e sai. Isso e deliberado: o destino pode ja conter uma configuracao em uso,
    e sobrescrever config de ferramenta sem aviso e como perder trabalho.

    Com -Force, a configuracao existente e copiada para _backup-<timestamp>/
    dentro deste repo ANTES de qualquer escrita.

    O instalador NAO faz, de proposito:
      - Nao define variaveis de ambiente. Ele checa e reporta as que faltam.
        Gravar chave de API por script significa a chave passar por linha de
        comando e historico de shell.
      - Nao cria symlinks que exijam Developer Mode/elevacao. Os links
        esperados sao reportados como dependencia externa.
      - Nao instala opencode, node, git. Checa e falha cedo se faltarem.

.PARAMETER TargetRoot
    Destino da configuracao. Default: ~/.config/opencode.

.PARAMETER Force
    Efetiva a instalacao. Sem isto, apenas simula.

.EXAMPLE
    .\Install-Orchestration.ps1
    .\Install-Orchestration.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE '.config\opencode'),
    [switch]$Force,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot       = Split-Path -Parent $PSScriptRoot
$payloadRoot    = Join-Path $repoRoot 'payload'
$symlinkTmpl    = Join-Path $repoRoot 'payload-symlinks.template.json'
$mcpManifest    = Join-Path $repoRoot 'scripts\mcp-packages.json'
$gitManifest    = Join-Path $repoRoot 'scripts\install-git-repos.json'
$llmDefaults    = Join-Path $repoRoot 'scripts\llm-defaults.json'
$llmUserOverride = Join-Path $repoRoot 'config\llm-providers.json'

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host "-- $Text " -NoNewline
    Write-Host ('-' * [Math]::Max(0, 60 - $Text.Length))
}

function Resolve-Paths {
    <#
        Descobre os caminhos locais. Preferencia:
          1. env ORCH_* (vem do install.js apos detectar npm root -g)
          2. `npm root -g`
          3. $env:USERPROFILE / $env:HOME / ~/.agents
        Resolucao de {{...}} placeholders acontece aqui.
    #>
    [CmdletBinding()]
    param()

    $nm = $env:ORCH_NPM_GLOBAL_NODE_MODULES
    if ([string]::IsNullOrWhiteSpace($nm)) {
        $r = & npm root -g 2>$null
        if ($LASTEXITCODE -eq 0 -and $r) { $nm = $r.Trim() }
    }
    if (-not $nm) {
        $fallback = Join-Path (Split-Path -Parent (Get-Command node -ErrorAction SilentlyContinue).Source -ErrorAction SilentlyContinue) 'node_modules'
        if (Test-Path $fallback) { $nm = $fallback }
    }

    $uh = $env:ORCH_USER_HOME
    if ([string]::IsNullOrWhiteSpace($uh)) { $uh = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($uh)) { $uh = $env:HOME }
    if ([string]::IsNullOrWhiteSpace($uh)) { $uh = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '') }

    $ua = $env:ORCH_USER_AGENTS
    if ([string]::IsNullOrWhiteSpace($ua)) { $ua = Join-Path $uh '.agents' }

    return [pscustomobject]@{
        NodeModules = $nm
        UserHome    = $uh
        UserAgents  = $ua
    }
}

function Resolve-Template {
    <#
        Substitui {{chave}} em uma string, a partir de um hashtable.
        Silencioso: se {{chave}} nao estiver no hashtable, nao substitui
        (assim um placeholder nao resolvido e visivel na saida para debug).

        Normaliza barras invertidas (`\`) em paths Windows para barras normais
        (`/`) no output. Em JSONC, `\` e caractere de escape: o valor
        `C:\node_modules` quebraria o parse (`\n` vira newline). Forward-slash
        e aceito por todo SO e por todos os parsers JSON, e o opencode trata
        paths uniformemente.
    #>
    param(
        [string]$Text,
        [hashtable]$Vars
    )
    $out = $Text
    foreach ($k in $Vars.Keys) {
        $v = [string]$Vars[$k]
        $v = $v.Replace('\', '/')
        $out = $out.Replace("{{$k}}", $v)
    }
    return $out
}

function Discover-OpencodeModels {
    <#
        Executa `opencode models --verbose` em diretorio vazio (para garantir
        que vem da config global, nao de opencode.json de projeto) e parseia
        a saida em uma lista de PSCustomObjects:
          providerID, id, fullId, name, npm, url, limit, options, envVar.
        Tambem roda `opencode providers list` para extrair o mapeamento
        provider->envVar para providers autenticados por Environment.
    #>
    [CmdletBinding()]
    param()

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('opencode-orch-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    try {
        Push-Location $tmp
        try {
            $r = & opencode models --verbose 2>&1
            if ($LASTEXITCODE -ne 0) { return @{ ok = $false; error = "opencode models --verbose falhou (exit $LASTEXITCODE)" } }
            $raw = ($r -join "`n")
            $blocks = $raw -split '(?m)^(?=[A-Za-z0-9_.-]+\/[A-Za-z0-9_.:-]+\s*$)'
            $models = @()
            foreach ($blk in $blocks) {
                $trimmed = $blk.Trim()
                if (-not $trimmed) { continue }
                $braceAt = $trimmed.IndexOf('{')
                if ($braceAt -lt 0) { continue }
                $json = $trimmed.Substring($braceAt)
                try {
                    $o = $json | ConvertFrom-Json
                    if ($o -and $o.providerID -and $o.id) { $models += $o }
                } catch { }
            }
            $pr = & opencode providers list 2>&1
            $envByProvider = @{}
            if ($LASTEXITCODE -eq 0) {
                $provRaw = ($pr -join "`n")
                $section = ''
                foreach ($line in ($provRaw -split "`r?`n")) {
                    $stripped = ($line -replace "`e\[","") -replace '\[[0-9;]*m', ''
                    $stripped = $stripped.Trim()
                    if (-not $stripped) { continue }
                    if ($stripped -match '(?i)credentials' -and $stripped -match '~\.local') { $section = 'creds'; continue }
                    if ($stripped -match '(?i)environment' -and -not ($stripped -match '(?i)variables?')) { $section = 'env'; continue }
                    if ($stripped -match '^───|^——|^—') { continue }
                    if ($section -ne 'env') { continue }
                    $m = [regex]::Match($stripped, '^(?:•\s*)?(.+?)\s+([A-Z][A-Z0-9_]+)\s*$')
                    if (-not $m.Success) { continue }
                    $displayName = $m.Groups[1].Value.ToLower()
                    $envVar = $m.Groups[2].Value
                    $providerId = if     ($displayName -match 'deepseek')   { 'deepseek' }
                                   elseif ($displayName -match 'openrouter') { 'openrouter' }
                                   elseif ($displayName -match 'cloudflare') { 'cloudflare' }
                                   elseif ($displayName -match 'minimax')    { 'minimax-coding-plan' }
                                   elseif ($displayName -match 'zen')        { 'opencode-zen' }
                                   elseif ($displayName -match 'nvidia')      { 'nvidia' }
                                   elseif ($displayName -match 'anthropic')   { 'anthropic' }
                                   elseif ($displayName -match 'openai')      { 'openai' }
                                   else {
                                       $displayName -replace '\s*\([^\)]*\)', '' -replace '[^a-z0-9-]+', '-'
                                   }
                    if (-not $envByProvider.ContainsKey($providerId)) {
                        $envByProvider[$providerId] = $envVar
                    }
                }
            }
            $aggregated = @()
            foreach ($m in $models) {
                $aggregated += [pscustomobject]@{
                    fullId     = "$($m.providerID)/$($m.id)"
                    providerID = $m.providerID
                    id         = $m.id
                    name       = if ($m.name) { $m.name } else { $m.id }
                    npm        = $m.api.npm
                    url        = $m.api.url
                    limit      = $m.limit
                    options    = $m.options
                    envVar     = if ($envByProvider.ContainsKey($m.providerID)) { $envByProvider[$m.providerID] } else { $null }
                }
            }
            return @{
                ok           = $true
                models       = $aggregated
                envByProvider = $envByProvider
            }
        } finally {
            Pop-Location
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-Prerequisites {
    <#
        Confere os 4 requisitos basicos para a instalacao:
          1. opencode instalado (ferramenta-alvo da config)
          2. npm instalado (instalador do pacote + deps de MCPs npm)
          3. node instalado (runtime dos MCPs em Node)
          4. git instalado (clone de skills externas; opcional em modo
             estritamente fechado, mas o instalador nao distingue)
        E confere tambem os providers LLM ativos: para cada um, qual env var
        e referenciada em apiKey tem que estar definida. Providers locais
        (sem apiKey) passam. Falhas bloqueiam o resto do install.
    #>
    [CmdletBinding()]
    param(
        [bool]$SkipNetwork = $false
    )

    Write-Section 'Pre-requisitos criticos'
    Write-Host '  Ferramentas obrigatorias (sem elas, o resto do install nao faz sentido):'

    $requiredTools = [ordered]@{
        opencode = 'ferramenta-alvo da config (opencode serve / opencode run / TUI)'
        npm      = 'instalador deste pacote + deps de MCPs npm'
        node     = 'runtime dos MCPs em Node (sequential-thinking, memory, OpenCodeRAG)'
        git      = 'clone de skills externas em scripts/install-git-repos.json'
    }
    foreach ($kv in $requiredTools.GetEnumerator()) {
        $cmd = Get-Command $kv.Key -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Host ("    OK    {0,-10} ({1}) -> {2}" -f $kv.Key, $kv.Value, $cmd.Source)
        } else {
            Write-Host ("    FALTA {0,-10} ({1})" -f $kv.Key, $kv.Value) -ForegroundColor Red
            $script:falhas += "$($kv.Key) nao esta no PATH"
        }
    }

    Write-Host ''
    Write-Host '  Providers LLM (env vars referenciadas em providers.<name>.options.apiKey):'

    $cfgPath = if (Test-Path $llmUserOverride) { $llmUserOverride }
               elseif (Test-Path $llmDefaults) { $llmDefaults }
               else { $null }

    if (-not $cfgPath) {
        Write-Host '    SKIP  sem manifesto de providers (nenhum ativo)' -ForegroundColor DarkGray
    } else {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        foreach ($p in $cfg.providers.PSObject.Properties) {
            $opts   = $p.Value.options
            $apiKey = if ($opts -and $opts.PSObject.Properties.Name -contains 'apiKey') { [string]$opts.apiKey } else { $null }
            if (-not $apiKey) {
                Write-Host ("    INFO  {0,-22} sem apiKey (provider local/remoto sem auth)" -f $p.Name) -ForegroundColor DarkGray
                continue
            }
            if ($apiKey -notmatch '\{env:(\w+)\}') {
                Write-Host ("    AVISO {0,-22} apiKey literal em config (sem {{env:...}}) - texto puro em .gitignore?" -f $p.Name) -ForegroundColor Yellow
                continue
            }
            $envVar = $Matches[1]
            $value  = [Environment]::GetEnvironmentVariable($envVar)
            if ([string]::IsNullOrWhiteSpace($value)) {
                Write-Host ("    FALTA {0,-22} {1} (apiKey do provider)" -f $p.Name, $envVar) -ForegroundColor Red
                $script:falhas += "$envVar nao definida (provider $($p.Name))"
            } else {
                Write-Host ("    OK    {0,-22} {1} definida" -f $p.Name, $envVar)
            }
        }
    }

    Write-Host ''
    Write-Host '  Ferramentas opcionais (ausencia nao bloqueia; perde feature):'
    foreach ($c in @('uvx')) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            Write-Host "    OK    $c (LSP python)"
        } else {
            Write-Host "    AVISO $c ausente (LSP python indisponivel)" -ForegroundColor Yellow
        }
    }

    if ($script:falhas.Count -gt 0) {
        Write-Section 'Instalacao bloqueada pelos pre-requisitos'
        $script:falhas | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        Write-Host ''
        Write-Host 'Sem os itens acima, o resto do instalador pode ate rodar, mas nao vai' -ForegroundColor Yellow
        Write-Host 'produzir uma orquestracao funcional. Resolva e rode de novo.' -ForegroundColor Yellow
        return $false
    }

    Write-Host ''
    Write-Host '  pre-requisitos OK - pode prosseguir' -ForegroundColor Green
    return $true
}

function Resolve-LlmConfig {
    <#
        Le a config de LLM/providers na ordem:
          1. config/llm-providers.json (override do usuario, gitignored)
          2. scripts/llm-defaults.json       (default do orquestrador)
        Retorna um hashtable com todos os placeholders {{...}} que o
        payload/opencode.jsonc espera, ja no formato de string para
        substituicao direta. O resultado inclui:
          enabledProvidersList  - "[a","b","c"]" inline para um array JSON
          modelDefault, smallModelDefault
          modelAgentPlan/Build/Review/Bugfix/General/Explore
          tempAgent*           - temperatura numerica, sem aspas
          descAgent*           - string descritiva
          providersBlock       - bloco JSON do objeto providers, formatado
    #>
    [CmdletBinding()]
    param()

    $source = $null
    $sourceLabel = ''
    if (Test-Path $llmUserOverride) {
        $source = Get-Content $llmUserOverride -Raw | ConvertFrom-Json
        $sourceLabel = $llmUserOverride
    } elseif (Test-Path $llmDefaults) {
        $source = Get-Content $llmDefaults -Raw | ConvertFrom-Json
        $sourceLabel = $llmDefaults
    } else {
        throw "Nenhum manifesto de providers encontrado: $llmDefaults (default) ou $llmUserOverride (user). Sem este arquivo, nao da para gerar o bloco de providers do opencode.jsonc."
    }

    $out = @{
        modelDefault       = [string]$source.model
        smallModelDefault  = [string]$source.small_model
    }

    $ep = @($source.enabled_providers)
    $out.enabledProvidersList = '[' + (($ep | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'

    $agentSlots = @('plan','build','review','bugfix','general','explore')
    foreach ($s in $agentSlots) {
        $a = $source.agents.PSObject.Properties | Where-Object { $_.Name -eq $s }
        if (-not $a) { throw "Manifesto de providers esta sem agent.$s. Em scripts/llm-defaults.json ou config/llm-providers.json, declare todos os 6 slots." }
        $cfg = $a.Value
        $out["modelAgent$( (Get-Culture).TextInfo.ToTitleCase($s) )"] = [string]$cfg.model
        $out["tempAgent$(  (Get-Culture).TextInfo.ToTitleCase($s) )"] = [string]$cfg.temperature
        $out["descAgent$(  (Get-Culture).TextInfo.ToTitleCase($s) )"] = [string]$cfg.description
    }

    $provHashtable = [ordered]@{}
    foreach ($p in $source.providers.PSObject.Properties) {
        $provHashtable[$p.Name] = $p.Value
    }
    $providersJson = $provHashtable | ConvertTo-Json -Depth 12 -Compress
    $out.providersBlock = $providersJson

    return [pscustomobject]@{
        Vars        = $out
        SourceLabel = $sourceLabel
    }
}

function Initialize-McpPackages {
    <#
        Garante que as deps declaradas em scripts/mcp-packages.json estao
        instaladas globalmente. Saida: lista de pacotes instalados para
        reportar ao usuario. Falha nao-bloqueante: se npm nao esta no PATH
        ou um pacote nao consegue instalar, reporta aviso e segue.
    #>
    [CmdletBinding()]
    param(
        [string]$ManifestPath
    )
    if (-not (Test-Path $ManifestPath)) {
        Write-Host "  sem manifesto em $ManifestPath - pulando install de MCPs npm"
        return @()
    }

    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCmd) {
        Write-Host '  npm nao esta no PATH - pulando install de MCPs npm' -ForegroundColor Yellow
        return @()
    }

    $pkgs = @(Get-Content $ManifestPath -Raw | ConvertFrom-Json)
    if ($pkgs.Count -eq 0) {
        Write-Host '  manifesto vazio - nada a instalar'
        return @()
    }

    Write-Host "  manifesto: $($pkgs.Count) pacote(s) declarados"

    $installed = @()
    foreach ($p in $pkgs) {
        $name    = $p.name
        $version = if ($p.version) { $p.version } else { 'latest' }
        $why     = if ($p.why) { $p.why } else { 'MCP server' }
        Write-Host "    $name@$version  ($why)"

        $check = & npm ls -g $name 2>$null
        if ($LASTEXITCODE -eq 0 -and $check -match [regex]::Escape($name)) {
            Write-Host "      OK - ja presente" -ForegroundColor DarkGray
            $installed += $name
            continue
        }

        if (-not $Force) {
            Write-Host "      simulacao: instalaria" -ForegroundColor DarkGray
            continue
        }

        Write-Host "      instalando..."
        & npm install -g "$name@$version" 2>&1 | ForEach-Object { Write-Host "        $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "      FALHOU (exit $LASTEXITCODE)" -ForegroundColor Yellow
            continue
        }
        $installed += $name
    }
    return $installed
}

$paths   = Resolve-Paths
$falhas  = @()
$vars    = @{
    nodeModules = $paths.NodeModules
    userHome    = $paths.UserHome
    userAgents  = $paths.UserAgents
}

Write-Section 'Deteccao de caminhos'
foreach ($kv in $vars.GetEnumerator()) {
    $val = $kv.Value
    $marca = if ($val) { 'OK    ' } else { 'FALTA ' }
    $cor   = if ($val) { 'Gray'  } else { 'Red'  }
    $who   = switch ($kv.Key) {
        'nodeModules' { '`npm root -g`' }
        'userHome'    { '$env:USERPROFILE ou $env:HOME' }
        'userAgents'  { '$userHome/.agents' }
    }
    Write-Host "  $marca $($kv.Key.PadRight(11)) = $val  (de: $who)" -ForegroundColor $cor
}
if ([string]::IsNullOrWhiteSpace($paths.NodeModules)) {
    $falhas += 'nodeModules global nao detectado (npm root -g falhou e node nao esta no PATH). Configure o ORCH_NPM_GLOBAL_NODE_MODULES ou instale o node.'
}
if ([string]::IsNullOrWhiteSpace($paths.UserHome)) {
    $falhas += 'userHome nao detectado - sem USERPROFILE nem HOME.'
}

Write-Section 'Providers LLM (manifesto carregado)'
$llmResolution = Resolve-LlmConfig
foreach ($k in ($llmResolution.Vars.Keys | Sort-Object)) {
    $v = $llmResolution.Vars[$k]
    if ($k -eq 'providersBlock') {
        $oneLine = $v -replace "`r?`n", ' ' | Select-Object -First 1
        Write-Host ("  {0,-22} = <{1} chars JSON>" -f $k, $v.Length) -ForegroundColor Gray
    } else {
        Write-Host "  $($k.PadRight(22)) = $v" -ForegroundColor Gray
    }
}
Write-Host "  fonte: $($llmResolution.SourceLabel)" -ForegroundColor DarkGray
foreach ($kv in ($llmResolution.Vars.GetEnumerator())) { $vars[$kv.Key] = [string]$kv.Value }

# --- 0. Pre-requisitos criticos (BLOQUEIA AQUI) -----------------------------
# Roda antes de qualquer trabalho: install MCP npm, clone de git, copia de
# payload. Sem os 4 tools ou sem as env vars dos providers ativos, nao faz
# sentido prosseguir.
if (-not (Test-Prerequisites)) {
    exit 1
}

# --- 0.3 Ollama + modelo de embedding (para OpenCodeRAG) ----------------------
# Instala Ollama silenciosamente se ausente, inicia o servico, e puxa o modelo
# nomic-embed-text:latest. NAO bloqueia: falhas sao reportadas como aviso.
# O modelo de embedding e necessario para o opencode-rag-plugin funcionar.
Write-Section 'Ollama + modelo de embedding (OpenCodeRAG)'
$ollamaScript = Join-Path $PSScriptRoot 'Install-Ollama.ps1'
if (Test-Path $ollamaScript) {
    $ollamaArgs = @{}
    if ($Force) { $ollamaArgs.Force = $true }
    $ollamaResult = & $ollamaScript @ollamaArgs
    if ($ollamaResult -and -not $ollamaResult.Success) {
        Write-Host ''
        Write-Host '  Ollama setup incompleto — OpenCodeRAG pode nao funcionar.' -ForegroundColor Yellow
        Write-Host '  Para resolver manualmente:' -ForegroundColor Yellow
        Write-Host '    1. Instale Ollama: irm https://ollama.com/install.ps1 | iex' -ForegroundColor DarkGray
        Write-Host '    2. Inicie o servico: ollama serve' -ForegroundColor DarkGray
        Write-Host '    3. Puxe o modelo: ollama pull nomic-embed-text:latest' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  A instalacao segue sem Ollama — o resto da orquestracao funciona normalmente.' -ForegroundColor Yellow
    }
} else {
    Write-Host "  Install-Ollama.ps1 nao encontrado em $PSScriptRoot — pulando setup de Ollama" -ForegroundColor Yellow
}

# --- 0.5 Auto-descoberta de models/providers do opencode ----------------------
# Roda `opencode models --verbose` em diretorio vazio para listar o que o
# opencode local realmente tem configurado. Valida a config ativa contra
# essa lista: se um model referenciado pelos defaults (ou pelo override do
# usuario) nao foi descoberto, AVISA - pode ser credencial expirada, mas
# nao bloqueia a instalacao (o opencode vai pegar e reclamar depois).
Write-Section 'Auto-descoberta de models (opencode models --verbose)'
$discovered = Discover-OpencodeModels
if (-not $discovered.ok) {
    Write-Host "  FALHOU: $($discovered.error)" -ForegroundColor Yellow
    Write-Host "  instalacao segue sem validacao contra discovery - rode npm run verify antes de usar" -ForegroundColor Yellow
} else {
    Write-Host "  $($discovered.models.Count) model(s) descoberto(s):"
    foreach ($m in ($discovered.models | Sort-Object providerID, id)) {
        $keyPart = if ($m.envVar) { " [key: $($m.envVar)]" } else { '' }
        Write-Host ("    {0,-45} {1,-30}{2}" -f $m.fullId, $m.name, $keyPart)
    }
    $discoveredIds = @($discovered.models | ForEach-Object { $_.fullId })
    $referencedModels = @($llmResolution.SourceLabel)  # placeholder
    $cfgSource = $null
    $cfgOverride = $llmUserOverride
    $cfgDefault  = $llmDefaults
    if ((Test-Path $cfgOverride) -or (Test-Path $cfgDefault)) {
        $path = if (Test-Path $cfgOverride) { $cfgOverride } else { $cfgDefault }
        $cfgSource = Get-Content $path -Raw | ConvertFrom-Json
    }
    if ($cfgSource) {
        $refs = @()
        if ($cfgSource.model)         { $refs += [string]$cfgSource.model }
        if ($cfgSource.small_model)   { $refs += [string]$cfgSource.small_model }
        foreach ($a in $cfgSource.agents.PSObject.Properties) { $refs += [string]$a.Value.model }
        $refs = $refs | Sort-Object -Unique
        foreach ($r in $refs) {
            if ($r -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.:-]+$') {
                if ($discoveredIds -notcontains $r) {
                    Write-Host "    AVISO  $r nao foi descoberto (credencial expirada? provider nao configurado?)" -ForegroundColor Yellow
                }
            }
        }
    }
}

# --- 1. Payload --------------------------------------------------------------
Write-Section 'Payload'
if (-not (Test-Path $payloadRoot)) {
    throw "payload/ nao existe. Rode scripts\Sync-Payload.ps1 numa maquina que ja tenha a config viva."
}
$payloadFiles = @(Get-ChildItem $payloadRoot -Recurse -File -Force)
Write-Host "  $($payloadFiles.Count) arquivo(s) em $payloadRoot"
if (-not (Test-Path (Join-Path $payloadRoot 'opencode.jsonc'))) {
    $falhas += 'payload/opencode.jsonc ausente - payload incompleto'
}

# --- 2. MCPs npm auto-instalados --------------------------------------------
Write-Section 'MCPs npm'
$installedMcp = Initialize-McpPackages -ManifestPath $mcpManifest

# --- 3. Repos git (skills/dependencias que nao estao no npm) ----------------
Write-Section 'Repos git (skills de sources externas)'
if (-not (Test-Path $gitManifest)) {
    Write-Host "  sem manifesto em $gitManifest - pulando clone de git" -ForegroundColor DarkGray
} else {
    $gitRepos = @(Get-Content $gitManifest -Raw | ConvertFrom-Json)
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Write-Host '  git nao esta no PATH - pulando clone; skills de sources externas ficaram sem origem' -ForegroundColor Yellow
    } elseif ($gitRepos.Count -eq 0) {
        Write-Host '  manifesto vazio - nada a clonar'
    } else {
        Write-Host "  manifesto: $($gitRepos.Count) repo(s)"
        foreach ($r in $gitRepos) {
            $target = Resolve-Template -Text $r.target -Vars $vars
            $reason = if ($r.why) { $r.why } else { 'repo de skill/dependencia externa' }
            $branch = if ($r.ref)  { $r.ref }  else { 'main' }
            $depth  = if ($r.depth) { $r.depth } else { 1 }
            Write-Host "    $($r.url) -> $target  ($branch, depth $depth) [$reason]"

            if (Test-Path $target) {
                Write-Host '      ja existe - pulado (use `git pull` manualmente para atualizar)' -ForegroundColor DarkGray
                continue
            }
            if (-not $Force) {
                Write-Host '      simulacao: clonaria' -ForegroundColor DarkGray
                continue
            }

            $parent = Split-Path -Parent $target
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

            Write-Host '      clonando...'
            & git clone --depth $depth --branch $branch $r.url $target 2>&1 | ForEach-Object { Write-Host "        $_" }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "      FALHOU (exit $LASTEXITCODE) - tente `git clone $($r.url) $target` manualmente" -ForegroundColor Yellow
                continue
            }
            Write-Host '      OK' -ForegroundColor Green
        }
    }
}

# --- 5. Destino --------------------------------------------------------------
Write-Section 'Destino'
$destinoExiste = Test-Path $TargetRoot
Write-Host "  $TargetRoot"
if ($destinoExiste) {
    $existentes = @(Get-ChildItem $TargetRoot -Force -ErrorAction SilentlyContinue)
    Write-Host "  ja existe, com $($existentes.Count) entrada(s) no topo" -ForegroundColor Yellow
    if (Test-Path (Join-Path $TargetRoot '.git')) {
        Write-Host '  e repositorio git - confira commit pendente antes de sobrescrever' -ForegroundColor Yellow
    }
} else {
    Write-Host '  nao existe, sera criado'
}

if ($falhas.Count -gt 0) {
    Write-Section 'Bloqueado por itens descobertos depois do pre-check'
    $falhas | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Esses itens nao estavam no pre-check mas apareceram ao longo do install. Resolva e rode de novo.' -ForegroundColor Red
    exit 1
}

if (-not $Force) {
    Write-Section 'Simulacao'
    Write-Host "  Copiaria $($payloadFiles.Count) arquivo(s) (com templates renderizados) para $TargetRoot"
    if ($destinoExiste) { Write-Host "  Faria backup do destino atual em $repoRoot\_backup-<timestamp>\" }
    Write-Host "  Criaria $($installedMcp.Count) MCP npm novo(s) globalmente (ou pula se ja presente)"
    if ((Test-Path $gitManifest) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $gitReposSim = @(Get-Content $gitManifest -Raw | ConvertFrom-Json)
        foreach ($r in $gitReposSim) {
            $t = Resolve-Template -Text $r.target -Vars $vars
            Write-Host "  Clonaria $($r.url) -> $t (branch $($r.ref), depth $($r.depth))"
        }
    }
    if (Test-Path $symlinkTmpl) {
        $links = Get-Content $symlinkTmpl -Raw | ConvertFrom-Json
        if ($links.links) {
            foreach ($l in $links.links) {
                Write-Host "  Symlink $($l.path) -> $($l.targetTemplate)  [via Developer Mode/elevacao]"
            }
        }
    }
    Write-Host ''
    Write-Host 'Nada foi escrito. Repita com -Force para efetivar.' -ForegroundColor Yellow
    exit 0
}

# --- 6. Backup ---------------------------------------------------------------
if ($destinoExiste) {
    Write-Section 'Backup do destino'
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $repoRoot "_backup-$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Get-ChildItem $TargetRoot -Force | Where-Object { $_.Name -ne 'node_modules' } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $backup -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  $backup"
}

# --- 7. Copia com renderizacao de templates ----------------------------------
Write-Section 'Instalando (com templates)'
if (-not (Test-Path $TargetRoot)) { New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null }
$copiados = 0
$renderizados = 0
foreach ($f in $payloadFiles) {
    $rel = $f.FullName.Substring($payloadRoot.Length).TrimStart('\')
    $dst = Join-Path $TargetRoot $rel
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $baseName = $f.BaseName
    $ext      = $f.Extension
    $rendered = $false
    if ($baseName -in @('opencode') -and $ext -in @('.jsonc', '.json')) {
        $text   = Get-Content $f.FullName -Raw -Encoding UTF8
        $renderedText = Resolve-Template -Text $text -Vars $vars
        Set-Content -Path $dst -Value $renderedText -Encoding UTF8 -NoNewline
        $rendered = $true
        $renderizados++
    } else {
        Copy-Item -Path $f.FullName -Destination $dst -Force
    }
    $copiados++
}
Write-Host "  $copiados arquivo(s) copiado(s), $renderizados com template renderizado"

# --- 8. Symlinks esperados ---------------------------------------------------
if (Test-Path $symlinkTmpl) {
    $linksData = Get-Content $symlinkTmpl -Raw | ConvertFrom-Json
    if ($linksData.links) {
        Write-Section 'Symlinks'
        foreach ($l in $linksData.links) {
            $linkPath = Join-Path $TargetRoot $l.path
            $target   = Resolve-Template -Text $l.targetTemplate -Vars $vars
            $alvoOk   = Test-Path $target
            if (-not $alvoOk) {
                Write-Host "  $($l.path) -> $target  ALVO AUSENTE" -ForegroundColor Yellow
                if ($l.fallback) { Write-Host "    $($l.fallback)" -ForegroundColor DarkGray }
                continue
            }
            if (Test-Path $linkPath) {
                Write-Host "  $($l.path) -> $target  ja existe (pulado)" -ForegroundColor DarkGray
                continue
            }
            try {
                New-Item -ItemType SymbolicLink -Path $linkPath -Target $target -Force | Out-Null
                Write-Host "  $($l.path) -> $target  criado" -ForegroundColor Green
            } catch {
                Write-Host "  $($l.path) -> $target  falhou (Developer Mode ou elevacao necessaria)" -ForegroundColor Yellow
            }
        }
        Write-Host '  Criar com New-Item -ItemType SymbolicLink exige Developer Mode no Windows.' -ForegroundColor DarkGray
    }
}

# --- 9. Verificacao ----------------------------------------------------------
Write-Section 'Verificacao'
$testScript = Join-Path $PSScriptRoot 'Test-Orchestration.ps1'
if (Test-Path $testScript) {
    & $testScript -TargetRoot $TargetRoot
} else {
    Write-Host '  Test-Orchestration.ps1 nao encontrado - verifique a mao com: opencode models' -ForegroundColor Yellow
}
