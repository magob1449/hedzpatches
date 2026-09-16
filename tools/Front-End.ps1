<#
.SYNOPSIS
    Front-End.ps1 - inspect and drive the H.E.D.Z. front-end dialog.

.DESCRIPTION
    The front end is a plain Win32 dialog (class #32770, caption "H.E.D.Z."). This
    enumerates its child controls (class, control id, text) and can click one by
    text match, so the attract/level code paths can be reached without a human at
    the keyboard.

    Clicking is done with BM_CLICK (works on owner-drawn buttons too, because the
    dialog still receives the WM_COMMAND/BN_CLICKED it routed).

.PARAMETER List
    Just list the controls (default if no action given).

.PARAMETER Click
    Substring of the button text to click, e.g. "New".

.PARAMETER Enter
    Post WM_KEYDOWN/WM_KEYUP VK_RETURN to the dialog (default button).

.EXAMPLE
    .\Front-End.ps1 -List
.EXAMPLE
    .\Front-End.ps1 -Click New
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$Click,
    [switch]$Enter
)

$ErrorActionPreference = 'Stop'

if (-not ('FE' -as [type])) {
    Add-Type -Namespace FE -Name U -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
}

$BM_CLICK  = 0x00F5
$WM_KEYDOWN = 0x0100
$WM_KEYUP   = 0x0101
$VK_RETURN  = 0x0D

function Get-Text([IntPtr]$h) {
    $n = [FE.U]::GetWindowTextLength($h)
    $sb = New-Object Text.StringBuilder (($n + 2))
    [void][FE.U]::GetWindowText($h, $sb, $sb.Capacity)
    $sb.ToString()
}
function Get-Cls([IntPtr]$h) {
    $sb = New-Object Text.StringBuilder 128
    [void][FE.U]::GetClassName($h, $sb, $sb.Capacity)
    $sb.ToString()
}

$dlg = [FE.U]::FindWindow('#32770', 'H.E.D.Z.')
if ($dlg -eq [IntPtr]::Zero) {
    Write-Host 'front-end dialog (#32770 "H.E.D.Z.") not found.' -ForegroundColor Yellow
    # fall back to any visible window owned by Hedz.exe
    Get-Process Hedz -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("  Hedz.exe pid={0} main='{1}' title='{2}'" -f $_.Id, $_.MainWindowHandle, $_.MainWindowTitle) }
    return
}
Write-Host ("dialog hwnd = 0x{0:X}" -f [int64]$dlg)

$controls = New-Object Collections.Generic.List[object]
$child = [FE.U]::FindWindowEx($dlg, [IntPtr]::Zero, $null, $null)
while ($child -ne [IntPtr]::Zero) {
    $controls.Add([pscustomobject]@{
        hwnd    = $child
        id      = [FE.U]::GetDlgCtrlID($child)
        class   = Get-Cls $child
        text    = Get-Text $child
        visible = [FE.U]::IsWindowVisible($child)
        enabled = [FE.U]::IsWindowEnabled($child)
    })
    $child = [FE.U]::FindWindowEx($dlg, $child, $null, $null)
}

Write-Host ("child controls: {0}" -f $controls.Count)
$controls | ForEach-Object {
    Write-Host ("  hwnd=0x{0:X8} id={1,-6} [{2}] visible={3} enabled={4} text='{5}'" -f `
        [int64]$_.hwnd, $_.id, $_.class, $_.visible, $_.enabled, $_.text)
}

if ($Enter) {
    [void][FE.U]::SetForegroundWindow($dlg)
    [void][FE.U]::PostMessage($dlg, $WM_KEYDOWN, [IntPtr]$VK_RETURN, [IntPtr]0x001C0001)
    [void][FE.U]::PostMessage($dlg, $WM_KEYUP,   [IntPtr]$VK_RETURN, [IntPtr]0xC01C0001)
    Write-Host 'posted VK_RETURN to the dialog.'
}

if ($Click) {
    $target = $controls | Where-Object { $_.text -like "*$Click*" -and $_.visible } | Select-Object -First 1
    if (-not $target) {
        $target = $controls | Where-Object { $_.text -like "*$Click*" } | Select-Object -First 1
    }
    if (-not $target) { Write-Host "no control matching '$Click'" -ForegroundColor Yellow; return }
    [void][FE.U]::SetForegroundWindow($dlg)
    [void][FE.U]::SendMessage($target.hwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
    Write-Host ("clicked '{0}' (hwnd=0x{1:X8} id={2})" -f $target.text, [int64]$target.hwnd, $target.id)
}
