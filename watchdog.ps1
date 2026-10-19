# Agent HUD · 看门狗（watchdog）
# ---------------------------------------------------------------------------
# 独立守护进程：发现主进程（hud.ps1）心跳断了就把它拉起来。
#
# 判定规则：
#   * 心跳文件不存在        → 主进程从未起来（比如刚开机）→ 拉起
#   * 心跳超过 40 秒没更新  → 主进程崩了 / 被杀了          → 拉起
#
# 单实例：用 watchdog.lock 独占打开；拿不到锁说明已经有一个在守，直接退出。
# 退出：  托盘菜单「退出」会写 watchdog.stop，本进程看到就自行退出。
$ErrorActionPreference = 'SilentlyContinue'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$hb = Join-Path $root 'heartbeat.txt'
$vbs = Join-Path $root 'start-silent.vbs'
$stopFile = Join-Path $root 'watchdog.stop'
$lockPath = Join-Path $root 'watchdog.lock'

try {
  $lk = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch { exit 0 }

if (Test-Path $stopFile) { Remove-Item $stopFile -Force }

while ($true) {
  Start-Sleep -Seconds 20
  try {
    if (Test-Path $stopFile) { break }

    $needStart = $false
    if (-not (Test-Path $hb)) {
      $needStart = $true
    } else {
      $age = ((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds
      if ($age -gt 40) { $needStart = $true }
    }

    if ($needStart) {
      & wscript.exe $vbs
      Start-Sleep -Seconds 25
    }
  } catch {
    Start-Sleep -Seconds 20
  }
}
