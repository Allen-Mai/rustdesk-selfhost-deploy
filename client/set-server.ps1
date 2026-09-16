<#
.SYNOPSIS
    RustDesk 客户端服务器配置工具（把 ID 服务器 / 中继服务器 / Key 写入客户端配置）。

.DESCRIPTION
    无需在 RustDesk 界面里手填，直接写入配置文件：
        %APPDATA%\RustDesk\config\RustDesk2.toml

    两种运行方式：
      - 弹窗模式：弹出设置窗口，改完点「确定」即可（双击 2-修改服务器设置.bat）
      - 静默模式：用 -Silent 直接套用预设值（双击 1-一键配置并启动.bat）

    写入前会自动：
      1. 关闭正在运行的 RustDesk（否则客户端退出时会回写覆盖我们的修改）
      2. 备份原文件为 RustDesk2.toml.bak

.PARAMETER Silent
    不弹窗，直接使用 服务器设置.ini 里的预设值。

.PARAMETER NoLaunch
    配置完成后不启动 RustDesk。

.EXAMPLE
    .\set-server.ps1
    .\set-server.ps1 -Silent
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$IniPath  = Join-Path $ScriptDir '服务器设置.ini'
$ExePath  = Join-Path $ScriptDir 'rustdesk.exe'
$TomlDir  = Join-Path $env:APPDATA 'RustDesk\config'
$TomlPath = Join-Path $TomlDir 'RustDesk2.toml'

# ============== 预设值 ==============
# make-package.ps1 生成客户端包时会自动替换下面三个值。
# 也可以直接改同目录的 服务器设置.ini（那个优先）。
$PresetId    = '<YOUR_SERVER_IP>'
$PresetRelay = '<YOUR_SERVER_IP>'
$PresetKey   = '<YOUR_PUBLIC_KEY>'
# ===================================


# ---------------------------------------------------------------- TOML 读写
function Read-TomlFile {
    param([string]$Path)
    $res = @{
        Top      = New-Object System.Collections.ArrayList
        Sections = New-Object System.Collections.Specialized.OrderedDictionary
        Order    = New-Object System.Collections.ArrayList
    }
    if (-not (Test-Path $Path)) { return $res }
    $cur = ''
    foreach ($line in @(Get-Content -Path $Path -Encoding UTF8)) {
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            $cur = $matches[1].Trim()
            if (-not $res.Sections.Contains($cur)) {
                $res.Sections[$cur] = New-Object System.Collections.ArrayList
                [void]$res.Order.Add($cur)
            }
            continue
        }
        if ($cur -eq '') { [void]$res.Top.Add($line) }
        else { [void]$res.Sections[$cur].Add($line) }
    }
    return $res
}

function Get-TomlKey {
    param($Lines, [string]$Key)
    if ($null -eq $Lines) { return '' }
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*''?(.*?)''?\s*$'
    foreach ($l in $Lines) {
        if ($l -match $pattern) { return $matches[1].Trim() }
    }
    return ''
}

function Set-TomlKey {
    param($Lines, [string]$Key, [string]$Value)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $pattern) { $Lines[$i] = "$Key = '$Value'"; return }
    }
    [void]$Lines.Add("$Key = '$Value'")
}

