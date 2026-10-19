# agent-hud-lite —— Windows 上的 AI 用量浮窗
#
# 外观照 jazzenchen/agent-hud-win 的 Simple 形态：
#   深色圆角矩形底 + 每个 provider 的模型图标外套一圈进度弧。
#
# 交互：
#   平时          —— 图标 + 进度弧
#   悬停          —— 矩形变宽，图标旁出现该模型的百分比（颜色与圆环一致）
#   左键点图标/百分比 —— 在旁边浮现明细框，列出全部余额 / 资源包 / 到期 / 今日消耗
#
# 贴边吸附（四条边）：
#   左/右 → 竖排（贴右边框时百分比在图标左侧）
#   上/下 → 打横（百分比在图标下方）
#   拖动过程中会根据离上/下边缘的远近**实时**把图标一个个拐成横排，
#   黑色底框同时跟着图标的位置一段段变形（像贪吃蛇拐弯）。
#
# 重要实现说明：这个窗口是「无边框 + AllowsTransparency + Topmost + 不激活」，
# 实测 WPF 只派发 MouseEnter/Move，**从不派发鼠标按键事件**，所以点击/拖动/右键
# 全部通过轮询 GetAsyncKeyState 自己判定，与 WPF 输入栈无关。

param(
  [string]$ConfigPath,
  [switch]$Once,
  [switch]$Decide
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:Root 'config.json' }

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $extra = @()
  if ($Once) { $extra += '-Once' }
  if ($Decide) { $extra += '-Decide' }
  Start-Process -FilePath $exe -ArgumentList (@('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $MyInvocation.MyCommand.Path, '-ConfigPath', $ConfigPath) + $extra)
  exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('HudNative.Win' -as [type])) {
  Add-Type -Namespace HudNative -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int index);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr h, int index, int value);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool RegisterHotKey(System.IntPtr h, int id, uint mods, uint vk);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool UnregisterHotKey(System.IntPtr h, int id);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetDC(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int ReleaseDC(System.IntPtr h, System.IntPtr hdc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern int GetDeviceCaps(System.IntPtr hdc, int index);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
}

[void][HudNative.Win]::SetProcessDPIAware()

# ---------------------------------------------------------------- 配置
$script:Cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function CfgOr($name, $fallback) {
  $p = $script:Cfg.PSObject.Properties[$name]
  if ($null -eq $p -or $null -eq $p.Value) { return $fallback }
  return $p.Value
}

$script:Circle      = [double](CfgOr 'circleSize' 32)
$script:Thickness   = [double](CfgOr 'ringThickness' 2.8)
$script:Gap         = [double](CfgOr 'gap' 10)
$script:IconScale   = [double](CfgOr 'iconScale' 0.60)

$script:Pad         = [double](CfgOr 'panelPadding' 8)
$script:PanelBg     = [string](CfgOr 'panelBackground' '#F0101218')
$script:PanelBd     = [string](CfgOr 'panelBorder' '#2EFFFFFF')
$script:PanelR      = [double](CfgOr 'panelRadius' 14)

$script:EdgeMargin  = [double](CfgOr 'edgeMargin' 4)
$script:SnapDist    = [double](CfgOr 'snapDistance' 70)
$script:CornerScale = [double](CfgOr 'cornerScale' 1.5)   # 轨道圆角半径 = 圆径 × 此值（越大内圈越圆滑）

$script:HoverExpand = [bool](CfgOr 'hoverExpand' $true)

$script:CardW       = [double](CfgOr 'detailWidth' 300)
$script:CardBg      = [string](CfgOr 'detailBackground' '#F81A1D26')
$script:CardPad     = [double](CfgOr 'detailPadding' 10)

$script:PollMs      = [int](CfgOr 'foregroundPollMs' 400)
$script:RefreshSec  = [int](CfgOr 'refreshSeconds' 60)
$script:CoverageAt  = [double](CfgOr 'fullscreenCoverage' 0.92)
$script:HideOnFull  = [bool](CfgOr 'hideWhenOtherFullscreen' $true)

$script:AllowProcExact     = @(CfgOr 'allowProcessExact' @())     | ForEach-Object { $_.ToLower() }
$script:AllowProcContains  = @(CfgOr 'allowProcessContains' @())  | ForEach-Object { $_.ToLower() }
$script:AllowTitleContains = @(CfgOr 'allowTitleContains' @())    | ForEach-Object { $_.ToLower() }
$script:DesktopClasses     = @(CfgOr 'desktopClassNames' @())     | ForEach-Object { $_.ToLower() }

$script:WarnRatio  = [double](CfgOr 'warnRatio' 0.35)
$script:LowRatio   = [double](CfgOr 'lowRatio' 0.15)
$script:WarnColor  = [string](CfgOr 'warnColor' '#F0B429')
$script:LowColor   = [string](CfgOr 'lowColor' '#EF4444')
$script:ErrorColor = [string](CfgOr 'errorColor' '#EF4444')
$script:StaleColor = [string](CfgOr 'staleColor' '#F0B429')
$script:TrackColor = [string](CfgOr 'trackColor' '#40FFFFFF')
$script:Fallback   = [string](CfgOr 'accentFallback' '#7A8699')

$script:PanelUrl = [string](CfgOr 'panelUrl' '')

$script:LogPath      = Join-Path $script:Root ([string](CfgOr 'logFile' 'hud.log'))
$script:StatePath    = Join-Path $script:Root 'state.json'
$script:SnapshotPath = Join-Path $env:TEMP 'agent-hud-win.json'
$script:SnapshotScript = Join-Path $script:Root 'snapshot.mjs'
$script:NodeExe = 'node'
try { $cmd = Get-Command node -ErrorAction Stop; $script:NodeExe = $cmd.Source } catch { }

function Write-Log([string]$msg) {
  try {
    Add-Content -Path $script:LogPath -Value ("{0}  {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $msg) -Encoding UTF8
  } catch { }
}

function Get-ProviderColor($provider) {
  # 传对象时优先用 providers.json 里声明的 color（唯一真源）；
  # 传字符串（老调用点）就按 id 去 config.json 的 providerColors 里查。
  $id = $provider
  if ($provider -and $provider.id) {
    $id = [string]$provider.id
    if ($provider.color) { return [string]$provider.color }
  } else {
    $id = [string]$provider
  }
  $map = CfgOr 'providerColors' $null
  if ($map) {
    $p = $map.PSObject.Properties[$id]
    if ($p -and $p.Value) { return [string]$p.Value }
  }
  return $script:Fallback
}

# 渐变色（如 Gemini 的 linear-gradient）只用在圆环上；文字和圆点用其中一个纯色，
# 否则小字渐变会很难看清。规则：取渐变中间那一档。
function Get-SolidColor([string]$spec) {
  if ($spec -and $spec -match 'linear-gradient') {
    $cols = @([regex]::Matches($spec, '#[0-9A-Fa-f]{6}') | ForEach-Object { $_.Value })
    if ($cols.Count -ge 1) { return $cols[[int][Math]::Floor(($cols.Count - 1) / 2)] }
  }
  return $spec
}

function Get-IconPath($provider) {
  # 优先用 providers.json 声明的 icon（和 color 一样是唯一真源）；
  # 没声明才回退到 config.json 的 providerIcons 映射。
  if ($provider -and $provider.id) {
    if ($provider.icon) {
      $p2 = Join-Path $script:Root ([string]$provider.icon)
      if (Test-Path $p2) { return $p2 }
    }
    $id = [string]$provider.id
  } else {
    $id = [string]$provider
  }
  $map = CfgOr 'providerIcons' $null
  if (-not $map) { return $null }
  $p = $map.PSObject.Properties[$id]
  if (-not $p -or -not $p.Value) { return $null }
  $path = Join-Path $script:Root ([string]$p.Value)
  if (Test-Path $path) { return $path }
  return $null
}

function Get-ReferenceBalance($provider) {
  # 优先用 provider 自己的 reference（providers.json 里声明），否则退回 config.json 的表
  if ($provider -and $null -ne $provider.reference) {
    $rv = 0.0
    if ([double]::TryParse([string]$provider.reference, [ref]$rv)) { if ($rv -gt 0) { return $rv } }
  }
  $id = if ($provider -and $provider.id) { [string]$provider.id } else { [string]$provider }
  $map = CfgOr 'referenceBalance' $null
  if (-not $map) { return $null }
  $p = $map.PSObject.Properties[$id]
  if (-not $p -or $null -eq $p.Value) { return $null }
  $v = 0.0
  if ([double]::TryParse([string]$p.Value, [ref]$v)) { if ($v -gt 0) { return $v } }
  return $null
}

# ---------------------------------------------------------------- 前台窗口判定
function Get-ForegroundInfo {
  $h = [HudNative.Win]::GetForegroundWindow()
  if ($h -eq [IntPtr]::Zero) { return $null }
  $rect = New-Object HudNative.Win+RECT
  if (-not [HudNative.Win]::GetWindowRect($h, [ref]$rect)) { return $null }
  $procId = [uint32]0
  [void][HudNative.Win]::GetWindowThreadProcessId($h, [ref]$procId)
  $cls = New-Object System.Text.StringBuilder 256
  [void][HudNative.Win]::GetClassName($h, $cls, 256)
  $pname = ''
  $title = ''
  try {
    $proc = Get-Process -Id $procId -ErrorAction Stop
    $pname = $proc.ProcessName
    $title = $proc.MainWindowTitle
  } catch { }
  return [pscustomobject]@{ Handle = $h; Rect = $rect; ProcessId = $procId; Process = $pname; Class = $cls.ToString(); Title = $title }
}

function Get-Coverage($rect, $work) {
  $ix = [Math]::Min($rect.Right, $work.Right) - [Math]::Max($rect.Left, $work.Left)
  $iy = [Math]::Min($rect.Bottom, $work.Bottom) - [Math]::Max($rect.Top, $work.Top)
  if ($ix -le 0 -or $iy -le 0) { return 0.0 }
  return ($ix * $iy) / [double]($work.Width * $work.Height)
}

function Resolve-Visibility($fg, $work) {
  if ($null -eq $fg) { return [pscustomobject]@{ Show = $true; Reason = 'desktop (no foreground window)' } }
  $pn = $fg.Process.ToLower()
  if ($script:AllowProcExact -contains $pn) { return [pscustomobject]@{ Show = $true; Reason = "agent process: $pn" } }
  foreach ($s in $script:AllowProcContains) {
    if ($pn.Contains($s)) { return [pscustomobject]@{ Show = $true; Reason = "agent process contains '$s': $pn" } }
  }
  $tl = $fg.Title.ToLower()
  foreach ($s in $script:AllowTitleContains) {
    if ($tl.Contains($s)) { return [pscustomobject]@{ Show = $true; Reason = "agent title contains '$s'" } }
  }
  $cl = $fg.Class.ToLower()
  if ($script:DesktopClasses -contains $cl) { return [pscustomobject]@{ Show = $true; Reason = "desktop/shell: $cl" } }
  $cov = Get-Coverage $fg.Rect $work
  if ($script:HideOnFull -and $cov -ge $script:CoverageAt) {
    return [pscustomobject]@{ Show = $false; Reason = ("other app nearly fullscreen ({0:P0}): {1}" -f $cov, $pn) }
  }
  return [pscustomobject]@{ Show = $true; Reason = ("other app windowed ({0:P0}): {1}" -f $cov, $pn) }
}

# ---------------------------------------------------------------- 单位 / 工作区
function Get-DpiScale {
  try {
    $hdc = [HudNative.Win]::GetDC([IntPtr]::Zero)
    $dpi = [HudNative.Win]::GetDeviceCaps($hdc, 88)
    [void][HudNative.Win]::ReleaseDC([IntPtr]::Zero, $hdc)
    if ($dpi -gt 0) { return $dpi / 96.0 }
  } catch { }
  return 1.0
}

$script:Scale = Get-DpiScale

function Get-WorkArea {
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $phys = [pscustomobject]@{ Left = $wa.Left; Top = $wa.Top; Right = $wa.Right; Bottom = $wa.Bottom; Width = $wa.Width; Height = $wa.Height }
  $s = $script:Scale
  $dip = [pscustomobject]@{
    Left = $wa.Left / $s; Top = $wa.Top / $s; Right = $wa.Right / $s; Bottom = $wa.Bottom / $s
    Width = $wa.Width / $s; Height = $wa.Height / $s
  }
  return [pscustomobject]@{ Phys = $phys; Dip = $dip }
}

# ---------------------------------------------------------------- 自检：当前前台
if ($Once) {
  $areas = Get-WorkArea
  $work = $areas.Phys
  $fg = Get-ForegroundInfo
  $d = Resolve-Visibility $fg $work
  Write-Output ("work area : {0},{1} {2}x{3}  (物理)" -f $work.Left, $work.Top, $work.Width, $work.Height)
  Write-Output ("dpi       : {0:N2}x  (1 DIP = {1} 物理px)" -f $script:Scale, $script:Scale)
  Write-Output ("circle    : {0} DIP = {1} 物理px" -f $script:Circle, ($script:Circle * $script:Scale))
  if ($fg) {
    Write-Output ("foreground: {0}  class={1}  pid={2}" -f $fg.Process, $fg.Class, $fg.ProcessId)
    Write-Output ("fg rect   : {0},{1} - {2},{3}  coverage={4:P1}" -f $fg.Rect.Left, $fg.Rect.Top, $fg.Rect.Right, $fg.Rect.Bottom, (Get-Coverage $fg.Rect $work))
  } else {
    Write-Output 'foreground: (none)'
  }
  Write-Output ("decision  : show={0}  because {1}" -f $d.Show, $d.Reason)
  exit 0
}

# ---------------------------------------------------------------- 自检：显隐规则
if ($Decide) {
  $wa = (Get-WorkArea).Phys
  function Fake-Fg([string]$proc, [string]$cls, [double]$cov) {
    $w = [int]($wa.Width * [Math]::Sqrt($cov))
    $h = [int]($wa.Height * [Math]::Sqrt($cov))
    $r = New-Object HudNative.Win+RECT
    $r.Left = $wa.Left; $r.Top = $wa.Top; $r.Right = $wa.Left + $w; $r.Bottom = $wa.Top + $h
    return [pscustomobject]@{ Handle = [IntPtr]1; Rect = $r; ProcessId = 1; Process = $proc; Class = $cls; Title = '' }
  }
  $cases = @(
    @{ n = 'no foreground (desktop)';    fg = $null;                          want = $true  },
    @{ n = 'VS Code fullscreen (in allowProcessExact)'; fg = (Fake-Fg 'Code' 'Chrome_WidgetWin_1' 1.0); want = $true },
    @{ n = 'Cursor 86% covered';         fg = (Fake-Fg 'Cursor' 'Chrome_WidgetWin_1' 0.86); want = $true },
    @{ n = 'WindowsTerminal fullscreen'; fg = (Fake-Fg 'WindowsTerminal' 'CASCADIA_HOSTING_WINDOW_CLASS' 1.0); want = $true },
    @{ n = 'substring match (vibearound)'; fg = (Fake-Fg 'VibeAroundHub' 'Chrome_WidgetWin_1' 1.0); want = $true },
    @{ n = 'explorer / Progman (desktop)'; fg = (Fake-Fg 'explorer' 'Progman' 1.0);        want = $true },
    @{ n = 'browser windowed 55%';       fg = (Fake-Fg 'chrome' 'Chrome_WidgetWin_1' 0.55); want = $true },
    @{ n = 'browser nearly fullscreen 97%'; fg = (Fake-Fg 'chrome' 'Chrome_WidgetWin_1' 0.97); want = $false },
    @{ n = 'Word fullscreen 100%';       fg = (Fake-Fg 'WINWORD' 'OpusApp' 1.0);           want = $false },
    @{ n = 'WeChat fullscreen 100%';     fg = (Fake-Fg 'Weixin' 'Qt51514QWindowIcon' 1.0); want = $false }
  )
  $fail = 0
  foreach ($c in $cases) {
    $d = Resolve-Visibility $c.fg $wa
    $ok = ($d.Show -eq $c.want)
    if (-not $ok) { $fail++ }
    $verdict = 'PASS'
    if (-not $ok) { $verdict = 'FAIL' }
    Write-Output ("{0}  {1,-24} want={2,-5} got={3,-5}  {4}" -f $verdict, $c.n, $c.want, $d.Show, $d.Reason)
  }
  Write-Output ("")
  Write-Output ("失败 {0} / {1}" -f $fail, $cases.Count)
  if ($fail -gt 0) { exit 1 }
  exit 0
}

# ---------------------------------------------------------------- 颜色 / 图标
function Get-Brush([string]$hex, [double]$opacity = 1.0) {
  $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
  $b = New-Object System.Windows.Media.SolidColorBrush $c
  $b.Opacity = $opacity
  $b.Freeze()
  return $b
}

# 供应商颜色可以是纯色（#RRGGBB）或 CSS 渐变：
#   linear-gradient(135deg, #00C6FF 0%, #0066FF 50%, #3A7BD5 100%)
# 渐变只用在圆环描边上。CSS 角度约定：0deg = 朝上，顺时针增加。
function Get-RingBrush([string]$spec, [double]$opacity = 0.95) {
  if ($spec -and $spec -match 'linear-gradient') {
    try {
      $deg = 135.0
      if ($spec -match 'linear-gradient\(\s*(-?[\d.]+)deg') { $deg = [double]$matches[1] }
      $stops = [regex]::Matches($spec, '#([0-9A-Fa-f]{6})\s*(?:([\d.]+)%)?')
      if ($stops.Count -ge 2) {
        $rad = $deg * [Math]::PI / 180.0
        $dx = [Math]::Sin($rad)
        $dy = -[Math]::Cos($rad)
        $g = New-Object System.Windows.Media.LinearGradientBrush
        $g.StartPoint = New-Object System.Windows.Point ((0.5 - $dx / 2), (0.5 - $dy / 2))
        $g.EndPoint = New-Object System.Windows.Point ((0.5 + $dx / 2), (0.5 + $dy / 2))
        $n = $stops.Count
        for ($i = 0; $i -lt $n; $i++) {
          $hex = '#' + $stops[$i].Groups[1].Value
          $off = if ($stops[$i].Groups[2].Success) { [double]$stops[$i].Groups[2].Value / 100.0 } else { $i / [double]($n - 1) }
          $col = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
          $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop $col, $off))
        }
        $g.Opacity = $opacity
        $g.Freeze()
        return $g
      }
    } catch { }
  }
  return (Get-Brush (Get-SolidColor $spec) $opacity)
}

