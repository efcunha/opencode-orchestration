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
    config — falha na primeira chamada, em silencio. Conferir cada referencia
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
    # Remove blocos /* */ e linhas que COMECAM com // — nao toca em "https://",
    # que seria destruido se o corte fosse por ocorrencia de // em qualquer posicao.
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

# --- 2. Variaveis de ambiente ------------------------------------------------
Write-Host ''
Write-Host 'Variaveis de ambiente (somente presenca)'
foreach ($v in @('MINIMAX_API_KEY', 'DEEPSEEK_API_KEY')) {
    Test-Item $v (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($v)))
}
foreach ($v in @('CONTEXT7_API_KEY', 'GITHUB_API_KEY', 'JIRA_API_TOKEN')) {
    Test-Item "$v (opcional)" (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($v))) -Aviso
}

# --- 3. Resolucao pelo opencode ----------------------------------------------
# Rodar de um diretorio vazio e o ponto: prova que a resolucao vem da config
# global, e nao de algum opencode.json de projeto.
Write-Host ''
Write-Host 'Resolucao (de um diretorio vazio)'
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('oc-verify-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$modelos = @()
$agentes = @()
try {
    Push-Location $tmpDir
    $modelos = @(& opencode models 2>&1) | Where-Object { $_ -match '^\S+/\S+$' }
    $agentes = @(& opencode agent list 2>&1)
} catch {
    Test-Item 'opencode responde' $false $_.Exception.Message
} finally {
    if ((Get-Location).Path -eq $tmpDir) { Pop-Location }
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Test-Item 'opencode models retorna modelos' ($modelos.Count -gt 0) "$($modelos.Count) modelo(s)"
foreach ($m in $modelos) { Write-Host "         $m" -ForegroundColor DarkGray }

# Esperado derivado do whitelist da config, nao de lista fixa
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

# --- 4. Referencias de modelo ------------------------------------------------
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

# Estagios de quest. Regex em vez de parser YAML de proposito: nao ha dependencia
# de YAML garantida numa maquina recem-instalada.
foreach ($qf in $questFiles) {
    # "model:" no inicio da linha aparece tambem em prosa dentro de blocos
    # context/description. Depois de tirar pontuacao final, so vale o que tem a
    # forma providerID/modelID; o resto e texto e nao declaracao. Campo model de
    # estagio malformado nao escapa por aqui — a validacao de schema do proprio
    # plugin rejeita na carga da quest.
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

# --- 5. Conectividade --------------------------------------------------------
if (-not $SkipNetwork) {
    Write-Host ''
    Write-Host 'Conectividade dos providers'
    $alvos = @(
        @{ Nome = 'DeepSeek'; Url = 'https://api.deepseek.com/chat/completions';  EnvVar = 'DEEPSEEK_API_KEY'; Modelo = 'deepseek-v4-flash' }
        @{ Nome = 'MiniMax';  Url = 'https://api.minimax.io/v1/chat/completions'; EnvVar = 'MINIMAX_API_KEY';  Modelo = 'MiniMax-M3' }
    )
    foreach ($t in $alvos) {
        $chave = [Environment]::GetEnvironmentVariable($t.EnvVar)
        if ([string]::IsNullOrWhiteSpace($chave)) {
            Test-Item "$($t.Nome) responde" $false "$($t.EnvVar) nao definida" -Aviso
            continue
        }
        $body = @{ model = $t.Modelo; messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 4 } |
                ConvertTo-Json -Depth 5 -Compress
        try {
            $r = Invoke-RestMethod -Uri $t.Url -Method Post -TimeoutSec 45 -Body $body `
                 -Headers @{ Authorization = "Bearer $chave"; 'Content-Type' = 'application/json' }
            Test-Item "$($t.Nome) responde" ($null -ne $r) "modelo retornado: $($r.model)"
        } catch {
            $det = if ($_.ErrorDetails.Message) { ($_.ErrorDetails.Message -replace '\s+', ' ') } else { $_.Exception.Message }
            Test-Item "$($t.Nome) responde" $false $det
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
