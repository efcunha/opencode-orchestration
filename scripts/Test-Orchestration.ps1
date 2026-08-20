<#
.SYNOPSIS
    Verifica se a orquestracao multi-LLM do opencode esta funcional.

.DESCRIPTION
    Checa a instalacao de fora para dentro, do arquivo ate a chamada real de
    API. Sai com codigo 1 se qualquer verificacao obrigatoria falhar, o que
    permite usar em CI ou como gate depois de instalar.

    Os modelos esperados NAO estao escritos aqui. Eles saem do whitelist
    declarado no proprio opencode.jsonc e sao conferidos contra o que o
    opencode resolve. Uma lista fixa neste script viraria uma segunda verdade
    para divergir da config.

    A verificacao dos YAML de quest existe por causa de um defeito real: o
    small_model global apontou para "deepseek-v4-flash-free", um modelo que
    nunca existiu na API. Referencia de modelo invalida nao falha na carga da
    config - falha na primeira chamada, em silencio. Conferir cada referencia
    contra a lista resolvida pega isso antes de doer.

.PARAMETER TargetRoot
    Raiz da configuracao. Default: ~/.config/opencode.

.PARAMETER SkipNetwork
    Nao testa conectividade dos providers. Use offline.

.EXAMPLE
    .\Test-Orchestration.ps1
    .\Test-Orchestration.ps1 -SkipNetwork
#>
[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE '.config\opencode'),
    [switch]$SkipNetwork,
    [ValidateSet('pt','en')]
    [string]$Language = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── i18n ──
if (-not $Language) {
    $Language = if ($env:ORCH_LANGUAGE -and $env:ORCH_LANGUAGE -in @('pt','en')) { $env:ORCH_LANGUAGE } else { 'pt' }
}

$Labels = @{
    'pt' = @{
        Pass         = 'PASSA'
        Fail         = 'FALHA'
        Warn         = 'AVISO'
        Verifying    = 'Verificando'
        Files        = 'Arquivos'
        EnvVars      = 'Variaveis de ambiente (somente presenca, derivado do manifesto LLM ativo)'
        McpDeclared  = 'MCPs declarados'
        Resolution   = 'Resolucao (de um diretorio vazio)'
        ModelRefs    = 'Referencias de modelo'
        Connectivity = 'Conectividade dos providers LLM (do manifesto ativo)'
        Result       = 'Resultado'
        Failures     = 'falha(s)'
        Warnings     = 'aviso(s)'
        NoneBlocking = 'nenhum bloqueante'
        NoManifest   = 'sem manifesto - pulado'
        NoProvider   = 'nenhum provider ativo requer env var'
        Source       = 'fonte'
    }
    'en' = @{
        Pass         = 'PASS'
        Fail         = 'FAIL'
        Warn         = 'WARN'
        Verifying    = 'Verifying'
        Files        = 'Files'
        EnvVars      = 'Environment variables (presence only, derived from active LLM manifest)'
        McpDeclared  = 'MCPs declared'
        Resolution   = 'Resolution (from an empty directory)'
        ModelRefs    = 'Model references'
        Connectivity = 'LLM provider connectivity (from active manifest)'
        Result       = 'Result'
        Failures     = 'failure(s)'
        Warnings     = 'warning(s)'
        NoneBlocking = 'none blocking'
        NoManifest   = 'no manifest - skipped'
        NoProvider   = 'no active provider requires env var'
        Source       = 'source'
    }
}
$L = $Labels[$Language]

$erros  = @()
$avisos = @()

function Test-Item {
    param([string]$Nome, [bool]$Ok, [string]$Detalhe = '', [switch]$Aviso)
    $marca = if ($Ok) { $L.Pass } elseif ($Aviso) { $L.Warn } else { $L.Fail }
    $cor   = if ($Ok) { 'Green' } elseif ($Aviso) { 'Yellow' } else { 'Red' }
    $sufixo = if ($Detalhe) { " - $Detalhe" } else { '' }
    Write-Host ('  [{0}] {1}{2}' -f $marca, $Nome, $sufixo) -ForegroundColor $cor
    if (-not $Ok) {
        if ($Aviso) { $script:avisos += $Nome }
        else        { $script:erros  += "$Nome$sufixo" }
    }
}

function ConvertFrom-Jsonc {
    param([string]$Text)
    $noBlock = [regex]::Replace($Text, '/\*.*?\*/', '', 'Singleline')
    $lines   = $noBlock -split "`r?`n" | Where-Object { $_.TrimStart() -notmatch '^//' }
    return ($lines -join "`n") | ConvertFrom-Json
}