$script:IconCache = @{}

function Get-IconBitmap([string]$path, [double]$size) {
  if ($script:IconCache.ContainsKey($path)) { return $script:IconCache[$path] }
  try {
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.UriSource = New-Object System.Uri($path)
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.DecodePixelWidth = [int][Math]::Max(32, $size * 2)
    $bi.EndInit()
    $bi.Freeze()
    $script:IconCache[$path] = $bi
    return $bi
  } catch {
    Write-Log "icon load failed: $path ($($_.Exception.Message))"
    $script:IconCache[$path] = $null
    return $null
  }
}

function Get-ProviderRatio($p) {
  if (-not $p.ok) { return $null }
  $items = @($p.items)
  $tightest = $null
  foreach ($it in $items) {
    if ($null -ne $it.ratio) {
      $r = [double]$it.ratio
      if ($null -eq $tightest -or $r -lt $tightest) { $tightest = $r }
    }
  }
  if ($null -ne $tightest) { return $tightest }
  $ref = Get-ReferenceBalance $p
  if ($null -ne $ref -and $items.Count -gt 0 -and $null -ne $items[0].amount) {
    return [Math]::Max(0.0, [Math]::Min(1.0, [double]$items[0].amount / $ref))
  }
  return $null
}

function Get-RingColor($p) {
  # 只有「查询失败」才改成错误色（这是状态，不是品牌色）。
  # 低余额变色是可选项：config.json 里 "warnOnLowBalance": true 才会把圆环
  # 从品牌色改成黄/红——默认关闭，保证每个模型的圆环颜色是固定可控的。
  if (-not $p.ok) { return $script:ErrorColor }
  if ($script:WarnOnLow) {
    $r = Get-ProviderRatio $p
    if ($null -ne $r) {
      if ($r -le $script:LowRatio) { return $script:LowColor }
      if ($r -le $script:WarnRatio) { return $script:WarnColor }
    }
  }
  return (Get-ProviderColor $p)
}

function Get-RowSummary($p) {
  if (-not $p.ok) { return '!' }
  $r = Get-ProviderRatio $p
  if ($null -ne $r) { return ('{0:N0}%' -f (100.0 * $r)) }
  $items = @($p.items)
  if ($items.Count -eq 0) { return '-' }
  $a = $items[0].amount
  if ($null -ne $a) {
    $u = [string]$items[0].unit
    if ($u -eq 'CNY') { return ('¥{0:0.#}' -f [double]$a) }
    return ('{0:0.#}' -f [double]$a)
  }
  return [string]$items[0].text
}

