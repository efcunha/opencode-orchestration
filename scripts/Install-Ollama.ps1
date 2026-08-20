<#
.SYNOPSIS
    Instala Ollama silenciosamente (se ausente), puxa nomic-embed-text:latest
    e garante que o servico esta pronto para o OpenCodeRAG.

.DESCRIPTION
    Pipeline:
      1. Verifica se `ollama` ja esta no PATH.
      2. Se ausente, baixa e executa o instalador oficial silenciosamente.
      3. Aguarda o servico Ollama ficar pronto (porta 11434).
      4. Verifica se nomic-embed-text:latest ja esta puxado.
      5. Se ausente, executa `ollama pull nomic-embed-text:latest`.
      6. Valida que o modelo responde (health check de embedding).

    NAO bloqueia a instalacao principal se falhar — reporta warnings.
    Projetado para ser chamado por Install-Orchestration.ps1 com -Force.

.PARAMETER Force
    Efetiva a instalacao. Sem isto, apenas simula (dry-run).

.PARAMETER SkipInstall
    Pula a instalacao do Ollama (so puxa o modelo se Ollama ja existe).

.PARAMETER ModelName
    Nome do modelo de embedding a puxar. Default: nomic-embed-text:latest.

.PARAMETER OllamaPort
    Porta do servico Ollama. Default: 11434.

.PARAMETER TimeoutSeconds
    Tempo maximo para aguardar o servico Ollama iniciar. Default: 120.

.EXAMPLE
    .\Install-Ollama.ps1 -Force
    .\Install-Ollama.ps1 -Force -ModelName "nomic-embed-text:v1.5"
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipInstall,
    [string]$ModelName = 'nomic-embed-text:latest',
    [int]$OllamaPort = 11434,
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers -----------------------------------------------------------------

function Write-Step {
    param([string]$Text)
    Write-Host "  [ollama] $Text"
}

function Write-StepOk {
    param([string]$Text)
    Write-Host "  [ollama] OK    $Text" -ForegroundColor Green
}

function Write-StepWarn {
    param([string]$Text)
    Write-Host "  [ollama] AVISO $Text" -ForegroundColor Yellow
}

function Write-StepFail {
    param([string]$Text)
    Write-Host "  [ollama] FALHA $Text" -ForegroundColor Red
}

function Test-OllamaInPath {
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
}

