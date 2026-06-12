<#
  cc-codex-switch  —  Codex 供应商一键切换 (官方 ChatGPT  <->  第三方如 DeepSeek)
  配合 CC Switch (https://github.com/farion1231/cc-switch) 使用，仅针对 Codex CLI。

  用法:
    powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target official
    powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target thirdparty
    powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target thirdparty -Provider DeepSeek

  原理见同目录 README.md。
#>
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('official','thirdparty')]
  [string]$Target,
  [string]$Provider  # 当有多个第三方供应商时，用名字指定要切到哪个
)
$ErrorActionPreference = 'Stop'

# ===== 可按需修改 =====
$OfficialModel = 'gpt-5.5'   # 官方 ChatGPT 登录使用的模型
# ======================

# ---- 路径(自动适配当前用户) ----
$CcDir    = Join-Path $env:USERPROFILE '.cc-switch'
$Db       = Join-Path $CcDir 'cc-switch.db'
$Settings = Join-Path $CcDir 'settings.json'
$Config   = Join-Path $env:USERPROFILE '.codex\config.toml'

# ---- 定位 CC Switch 可执行文件 ----
$ExeCandidates = @(
  (Join-Path $env:LOCALAPPDATA 'Programs\CC Switch\cc-switch.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\cc-switch\cc-switch.exe'),
  (Join-Path ${env:ProgramFiles} 'CC Switch\cc-switch.exe')
)
$Exe = $ExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Exe) {
  $Exe = (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Recurse -Filter 'cc-switch.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}

# ---- 定位 sqlite3 ----
$Sqlite = (Get-Command sqlite3 -ErrorAction SilentlyContinue).Source
if (-not $Sqlite) {
  throw "找不到 sqlite3。请安装后重试：winget install SQLite.SQLite  (或 scoop install sqlite)。"
}
foreach ($f in @($Db,$Settings,$Config)) { if (-not (Test-Path $f)) { throw "找不到文件：$f （请先正常运行过 CC Switch 与 Codex）" } }
if (-not $Exe -and $Target -eq 'thirdparty') { throw "找不到 CC Switch 可执行文件，请手动设置 \$Exe。" }

function Invoke-Sql([string]$sql) { & $Sqlite $Db $sql | Out-Null }
function Query-Sql([string]$sql) { & $Sqlite $Db $sql }
function Read-Text([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-Text([string]$p,[string]$t) { [System.IO.File]::WriteAllText($p, $t) }

# ---- 从 CC Switch 数据库自动识别官方 / 第三方供应商 ----
$rows = Query-Sql "SELECT id||'<|>'||name||'<|>'||COALESCE(category,'') FROM providers WHERE app_type='codex';"
$providers = foreach ($r in $rows) {
  $p = $r -split '<\|>'
  [pscustomobject]@{ Id=$p[0]; Name=$p[1]; Category=$p[2] }
}
$official = $providers | Where-Object { $_.Id -eq 'codex-official' -or $_.Category -eq 'official' } | Select-Object -First 1
$thirds   = $providers | Where-Object { $_.Id -ne 'codex-official' -and $_.Category -ne 'official' }
if (-not $official) { throw "数据库里找不到官方 Codex 供应商(codex-official)。" }

function Get-ProviderModel([string]$id) {
  $json = (Query-Sql "SELECT settings_config FROM providers WHERE id='$id' AND app_type='codex';") -join "`n"
  try { $cfg = ($json | ConvertFrom-Json).config } catch { $cfg = '' }
  if ($cfg -match '(?m)^\s*model\s*=\s*"([^"]+)"') { return $Matches[1] }
  return $null
}

function Set-CodexConfig([string]$mode, [string]$model) {
  $c = Read-Text $Config
  $c = $c -replace '(?ms)^\[model_providers\.openai\]\r?\n(?:^(?!\[).*\r?\n?)*', ''   # 删除对内置 openai 的覆盖
  $c = $c -replace '(?m)^\s*experimental_bearer_token = ".*"\r?\n', ''
  if ($mode -eq 'official') {
    $c = $c -replace '(?m)^model_provider = ".*"', 'model_provider = "openai"'
    $c = $c -replace '(?m)^model = ".*"', "model = `"$model`""
    $custom = "[model_providers.custom]`nname = `"thirdparty`"`nbase_url = `"https://api.openai.com/v1`"`nwire_api = `"responses`"`nrequires_openai_auth = true"
  } else {
    $c = $c -replace '(?m)^model_provider = ".*"', 'model_provider = "custom"'
    $c = $c -replace '(?m)^model = ".*"', "model = `"$model`""
    $custom = "[model_providers.custom]`nname = `"thirdparty`"`nbase_url = `"http://127.0.0.1:15721/v1`"`nwire_api = `"responses`"`nrequires_openai_auth = true`nexperimental_bearer_token = `"PROXY_MANAGED`""
  }
  if ($c -match '(?ms)^\[model_providers\.custom\].*?(?=\r?\n\[|\Z)') {
    $c = [System.Text.RegularExpressions.Regex]::Replace($c, '(?ms)^\[model_providers\.custom\].*?(?=\r?\n\[|\Z)', $custom)
  }
  Write-Text $Config $c
}

Write-Host "==> Target: $Target" -ForegroundColor Cyan
Get-Process -Name cc-switch -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
if (Test-Path $Config) { Copy-Item $Config "$Config.switch-bak" -Force }

if ($Target -eq 'official') {
  Invoke-Sql "UPDATE proxy_config SET proxy_enabled=0, enabled=0, live_takeover_active=0 WHERE app_type='codex';"
  Invoke-Sql "UPDATE providers SET is_current=0 WHERE app_type='codex';"
  Invoke-Sql "UPDATE providers SET is_current=1 WHERE id='$($official.Id)' AND app_type='codex';"
  $s = Read-Text $Settings
  $s = $s -replace '"currentProviderCodex":\s*".*?"', "`"currentProviderCodex`": `"$($official.Id)`""
  Write-Text $Settings $s
  Set-CodexConfig 'official' $OfficialModel   # 保持 CC Switch 关闭
  $cfg = Read-Text $Config
  if ($cfg -notmatch '15721' -and $cfg -notmatch '\[model_providers\.openai\]' -and $cfg -match [regex]::Escape("model = `"$OfficialModel`"")) {
    Write-Host "[OK] Switched to OFFICIAL ($OfficialModel, direct). CC Switch closed." -ForegroundColor Green
    Write-Host ">> Open a NEW Codex terminal to use it." -ForegroundColor Yellow
  } else { Write-Host "[WARN] verify failed, check $Config" -ForegroundColor Red }
}
else {
  # 选择第三方供应商
  if (-not $thirds) { throw "数据库里没有第三方 Codex 供应商，请先在 CC Switch 里添加一个。" }
  if ($Provider) { $tp = $thirds | Where-Object { $_.Name -ieq $Provider } | Select-Object -First 1 }
  elseif (@($thirds).Count -eq 1) { $tp = @($thirds)[0] }
  if (-not $tp) {
    Write-Host "有多个第三方供应商，请用 -Provider 指定其一：" -ForegroundColor Yellow
    $thirds | ForEach-Object { Write-Host "   $($_.Name)" }
    throw "未指定 -Provider。"
  }
  $model = Get-ProviderModel $tp.Id
  if (-not $model) { throw "无法从 $($tp.Name) 读出模型名，请检查该供应商配置。" }

  Invoke-Sql "UPDATE proxy_config SET proxy_enabled=1, enabled=1 WHERE app_type='codex';"
  Invoke-Sql "UPDATE providers SET is_current=0 WHERE app_type='codex';"
  Invoke-Sql "UPDATE providers SET is_current=1 WHERE id='$($tp.Id)' AND app_type='codex';"
  $s = Read-Text $Settings
  $s = $s -replace '"currentProviderCodex":\s*".*?"', "`"currentProviderCodex`": `"$($tp.Id)`""
  Write-Text $Settings $s

  Start-Process $Exe
  Write-Host "==> CC Switch started, waiting for local proxy..." -ForegroundColor DarkGray
  $listening = $false
  for ($i=0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    if (Test-NetConnection 127.0.0.1 -Port 15721 -WarningAction SilentlyContinue -InformationLevel Quiet) { $listening = $true; break }
  }
  Start-Sleep -Seconds 2
  Set-CodexConfig 'thirdparty' $model
  Start-Sleep -Seconds 1
  $cfg = Read-Text $Config
  if (-not ($cfg -match '127\.0\.0\.1:15721' -and $cfg -match 'model_provider = "custom"')) { Set-CodexConfig 'thirdparty' $model }
  $cfg = Read-Text $Config
  if ($listening -and $cfg -match '127\.0\.0\.1:15721' -and $cfg -notmatch '\[model_providers\.openai\]') {
    Write-Host "[OK] Switched to $($tp.Name) ($model, via local proxy 15721)." -ForegroundColor Green
    Write-Host ">> Open a NEW Codex terminal to use it." -ForegroundColor Yellow
  } else { Write-Host "[WARN] proxy/config not ready, open CC Switch to check." -ForegroundColor Red }
}
Write-Host ""