# ---------------------------------------------------------------- 画一个圆
function New-Ring($provider) {
  $size = $script:Circle
  $t = $script:Thickness
  $color = Get-RingColor $provider
  $ratio = Get-ProviderRatio $provider

  $grid = New-Object System.Windows.Controls.Grid
  $grid.Width = $size
  $grid.Height = $size

  $iconPath = Get-IconPath $provider
  $iconSize = $size * $script:IconScale
  if ($iconPath) {
    $bmp = Get-IconBitmap $iconPath $iconSize
    if ($bmp) {
      $img = New-Object System.Windows.Controls.Image
      $img.Source = $bmp
      $img.Width = $iconSize
      $img.Height = $iconSize
      $img.Stretch = 'Uniform'
      $img.HorizontalAlignment = 'Center'
      $img.VerticalAlignment = 'Center'
      [void]$grid.Children.Add($img)
    }
  } else {
    # 没有图标文件时的占位：品牌色字母。开源版默认就靠它，
    # 谁想换成真 logo，把自己的 png 丢进 icons/ 并在 config.json 里映射即可。
    $lbl = New-Object System.Windows.Controls.TextBlock
    $txt = [string]$provider.label
    if ([string]::IsNullOrWhiteSpace($txt)) { $txt = [string]$provider.id }
    $lbl.Text = $txt.Substring(0, 1).ToUpper()
    $lbl.FontSize = $size * 0.42
    $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
    $lbl.Foreground = Get-Brush (Get-SolidColor (Get-ProviderColor $provider)) 1.0
    $lbl.HorizontalAlignment = 'Center'
    $lbl.VerticalAlignment = 'Center'
    [void]$grid.Children.Add($lbl)
  }

  $track = New-Object System.Windows.Shapes.Ellipse
  $track.Width = $size; $track.Height = $size
  $track.Stroke = Get-Brush $script:TrackColor 1.0
  $track.StrokeThickness = 1.2
  [void]$grid.Children.Add($track)

  $d = $size - $t
  $circumference = [Math]::PI * $d
  $frac = 1.0
  if ($null -ne $ratio) { $frac = [Math]::Max(0.03, [Math]::Min(1.0, [double]$ratio)) }
  $dashLen = ($frac * $circumference) / $t

  $arc = New-Object System.Windows.Shapes.Ellipse
  $arc.Width = $size; $arc.Height = $size
  $arc.Stroke = Get-RingBrush $color 0.95
  $arc.StrokeThickness = $t
  $da = New-Object System.Windows.Media.DoubleCollection
  [void]$da.Add($dashLen)
  [void]$da.Add(100000)
  $arc.StrokeDashArray = $da
  $arc.StrokeDashCap = [System.Windows.Media.PenLineCap]::Round
  [void]$grid.Children.Add($arc)

  $grid.Tag = $provider
  return $grid
}

# ---------------------------------------------------------------- 明细框内容
function New-CardText([string]$text, [double]$size, [string]$color, [double]$topGap = 0, [bool]$bold = $false) {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $text
  $tb.FontSize = $size
  $tb.Foreground = Get-Brush $color 1.0
  $tb.TextWrapping = 'NoWrap'
  if ($topGap -gt 0) { $tb.Margin = New-Object System.Windows.Thickness 0, $topGap, 0, 0 }
  if ($bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
  return $tb
}

function New-ProviderBlock($p) {
  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
  $head = New-Object System.Windows.Controls.StackPanel
  $head.Orientation = 'Horizontal'
  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 7; $dot.Height = 7
  $dot.Fill = Get-Brush (Get-SolidColor (Get-ProviderColor $p)) 1.0
  $dot.Margin = New-Object System.Windows.Thickness 0, 5, 6, 0
  $dot.VerticalAlignment = 'Top'
  [void]$head.Children.Add($dot)
  [void]$head.Children.Add((New-CardText ([string]$p.label) 12.5 '#F2F4F8' 0 $true))
  [void]$sp.Children.Add($head)
  if (-not $p.ok) {
    [void]$sp.Children.Add((New-CardText ('  查询失败：' + [string]$p.error) 11 '#FF8A80' 3))
    return $sp
  }
  $items = @($p.items)
  if ($items.Count -eq 0) { [void]$sp.Children.Add((New-CardText '  （无明细）' 11 '#9AA3B2' 3)) }
  foreach ($it in $items) {
    $name = [string]$it.label
    if ($name.Length -gt 24) { $name = $name.Substring(0, 23) + '…' }
    [void]$sp.Children.Add((New-CardText ('  ' + $name) 11 '#AEB6C4' 5))
    $extra = @()
    if ($null -ne $it.ratio) { $extra += ('剩 {0:N1}%' -f (100.0 * [double]$it.ratio)) }
    if ($it.expiresAt) {
      try { $extra += ('{0:MM-dd} 到期' -f [datetime]::Parse([string]$it.expiresAt)) } catch { }
    }
    $line = '    ' + [string]$it.text
    if ($extra.Count -gt 0) { $line += '   · ' + ($extra -join ' · ') }
    [void]$sp.Children.Add((New-CardText $line 11.5 '#E6E9F0' 1))
  }
  if ($null -ne $p.todaySpend -and [double]$p.todaySpend -gt 0) {
    [void]$sp.Children.Add((New-CardText ('  今日消耗 ≈ {0:0.##}' -f [double]$p.todaySpend) 11 '#8FD6A0' 5))
  }
  if ($p.stale) { [void]$sp.Children.Add((New-CardText '  ! 数据可能已过期' 11 $script:StaleColor 3)) }
  return $sp
}

function Build-CardFor($p) {
  $sp = New-Object System.Windows.Controls.StackPanel
  if ($null -eq $p) { return $sp }
  [void]$sp.Children.Add((New-ProviderBlock $p))
  try {
    $when = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$script:LastUpdatedRaw).ToLocalTime()
    [void]$sp.Children.Add((New-CardText ('更新于 {0:HH:mm:ss} · 每 {1}s 刷新' -f $when, $script:RefreshSec) 10.5 '#7E8798' 2))
  } catch { }
  return $sp
}

# ---------------------------------------------------------------- 窗口骨架
$script:Providers = @()
$script:LastUpdated = -1
$script:LastUpdatedRaw = 0
$script:Active = $false
$script:SelectedId = $null
$script:Edge = 'left'
$script:Morph = 0.0          # 0 = 竖排, 1 = 横排（拖动中连续变化）
$script:Dragging = $false

# 绝对定位：每行用 Canvas 摆放，才能做出「一个个拐弯」的连续动画
$script:Canvas = New-Object System.Windows.Controls.Canvas
$script:Canvas.HorizontalAlignment = 'Left'
$script:Canvas.VerticalAlignment = 'Top'
# 行的子元素顺序会随「贴左边/贴右边」互换，所以不能按下标取，
# 必须持有引用。上一版按下标取导致把 Grid 当 TextBlock 用，报「找不到 FontSize」。
$script:RingRefs = @()
$script:LabelRefs = @()

# 行尺寸缓存（拖动时每帧复用，避免反复 Measure）
$script:Metrics = New-Object System.Collections.ArrayList
$script:MetricsKey = ''
$script:VisKey = ''
$script:LastPillMargin = ''

$script:Pill = New-Object System.Windows.Controls.Border
$script:Pill.Background = Get-Brush $script:PanelBg 1.0
$script:Pill.BorderBrush = Get-Brush $script:PanelBd 1.0
$script:Pill.BorderThickness = New-Object System.Windows.Thickness 1
$script:Pill.CornerRadius = New-Object System.Windows.CornerRadius $script:PanelR
$script:Pill.HorizontalAlignment = 'Left'
$script:Pill.VerticalAlignment = 'Top'

# 形变过程中的背景：一条有厚度的折线（一笔画成、圆角、无接缝），
# 厚度 = 圆直径 + 两侧内边距，正好把图标裹住 → 整块底随图标一起弯成 L。
$script:BendPath = New-Object System.Windows.Shapes.Path
$script:BendPath.Stroke = Get-Brush $script:PanelBg 1.0
$script:BendPath.StrokeThickness = $script:Circle + 2 * $script:Pad
$script:BendPath.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
$script:BendPath.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
$script:BendPath.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
$script:BendPath.HorizontalAlignment = 'Left'
$script:BendPath.VerticalAlignment = 'Top'
$script:BendPath.Visibility = 'Collapsed'

$script:CardPanel = New-Object System.Windows.Controls.Border
$script:CardPanel.Background = Get-Brush $script:CardBg 1.0
$script:CardPanel.CornerRadius = New-Object System.Windows.CornerRadius 10
$script:CardPanel.Padding = New-Object System.Windows.Thickness $script:CardPad
$script:CardPanel.HorizontalAlignment = 'Left'
$script:CardPanel.VerticalAlignment = 'Top'
$script:CardPanel.Visibility = 'Collapsed'
$script:CardPanel.Width = $script:CardW
$script:CardPanel.MaxHeight = 460

$script:CardScroll = New-Object System.Windows.Controls.ScrollViewer
$script:CardScroll.VerticalScrollBarVisibility = 'Auto'
$script:CardScroll.HorizontalScrollBarVisibility = 'Disabled'
$script:CardPanel.Child = $script:CardScroll

$script:RootGrid = New-Object System.Windows.Controls.Grid
[void]$script:RootGrid.Children.Add($script:Pill)
[void]$script:RootGrid.Children.Add($script:BendPath)
[void]$script:RootGrid.Children.Add($script:Canvas)
[void]$script:RootGrid.Children.Add($script:CardPanel)

$script:Win = New-Object System.Windows.Window
$script:Win.WindowStyle = 'None'
$script:Win.AllowsTransparency = $true
$script:Win.Background = [System.Windows.Media.Brushes]::Transparent
if ($env:HUD_DEBUG_BG) {
  $script:Win.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(10, 200, 10))
  Write-Log 'DEBUG: opaque green window background'
}
$script:Win.Topmost = $true
$script:Win.ShowInTaskbar = $false
if ($env:HUD_ACTIVATE) { $script:Win.ShowActivated = $true } else { $script:Win.ShowActivated = $false }
$script:Win.ResizeMode = 'NoResize'
$script:Win.SizeToContent = 'Manual'
$script:Win.Focusable = $false
$script:Win.Content = $script:RootGrid

$script:Areas = Get-WorkArea
$script:WorkArea = $script:Areas.Phys
$script:WorkDip = $script:Areas.Dip

function Get-CardIndex {
  if ($null -eq $script:SelectedId) { return -1 }
  for ($i = 0; $i -lt $script:Providers.Count; $i++) {
    if ($script:Providers[$i].id -eq $script:SelectedId) { return $i }
  }
  return -1
}

function Set-LabelsVisible([bool]$on) {
  foreach ($lbl in $script:LabelRefs) {
    if ($null -eq $lbl) { continue }
    if ($on) { $lbl.Visibility = 'Visible' } else { $lbl.Visibility = 'Collapsed' }
  }
}