Write-Host ''
Write-Host "$($L.Verifying): $TargetRoot"

# --- 1. Arquivos -------------------------------------------------------------
Write-Host ''
Write-Host $L.Files
$cfgPath = Join-Path $TargetRoot 'opencode.jsonc'
$cfgJson = $null
Test-Item 'opencode.jsonc existe' (Test-Path $cfgPath)
if (Test-Path $cfgPath) {
    try {
        $cfgJson = ConvertFrom-Jsonc (Get-Content $cfgPath -Raw)
        Test-Item 'opencode.jsonc parseia' $true
    } catch {
        Test-Item 'opencode.jsonc parseia' $false $_.Exception.Message
    }
}
Test-Item 'plugin de quests presente' (Test-Path (Join-Path $TargetRoot 'plugins\opencode-quests.ts'))
$questDir   = Join-Path $TargetRoot 'agents'
$questFiles = @()
if (Test-Path $questDir) { $questFiles = @(Get-ChildItem $questDir -Filter *.yaml -File) }
Test-Item 'quests globais presentes' ($questFiles.Count -gt 0) "$($questFiles.Count) arquivo(s)"

# --- 2. Variaveis de ambiente (dinamico, do manifesto ativo) ----------------
Write-Host ''
Write-Host $L.EnvVars

$cfgRoot = Split-Path -Parent $PSScriptRoot
$cfgDefaults = Join-Path $cfgRoot 'scripts\llm-defaults.json'
$cfgOverride = Join-Path $cfgRoot 'config\llm-providers.json'
$cfgUsed     = if     (Test-Path $cfgOverride) { $cfgOverride }
               elseif (Test-Path $cfgDefaults) { $cfgDefaults }
               else                              { $null }

if (-not $cfgUsed) {
    Test-Item 'manifesto de providers' $false "nem $cfgDefaults nem $cfgOverride existem"
} else {
    $cfg = Get-Content $cfgUsed -Raw | ConvertFrom-Json
    $envsNeeded = @()
    foreach ($p in $cfg.providers.PSObject.Properties) {
        $opts = $p.Value.options
        if ($opts -and ($opts.PSObject.Properties.Name -contains 'apiKey')) {
            $k = [string]$opts.apiKey
            if ($k -match '\{env:(\w+)\}') { $envsNeeded += [string]$Matches[1] }
        }
    }
    foreach ($v in ($envsNeeded | Sort-Object -Unique)) {
        Test-Item $v (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($v)))
    }
    if ($envsNeeded.Count -eq 0) {
        Write-Host "  ($($L.NoProvider))" -ForegroundColor DarkGray
    } else {
        Write-Host "  $($L.Source): $cfgUsed" -ForegroundColor DarkGray
    }
}

# --- 3. MCPs declarados ------------------------------------------------------
Write-Host ''
Write-Host $L.McpDeclared
if ($cfgJson -and $cfgJson.PSObject.Properties.Name -contains 'mcp') {
    foreach ($m in $cfgJson.mcp.PSObject.Properties) {
        $def = $m.Value
        $type = $def.PSObject.Properties | Where-Object { $_.Name -eq 'type' }
        $typeVal = if ($type) { $type.Value } else { 'local' }
        if ($typeVal -eq 'local') {
            $cmd = $def.PSObject.Properties | Where-Object { $_.Name -eq 'command' }
            if ($cmd -and $cmd.Value.Count -ge 2 -and $cmd.Value[0] -eq 'node') {
                $bin = $cmd.Value[1]
                $exists = Test-Path $bin
                Test-Item "mcp.$($m.Name) binario" $exists $bin
            } else {
                Test-Item "mcp.$($m.Name)" $true 'sem node <path> - usa wrapper externo' -Aviso
            }
        } else {
            Test-Item "mcp.$($m.Name)" $true 'remoto' -Aviso
        }
    }
}

