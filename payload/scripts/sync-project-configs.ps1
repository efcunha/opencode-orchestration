<#
.SYNOPSIS
    Copia os opencode.json de projeto entre os repos de projeto e este repo.

.DESCRIPTION
    Os arquivos opencode.json de ameg e cip estao ignorados nos respectivos
    repos (.gitignore:71 e .gitignore:104) e essa decisao esta CORRETA: eles
    carregam caminho absoluto de maquina — C:/nvm4w/nodejs/node_modules/...,
    C:\Users\ECUNHA\.pencil\... — que quebraria em qualquer outro usuario ou
    maquina. Commita-los nos repos de projeto empurraria configuracao pessoal
    para dentro de codigo compartilhado.

    Mas ignorado nos projetos significava, ate agora, existir em UMA copia
    apenas: um disco perdido levava a configuracao junto. Este script da a eles
    um lar versionado aqui, onde caminho de maquina e esperado e nao atrapalha
    ninguem.

    Nao usa symlink de proposito. Symlink no Windows exige Developer Mode ou
    shell elevado, o que tornaria o restore inutilizavel exatamente na hora em
    que ele importa — maquina nova, sem setup.

.PARAMETER Backup
    Le os opencode.json dos projetos e escreve em project-configs/ neste repo.
    Direcao a usar depois de mexer na config de um projeto.

.PARAMETER Restore
    Le project-configs/ e escreve nos projetos. SOBRESCREVE os arquivos vivos.
    Exige -Force para efetivar; sem ele, apenas relata o que faria.

.PARAMETER Force
    Confirma a sobrescrita em -Restore.

.EXAMPLE
    .\sync-project-configs.ps1 -Backup

.EXAMPLE
    .\sync-project-configs.ps1 -Restore          # so relata
    .\sync-project-configs.ps1 -Restore -Force   # efetiva
#>
[CmdletBinding(DefaultParameterSetName = 'Backup')]
param(
    [Parameter(ParameterSetName = 'Backup')]
    [switch]$Backup,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$store    = Join-Path $repoRoot 'project-configs'

# Projetos cobertos. Para adicionar um, basta uma linha aqui.
$projects = [ordered]@{
    'cloudpilot-deploy' = 'D:\cloudpilot-deploy\opencode.json'
    'ameg'              = 'D:\ameg\opencode.json'
    'cip'               = 'D:\cip\opencode.json'
}

function Test-JsonFile {
    param([string]$Path)
    try {
        $null = Get-Content -Path $Path -Raw | ConvertFrom-Json
        return $true
    } catch {
        return $false
    }
}

if (-not (Test-Path $store)) {
    New-Item -ItemType Directory -Path $store -Force | Out-Null
}

$rows = @()

foreach ($name in $projects.Keys) {
    $live   = $projects[$name]
    $stored = Join-Path $store "$name.opencode.json"

    if ($Restore) {
        if (-not (Test-Path $stored)) {
            $rows += [pscustomobject]@{ Projeto = $name; Acao = 'pulado'; Motivo = 'sem copia em project-configs' }
            continue
        }
        if (-not (Test-JsonFile $stored)) {
            $rows += [pscustomobject]@{ Projeto = $name; Acao = 'ABORTADO'; Motivo = 'copia versionada nao e JSON valido' }
            continue
        }
        if (-not $Force) {
            $existe = if (Test-Path $live) { 'sobrescreveria' } else { 'criaria' }
            $rows += [pscustomobject]@{ Projeto = $name; Acao = 'simulado'; Motivo = "$existe $live" }
            continue
        }
        $parent = Split-Path -Parent $live
        if (-not (Test-Path $parent)) {
            $rows += [pscustomobject]@{ Projeto = $name; Acao = 'pulado'; Motivo = "diretorio do projeto nao existe: $parent" }
            continue
        }
        Copy-Item -Path $stored -Destination $live -Force
        $rows += [pscustomobject]@{ Projeto = $name; Acao = 'restaurado'; Motivo = $live }
        continue
    }

    # Backup e o default
    if (-not (Test-Path $live)) {
        $rows += [pscustomobject]@{ Projeto = $name; Acao = 'pulado'; Motivo = "nao existe: $live" }
        continue
    }
    if (-not (Test-JsonFile $live)) {
        $rows += [pscustomobject]@{ Projeto = $name; Acao = 'ABORTADO'; Motivo = 'config viva nao e JSON valido' }
        continue
    }
    Copy-Item -Path $live -Destination $stored -Force
    $rows += [pscustomobject]@{ Projeto = $name; Acao = 'copiado'; Motivo = $stored }
}

$rows | Format-Table -AutoSize

$problemas = @($rows | Where-Object { $_.Acao -eq 'ABORTADO' })
if ($problemas.Count -gt 0) {
    Write-Error "$($problemas.Count) projeto(s) abortaram — veja a tabela acima."
    exit 1
}

if ($Restore -and -not $Force) {
    Write-Host ''
    Write-Host 'Nada foi escrito. Repita com -Force para efetivar.' -ForegroundColor Yellow
}