# 每行的内部排布：竖排时标签在图标右/左，横排时在图标下方
function Apply-RowOrientation {
  $horiz = ($script:Morph -ge 0.5)
  $rightSide = ($script:Edge -eq 'right')
  $n = $script:Canvas.Children.Count
  for ($i = 0; $i -lt $n; $i++) {
    $row = $script:Canvas.Children[$i]
    $ring = $script:RingRefs[$i]
    $lbl = $script:LabelRefs[$i]
    if ($null -eq $ring -or $null -eq $lbl) { continue }
    if ($horiz) {
      $row.Orientation = 'Vertical'
      if ($row.Children.IndexOf($ring) -ne 0) { $row.Children.Remove($ring); $row.Children.Insert(0, $ring) }
      $lbl.TextAlignment = 'Center'
      $lbl.HorizontalAlignment = 'Center'
      $lbl.VerticalAlignment = 'Top'
      $lbl.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
      $lbl.FontSize = 10
      $ring.HorizontalAlignment = 'Center'
    } else {
      $row.Orientation = 'Horizontal'
      $lbl.VerticalAlignment = 'Center'
      $lbl.FontSize = 11
      $ring.HorizontalAlignment = 'Left'
      if ($rightSide) {
        # 贴右边框：标签放左边、图标贴住右边
        if ($row.Children.IndexOf($ring) -ne 1) { $row.Children.Remove($ring); $row.Children.Insert(1, $ring) }
        $lbl.TextAlignment = 'Right'
        $lbl.HorizontalAlignment = 'Right'
        $lbl.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
      } else {
        if ($row.Children.IndexOf($ring) -ne 0) { $row.Children.Remove($ring); $row.Children.Insert(0, $ring) }
        $lbl.TextAlignment = 'Left'
        $lbl.HorizontalAlignment = 'Left'
        $lbl.Margin = New-Object System.Windows.Thickness 6, 0, 0, 0
      }
    }
  }
}

# 行尺寸（标签显示时才有额外宽/高）
# 行尺寸缓存：只有「标签显隐」或「方向」变化时才重新测量。
# 之前每帧对每行调 Measure()，拖动时 25 帧/秒 → 明显卡顿。
function Update-Metrics([bool]$horiz, [bool]$labelsOn) {
  $n = $script:Canvas.Children.Count
  $key = "$horiz|$labelsOn|$n"
  if ($script:MetricsKey -eq $key) { return }
  $script:Metrics = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $n; $i++) {
    if (-not $labelsOn) {
      # 拖动时不显示标签，每行就是图标本身，不需要测量
      [void]$script:Metrics.Add([pscustomobject]@{ W = $script:Circle; H = $script:Circle })
      continue
    }
    $row = $script:Canvas.Children[$i]
    try { $row.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)) } catch { }
    [void]$script:Metrics.Add([pscustomobject]@{
        W = [Math]::Max($row.DesiredSize.Width, $script:Circle)
        H = [Math]::Max($row.DesiredSize.Height, $script:Circle)
      })
  }
  $script:MetricsKey = $key
}

# 核心：按 morph(0=竖排,1=横排) 摆放每一行
#  * 背景永远是**一整块**圆角矩形，尺寸 = 所有行（含百分比）的包围盒 + 内边距
#  * 错峰顺序：离目标边框最近的那个图标最先放平，其余依次跟上
function Update-Layout {
  $n = $script:Canvas.Children.Count
  $pad = $script:Pad
  if ($n -lt 1) {
    $c = $script:Circle + 2 * $pad
    $script:Pill.Width = $c; $script:Pill.Height = $c
    $script:Canvas.Width = $c; $script:Canvas.Height = $c
    $script:Win.Width = $c + 2; $script:Win.Height = $c + 2
    return
  }

  $labelsOn = $script:Active -and (-not $script:Dragging)
  $horiz = ($script:Morph -ge 0.5)

  # 标签显隐 / 行内部排布：**只在 Update-Layout 里统一决定**。
  # 之前 Apply-State 和 Update-Layout 各算一遍，两处状态会漂移 →
  # 出现「百分比跑到图标下面」「底图没跟着变大」这类不自洽。
  $visKey = "$labelsOn|$horiz|$($script:Edge)"
  if ($script:VisKey -ne $visKey) {
    if ($env:HUD_LABEL_DEBUG) {
      Write-Log ("vischange {0} (active={1} dragging={2} refs={3})" -f $visKey, $script:Active, $script:Dragging, $script:LabelRefs.Count)
    }
    Set-LabelsVisible $labelsOn
    Apply-RowOrientation
    $script:MetricsKey = ''      # 行尺寸取决于这两者，必须重量
    $script:VisKey = $visKey
  }
  Update-Metrics $horiz $labelsOn

  # ---- 列车模型：所有图标在同一条「直角轨道」上匀速跟进，间距恒定 ----
  # 轨道 = 竖臂(向下) → 圆角 → 横臂(向右)。头车（最靠边框的图标）先沿横臂走，
  # 后面的沿轨道向上走到拐角再跟上去。所有人沿同一轨道匀速前进：
  #   * 间距恒等于 step        → 几何上不可能重叠
  #   * 轨道总长不变           → 底框不是「变大」，是把竖的一段拉伸成横的一段
  $step = $script:Circle + $script:Gap
  $r = $script:Circle / 2
  $rc = [Math]::Max(24.0, $script:Circle * $script:CornerScale)   # 中心线圆角半径（cornerScale 越大内圈越圆滑）
  $larc = [Math]::PI / 2 * $rc                        # 四分之一圆弧的弧长
  $dmax = ($n - 1) * $step + $larc                    # 头车要走的总距离（= 在轨要推的距离）
  $d = $script:Morph * $dmax
  $script:Dmax = $dmax

  # 弯折方向：在轨时由铁轨决定（贴哪条边就绕哪条边）；自由拖动时不弯
  $fromTop = $true
  if ($script:RailEdge -eq 'top') {
    $fromTop = $true
    $mx = $script:RailMirror
  } elseif ($script:RailEdge -eq 'bottom') {
    $fromTop = $false
    $mx = $script:RailMirror
  } elseif ($script:Dragging) {
    $mx = 1.0
    # 不在轨上 → morph 必为 0，方向随手放在哪边都行（不会真的画出来）
    $cp = New-Object HudNative.Win+POINT
    if ([HudNative.Win]::GetCursorPos([ref]$cp)) {
      $ccy = $cp.Y / $script:Scale
      $midY = ($script:WorkDip.Top + $script:WorkDip.Bottom) / 2
      if ($ccy -gt $midY) { $fromTop = $false }
    }
  } elseif ($script:Edge -eq 'bottom') {
    $fromTop = $false
    $mx = 1.0
  } elseif ($script:Edge -eq 'right') {
    $mx = -1.0
  } else {
    $mx = 1.0
  }
  $my = 1.0
  if (-not $fromTop) { $my = -1.0 }

  $inFlight = ($script:Morph -gt 0.005 -and $script:Morph -lt 0.995)
  # 头车 = 最靠近目标边框的那个图标（贴上边→第 0 个；贴下边→最后一个）
  $headIdx = 0
  if (-not $fromTop) { $headIdx = $n - 1 }
  # 标签在图标左侧时（贴右边框），行的左上角要向左让出标签宽度
  $labelLeft = ((-not $horiz) -and $script:Edge -eq 'right')

  # 轨道取点：t 为带符号弧长（0=圆弧起点，负=还在竖臂上，>=larc=已上横臂）
  # 返回中心线坐标（canonical：竖臂向下、横臂向右）
  $script:_rc = $rc
  $script:_larc = $larc

  $pos = New-Object System.Collections.ArrayList
  $minX = 1e9; $minY = 1e9; $maxX = -1e9; $maxY = -1e9
  for ($i = 0; $i -lt $n; $i++) {
    $m = $script:Metrics[$i]
    $t = $d - ([Math]::Abs($i - $headIdx)) * $step
    if ($t -le 0) { $tcx = 0.0; $tcy = $rc - $t }
    elseif ($t -ge $larc) { $tcx = $rc + $t - $larc; $tcy = 0.0 }
    else {
      $th = [Math]::PI / 2 * ($t / $larc)
      $tcx = $rc - $rc * [Math]::Cos($th)
      $tcy = $rc - $rc * [Math]::Sin($th)
    }
    $cX = $tcx * $mx
    $cY = $tcy * $my
    # 行的左上角：默认 = 图标中心 − 半径；标签在左时再向左让出标签宽
    $offX = $r
    if ($labelLeft) { $offX = $m.W - $r }
    $px = $cX - $offX
    $py = $cY - $r
    [void]$pos.Add([pscustomobject]@{ X = $px; Y = $py; W = $m.W; H = $m.H; CX = $cX; CY = $cY })
    if ($px -lt $minX) { $minX = $px }
    if ($py -lt $minY) { $minY = $py }
    if (($px + $m.W) -gt $maxX) { $maxX = $px + $m.W }
    if (($py + $m.H) -gt $maxY) { $maxY = $py + $m.H }
  }

  for ($i = 0; $i -lt $n; $i++) {
    $row = $script:Canvas.Children[$i]
    [System.Windows.Controls.Canvas]::SetLeft($row, ($pos[$i].X - $minX + $pad))
    [System.Windows.Controls.Canvas]::SetTop($row, ($pos[$i].Y - $minY + $pad))
  }

  $pillW = ($maxX - $minX) + 2 * $pad
  $pillH = ($maxY - $minY) + 2 * $pad
  if ($script:Canvas.Width -ne $pillW) { $script:Canvas.Width = $pillW }
  if ($script:Canvas.Height -ne $pillH) { $script:Canvas.Height = $pillH }
  if (-not $inFlight) {
    if ($script:Pill.Width -ne $pillW) { $script:Pill.Width = $pillW }
    if ($script:Pill.Height -ne $pillH) { $script:Pill.Height = $pillH }
  }

  # 背景：
  #   静止   → 一整块圆角矩形（含百分比）
  #   形变中 → 一条**有厚度的轨道线**跟着图标从竖臂拐到横臂。
  #            轨道总长恒定 → 视觉上不是变大，而是把竖段拉伸成横段。
  if ($inFlight) {
    try {
      $tHead = $d
      $tTail = $d - ($n - 1) * $step
      $pts = New-Object System.Windows.Media.PointCollection
      $segN = [Math]::Max(2.0, [Math]::Ceiling([Math]::Abs($tHead - $tTail) / 8))
      for ($j = 0; $j -le $segN; $j++) {
        $tt = $tTail + ($tHead - $tTail) * $j / $segN
        if ($tt -le 0) { $bx = 0.0; $by = $rc - $tt }
        elseif ($tt -ge $larc) { $bx = $rc + $tt - $larc; $by = 0.0 }
        else {
          $th2 = [Math]::PI / 2 * ($tt / $larc)
          $bx = $rc - $rc * [Math]::Cos($th2)
          $by = $rc - $rc * [Math]::Sin($th2)
        }
        [void]$pts.Add([System.Windows.Point]::new(($bx * $mx - $minX + $pad), ($by * $my - $minY + $pad)))
      }
      $fig = New-Object System.Windows.Media.PathFigure
      $fig.StartPoint = $pts[0]
      if ($pts.Count -gt 1) {
        $sg = New-Object System.Windows.Media.PolyLineSegment
        for ($j = 1; $j -lt $pts.Count; $j++) { $sg.Points.Add($pts[$j]) }
        $fig.Segments.Add($sg)
      }
      $geo = New-Object System.Windows.Media.PathGeometry
      $geo.Figures.Add($fig)
      $script:BendPath.Data = $geo
      $script:BendPath.Visibility = 'Visible'
      $script:Pill.Visibility = 'Collapsed'
    } catch { $script:BendPath.Visibility = 'Collapsed'; $script:Pill.Visibility = 'Visible' }
  } else {
    if ($script:BendPath.Visibility -ne 'Collapsed') { $script:BendPath.Visibility = 'Collapsed' }
    if ($script:Pill.Visibility -ne 'Visible') { $script:Pill.Visibility = 'Visible' }
  }

  # 明细框
  $idx = Get-CardIndex
  $needW = $pillW + 2
  $needH = $pillH + 2
  $pillLeft = 0.0; $pillTop = 0.0
  if ($idx -ge 0) {
    $inner = $script:CardScroll.Content
    $cardH = 0.0
    if ($inner) {
      try {
        $inner.Measure([System.Windows.Size]::new(($script:CardW - 2 * $script:CardPad - 14), [double]::PositiveInfinity))
        $cardH = $inner.DesiredSize.Height + 2 * $script:CardPad + 4
      } catch { $cardH = 0 }
    }
    if ($cardH -lt 40) { $cardH = 200 }
    if ($cardH -gt $script:CardPanel.MaxHeight) { $cardH = $script:CardPanel.MaxHeight }
    if ($script:CardPanel.Height -ne $cardH) { $script:CardPanel.Height = $cardH }
    $script:CardPanel.Visibility = 'Visible'

    $rowTop = $pos[$idx].Y - $minY + $pad
    $rowLeft = $pos[$idx].X - $minX + $pad
    if ($horiz -and $script:Morph -ge 0.99) {
      $cardX = $rowLeft
      if ($script:Edge -eq 'bottom') { $cardY = 0.0; $pillTop = $cardH + 10 }
      else { $cardY = $pillH + 10; $pillTop = 0.0 }
    } else {
      $cardY = $rowTop
      if ($script:Edge -eq 'right') { $cardX = 0.0; $pillLeft = $script:CardW + 10 }
      else { $cardX = $pillW + 10; $pillLeft = 0.0 }
    }
    $key = "$pillLeft,$pillTop"
    if ($script:LastPillMargin -ne $key) {
      $nm = New-Object System.Windows.Thickness $pillLeft, $pillTop, 0, 0
      $script:Pill.Margin = $nm
      $script:Canvas.Margin = $nm
      $script:LastPillMargin = $key
    }
    $script:CardPanel.Margin = New-Object System.Windows.Thickness $cardX, $cardY, 0, 0
    $needW = [Math]::Max($needW, $cardX + $script:CardW)
    $needH = [Math]::Max($needH, $cardY + $cardH)
    $needW = [Math]::Max($needW, $pillLeft + $pillW + 2)
    $needH = [Math]::Max($needH, $pillTop + $pillH + 2)
  } else {
    $script:CardPanel.Visibility = 'Collapsed'
    if ($script:LastPillMargin -ne '0,0') {
      $z = New-Object System.Windows.Thickness 0, 0, 0, 0
      $script:Pill.Margin = $z
      $script:Canvas.Margin = $z
      $script:LastPillMargin = '0,0'
    }
  }
  # 形变进行中把窗口尺寸**向上**量化到 6 DIP：每帧连续改窗口尺寸是卡顿主因
  # （WPF 要重排整棵树并重设分层窗口）。向上取整保证不裁内容，静止后回到精确尺寸。
  if ($inFlight) {
    $needW = [Math]::Ceiling($needW / 6) * 6
    $needH = [Math]::Ceiling($needH / 6) * 6
  }
  if ($script:Win.Width -ne $needW) { $script:Win.Width = $needW }
  if ($script:Win.Height -ne $needH) { $script:Win.Height = $needH }
}

