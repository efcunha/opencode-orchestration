<#
.SYNOPSIS
    Instala a orquestracao multi-LLM do opencode nesta maquina.

.DESCRIPTION
    Copia payload/ para ~/.config/opencode, restaura os opencode.json de
    projeto e verifica o resultado. Funciona offline: o payload e completo.

    SIMULA POR DEFAULT. Sem -Force nada e escrito — o script relata o que faria
    e sai. Isso e deliberado: o destino pode ja conter uma configuracao em uso,
    e sobrescrever config de ferramenta sem aviso e como perder trabalho.

    Com -Force, a configuracao existente e copiada para _backup-<timestamp>/
    dentro deste repo ANTES de qualquer escrita.

    O que o instalador NAO faz, e por que:
      - Nao define variaveis de ambiente. Ele checa e reporta as que faltam.
        Gravar chave de API por script significa a chave passar por linha de
        comando e historico de shell.
      - Nao cria symlinks. Recriar symlink no Windows exige Developer Mode ou
        elevacao. Os links esperados sao reportados como dependencia externa.
      - Nao instala opencode, node, git nem os binarios de MCP. Checa e falha
        cedo se faltarem.

.PARAMETER TargetRoot
    Destino da configuracao. Default: ~/.config/opencode.

.PARAMETER Force
    Efetiva a instalacao. Sem isto, apenas simula.

.PARAMETER SkipProjectConfigs
    Nao restaura os opencode.json de projeto.

.EXAMPLE
    .\Install-Orchestration.ps1
    .\Install-Orchestration.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE '.config\opencode'),
    [switch]$Force,
    [switch]$SkipProjectConfigs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$payloadRoot  = Join-Path $repoRoot 'payload'
$linkManifest = Join-Path $repoRoot 'payload-symlinks.json'

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host "-- $Text " -NoNewline
    Write-Host ('-' * [Math]::Max(0, 60 - $Text.Length))
}

$falhas = @()

# --- 1. Payload --------------------------------------------------------------
Write-Section 'Payload'
if (-not (Test-Path $payloadRoot)) {
    throw "payload/ nao existe. Rode scripts\Sync-Payload.ps1 numa maquina que ja tenha a config viva."
}
$payloadFiles = @(Get-ChildItem $payloadRoot -Recurse -File -Force)
Write-Host "  $($payloadFiles.Count) arquivo(s) em $payloadRoot"
if (-not (Test-Path (Join-Path $payloadRoot 'opencode.jsonc'))) {
    $falhas += 'payload/opencode.jsonc ausente — payload incompleto'
    Write-Host '  opencode.jsonc AUSENTE' -ForegroundColor Red
}

# --- 2. Pre-requisitos -------------------------------------------------------
Write-Section 'Pre-requisitos'
foreach ($c in @('opencode', 'node', 'git')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "  OK      $c  ->  $($cmd.Source)"
    } else {
        Write-Host "  FALTA   $c" -ForegroundColor Red
        $falhas += "$c nao esta no PATH"
    }
}
foreach ($c in @('npm', 'uvx', 'docker')) {
    if (Get-Command $c -ErrorAction SilentlyContinue) {
        Write-Host "  OK      $c (opcional)"
    } else {
        Write-Host "  ausente $c (opcional — alguns MCP nao vao subir)" -ForegroundColor Yellow
    }
}

# --- 3. Variaveis de ambiente ------------------------------------------------
# Somente presenca. O valor nunca e lido nem impresso.
Write-Section 'Variaveis de ambiente'
foreach ($v in @('MINIMAX_API_KEY', 'DEEPSEEK_API_KEY')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($v))) {
        Write-Host "  FALTA    $v  (provider nao vai autenticar)" -ForegroundColor Red
        $falhas += "$v nao definida"
    } else {
        Write-Host "  definida $v"
    }
}
foreach ($v in @('CONTEXT7_API_KEY', 'GITHUB_API_KEY', 'JIRA_API_TOKEN')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($v))) {
        Write-Host "  ausente  $v (opcional — MCP correspondente falha)" -ForegroundColor Yellow
    } else {
        Write-Host "  definida $v"
    }
}

