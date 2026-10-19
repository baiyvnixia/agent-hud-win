Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Bk -Name W -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
[void][Bk.W]::SetProcessDPIAware()

# 全屏纯色衬底（浅灰），让深色浮窗看得清；它是 topmost，但浮窗创建更晚 → 浮窗在上
$bg = New-Object System.Windows.Window
$bg.WindowStyle = 'None'
$bg.ResizeMode = 'NoResize'
$bg.AllowsTransparency = $false
$bg.Topmost = $true
$bg.ShowInTaskbar = $false
$bg.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(238, 240, 245))
$bg.Left = 0; $bg.Top = 0; $bg.Width = 1920; $bg.Height = 1080
$bg.Show()
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.Run($bg) | Out-Null