# 兼容旧调用名
function Update-WindowSize { Update-Layout }

function Apply-SnapPosition {
  if ($env:HUD_FOLLOW_CURSOR) { return }
  $w = $script:Win.Width
  $h = $script:Win.Height
  $m = $script:EdgeMargin
  $x = $script:Win.Left
  $y = $script:Win.Top
  switch ($script:Edge) {
    'left'   { $x = $script:WorkDip.Left + $m }
    'right'  { $x = $script:WorkDip.Right - $w - $m }
    'top'    { $y = $script:WorkDip.Top + $m }
    'bottom' { $y = $script:WorkDip.Bottom - $h - $m }
  }
  if ($x -lt $script:WorkDip.Left) { $x = $script:WorkDip.Left }
  if ($x + $w -gt $script:WorkDip.Right) { $x = $script:WorkDip.Right - $w }
  if ($y -lt $script:WorkDip.Top) { $y = $script:WorkDip.Top }
  if ($y + $h -gt $script:WorkDip.Bottom) { $y = $script:WorkDip.Bottom - $h }
  $script:Win.Left = [Math]::Round($x)
  $script:Win.Top = [Math]::Round($y)
}

function Set-DefaultPosition {
  $x = $script:WorkDip.Left + $script:EdgeMargin
  $y = ($script:WorkDip.Top + $script:WorkDip.Height) / 2 - $script:Win.Height / 2
  $st = Read-State
  if ($st -and $st.edge) { $script:Edge = [string]$st.edge }
  if ($st -and $null -ne $st.offsetX -and $null -ne $st.offsetY) {
    $x = [double]$st.offsetX
    $y = [double]$st.offsetY
  }
  $script:Morph = 0.0
  if ($script:Edge -eq 'top' -or $script:Edge -eq 'bottom') { $script:Morph = 1.0 }
  Update-Layout
  $script:Win.Left = [Math]::Round($x)
  $script:Win.Top = [Math]::Round($y)
  Apply-SnapPosition
}

# ---------------------------------------------------------------- 铁轨模型
# 拖动时浮窗贴着屏幕边框滑行（像铺在屏幕四周的看不见的铁轨）：
#   * 自由拖动时不受力，但一顶到上/下边界，就「上轨」——窗口贴住那条边不再往外走，
#     继续往里推的距离转化为弯折量（推多少弯多少）；
#   * 往回拉，弯折同步退直，退直后才离开轨道恢复自由拖动；
#   * 弯折量 = 头车沿轨道走过的弧长，推满一整条轨道（dmax）正好完全打横。
$script:RailEdge = ''      # '' | 'top' | 'bottom'
$script:RailBend = 0.0     # 当前在轨弯折量（DIP）
$script:RailBend0 = 0.0    # 上轨那一刻的初始弯折量（抓着已打横的 → dmax；从直的顶进去 → 0）
$script:RailMirror = 1.0   # 上轨那一刻定死的横臂朝向（1=向右展，-1=向左展）

function Get-Dmax {
  $step = $script:Circle + $script:Gap
  $rc = [Math]::Max(24.0, $script:Circle * $script:CornerScale)
  return (($script:Canvas.Children.Count - 1) * $step + [Math]::PI / 2 * $rc)
}

function Apply-RailDrag([double]$dxDip, [double]$dyDip, $pt) {
  $unTop = $script:DragOrigin[1] + $dyDip
  $unLeft = $script:DragOrigin[0] + $dxDip
  $dmax = Get-Dmax
  $m = $script:EdgeMargin

  if ($script:RailEdge -eq '') {
    if ($unTop -lt ($script:WorkDip.Top + $m)) { $script:RailEdge = 'top' }
    elseif (($unTop + $script:Win.Height) -gt ($script:WorkDip.Bottom - $m)) { $script:RailEdge = 'bottom' }
    if ($script:RailEdge -ne '') {
      # 上轨那一刻的初始弯折量：抓着已打横的同一条边 → 满弯；从直的顶进去 → 0
      $script:RailBend0 = 0.0
      if ($script:Edge -eq $script:RailEdge) { $script:RailBend0 = $dmax }
      # 上轨那一刻定死横臂朝向（光标在屏幕左半 → 臂向右展，反之向左），中途不再翻转
      try {
        $cp0 = New-Object HudNative.Win+POINT
        if ([HudNative.Win]::GetCursorPos([ref]$cp0)) {
          $midX0 = ($script:WorkDip.Left + $script:WorkDip.Right) / 2
          if (($cp0.X / $script:Scale) -gt $midX0) { $script:RailMirror = -1.0 } else { $script:RailMirror = 1.0 }
        }
      } catch { $script:RailMirror = 1.0 }
    }
  }

  $bend = 0.0
  if ($script:RailEdge -eq 'top') {
    $glueY = $script:WorkDip.Top + $m
    $bend = [Math]::Max(0.0, [Math]::Min($dmax, ($script:RailBend0 + ($glueY - $unTop))))
    if ($bend -le 0) { $script:RailEdge = '' }        # 退直了 → 下轨，重新锚定拖动
  } elseif ($script:RailEdge -eq 'bottom') {
    $glueY = $script:WorkDip.Bottom - $script:Win.Height - $m
    $bend = [Math]::Max(0.0, [Math]::Min($dmax, ($script:RailBend0 + ($unTop - $glueY))))
    if ($bend -le 0) { $script:RailEdge = '' }
  }
  $script:RailBend = $bend

  if ($bend -gt 0) {
    # 在轨：贴住那条边，沿轨道滑动（左右仍可滑，但不能出屏）
    if ($script:RailEdge -eq 'top') { $script:Win.Top = [Math]::Round($script:WorkDip.Top + $m) }
    else { $script:Win.Top = [Math]::Round($script:WorkDip.Bottom - $script:Win.Height - $m) }
    $lx = [Math]::Max($script:WorkDip.Left, [Math]::Min($unLeft, ($script:WorkDip.Right - $script:Win.Width)))
    $script:Win.Left = [Math]::Round($lx)
    $script:Morph = [Math]::Min(1.0, $bend / $dmax)
  } else {
    if ($script:RailEdge -eq '') {
      # 刚下轨：把拖动原点重新锚到当前位置，避免「松开约束」瞬间的位置跳变
      $script:DragOrigin = @($unLeft, $unTop)
      $script:PressPt = $pt
    }
    $script:Win.Top = [Math]::Round($unTop)
    $script:Win.Left = [Math]::Round($unLeft)
    # 自由拖动也不许拖出屏幕
    if ($script:Win.Top -lt $script:WorkDip.Top) { $script:Win.Top = [Math]::Round($script:WorkDip.Top) }
    if (($script:Win.Top + $script:Win.Height) -gt $script:WorkDip.Bottom) { $script:Win.Top = [Math]::Round($script:WorkDip.Bottom - $script:Win.Height) }
    if ($script:Win.Left -lt $script:WorkDip.Left) { $script:Win.Left = [Math]::Round($script:WorkDip.Left) }
    if (($script:Win.Left + $script:Win.Width) -gt $script:WorkDip.Right) { $script:Win.Left = [Math]::Round($script:WorkDip.Right - $script:Win.Width) }
    $script:Morph = 0.0
  }
  Update-Layout
}