function Write-TomlFile {
    param($Cfg, [string]$Path)
    $out = New-Object System.Collections.ArrayList
    foreach ($l in $Cfg.Top) { [void]$out.Add($l) }
    foreach ($s in $Cfg.Order) {
        [void]$out.Add('')
        [void]$out.Add("[$s]")
        foreach ($l in $Cfg.Sections[$s]) { [void]$out.Add($l) }
    }
    $text = ($out -join "`r`n") + "`r`n"
    # 关键：必须写「不带 BOM 的 UTF-8」，带 BOM 的 TOML 会让 RustDesk 读取失败
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Stop-RustDesk {
    $procs = @(Get-Process rustdesk -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        # 客户端退出时会回写配置文件，所以必须先关掉再改
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

function Apply-Config {
    param([string]$IdServer, [string]$RelayServer, [string]$Key)
    if (-not (Test-Path $TomlDir)) { New-Item -ItemType Directory -Path $TomlDir -Force | Out-Null }
    $cfg = Read-TomlFile -Path $TomlPath
    Set-TomlKey -Lines $cfg.Top -Key 'rendezvous_server' -Value ("{0}:21116" -f $IdServer)
    if (-not $cfg.Sections.Contains('options')) {
        $cfg.Sections['options'] = New-Object System.Collections.ArrayList
        [void]$cfg.Order.Add('options')
    }
    $opt = $cfg.Sections['options']
    Set-TomlKey -Lines $opt -Key 'custom-rendezvous-server' -Value $IdServer
    Set-TomlKey -Lines $opt -Key 'relay-server'           -Value $RelayServer
    Set-TomlKey -Lines $opt -Key 'key'                    -Value $Key
    if (Test-Path $TomlPath) { Copy-Item $TomlPath "$TomlPath.bak" -Force }
    Write-TomlFile -Cfg $cfg -Path $TomlPath
}

function Save-Ini {
    param([string]$IdServer, [string]$RelayServer, [string]$Key)
    $lines = @(
        '# RustDesk 服务器设置（改完保存，下次运行 bat 就会用这里的值）',
        "ID_SERVER=$IdServer",
        "RELAY_SERVER=$RelayServer",
        "KEY=$Key"
    )
    $text = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($IniPath, $text, (New-Object System.Text.UTF8Encoding($true)))
}

function Start-RustDesk {
    if (Test-Path $ExePath) { Start-Process -FilePath $ExePath | Out-Null }
}


# ------------------------------------------------------------------ 读取初值
$IdServer    = $PresetId
$RelayServer = $PresetRelay
$Key         = $PresetKey

if (Test-Path $IniPath) {
    foreach ($line in @(Get-Content -Path $IniPath -Encoding UTF8)) {
        if     ($line -match '^\s*ID_SERVER\s*=\s*(.+?)\s*$')    { $IdServer    = $matches[1] }
        elseif ($line -match '^\s*RELAY_SERVER\s*=\s*(.+?)\s*$') { $RelayServer = $matches[1] }
        elseif ($line -match '^\s*KEY\s*=\s*(.+?)\s*$')          { $Key         = $matches[1] }
    }
}

# 只有「弹窗修改」模式才用现有配置值当前提（方便只改其中一项）。
# 静默模式必须用 ini/预设值：否则本机若存在旧配置（比如上次填错了），
# 会把错误的值原样再写回去，导致「一键配置」根本修不好。
if (-not $Silent -and (Test-Path $TomlPath)) {
    $old = Read-TomlFile -Path $TomlPath
    $v = Get-TomlKey -Lines $old.Sections['options'] -Key 'custom-rendezvous-server'
    if ($v) { $IdServer = $v }
    $v = Get-TomlKey -Lines $old.Sections['options'] -Key 'relay-server'
    if ($v) { $RelayServer = $v }
    $v = Get-TomlKey -Lines $old.Sections['options'] -Key 'key'
    if ($v) { $Key = $v }
}


# ------------------------------------------------------------------ 弹窗设置
if (-not $Silent) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'RustDesk 服务器设置'
    $form.Size            = New-Object System.Drawing.Size(560, 290)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.Font            = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $mkLabel = {
        param($text, $y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point(18, $y)
        $l.Size = New-Object System.Drawing.Size(120, 22); $l.TextAlign = 'MiddleRight'
        return $l
    }
    $mkBox = {
        param($text, $y)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Text = $text; $t.Location = New-Object System.Drawing.Point(146, $y)
        $t.Size = New-Object System.Drawing.Size(378, 24)
        return $t
    }

    $lblId  = & $mkLabel 'ID 服务器:' 22;   $tbId    = & $mkBox $IdServer 20
    $lblRl  = & $mkLabel '中继服务器:' 62;  $tbRelay = & $mkBox $RelayServer 60
    $lblKy  = & $mkLabel 'Key(公钥):' 102;  $tbKey   = & $mkBox $Key 100

    $tip = New-Object System.Windows.Forms.Label
    $tip.Text = '留空表示不设置该项。改完点「确定」会自动写入客户端配置并重启客户端。'
    $tip.Location = New-Object System.Drawing.Point(18, 138)
    $tip.Size = New-Object System.Drawing.Size(510, 34)
    $tip.ForeColor = [System.Drawing.Color]::DimGray
    $tip.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定'; $btnOk.Location = New-Object System.Drawing.Point(318, 186)
    $btnOk.Size = New-Object System.Drawing.Size(96, 32)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'; $btnCancel.Location = New-Object System.Drawing.Point(428, 186)
    $btnCancel.Size = New-Object System.Drawing.Size(96, 32)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.AddRange(@($lblId, $tbId, $lblRl, $tbRelay, $lblKy, $tbKey, $tip, $btnOk, $btnCancel))
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }

    $IdServer    = $tbId.Text.Trim()
    $RelayServer = $tbRelay.Text.Trim()
    $Key         = $tbKey.Text.Trim()

    if ($IdServer -eq '') {
        [void][System.Windows.Forms.MessageBox]::Show('ID 服务器不能为空。', '提示', 'OK', 'Warning')
        exit 1
    }
}


# --------------------------------------------------------------- 校验 + 写入
if ($IdServer -match "['`"]") {
    Write-Host '错误：ID 服务器里不能有引号。' -ForegroundColor Red
    exit 1
}
if ($Key -ne '' -and $Key -notmatch '^[A-Za-z0-9+/=]+$') {
    Write-Host '错误：Key 格式不对，应该是一串 base64 字符（结尾通常带一个 =）。' -ForegroundColor Red
    exit 1
}
if ($IdServer -eq '<YOUR_SERVER_IP>') {
    Write-Host '错误：还没设置服务器地址。请编辑 服务器设置.ini，或运行 2-修改服务器设置.bat。' -ForegroundColor Red
    exit 1
}

Stop-RustDesk
Apply-Config -IdServer $IdServer -RelayServer $RelayServer -Key $Key
Save-Ini     -IdServer $IdServer -RelayServer $RelayServer -Key $Key

$summary = @"
配置已写入：
$TomlPath

  ID 服务器   : $IdServer
  中继服务器  : $RelayServer
  Key(公钥)   : $Key

客户端需要重启才会生效（脚本会自动重启它）。
"@

Write-Host $summary -ForegroundColor Green

if (-not $Silent) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($summary, '配置完成', 'OK', 'Information')
}

if (-not $NoLaunch) {
    Start-RustDesk
    Write-Host 'RustDesk 已启动。' -ForegroundColor Green
}
