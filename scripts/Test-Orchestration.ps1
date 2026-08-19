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
    [switch]$SkipNetwork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$erros  = @()
$avisos = @()

function Test-Item {
    param([string]$Nome, [bool]$Ok, [string]$Detalhe = '', [switch]$Aviso)
    $marca = if ($Ok) { 'PASSA' } elseif ($Aviso) { 'AVISO' } else { 'FALHA' }
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
Write-Host "Verificando: $TargetRoot"

# --- 1. Arquivos -------------------------------------------------------------
Write-Host ''
Write-Host 'Arquivos'
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
Write-Host 'Variaveis de ambiente (somente presenca, derivado do manifesto LLM ativo)'

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
        Write-Host '  (nenhum provider ativo requer env var)' -ForegroundColor DarkGray
    } else {
        Write-Host "  fonte: $cfgUsed" -ForegroundColor DarkGray
    }
}

# --- 3. MCPs declarados ------------------------------------------------------
Write-Host ''
Write-Host 'MCPs declarados'
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
Write-Host 'Resolucao (de um diretorio vazio)'
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
Write-Host 'Referencias de modelo'
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

foreach ($qf in $questFiles) {
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
    Write-Host 'Conectividade dos providers LLM (do manifesto ativo)'
    if (-not $cfgUsed) {
        Write-Host '  sem manifesto - pulado' -ForegroundColor DarkGray
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

# --- Resumo ------------------------------------------------------------------
Write-Host ''
if ($erros.Count -eq 0) {
    $extra = if ($avisos.Count) { " - $($avisos.Count) aviso(s), nenhum bloqueante" } else { '' }
    Write-Host "Resultado: OK$extra" -ForegroundColor Green
    exit 0
}
Write-Host "Resultado: $($erros.Count) falha(s)" -ForegroundColor Red
$erros | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