# 松手：在轨上就吸到那条边并完成弯折；否则按最近边吸附
function Snap-ToNearestEdge {
  try {
    $pick = $null
    if ($script:RailEdge -ne '' -and $script:RailBend -gt 0) {
      $pick = $script:RailEdge                      # 还弯着 → 顺势吸到这条边
    } else {
      $w = $script:Win.Width; $h = $script:Win.Height
      $l = $script:Win.Left - $script:WorkDip.Left
      $t = $script:Win.Top - $script:WorkDip.Top
      $r = $script:WorkDip.Right - ($script:Win.Left + $w)
      $b = $script:WorkDip.Bottom - ($script:Win.Top + $h)
      $horizEdge = 'top'; $horizD = $t
      if ($b -lt $horizD) { $horizEdge = 'bottom'; $horizD = $b }
      $vertEdge = 'left'; $vertD = $l
      if ($r -lt $vertD) { $vertEdge = 'right'; $vertD = $r }
      if ($horizD -le $script:SnapDist -and $horizD -le $vertD) { $pick = $horizEdge }
      elseif ($vertD -le $script:SnapDist) { $pick = $vertEdge }
      elseif ($horizD -le $script:SnapDist) { $pick = $horizEdge }
      else { $pick = $vertEdge }
    }

    $old = $script:Edge
    $script:Edge = $pick
    if ($old -ne $pick) { Write-Log ("snap: {0} -> {1} (rail={2})" -f $old, $pick, $script:RailEdge) }
    $script:Morph = 0.0
    if ($pick -eq 'top' -or $pick -eq 'bottom') { $script:Morph = 1.0 }
    $script:RailEdge = ''
    $script:RailBend = 0.0
    Update-Layout
    Apply-SnapPosition
    Write-State
  } catch { Write-Log ("snap error: {0}" -f $_.Exception.Message) }
}

# ---------------------------------------------------------------- 状态切换
function Apply-State {
  # 标签显隐交给 Update-Layout 统一决定（那里是唯一真相），这里不再单独设置，
  # 否则两处状态会漂移：出现「百分比在图标下方」「底图没跟着变大」这类不自洽。
  $idx = Get-CardIndex
  if ($idx -ge 0) { $script:CardScroll.Content = (Build-CardFor $script:Providers[$idx]) }
  Update-Layout
  if (-not $script:Dragging) { Apply-SnapPosition }
}

function Set-Active([bool]$on) {
  if ($script:Active -eq $on) { return }
  $script:Active = $on
  if (-not $on) { $script:SelectedId = $null }
  Apply-State
}

function Select-Provider([string]$id) {
  if ($script:SelectedId -eq $id) { $script:SelectedId = $null }
  else { $script:SelectedId = $id }
  $script:Active = $true
  Apply-State
}

# ---------------------------------------------------------------- 交互（轮询鼠标，不依赖 WPF 输入栈）
# 用每行真实的屏幕矩形做命中，不再手算坐标 —— 上一版「点智谱显示 Kimi」
# 就是因为手算的行高/起点和实际布局差了半行。
function Get-RowIndexAtPoint($pt) {
  try {
    $n = $script:Canvas.Children.Count
    for ($i = 0; $i -lt $n; $i++) {
      $row = $script:Canvas.Children[$i]
      try {
        $p0 = $row.PointToScreen([System.Windows.Point]::new(0, 0))
        $p1 = $row.PointToScreen([System.Windows.Point]::new($row.ActualWidth, $row.ActualHeight))
      } catch { continue }
      if ($pt.X -ge $p0.X -and $pt.X -le $p1.X -and $pt.Y -ge $p0.Y -and $pt.Y -le $p1.Y) { return $i }
    }
  } catch { }
  return -1
}

$script:BtnWasDown = $false
$script:RBtnWasDown = $false
$script:PressPt = $null
$script:PressIdx = -1
$script:DragOrigin = $null

$script:InputTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:InputTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$script:InputTimer.Add_Tick({
  try {
    $pt = New-Object HudNative.Win+POINT
    if (-not [HudNative.Win]::GetCursorPos([ref]$pt)) { return }
    $down = (([HudNative.Win]::GetAsyncKeyState(1)) -band 0x8000) -ne 0

    if ($down -and -not $script:BtnWasDown) {
      $script:BtnWasDown = $true
      # 只有「按下的那一刻光标就在浮窗上」才可能演变成拖动或点击。
      # 之前缺这个闸：在别的应用里长按拖动、路径扫过浮窗位置时，浮窗会被「跟车」拖走。
      $overAtPress = Test-CursorOverWindow
      if ($overAtPress) {
        $script:PressPt = $pt
        $script:PressIdx = Get-RowIndexAtPoint $pt
        $script:DragOrigin = @($script:Win.Left, $script:Win.Top)
      } else {
        $script:PressPt = $null
        $script:PressIdx = -1
        $script:DragOrigin = $null
      }
      $script:Dragging = $false
      if ($env:HUD_CLICK_DEBUG) { Write-Log ("press over={0} idx={1} at ({2},{3})" -f $overAtPress, $script:PressIdx, $pt.X, $pt.Y) }
    }
    elseif ($down -and $script:BtnWasDown) {
      if ($null -ne $script:PressPt) {
        $dx = $pt.X - $script:PressPt.X
        $dy = $pt.Y - $script:PressPt.Y
        if (-not $script:Dragging -and $null -ne $script:PressPt -and ([Math]::Abs($dx) -gt 4 -or [Math]::Abs($dy) -gt 4)) {
          $script:Dragging = $true
          $script:SelectedId = $null
          $script:RailEdge = ''
          $script:RailBend = 0.0
          $script:RailBend0 = 0.0
          # 抓住的是已打横（贴上/下边）的浮窗 → 立即上轨，保持打横，往下拉才逐渐退直
          if ($script:Edge -eq 'top' -or $script:Edge -eq 'bottom') {
            $script:RailEdge = $script:Edge
            $script:RailBend0 = (Get-Dmax)
            try {
              $cp1 = New-Object HudNative.Win+POINT
              if ([HudNative.Win]::GetCursorPos([ref]$cp1)) {
                $midX1 = ($script:WorkDip.Left + $script:WorkDip.Right) / 2
                if (($cp1.X / $script:Scale) -gt $midX1) { $script:RailMirror = -1.0 } else { $script:RailMirror = 1.0 }
              }
            } catch { }
          }
          if ($env:HUD_CLICK_DEBUG) { Write-Log ("drag start (rail={0})" -f $script:RailEdge) }
        }
        if ($script:Dragging -and $null -ne $script:DragOrigin) {
          Apply-RailDrag ($dx / $script:Scale) ($dy / $script:Scale) $pt
        }
      }
    }
    elseif (-not $down -and $script:BtnWasDown) {
      $script:BtnWasDown = $false
      $wasDrag = $script:Dragging
      $pressIdx = $script:PressIdx
      $script:PressPt = $null
      $script:PressIdx = -1
      $script:Dragging = $false
      $script:DragOrigin = $null
      if ($wasDrag) {
        Snap-ToNearestEdge
      } elseif ($pressIdx -ge 0) {
        $idxNow = Get-RowIndexAtPoint $pt
        if ($idxNow -eq $pressIdx -and $idxNow -lt $script:Providers.Count) {
          if ($env:HUD_CLICK_DEBUG) { Write-Log ("click idx={0} id={1}" -f $idxNow, $script:Providers[$idxNow].id) }
          Select-Provider $script:Providers[$idxNow].id
        }
      } elseif ($null -ne $script:SelectedId) {
        $script:SelectedId = $null
        Apply-State
      }
    }

    $rdown = (([HudNative.Win]::GetAsyncKeyState(2)) -band 0x8000) -ne 0
    if ($rdown -and -not $script:RBtnWasDown -and (Test-CursorOverWindow)) {
      try { $script:TrayMenu.Show([System.Windows.Forms.Cursor]::Position) } catch { }
    }
    $script:RBtnWasDown = $rdown
  } catch { }
})