# --- 4. Resolucao pelo opencode ----------------------------------------------
Write-Host ''
Write-Host $L.Resolution
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('oc-verify-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$modelos = @()
$agentes = @()
try {
    Push-Location $tmpDir
    $modelos = @(@(& opencode models 2>&1) | Where-Object { $_ -match '^\S+/\S+$' })
    $agentes = @(@(& opencode agent list 2>&1))
} catch {
    Test-Item 'opencode responde' $false $_.Exception.Message
} finally {
    if ((Get-Location).Path -eq $tmpDir) { Pop-Location }
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Test-Item 'opencode models retorna modelos' ($modelos.Count -gt 0) "$($modelos.Count) modelo(s)"
foreach ($m in $modelos) { Write-Host "         $m" -ForegroundColor DarkGray }

if ($cfgJson -and $cfgJson.PSObject.Properties.Name -contains 'provider') {
    $esperados = @()
    foreach ($p in $cfgJson.provider.PSObject.Properties) {
        $wl = $p.Value.PSObject.Properties | Where-Object { $_.Name -eq 'whitelist' }
        if ($wl) { foreach ($mid in $wl.Value) { $esperados += "$($p.Name)/$mid" } }
    }
    $faltando = @($esperados | Where-Object { $modelos -notcontains $_ })
    $sobrando = @($modelos   | Where-Object { $esperados -notcontains $_ })
    $det = if ($faltando.Count -or $sobrando.Count) {
        "faltando: $($faltando -join ', ') | sobrando: $($sobrando -join ', ')"
    } else { "$($esperados.Count) modelo(s)" }
    Test-Item 'whitelist da config == modelos resolvidos' ($faltando.Count -eq 0 -and $sobrando.Count -eq 0) $det
}

if ($cfgJson -and $cfgJson.PSObject.Properties.Name -contains 'agent') {
    $declarados = @($cfgJson.agent.PSObject.Properties.Name)
    $texto      = ($agentes -join ' ')
    $ausentes   = @($declarados | Where-Object { $texto -notmatch [regex]::Escape($_) })
    $det = if ($ausentes.Count) { "ausentes: $($ausentes -join ', ')" } else { "$($declarados.Count) agente(s)" }
    Test-Item 'agentes declarados aparecem em agent list' ($ausentes.Count -eq 0) $det
}

# --- 5. Referencias de modelo ------------------------------------------------
Write-Host ''
Write-Host $L.ModelRefs
if ($cfgJson) {
    foreach ($campo in @('model', 'small_model')) {
        $prop = $cfgJson.PSObject.Properties | Where-Object { $_.Name -eq $campo }
        if ($prop) { Test-Item "$campo resolvido" ($modelos -contains $prop.Value) $prop.Value }
    }
    if ($cfgJson.PSObject.Properties.Name -contains 'agent') {
        foreach ($a in $cfgJson.agent.PSObject.Properties) {
            $mp = $a.Value.PSObject.Properties | Where-Object { $_.Name -eq 'model' }
            if ($mp) { Test-Item "agent.$($a.Name).model resolvido" ($modelos -contains $mp.Value) $mp.Value }
        }
    }
}

function Test-QuestStructure {
    param([System.IO.FileInfo]$QuestFile)

    $text = Get-Content $QuestFile.FullName -Raw -Encoding UTF8
    $kindOk = $text -match '(?m)^kind:\s*quest\s*$'
    Test-Item "quest $($QuestFile.Name) kind" $kindOk

    $stageMatches = [regex]::Matches($text, '(?m)^\s+- id:\s*([A-Za-z0-9_-]+)\s*$')
    $stageIds = @($stageMatches | ForEach-Object { $_.Groups[1].Value })
    Test-Item "quest $($QuestFile.Name) stages" ($stageIds.Count -gt 0) "$($stageIds.Count) stage(s)"
    if ($stageIds.Count -eq 0) { return }

    for ($i = 0; $i -lt $stageMatches.Count; $i++) {
        $match = $stageMatches[$i]
        $start = $match.Index
        $end = if ($i + 1 -lt $stageMatches.Count) { $stageMatches[$i + 1].Index } else { $text.Length }
        $block = $text.Substring($start, $end - $start)
        $targets = @([regex]::Matches($block, '(?m)^\s{6}[A-Za-z0-9_-]+:\s*([A-Za-z0-9_-]+)\s*$') |
            ForEach-Object { $_.Groups[1].Value })
        foreach ($target in ($targets | Sort-Object -Unique)) {
            $valid = $target -eq 'done' -or $stageIds -contains $target
            Test-Item "quest $($QuestFile.Name) transition -> $target" $valid
        }
    }
}

foreach ($qf in $questFiles) {
    Test-QuestStructure -QuestFile $qf
    $refs = @(
        Select-String -Path $qf.FullName -Pattern '^\s*model:\s*(\S+)' -AllMatches |
        ForEach-Object { $_.Matches } |
        ForEach-Object { $_.Groups[1].Value.TrimEnd(',', '.', ';', ':') } |
        Where-Object { $_ -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.:-]+$' }
    ) | Sort-Object -Unique
    foreach ($r in $refs) {
        Test-Item "quest $($qf.Name) -> $r" ($modelos -contains $r)
    }
}

# --- 6. Conectividade dos providers LLM (dinamico) --------------------------
if (-not $SkipNetwork) {
    Write-Host ''
    Write-Host $L.Connectivity
    if (-not $cfgUsed) {
        Write-Host "  $($L.NoManifest)" -ForegroundColor DarkGray
    } else {
        $cfg = Get-Content $cfgUsed -Raw | ConvertFrom-Json
        foreach ($p in $cfg.providers.PSObject.Properties) {
            $opts = $p.Value.options
            if (-not $opts) { continue }
            $baseURL = if ($opts.PSObject.Properties.Name -contains 'baseURL') { [string]$opts.baseURL } else { '' }
            $apiKey  = if ($opts.PSObject.Properties.Name -contains 'apiKey')  { [string]$opts.apiKey }  else { '' }
            $modelo  = if ($p.Value.whitelist) { [string]$p.Value.whitelist[0] } else { '' }
            $envVar  = ''
            if ($apiKey -match '\{env:(\w+)\}') { $envVar = $Matches[1] }
            if (-not $baseURL -or -not $modelo) {
                Write-Host "    SKIP $($p.Name) (sem baseURL ou modelo whitelist)" -ForegroundColor DarkGray
                continue
            }
            if ($modelo -match '(?i)embed') {
                Write-Host "    SKIP $($p.Name) (modelo de embedding, nao chat - $modelo)" -ForegroundColor DarkGray
                continue
            }
            if ($envVar -and [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envVar))) {
                Test-Item "$($p.Name) responde" $false "$envVar nao definida" -Aviso
                continue
            }
            $headers = @{ 'Content-Type' = 'application/json' }
            if ($envVar) { $headers.Authorization = "Bearer $(([Environment]::GetEnvironmentVariable($envVar)))" }
            $url = "$($baseURL.TrimEnd('/'))/chat/completions"
            $body = @{ model = $modelo; messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 4 } |
                    ConvertTo-Json -Depth 5 -Compress
            try {
                $r = Invoke-RestMethod -Uri $url -Method Post -TimeoutSec 45 -Body $body -Headers $headers
                Test-Item "$($p.Name) responde" ($null -ne $r) "modelo retornado: $($r.model)"
            } catch {
                $det = if ($_.ErrorDetails.Message) { ($_.ErrorDetails.Message -replace '\s+', ' ') } else { $_.Exception.Message }
                Test-Item "$($p.Name) responde" $false $det
            }
        }
    }
}

# --- 7. Ollama + modelo de embedding (OpenCodeRAG) ---------------------------
Write-Host ''
$ollamaLabel = if ($Language -eq 'en') { 'Ollama + embedding model (OpenCodeRAG)' } else { 'Ollama + modelo de embedding (OpenCodeRAG)' }
Write-Host $ollamaLabel

$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCmd) {
    $det = if ($Language -eq 'en') { 'ollama not in PATH — install: irm https://ollama.com/install.ps1 | iex' }
           else { 'ollama nao esta no PATH — instale: irm https://ollama.com/install.ps1 | iex' }
    Test-Item 'ollama instalado' $false $det -Aviso
} else {
    Test-Item 'ollama instalado' $true $ollamaCmd.Source

    # Servico respondendo?
    $ollamaPort = 11434
    $ollamaUp = $false
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$ollamaPort/" -TimeoutSec 5 -UseBasicParsing -ErrorAction SilentlyContinue
        $ollamaUp = ($resp.StatusCode -eq 200)
    } catch { $ollamaUp = $false }

    if ($ollamaUp) {
        Test-Item 'ollama serve (porta 11434)' $true 'respondendo'
    } else {
        $det = if ($Language -eq 'en') { 'not responding — run: ollama serve' }
               else { 'nao responde — rode: ollama serve' }
        Test-Item 'ollama serve (porta 11434)' $false $det -Aviso
    }

    # Modelo nomic-embed-text presente?
    $embedModel = 'nomic-embed-text:latest'
    $modelFound = $false
    try {
        $raw = & ollama list 2>&1
        if ($LASTEXITCODE -eq 0) {
            $lines = ($raw -join "`n") -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^NAME' }
            foreach ($line in $lines) {
                $parts = ($line -split '\s+', 2)
                if ($parts.Count -gt 0) {
                    $mName = $parts[0].Trim()
                    if ($mName -eq $embedModel -or $mName -match '^nomic-embed-text') {
                        $modelFound = $true
                        break
                    }
                }
            }
        }
    } catch { }

    if ($modelFound) {
        Test-Item "modelo $embedModel" $true 'disponivel localmente'
    } else {
        $det = if ($Language -eq 'en') { "not found — pull: ollama pull $embedModel" }
               else { "nao encontrado — puxe: ollama pull $embedModel" }
        Test-Item "modelo $embedModel" $false $det -Aviso
    }

    # Health check embedding (so se servico up e modelo presente)
    if ($ollamaUp -and $modelFound -and -not $SkipNetwork) {
        try {
            $body = @{ model = $embedModel; prompt = 'test' } | ConvertTo-Json -Compress
            $emb = Invoke-RestMethod -Uri "http://localhost:$ollamaPort/api/embeddings" `
                                     -Method Post -Body $body `
                                     -ContentType 'application/json' `
                                     -TimeoutSec 30
            $dim = if ($emb.embedding) { $emb.embedding.Count } else { 0 }
            Test-Item 'embedding health check' ($dim -gt 0) "dimensao: $dim"
        } catch {
            Test-Item 'embedding health check' $false $_.Exception.Message -Aviso
        }
    }
}

# --- 8. Browser Harness (controle de browser via CDP) -------------------------
Write-Host ''
$bhLabel = if ($Language -eq 'en') { 'Browser Harness (browser control via CDP)' } else { 'Browser Harness (controle de browser via CDP)' }
Write-Host $bhLabel

$uvCmd = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uvCmd) {
    $det = if ($Language -eq 'en') { 'uv not in PATH — browser-harness requires uv. Install: irm https://astral.sh/uv/install.ps1 | iex' }
           else { 'uv nao esta no PATH — browser-harness requer uv. Instale: irm https://astral.sh/uv/install.ps1 | iex' }
    Test-Item 'uv instalado' $false $det -Aviso
} else {
    Test-Item 'uv instalado' $true $uvCmd.Source

    $bhCmd = Get-Command browser-harness -ErrorAction SilentlyContinue
    if (-not $bhCmd) {
        $det = if ($Language -eq 'en') { 'not installed — run: uv tool install --python 3.12 --upgrade --force browser-harness' }
               else { 'nao instalado — rode: uv tool install --python 3.12 --upgrade --force browser-harness' }
        Test-Item 'browser-harness instalado' $false $det -Aviso
    } else {
        Test-Item 'browser-harness instalado' $true $bhCmd.Source

        # Skill registrada?
        $bhSkillPath = Join-Path $TargetRoot 'skills\browser-harness\SKILL.md'
        Test-Item 'browser-harness skill registrada' (Test-Path $bhSkillPath) $bhSkillPath

        # Doctor check (so se nao SkipNetwork)
        if (-not $SkipNetwork) {
            try {
                $doctorOut = & browser-harness --doctor 2>&1
                $doctorText = ($doctorOut -join ' ')
                $chromeOk = $doctorText -match '(?i)chrome running\s*(OK|PASS|running)'
                $daemonOk = $doctorText -match '(?i)daemon alive\s*(OK|PASS|alive)'
                if ($chromeOk) {
                    Test-Item 'browser-harness doctor: chrome' $true 'running'
                } else {
                    Test-Item 'browser-harness doctor: chrome' $false 'not running or CDP not enabled' -Aviso
                }
                if ($daemonOk) {
                    Test-Item 'browser-harness doctor: daemon' $true 'alive'
                } else {
                    Test-Item 'browser-harness doctor: daemon' $false 'not connected — enable chrome://inspect/#remote-debugging' -Aviso
                }
            } catch {
                Test-Item 'browser-harness --doctor' $false $_.Exception.Message -Aviso
            }
        }
    }
}

# --- Resumo ------------------------------------------------------------------
Write-Host ''
if ($erros.Count -eq 0) {
    $extra = if ($avisos.Count) { " - $($avisos.Count) $($L.Warnings), $($L.NoneBlocking)" } else { '' }
    Write-Host "$($L.Result): OK$extra" -ForegroundColor Green
    exit 0
}
Write-Host "$($L.Result): $($erros.Count) $($L.Failures)" -ForegroundColor Red
$erros | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
