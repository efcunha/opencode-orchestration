<#
.SYNOPSIS
    Copia a configuracao viva do opencode para payload/ neste repo.

.DESCRIPTION
    A configuracao viva em ~/.config/opencode e a fonte de verdade: e o que o
    opencode le, e ela ja e um repositorio git proprio. Este repo e o
    DISTRIBUIVEL — instalador, documentacao e uma copia offline que permite
    instalar numa maquina limpa sem depender de remoto.

    A direcao e sempre viva -> payload. Nunca o contrario. Editar payload/ na
    mao e erro: o proximo sync sobrescreve. Para mudar a configuracao, edite a
    viva, valide, e sincronize.

    O conjunto de arquivos vem de `git ls-files` na config viva, nao de uma
    lista mantida aqui. Assim o payload reflete exatamente o que esta
    versionado la, e regras de ignore (node_modules, manifests npm, estado de
    UI por maquina) valem automaticamente, sem serem reimplementadas.

    Symlinks nao sao copiados como conteudo. Git os guarda como link e recria-los
    no Windows exige Developer Mode ou elevacao, o que nao se pode assumir numa
    maquina nova. Eles vao para payload-symlinks.json e o instalador os reporta
    como dependencia externa em vez de fingir que resolveu.

.PARAMETER LiveRoot
    Raiz da config viva. Default: ~/.config/opencode.

.PARAMETER Check
    Nao escreve nada. Compara e sai com codigo 1 se houver divergencia.
    Serve para CI ou para conferir antes de commitar.

.EXAMPLE
    .\Sync-Payload.ps1
    .\Sync-Payload.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$LiveRoot = (Join-Path $env:USERPROFILE '.config\opencode'),
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$payloadRoot  = Join-Path $repoRoot 'payload'
$linkManifest = Join-Path $repoRoot 'payload-symlinks.json'

if (-not (Test-Path $LiveRoot)) {
    throw "Config viva nao encontrada em: $LiveRoot"
}
if (-not (Test-Path (Join-Path $LiveRoot '.git'))) {
    throw "Config viva nao e repositorio git: $LiveRoot — o conjunto de arquivos vem de 'git ls-files'."
}

Push-Location $LiveRoot
try {
    $tracked = @(git ls-files) | Where-Object { $_ }
} finally {
    Pop-Location
}

if ($tracked.Count -eq 0) {
    throw "git ls-files nao retornou nada em $LiveRoot."
}

$copied  = 0
$skipped = 0
$drift   = @()
$links   = @()

foreach ($rel in $tracked) {
    $srcPath = Join-Path $LiveRoot ($rel -replace '/', '\')
    $dstPath = Join-Path $payloadRoot ($rel -replace '/', '\')

    if (-not (Test-Path $srcPath)) {
        $drift += [pscustomobject]@{ Arquivo = $rel; Situacao = 'rastreado mas ausente na viva' }
        continue
    }

    $item = Get-Item $srcPath -Force
    if ($item.LinkType) {
        $links += [pscustomobject]@{ path = $rel; linkType = $item.LinkType; target = $item.Target }
        $skipped++
        continue
    }

    $srcHash = (Get-FileHash $srcPath -Algorithm SHA256).Hash
    $dstHash = if (Test-Path $dstPath) { (Get-FileHash $dstPath -Algorithm SHA256).Hash } else { $null }

    if ($srcHash -eq $dstHash) { continue }

    if ($Check) {
        $situacao = if ($null -eq $dstHash) { 'ausente no payload' } else { 'conteudo diferente' }
        $drift += [pscustomobject]@{ Arquivo = $rel; Situacao = $situacao }
        continue
    }

    $dstDir = Split-Path -Parent $dstPath
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -Path $srcPath -Destination $dstPath -Force
    $copied++
}

# Arquivos que sobraram no payload e nao existem mais na viva
if (Test-Path $payloadRoot) {
    $trackedSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]($tracked | ForEach-Object { ($_ -replace '/', '\') }),
        [StringComparer]::OrdinalIgnoreCase
    )
    $orfaos = @()
    foreach ($f in Get-ChildItem $payloadRoot -Recurse -File -Force) {
        $rel = $f.FullName.Substring($payloadRoot.Length).TrimStart('\')
        if (-not $trackedSet.Contains($rel)) { $orfaos += $rel }
    }
    foreach ($o in $orfaos) {
        if ($Check) {
            $drift += [pscustomobject]@{ Arquivo = $o; Situacao = 'orfao no payload (nao mais rastreado)' }
        } else {
            Remove-Item (Join-Path $payloadRoot $o) -Force
        }
    }
}

if (-not $Check) {
    $links | ConvertTo-Json -Depth 4 | Set-Content -Path $linkManifest -Encoding utf8
}

Write-Host ''
Write-Host "Config viva : $LiveRoot"
Write-Host "Payload     : $payloadRoot"
Write-Host "Rastreados  : $($tracked.Count)"

if ($Check) {
    if ($drift.Count -eq 0) {
        Write-Host 'Divergencia : nenhuma — payload em sincronia.' -ForegroundColor Green
        exit 0
    }
    Write-Host "Divergencia : $($drift.Count) arquivo(s)" -ForegroundColor Yellow
    $drift | Format-Table -AutoSize
    Write-Host 'Rode sem -Check para sincronizar.' -ForegroundColor Yellow
    exit 1
}

Write-Host "Copiados    : $copied"
Write-Host "Symlinks    : $skipped (registrados em payload-symlinks.json, nao copiados)"
if ($links.Count -gt 0) {
    $links | Select-Object path, target | Format-Table -AutoSize
}