# ---------------------------------------------------------------- 位置持久化
function Read-State {
  if (-not (Test-Path $script:StatePath)) { return $null }
  try { return Get-Content $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Write-State {
  try {
    $o = [ordered]@{
      offsetX = [int][Math]::Round($script:Win.Left)
      offsetY = [int][Math]::Round($script:Win.Top)
      edge    = [string]$script:Edge
    }
    ($o | ConvertTo-Json) | Set-Content -Path $script:StatePath -Encoding UTF8
  } catch { Write-Log "state save failed: $($_.Exception.Message)" }
}
$script:MoveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:MoveTimer.Interval = [TimeSpan]::FromSeconds(1.2)
$script:MoveTimer.Add_Tick({
  $script:MoveTimer.Stop()
  if (-not $script:Dragging) { Write-State }
})

# ---------------------------------------------------------------- 数据
function Read-Snapshot {
  if (-not (Test-Path $script:SnapshotPath)) { return $null }
  try {
    $raw = Get-Content $script:SnapshotPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
  } catch { return $null }
}

function Update-Content($snap) {
  if ($null -eq $snap) { return }
  if ($snap.updated -eq $script:LastUpdated) { return }
  $wasEmpty = $script:Canvas.Children.Count -eq 0

  $script:Providers = @($snap.providers)
  $script:LastUpdated = $snap.updated
  $script:LastUpdatedRaw = $snap.updated

  $script:Canvas.Children.Clear()
  $script:RingRefs = @()
  $script:LabelRefs = @()
  # 重建了行 → 新标签默认 Collapsed，必须让下一次布局重新应用显隐与尺寸，
  # 否则 VisKey/MetricsKey 还记着旧状态，增量分支被跳过，百分比会一直不显示。
  $script:VisKey = ''
  $script:MetricsKey = ''
  foreach ($p in $script:Providers) {
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Background = [System.Windows.Media.Brushes]::Transparent
    $ring = New-Ring $p
    [void]$row.Children.Add($ring)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = (Get-RowSummary $p)
    $lbl.Foreground = Get-Brush (Get-SolidColor (Get-RingColor $p)) 1.0
    $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
    $lbl.Visibility = 'Collapsed'
    [void]$row.Children.Add($lbl)

    $script:RingRefs += $ring
    $script:LabelRefs += $lbl
    [void]$script:Canvas.Children.Add($row)
  }
  if ($null -ne $script:SelectedId -and (Get-CardIndex) -lt 0) { $script:SelectedId = $null }
  Apply-State
  if ($wasEmpty) { Set-DefaultPosition }
  Write-Log ("rings updated: {0} providers [{1}]" -f $script:Providers.Count, (($script:Providers | ForEach-Object { $_.id }) -join ','))
}

# ---------------------------------------------------------------- 悬停
$script:HoverOutsideTicks = 0
$script:ActiveAt = [datetime]::MinValue
$script:ForceActive = [bool]$env:HUD_FORCE_ACTIVE
$script:ForceSelect = [string]$env:HUD_FORCE_SELECT
$script:ForceMorph = $env:HUD_FORCE_MORPH
$script:DemoT = 0.0
$script:PerfN = 0
$script:PerfSum = 0.0
$script:PerfMax = 0.0

function Test-CursorOverWindow {
  try {
    $pt = New-Object HudNative.Win+POINT
    if (-not [HudNative.Win]::GetCursorPos([ref]$pt)) { return $false }
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:Win).Handle
    $r = New-Object HudNative.Win+RECT
    if (-not [HudNative.Win]::GetWindowRect($h, [ref]$r)) { return $false }
    return ($pt.X -ge $r.Left -and $pt.X -lt $r.Right -and $pt.Y -ge $r.Top -and $pt.Y -lt $r.Bottom)
  } catch { return $false }
}

$script:HoverTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HoverTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:HoverTimer.Add_Tick({
  try {
    # 诊断：把每一行真实的屏幕矩形打出来，用来核对点击命中区是否和肉眼看到的图标对齐
    if ($env:HUD_RECT_DEBUG) {
      $parts = @()
      for ($ri = 0; $ri -lt $script:Canvas.Children.Count; $ri++) {
        $rw = $script:Canvas.Children[$ri]
        try {
          $a = $rw.PointToScreen([System.Windows.Point]::new(0, 0))
          $b = $rw.PointToScreen([System.Windows.Point]::new($rw.ActualWidth, $rw.ActualHeight))
          $parts += ("{0}:[{1},{2}]-[{3},{4}]" -f $ri, [int]$a.X, [int]$a.Y, [int]$b.X, [int]$b.Y)
        } catch { }
      }
      $line = "rectdbg " + ($parts -join '  ')
      if ($line -ne $script:LastRectDump) { $script:LastRectDump = $line; Write-Log $line }
    }
    # 诊断：百分比文字的实际状态（为什么看不见时用这个查）
    if ($env:HUD_LABEL_DEBUG) {
      $parts = @()
      for ($li = 0; $li -lt $script:LabelRefs.Count; $li++) {
        $lbl = $script:LabelRefs[$li]
        if ($null -eq $lbl) { continue }
        $col = ''
        try { if ($lbl.Foreground -is [System.Windows.Media.SolidColorBrush]) { $col = $lbl.Foreground.Color.ToString() } else { $col = [string]$lbl.Foreground } } catch { }
        $vis = ''
        try { $vis = [string]$lbl.Visibility } catch { }
        $parts += ("{0}:'{1}' vis={2} w={3:N1} fg={4}" -f $li, $lbl.Text, $vis, $lbl.ActualWidth, $col)
      }
      $line = "labeldbg " + ($parts -join '  |  ')
      if ($line -ne $script:LastLabelDump) { $script:LastLabelDump = $line; Write-Log $line }
    }
    if ($script:Dragging) { return }
    # 动画演示 + 计时：HUD_ANIM_DEMO=1 时让 morph 在 0↔1 之间来回扫，
    # 每 20 帧记一次平均/最慢耗时，用来判断拖动时到底还卡不卡。
    if ($env:HUD_ANIM_DEMO) {
      $script:DemoT += 0.06
      if ($script:DemoT -ge 2.0) { $script:DemoT = 0.0 }
      if ($script:DemoT -le 1.0) { $script:Morph = $script:DemoT } else { $script:Morph = 2.0 - $script:DemoT }
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      Update-Layout
      $sw.Stop()
      $script:PerfN++
      $script:PerfSum += $sw.Elapsed.TotalMilliseconds
      if ($sw.Elapsed.TotalMilliseconds -gt $script:PerfMax) { $script:PerfMax = $sw.Elapsed.TotalMilliseconds }
      if ($script:PerfN -ge 20) {
        Write-Log ("layout perf: avg={0:N2}ms max={1:N2}ms morph={2:N2}" -f ($script:PerfSum / $script:PerfN), $script:PerfMax, $script:Morph)
        $script:PerfN = 0; $script:PerfSum = 0.0; $script:PerfMax = 0.0
      }
    } elseif ($script:ForceMorph) {
      $script:Morph = [double]::Parse($script:ForceMorph)
      Update-Layout
    }
    if ($script:ForceActive) {
      if (-not $script:Active) { Set-Active $true }
      if ($script:ForceSelect -and $script:SelectedId -ne $script:ForceSelect) { Select-Provider $script:ForceSelect }
      return
    }
    if ($env:HUD_FOLLOW_CURSOR) {
      $fp = New-Object HudNative.Win+POINT
      [void][HudNative.Win]::GetCursorPos([ref]$fp)
      $script:Win.Left = [Math]::Round($fp.X / $script:Scale - 25)
      $script:Win.Top = [Math]::Round($fp.Y / $script:Scale - 25)
      $over = $true
    } else {
      $over = Test-CursorOverWindow
    }
    if ($over -and $script:HoverExpand) {
      $script:HoverOutsideTicks = 0
      if (-not $script:Active) { $script:Active = $true; $script:ActiveAt = Get-Date; Apply-State }
    } elseif ($script:Active) {
      if (((Get-Date) - $script:ActiveAt).TotalMilliseconds -lt 500) { return }
      $script:HoverOutsideTicks++
      if ($script:HoverOutsideTicks -ge 3) {
        $script:HoverOutsideTicks = 0
        $script:Active = $false
        $script:SelectedId = $null
        Apply-State
      }
    }
  } catch { }
})

# ---------------------------------------------------------------- 开关：单实例 + 热键 + 启动脚本
#
# 这块是补「找不到开关」的：之前除了托盘里一个没人认得的图标，没有任何入口。
#   * Ctrl+Alt+H            随时显示/隐藏（全局热键）
#   * 再双击 start-silent.vbs 当开关用（已在运行就切换显隐，不会开第二个）
#   * 托盘菜单里也有「显示/隐藏浮窗」
#   * 手动隐藏后不会被自动显隐规则立刻拉回来（UserHidden）
$script:ToggleFile  = Join-Path $script:Root 'toggle.cmd'
$script:UserHidden  = $false
$script:HotkeyOk    = $false

# 单实例：用一个独占打开的锁文件判定。
# 不用命名 Mutex —— 之前那版在 Global\ 上出异常时会「fail-open」（catch 里当成
# 自己是第一个），结果真的开出了第二个实例。文件独占是崩溃安全：进程一死句柄就释放，
# 不会留下需要手动清理的僵尸锁。
$script:LockPath = Join-Path $script:Root 'running.lock'
$script:LockStream = $null
$alreadyRunning = $false
try {
  $script:LockStream = [System.IO.File]::Open(
    $script:LockPath,
    [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None)
} catch {
  $alreadyRunning = $true
}
if ($alreadyRunning) {
  try { (Get-Date).Ticks | Set-Content -Path $script:ToggleFile -Encoding UTF8 } catch { }
  Write-Host 'Agent HUD Lite 已在运行 —— 已通知它切换显示/隐藏。'
  exit 0
}

function Toggle-Hud {
  try {
    if ($script:Win.IsVisible) {
      $script:UserHidden = $true
      $script:Win.Hide()
      Write-Log 'toggle: hidden by user'
    } else {
      $script:UserHidden = $false
      $script:Win.Show()
      Write-Log 'toggle: shown by user'
    }
  } catch { Write-Log ("toggle error: {0}" -f $_.Exception.Message) }
}

# ---------------------------------------------------------------- 托盘
$script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miToggle  = $script:TrayMenu.Items.Add('显示 / 隐藏浮窗    (Ctrl+Alt+H)')
$miRefresh = $script:TrayMenu.Items.Add('立即刷新数据')
$miPause   = $script:TrayMenu.Items.Add('暂停自动显隐')
$miReset   = $script:TrayMenu.Items.Add('重置位置')
$miPanel   = $script:TrayMenu.Items.Add('打开 DSH 面板')
$miStartup = $script:TrayMenu.Items.Add('开机自启')
[void]$script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit    = $script:TrayMenu.Items.Add('退出')

# 自己画一个认得出的托盘图标（深底 + 三个彩色小点），比默认的通用图标好找
function New-TrayIcon {
  try {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 22, 24, 32))
    $g.FillEllipse($bg, 1, 1, 30, 30)
    $cols = @(
      [System.Drawing.Color]::FromArgb(255, 77, 107, 254),
      [System.Drawing.Color]::FromArgb(255, 139, 92, 246),
      [System.Drawing.Color]::FromArgb(255, 16, 181, 165))
    for ($i = 0; $i -lt 3; $i++) {
      $b = New-Object System.Drawing.SolidBrush $cols[$i]
      $g.FillEllipse($b, 10, (7 + $i * 7), 6, 6)
      $b.Dispose()
    }
    $g.Dispose(); $bg.Dispose()
    $h = $bmp.GetHicon()
    $ico = [System.Drawing.Icon]::FromHandle($h)
    $bmp.Dispose()
    return $ico
  } catch { return [System.Drawing.SystemIcons]::Application }
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = New-TrayIcon
$script:Tray.Text = 'Agent HUD Lite — 左键显示/隐藏，右键菜单'
$script:Tray.ContextMenuStrip = $script:TrayMenu
$script:Tray.Visible = $true
# 双击托盘图标也切换显隐
$script:Tray.Add_MouseDoubleClick({ param($s, $e) Toggle-Hud })

$script:Paused = $false

$miToggle.Add_Click({ Toggle-Hud })
$miRefresh.Add_Click({
  try {
    $a = @($script:SnapshotScript, '--out', $script:SnapshotPath, '--interval', $script:RefreshSec)
    Start-Process -FilePath $script:NodeExe -ArgumentList $a -WindowStyle Hidden | Out-Null
  } catch { }
})
$miPause.Add_Click({
  $script:Paused = -not $script:Paused
  if ($script:Paused) { $miPause.Text = '恢复自动显隐'; Write-Log 'auto show/hide paused' }
  else { $miPause.Text = '暂停自动显隐'; Write-Log 'auto show/hide resumed' }
})
$miStartup.Add_Click({
  try {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnk = Join-Path $startup 'Agent HUD Lite.lnk'
    if (Test-Path $lnk) {
      Remove-Item $lnk -Force
      [System.Windows.Forms.NotifyIcon]::new() | Out-Null
      $script:Tray.ShowBalloonTip(2000, 'Agent HUD Lite', '已取消开机自启', [System.Windows.Forms.ToolTipIcon]::Info)
      Write-Log 'autostart removed'
    } else {
      $ws = New-Object -ComObject WScript.Shell
      $sc = $ws.CreateShortcut($lnk)
      $sc.TargetPath = 'wscript.exe'
      $sc.Arguments = '"' + (Join-Path $script:Root 'start-silent.vbs') + '"'
      $sc.WorkingDirectory = $script:Root
      $sc.IconLocation = 'wscript.exe,0'
      $sc.Description = 'Agent HUD Lite'
      $sc.Save()
      $script:Tray.ShowBalloonTip(2000, 'Agent HUD Lite', '已设为开机自启', [System.Windows.Forms.ToolTipIcon]::Info)
      Write-Log 'autostart added'
    }
  } catch { Write-Log ("autostart error: {0}" -f $_.Exception.Message) }
})
$miReset.Add_Click({
  try { Remove-Item $script:StatePath -Force -ErrorAction SilentlyContinue } catch { }
  Set-DefaultPosition
})
$miPanel.Add_Click({ if ($script:PanelUrl) { try { Start-Process $script:PanelUrl } catch { } } })
$miQuit.Add_Click({
  try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { }
  try { $script:Win.Close() } catch { }
  [System.Windows.Application]::Current.Shutdown()
})

# ---------------------------------------------------------------- watcher
$script:Watcher = $null

function Start-Watcher {
  # 先清掉本目录残留的 watcher（用完整脚本路径匹配，避免误杀别的目录、
  # 也避免改了目录名之后匹配串失配——之前写成 *agent-hud-lite*，
  # 结果改名后旧 watcher 永远清不掉，会越积越多互相覆盖输出文件）
  try {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:SnapshotScript) } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch { }
  $a = @($script:SnapshotScript, '--watch', '--out', $script:SnapshotPath, '--interval', $script:RefreshSec)
  try {
    $script:Watcher = Start-Process -FilePath $script:NodeExe -ArgumentList $a -WindowStyle Hidden -PassThru
    Write-Log ("watcher started pid={0} interval={1}s" -f $script:Watcher.Id, $script:RefreshSec)
  } catch {
    Write-Log "watcher failed: $($_.Exception.Message)"
  }
}

