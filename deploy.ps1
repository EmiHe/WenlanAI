param(
  [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Step($msg) {
  Write-Host "[MuMuAINovel] $msg" -ForegroundColor Cyan
}

function Write-Err($msg) {
  Write-Host "[MuMuAINovel] ❌ $msg" -ForegroundColor Red
}

function Test-CommandAvailable($name, $checkArgs = '--version') {
  try {
    & $name $checkArgs *> $null
  } catch {
    throw "Command not found: $name. Please install it and add to PATH."
  }
}

function Get-EnvValue($name, $defaultValue) {
  $line = Get-Content '.env' | Where-Object { $_ -match "^$name=" } | Select-Object -Last 1
  if (-not $line) {
    return $defaultValue
  }

  $value = $line.Substring($name.Length + 1).Trim().Trim('"').Trim("'")
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $defaultValue
  }

  return $value
}

# 读取密码文件：剥离 UTF-8 BOM + 所有空白字符（兼容 Notepad 编辑遗留）
function Read-SecretFile($path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $bytes = $bytes[3..($bytes.Length - 1)]
  }
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  return ($text -replace '\s', '')
}

Write-Step "Checking Docker environment"
Test-CommandAvailable docker

docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
  throw "docker compose plugin not found. Please update Docker Desktop."
}

# 向量（记忆检索）模型不是必需的：backend/embedding/ 里有模型就随镜像打包；没有则由容器首次启动时自动下载
$embeddingModels = @()
if (Test-Path 'backend/embedding') {
  $embeddingModels = @(Get-ChildItem -Path 'backend/embedding' -Directory -Filter 'models--*' | Select-Object -ExpandProperty Name)
}
if ($embeddingModels.Count -gt 0) {
  Write-Step "向量模型：backend/embedding/ 里已有模型，会打包进镜像，容器启动时不用再下载"
  foreach ($modelName in $embeddingModels) {
    Write-Host "  - $modelName"
  }
} else {
  Write-Step "向量模型：backend/embedding/ 里没有模型，容器首次启动时会自动下载中文模型 bge-small-zh（约 95MB）"
  Write-Host "  下载失败也照常启动，只是暂时没有语义检索；之后可在「设置 → 记忆检索」里重新下载"
}

if (-not (Test-Path '.env')) {
  if (-not (Test-Path '.env.example')) {
    throw "Missing .env.example, cannot initialize .env"
  }
  Copy-Item '.env.example' '.env'
  Write-Step "已从 .env.example 生成 .env，请按需修改后重新执行"
}

if (-not (Test-Path 'secrets')) {
  New-Item -ItemType Directory -Path 'secrets' | Out-Null
}

if (-not (Test-Path 'secrets/local_auth_password.txt')) {
  Set-Content -Path 'secrets/local_auth_password.txt' -Value 'CHANGE_ME_LOCAL_AUTH_PASSWORD' -NoNewline -Encoding UTF8
  Write-Err "已生成占位密码文件 secrets/local_auth_password.txt，请编辑为强密码后重新执行"
  exit 1
}

$localPwd = Read-SecretFile 'secrets/local_auth_password.txt'
if ([string]::IsNullOrEmpty($localPwd)) {
  Write-Err "secrets/local_auth_password.txt 内容为空，请填入强密码"
  exit 1
}
if ($localPwd -like 'CHANGE_ME*') {
  Write-Err "检测到默认占位密码，请修改 secrets/local_auth_password.txt 后再部署"
  exit 1
}

$appPort = Get-EnvValue 'APP_PORT' '8000'
$healthUrl = "http://localhost:$appPort/health/ready"

$composeArgs = @('-f', 'docker-compose.yml', '-f', 'docker-compose.prod.yml', 'up', '-d')
if (-not $NoBuild) {
  $composeArgs += '--build'
}

Write-Step "Starting containers (首次构建可能需要 5-10 分钟)"
docker compose @composeArgs

# 首次启动可能要先下载向量模型（约 95MB，下载源不通时三个源各等 30 秒超时），所以多等一会儿；
# 容器退出 / 反复重启就不用干等，直接打出日志
$healthTimeoutSec = 420
$containerName = 'mumuainovel'

function Get-ContainerState($name) {
  # 容器不存在时 docker inspect 会写 stderr；Windows PowerShell 5.1 在 Stop 模式下重定向 stderr 会抛错，这里兜住
  try {
    $state = & docker inspect -f '{{.State.Status}}' $name 2>$null
  } catch {
    return 'missing'
  }
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace("$state")) {
    return 'missing'
  }
  return "$state".Trim()
}

Write-Step "Waiting for readiness endpoint (最多 $($healthTimeoutSec / 60) 分钟，首次启动可能要下载向量模型)"
Write-Host "  看启动进度：docker compose logs -f $containerName" -ForegroundColor Gray
$deadline = (Get-Date).AddSeconds($healthTimeoutSec)
while ($true) {
  try {
    $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    if ($resp.StatusCode -eq 200) {
      Write-Host "✅ 部署成功，访问地址: http://localhost:$appPort" -ForegroundColor Green
      exit 0
    }
  } catch {
    # 还没就绪，继续等
  }

  $state = Get-ContainerState $containerName
  if ($state -ne 'running' -or (Get-Date) -ge $deadline) {
    break
  }
  Start-Sleep -Seconds 5
}

if ($state -ne 'running') {
  Write-Err "容器没有正常运行（状态：$state），最近的日志："
} else {
  Write-Err "服务未在 $($healthTimeoutSec / 60) 分钟内就绪，最近的日志："
}
$ErrorActionPreference = 'Continue'
docker logs --tail 60 $containerName
Write-Host "请执行以下命令继续排查：" -ForegroundColor Yellow
Write-Host "  docker compose logs -f $containerName" -ForegroundColor Yellow
exit 1