function Test-OllamaService {
    <# Testa se o servico Ollama responde na porta configurada. #>
    param([int]$Port = 11434)
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port/" -TimeoutSec 5 -UseBasicParsing -ErrorAction SilentlyContinue
        return ($response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Wait-OllamaService {
    <# Aguarda o servico Ollama ficar pronto, com timeout. #>
    param(
        [int]$Port = 11434,
        [int]$MaxWaitSeconds = 120
    )
    $elapsed = 0
    $interval = 3
    while ($elapsed -lt $MaxWaitSeconds) {
        if (Test-OllamaService -Port $Port) { return $true }
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        Write-Host "    aguardando servico Ollama (${elapsed}s / ${MaxWaitSeconds}s)..." -ForegroundColor DarkGray
    }
    return $false
}

function Get-OllamaModels {
    <# Lista modelos locais via `ollama list`. Retorna array de nomes. #>
    try {
        $raw = & ollama list 2>&1
        if ($LASTEXITCODE -ne 0) { return @() }
        $lines = ($raw -join "`n") -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^NAME' }
        $models = @()
        foreach ($line in $lines) {
            $parts = $line -split '\s+', 2
            if ($parts.Count -gt 0 -and $parts[0]) {
                $models += $parts[0].Trim()
            }
        }
        return $models
    } catch {
        return @()
    }
}

function Test-ModelPresent {
    param([string]$Name)
    $models = Get-OllamaModels
    # Checa tanto nome exato quanto sem tag (:latest implicito)
    $baseName = ($Name -split ':')[0]
    foreach ($m in $models) {
        if ($m -eq $Name) { return $true }
        if ($m -eq $baseName) { return $true }
        if ($m -match "^$([regex]::Escape($baseName)):") { return $true }
    }
    return $false
}

function Start-OllamaService {
    <# Inicia o servico Ollama se nao estiver rodando. #>
    if (Test-OllamaService -Port $OllamaPort) { return $true }

    Write-Step "Servico nao detectado na porta $OllamaPort. Iniciando..."

    # Tenta via `ollama serve` em background
    $ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollamaExe) { return $false }

    # No Windows, Ollama geralmente roda como processo de usuario (tray app).
    # Tentar iniciar via Start-Process sem janela.
    try {
        Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden -PassThru | Out-Null
        Start-Sleep -Seconds 2
        return (Wait-OllamaService -Port $OllamaPort -MaxWaitSeconds 30)
    } catch {
        # Pode ja ter sido iniciado pelo instalador
        return (Test-OllamaService -Port $OllamaPort)
    }
}

# --- Main --------------------------------------------------------------------

$result = [pscustomobject]@{
    OllamaInstalled  = $false
    OllamaWasPresent = $false
    ServiceReady     = $false
    ModelPulled      = $false
    ModelWasPresent  = $false
    Success          = $false
    Warnings         = @()
}

# 1. Verificar se Ollama ja esta instalado
Write-Step "Verificando se Ollama esta no PATH..."

if (Test-OllamaInPath) {
    $ollamaSrc = (Get-Command ollama).Source
    Write-StepOk "Ollama encontrado: $ollamaSrc"
    $result.OllamaInstalled = $true
    $result.OllamaWasPresent = $true
} else {
    Write-Step "Ollama NAO encontrado no PATH."

    if ($SkipInstall) {
        Write-StepWarn "SkipInstall ativo — pulando instalacao. OpenCodeRAG nao tera embeddings locais."
        $result.Warnings += "Ollama nao instalado (SkipInstall)"
        return $result
    }

    if (-not $Force) {
        Write-Step "Simulacao: instalaria Ollama via script oficial (irm https://ollama.com/install.ps1 | iex)"
        Write-Step "Simulacao: puxaria modelo $ModelName"
        $result.Warnings += "Simulacao — nada executado"
        return $result
    }

    # 2. Instalar Ollama silenciosamente
    Write-Step "Instalando Ollama via script oficial do ollama.com..."
    Write-Step "(Fonte: https://ollama.com/install.ps1)"

    try {
        # O script oficial do Ollama para Windows:
        # - Baixa OllamaSetup.exe
        # - Executa com /VERYSILENT /NORESTART /SP-
        # - Adiciona ollama ao PATH do usuario
        $installScript = Invoke-RestMethod -Uri 'https://ollama.com/install.ps1' -TimeoutSec 30
        # Executar o script baixado
        $scriptBlock = [scriptblock]::Create($installScript)
        & $scriptBlock
        
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Script de instalacao retornou exit code $LASTEXITCODE"
        }
    } catch {
        # Fallback: baixar OllamaSetup.exe e rodar /VERYSILENT
        Write-Step "Script oficial falhou ($($_.Exception.Message)). Tentando download direto..."
        try {
            $setupUrl = 'https://ollama.com/download/OllamaSetup.exe'
            $setupPath = Join-Path $env:TEMP 'OllamaSetup.exe'
            
            Write-Step "Baixando $setupUrl..."
            Invoke-WebRequest -Uri $setupUrl -OutFile $setupPath -TimeoutSec 300 -UseBasicParsing
            
            Write-Step "Executando instalacao silenciosa..."
            $proc = Start-Process -FilePath $setupPath -ArgumentList '/VERYSILENT', '/NORESTART', '/SP-' `
                                  -Wait -PassThru -WindowStyle Hidden
            
            if ($proc.ExitCode -ne 0) {
                throw "Instalador retornou exit code $($proc.ExitCode)"
            }
            
            # Limpar installer
            Remove-Item $setupPath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-StepFail "Nao foi possivel instalar Ollama: $($_.Exception.Message)"
            $result.Warnings += "Falha na instalacao do Ollama: $($_.Exception.Message)"
            return $result
        }
    }

    # Atualizar PATH da sessao para encontrar o ollama recem-instalado
    $ollamaPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama'),
        (Join-Path $env:ProgramFiles 'Ollama'),
        (Join-Path ${env:ProgramFiles(x86)} 'Ollama')
    )
    foreach ($p in $ollamaPaths) {
        if ((Test-Path $p) -and ($env:PATH -notmatch [regex]::Escape($p))) {
            $env:PATH = "$p;$env:PATH"
        }
    }

    # Revalidar
    if (Test-OllamaInPath) {
        Write-StepOk "Ollama instalado com sucesso: $((Get-Command ollama).Source)"
        $result.OllamaInstalled = $true
    } else {
        Write-StepFail "Ollama instalado mas nao encontrado no PATH. Pode ser necessario reiniciar o terminal."
        $result.Warnings += "Ollama instalado mas nao no PATH da sessao atual"
        return $result
    }
}

# 3. Garantir que o servico esta rodando
Write-Step "Verificando servico Ollama na porta $OllamaPort..."

if (Test-OllamaService -Port $OllamaPort) {
    Write-StepOk "Servico Ollama respondendo em localhost:$OllamaPort"
    $result.ServiceReady = $true
} else {
    Write-Step "Servico nao detectado. Tentando iniciar..."
    
    if (-not $Force) {
        Write-Step "Simulacao: iniciaria servico Ollama"
        $result.ServiceReady = $false
        $result.Warnings += "Simulacao — servico nao iniciado"
    } else {
        $started = Start-OllamaService
        if ($started) {
            Write-StepOk "Servico Ollama iniciado e respondendo"
            $result.ServiceReady = $true
        } else {
            # Ultima tentativa: aguardar mais (o instalador pode ter iniciado o servico com delay)
            Write-Step "Aguardando servico Ollama ficar pronto (max ${TimeoutSeconds}s)..."
            $ready = Wait-OllamaService -Port $OllamaPort -MaxWaitSeconds $TimeoutSeconds
            if ($ready) {
                Write-StepOk "Servico Ollama pronto"
                $result.ServiceReady = $true
            } else {
                Write-StepFail "Servico Ollama nao respondeu em ${TimeoutSeconds}s. Verifique manualmente: ollama serve"
                $result.Warnings += "Servico Ollama nao iniciou (timeout ${TimeoutSeconds}s)"
                return $result
            }
        }
    }
}

# 4. Verificar/Puxar modelo de embedding
Write-Step "Verificando modelo $ModelName..."

if (Test-ModelPresent -Name $ModelName) {
    Write-StepOk "Modelo $ModelName ja disponivel localmente"
    $result.ModelPulled = $true
    $result.ModelWasPresent = $true
} else {
    Write-Step "Modelo $ModelName NAO encontrado localmente."
    
    if (-not $Force) {
        Write-Step "Simulacao: puxaria $ModelName (~274 MB)"
        $result.Warnings += "Simulacao — modelo nao puxado"
    } else {
        Write-Step "Puxando $ModelName (isso pode levar alguns minutos na primeira vez)..."
        try {
            & ollama pull $ModelName 2>&1 | ForEach-Object {
                $line = $_.ToString().Trim()
                if ($line) { Write-Host "    $line" -ForegroundColor DarkGray }
            }
            if ($LASTEXITCODE -ne 0) {
                throw "ollama pull retornou exit code $LASTEXITCODE"
            }
            
            # Validar que o modelo agora esta presente
            if (Test-ModelPresent -Name $ModelName) {
                Write-StepOk "Modelo $ModelName puxado com sucesso"
                $result.ModelPulled = $true
            } else {
                throw "Modelo nao aparece em 'ollama list' apos pull"
            }
        } catch {
            Write-StepFail "Falha ao puxar $ModelName : $($_.Exception.Message)"
            $result.Warnings += "Falha no pull de $ModelName : $($_.Exception.Message)"
            return $result
        }
    }
}

# 5. Health check — validar que o modelo de embedding responde
if ($result.ServiceReady -and ($result.ModelPulled -or $result.ModelWasPresent)) {
    Write-Step "Validando embedding (health check)..."
    try {
        $body = @{
            model  = $ModelName
            prompt = 'test'
        } | ConvertTo-Json -Compress
        
        $response = Invoke-RestMethod -Uri "http://localhost:$OllamaPort/api/embeddings" `
                                      -Method Post -Body $body `
                                      -ContentType 'application/json' `
                                      -TimeoutSec 30
        
        if ($response.embedding -and $response.embedding.Count -gt 0) {
            Write-StepOk "Embedding funcional (dimensao: $($response.embedding.Count))"
            $result.Success = $true
        } else {
            Write-StepWarn "Resposta inesperada do endpoint de embedding"
            $result.Warnings += "Health check: resposta sem vetor de embedding"
            $result.Success = $true  # Nao-bloqueante
        }
    } catch {
        Write-StepWarn "Health check falhou: $($_.Exception.Message)"
        Write-Step "O modelo esta instalado mas pode precisar de warmup. Tente: ollama run $ModelName"
        $result.Warnings += "Health check falhou (pode ser warmup): $($_.Exception.Message)"
        $result.Success = $true  # Modelo puxado com sucesso, health check e best-effort
    }
} elseif (-not $Force) {
    $result.Success = $true  # Simulacao e considerada sucesso
}

# --- Resumo ------------------------------------------------------------------
Write-Host ''
if ($result.Success) {
    if ($result.Warnings.Count -gt 0) {
        Write-Step "Concluido com $($result.Warnings.Count) aviso(s):"
        $result.Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    } else {
        Write-StepOk "Ollama + $ModelName prontos para OpenCodeRAG"
    }
} else {
    Write-StepWarn "Ollama setup incompleto — OpenCodeRAG pode nao funcionar sem configuracao manual"
}

return $result