# ---------------------------------------------------------------- 定时器
$script:UiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UiTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:UiTimer.Add_Tick({
  # 启动脚本的第二重身份：再双击 start-silent.vbs 时，新进程拿不到互斥体会写一个
  # toggle 请求文件然后退出，这里消费它 → 变成「点一下就开关一次」。
  try {
    if (Test-Path $script:ToggleFile) {
      Start-Sleep -Milliseconds 60
      Remove-Item $script:ToggleFile -Force -ErrorAction SilentlyContinue
      Write-Log 'toggle request received from launcher'
      Toggle-Hud
    }
  } catch { }
  $snap = Read-Snapshot
  if ($snap) { Update-Content $snap }
})

$script:VisTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:VisTimer.Interval = [TimeSpan]::FromMilliseconds($script:PollMs)
$script:VisTimer.Add_Tick({
  if ($script:Paused) { return }
  try {
    # 用户手动隐藏了就不要再自动弹回来；但要是窗口在被别的虚拟桌面遮住（Cloaked），
    # 这里会记一笔，方便以后排查「明明该显示却看不见」。
    if ($script:UserHidden) {
      if (-not $script:Win.IsVisible) {
        if ($script:LastReason -ne 'user hidden') { $script:LastReason = 'user hidden'; Write-Log 'visibility stays hidden (user)' }
        return
      }
      $script:UserHidden = $false
    }
    $fg = Get-ForegroundInfo
    $d = Resolve-Visibility $fg $script:WorkArea
    if ($d.Show) {
      if (-not $script:Win.IsVisible) {
        $script:Win.Show()
        Write-Log 'window re-shown'
      }
    } else {
      if ($script:Win.IsVisible) { $script:Win.Hide() }
    }
    if ($d.Reason -ne $script:LastReason) {
      $script:LastReason = $d.Reason
      Write-Log ("visibility={0}  {1}" -f $d.Show, $d.Reason)
    }
  } catch {
    Write-Log "visibility tick error: $($_.Exception.Message)"
  }
})
$script:LastReason = ''

# ---------------------------------------------------------------- 启动
$script:Win.Add_SourceInitialized({
  if ($env:HUD_NO_TOOLWIN) { return }
  $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:Win).Handle
  $ex = [HudNative.Win]::GetWindowLong($h, -20)
  [void][HudNative.Win]::SetWindowLong($h, -20, ($ex -bor 0x80))   # WS_EX_TOOLWINDOW：不进 Alt+Tab

  # 全局热键 Ctrl+Alt+H → 显示/隐藏
  # 注意：HwndSource.AddHook 的回调里**绝不能**碰第 5 个参数（handled）——
  # PowerShell 5.1 里它按值传入（bool），给它 .Value 赋值会抛
  # 「在此对象上找不到属性 Value」，且这个异常发生在消息泵最深处，会带走整个进程。
  # 15:26 / 15:31 / 15:44 的三次 FATAL 全是它。所以这里只 return，不标记 handled。
  try {
    $MOD_ALT = 0x0001; $MOD_CONTROL = 0x0002; $VK_H = 0x48
    $script:HotkeyOk = [HudNative.Win]::RegisterHotKey($h, 1, ($MOD_CONTROL -bor $MOD_ALT), $VK_H)
    if ($script:HotkeyOk) {
      $src = [System.Windows.Interop.HwndSource]::FromHwnd($h)
      if ($src) {
        $src.AddHook({
          param($h2, $m, $w, $l)
          if ($m -eq 0x0312 -and [int]$w -eq 1) {
            try { Toggle-Hud } catch { }
          }
          return [IntPtr]::Zero
        })
      }
      Write-Log 'hotkey Ctrl+Alt+H registered'
    } else {
      Write-Log 'hotkey Ctrl+Alt+H FAILED (可能已被别的程序占用)'
    }
  } catch { Write-Log ("hotkey error: {0}" -f $_.Exception.Message) }
})

$script:Win.Add_Closed({
  try { $script:Tray.Visible = $false } catch { }
  if ($script:Watcher -and -not $script:Watcher.HasExited) {
    try { Stop-Process -Id $script:Watcher.Id -Force -ErrorAction SilentlyContinue } catch { }
  }
  # 主动退出：停掉心跳，让看门狗知道这是退出而不是崩溃，随后收掉看门狗自己
  try {
    Remove-Item $script:HeartbeatPath -Force -ErrorAction SilentlyContinue
    New-Item -Path (Join-Path $script:Root 'watchdog.stop') -ItemType File -Force | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -and $_.CommandLine.Contains('watchdog.ps1') -and $_.ProcessId -ne $PID } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch { }
})

Write-Log ("=== start (circle={0} DIP = {1} 物理px, poll={2}ms, refresh={3}s) ===" -f $script:Circle, ($script:Circle * $script:Scale), $script:PollMs, $script:RefreshSec)

# 第一次运行时用气泡提示「开关在哪」——这个之前最容易找不到
$script:HintFile = Join-Path $script:Root 'hint-shown.marker'
if (-not (Test-Path $script:HintFile)) {
  try {
    $script:Tray.ShowBalloonTip(6000, 'Agent HUD Lite 已启动',
      "开关：Ctrl+Alt+H 显示/隐藏；也可以再双击一次 start-silent.vbs。`n托盘图标（三个彩色小点）双击同样是开关。",
      [System.Windows.Forms.ToolTipIcon]::Info)
    'shown' | Set-Content -Path $script:HintFile -Encoding UTF8
    Write-Log 'first-run hint balloon shown'
  } catch { }
}

Start-Watcher
Update-WindowSize
Set-DefaultPosition
$script:UiTimer.Start()
$script:VisTimer.Start()
$script:HoverTimer.Start()
$script:InputTimer.Start()

# 看门狗：主进程每 5s 续写心跳；独立守护进程发现心跳断了（= 崩溃/被杀）就自动拉起。
# 解决「进程无声死掉后没有任何入口能叫回来」——中午那次的直接原因。
$script:HeartbeatPath = Join-Path $script:Root 'heartbeat.txt'
$script:HeartbeatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HeartbeatTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:HeartbeatTimer.Add_Tick({
  try { (Get-Date).Ticks | Set-Content -Path $script:HeartbeatPath -Encoding UTF8 } catch { }
})
$script:HeartbeatTimer.Start()
try {
  # 仓库里已经附带了 watchdog.ps1，优先直接用它（自定位、不烧绝对路径）。
  # 只有在文件缺失时才现场生成一份兜底，生成的内容同样用 $PSScriptRoot 自定位。
  $wdPath = Join-Path $script:Root 'watchdog.ps1'
  if (-not (Test-Path $wdPath)) {
    $watchdogPs = @"
`$root = `$PSScriptRoot
if (-not `$root) { `$root = Split-Path -Parent `$MyInvocation.MyCommand.Path }
`$hb = Join-Path `$root 'heartbeat.txt'
`$vbs = Join-Path `$root 'start-silent.vbs'
`$stopFile = Join-Path `$root 'watchdog.stop'
`$lockPath = Join-Path `$root 'watchdog.lock'
try { `$lk = [System.IO.File]::Open(`$lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) } catch { exit 0 }
if (Test-Path `$stopFile) { Remove-Item `$stopFile -Force -ErrorAction SilentlyContinue }
while (`$true) {
  Start-Sleep -Seconds 20
  try {
    if (Test-Path `$stopFile) { break }
    `$need = `$false
    if (-not (Test-Path `$hb)) { `$need = `$true }
    else {
      `$age = ((Get-Date) - (Get-Item `$hb).LastWriteTime).TotalSeconds
      if (`$age -gt 40) { `$need = `$true }
    }
    if (`$need) { & wscript.exe `$vbs; Start-Sleep -Seconds 25 }
  } catch { Start-Sleep -Seconds 20 }
}
"@
    [System.IO.File]::WriteAllText($wdPath, $watchdogPs, [System.Text.UTF8Encoding]::new($true))
    Write-Log 'watchdog.ps1 was missing - generated a self-locating one'
  }
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$wdPath) -WindowStyle Hidden
  Write-Log 'watchdog started'
} catch { Write-Log ("watchdog start failed: {0}" -f $_.Exception.Message) }

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
try {
  $app.Run($script:Win) | Out-Null
} catch {
  # 全局兜底：未捕获异常不再无声带走进程，落盘后由看门狗拉起
  try { Write-Log ("FATAL: {0}" -f $_.Exception.ToString().Replace("`r`n", ' | ')) } catch { }
  throw
}