# --- 4. Destino --------------------------------------------------------------
Write-Section 'Destino'
$destinoExiste = Test-Path $TargetRoot
Write-Host "  $TargetRoot"
if ($destinoExiste) {
    $existentes = @(Get-ChildItem $TargetRoot -Force -ErrorAction SilentlyContinue)
    Write-Host "  ja existe, com $($existentes.Count) entrada(s) no topo" -ForegroundColor Yellow
    if (Test-Path (Join-Path $TargetRoot '.git')) {
        Write-Host '  e repositorio git — confira commit pendente antes de sobrescrever' -ForegroundColor Yellow
    }
} else {
    Write-Host '  nao existe, sera criado'
}

if ($falhas.Count -gt 0) {
    Write-Section 'Bloqueado'
    $falhas | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Resolva os itens acima e rode de novo.' -ForegroundColor Red
    exit 1
}

if (-not $Force) {
    Write-Section 'Simulacao'
    Write-Host "  Copiaria $($payloadFiles.Count) arquivo(s) para $TargetRoot"
    if ($destinoExiste) { Write-Host "  Faria backup do destino atual em $repoRoot\_backup-<timestamp>\" }
    if (-not $SkipProjectConfigs) { Write-Host '  Restauraria os opencode.json de projeto que existirem' }
    Write-Host ''
    Write-Host 'Nada foi escrito. Repita com -Force para efetivar.' -ForegroundColor Yellow
    exit 0
}

# --- 5. Backup ---------------------------------------------------------------
if ($destinoExiste) {
    Write-Section 'Backup do destino'
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $repoRoot "_backup-$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    # -Force pega arquivos ocultos; node_modules fica de fora por volume.
    Get-ChildItem $TargetRoot -Force | Where-Object { $_.Name -ne 'node_modules' } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $backup -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  $backup"
}

# --- 6. Copia ----------------------------------------------------------------
Write-Section 'Instalando'
if (-not (Test-Path $TargetRoot)) { New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null }
$copiados = 0
foreach ($f in $payloadFiles) {
    $rel = $f.FullName.Substring($payloadRoot.Length).TrimStart('\')
    $dst = Join-Path $TargetRoot $rel
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -Path $f.FullName -Destination $dst -Force
    $copiados++
}
Write-Host "  $copiados arquivo(s) copiado(s)"

# --- 7. Symlinks esperados ---------------------------------------------------
if (Test-Path $linkManifest) {
    $links = @(Get-Content $linkManifest -Raw | ConvertFrom-Json)
    if ($links.Count -gt 0) {
        Write-Section 'Symlinks (nao criados — dependencia externa)'
        foreach ($l in $links) {
            $alvoOk = Test-Path $l.target
            $marca  = if ($alvoOk) { 'alvo existe' } else { 'ALVO AUSENTE' }
            $cor    = if ($alvoOk) { 'Gray' } else { 'Yellow' }
            Write-Host "  $($l.path) -> $($l.target)  [$marca]" -ForegroundColor $cor
        }
        Write-Host '  Criar com New-Item -ItemType SymbolicLink exige Developer Mode ou shell elevado.'
    }
}

# --- 8. Configs de projeto ---------------------------------------------------
if (-not $SkipProjectConfigs) {
    Write-Section 'Configs de projeto'
    $syncScript = Join-Path $TargetRoot 'scripts\sync-project-configs.ps1'
    if (Test-Path $syncScript) {
        & $syncScript -Restore -Force
    } else {
        Write-Host '  sync-project-configs.ps1 nao veio no payload — pulado' -ForegroundColor Yellow
    }
}

# --- 9. Verificacao ----------------------------------------------------------
Write-Section 'Verificacao'
$testScript = Join-Path $PSScriptRoot 'Test-Orchestration.ps1'
if (Test-Path $testScript) {
    & $testScript
} else {
    Write-Host '  Test-Orchestration.ps1 nao encontrado — verifique a mao com: opencode models' -ForegroundColor Yellow
}
