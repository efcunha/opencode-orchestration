<#
.SYNOPSIS
    Compara o payload deste repo com a copia instalada em TargetRoot.

.DESCRIPTION
    No design antigo isto sincronizava config viva -> payload. Agora o payload/
    deste repo E a fonte de verdade (e um template). Sync-Payload.ps1 virou:
    renderiza o template localmente, compara com o que ja esta no destino, e
    reporta divergencias. Use -Check antes de commitar instalacao em massa.

    Para usar:
      .\Sync-Payload.ps1              # relata, nao escreve
      .\Sync-Payload.ps1 -Check       # sai 1 se houver divergencia
      .\Sync-Payload.ps1 -Force       # efetiva (na pratica: re-rodar Install -Force)

.PARAMETER TargetRoot
    Configuracao ja instalada. Default: ~/.config/opencode.

.PARAMETER Force
    Alias para re-instalar. Como nada aqui escreve no payload, apenas
    reporta que Install-Orchestration.ps1 -Force deve ser rodado.

.PARAMETER Check
    Sai 1 se o que renderiza difere do destino. Use em CI.

.EXAMPLE
    .\Sync-Payload.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE '.config\opencode'),
    [switch]$Force,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot    = Split-Path -Parent $PSScriptRoot
$payloadRoot = Join-Path $repoRoot 'payload'

if (-not (Test-Path $payloadRoot)) {
    throw "payload/ nao existe. Rode de dentro do repo."
}

$uh = $env:ORCH_USER_HOME
if (-not $uh) { $uh = $env:USERPROFILE }
$nm = $env:ORCH_NPM_GLOBAL_NODE_MODULES
if (-not $nm) { $r = & npm root -g 2>$null; if ($LASTEXITCODE -eq 0) { $nm = $r.Trim() } }
$ua = if ($uh) { Join-Path $uh '.agents' } else { '' }

$vars = @{
    nodeModules = $nm
    userHome    = $uh
    userAgents  = $ua
}

function Resolve-Template {
    param([string]$Text, [hashtable]$Vars)
    $out = $Text
    foreach ($k in $Vars.Keys) {
        $v = [string]$Vars[$k]
        $v = $v.Replace('\', '/')
        $out = $out.Replace("{{$k}}", $v)
    }
    return $out
}

function Resolve-LlmConfigLocal {
    [CmdletBinding()]
    param()

    $defaults    = Join-Path $repoRoot 'scripts\llm-defaults.json'
    $userOverride = Join-Path $repoRoot 'config\llm-providers.json'
    $source = $null
    if (Test-Path $userOverride) {
        $source = Get-Content $userOverride -Raw | ConvertFrom-Json
    } elseif (Test-Path $defaults) {
        $source = Get-Content $defaults -Raw | ConvertFrom-Json
    } else {
        return @{}
    }

    $out = @{
        modelDefault       = [string]$source.model
        smallModelDefault  = [string]$source.small_model
    }
    $ep = @($source.enabled_providers)
    $out.enabledProvidersList = '[' + (($ep | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'

    foreach ($s in @('plan','build','review','bugfix','general','explore')) {
        $a = $source.agents.PSObject.Properties | Where-Object { $_.Name -eq $s }
        if (-not $a) { continue }
        $cfg = $a.Value
        $cap = (Get-Culture).TextInfo.ToTitleCase($s)
        $out["modelAgent$cap"] = [string]$cfg.model
        $out["tempAgent$cap"]  = [string]$cfg.temperature
        $out["descAgent$cap"]  = [string]$cfg.description
    }

    $provHashtable = [ordered]@{}
    foreach ($p in $source.providers.PSObject.Properties) {
        $provHashtable[$p.Name] = $p.Value
    }
    $out.providersBlock = ($provHashtable | ConvertTo-Json -Depth 12 -Compress)
    return $out
}

$llmVars = Resolve-LlmConfigLocal
foreach ($kv in $llmVars.GetEnumerator()) { $vars[$kv.Key] = [string]$kv.Value }

$drift = @()

foreach ($srcFile in (Get-ChildItem $payloadRoot -Recurse -File -Force)) {
    $rel = $srcFile.FullName.Substring($payloadRoot.Length).TrimStart('\')
    $dstPath = Join-Path $TargetRoot $rel
    $baseName = $srcFile.BaseName
    $ext      = $srcFile.Extension

    if (-not (Test-Path $dstPath)) {
        $drift += [pscustomobject]@{ Arquivo = $rel; Situacao = 'ausente no destino' }
        continue
    }

    $srcText = Get-Content $srcFile.FullName -Raw -Encoding UTF8
    $dstText = Get-Content $dstPath -Raw -Encoding UTF8

    if ($baseName -in @('opencode') -and $ext -in @('.jsonc', '.json')) {
        $expectedText = Resolve-Template -Text $srcText -Vars $vars
        if ($expectedText -ne $dstText) {
            $drift += [pscustomobject]@{ Arquivo = $rel; Situacao = 'conteudo do destino difere da renderizacao do template' }
            continue
        }
    } else {
        $srcHash = (Get-FileHash $srcFile.FullName -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash $dstPath       -Algorithm SHA256).Hash
        if ($srcHash -ne $dstHash) {
            $drift += [pscustomobject]@{ Arquivo = $rel; Situacao = 'hash difere' }
            continue
        }
    }
}

if (-not (Test-Path $TargetRoot)) {
    Write-Host "Destino $TargetRoot nao existe ainda - drift = todos os arquivos do payload estao ausentes." -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Payload    : $payloadRoot"
Write-Host "Destino    : $TargetRoot"
Write-Host "Variaveis  : nodeModules=$nm userHome=$uh userAgents=$ua"
Write-Host ''

if ($drift.Count -eq 0) {
    Write-Host 'Divergencia : nenhuma - payload em sincronia com o destino.' -ForegroundColor Green
    if ($Check) { exit 0 }
    exit 0
}

Write-Host "Divergencia : $($drift.Count) item(s)" -ForegroundColor Yellow
$drift | Format-Table -AutoSize

if ($Check) {
    Write-Host 'Rode Install-Orchestration.ps1 -Force para sincronizar.' -ForegroundColor Yellow
    exit 1
}

if ($Force) {
    Write-Host "Sync-Payload.ps1 -Force nao escreve no payload. Para sincronizar o destino, rode:" -ForegroundColor Yellow
    Write-Host "  .\scripts\Install-Orchestration.ps1 -Force" -ForegroundColor Yellow
}
