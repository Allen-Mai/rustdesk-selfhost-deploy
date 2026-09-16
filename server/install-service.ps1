<#
.SYNOPSIS
    在 Windows 上一键部署 RustDesk Server（hbbs + hbbr）为系统服务。

.DESCRIPTION
    1. 下载官方 rustdesk-server Windows 版
    2. 下载 WinSW（把控制台程序包装成 Windows 服务）
    3. 生成服务配置并注册为自动启动的 Windows 服务
    4. 添加 Windows 防火墙放行规则
    5. 打印客户端需要填写的公钥

    需要管理员权限运行。

.PARAMETER RelayServer
    中继服务器地址，填本机的公网 IP 或域名。
    这是 hbbs 的 -r 参数，客户端会用它做中继。必填。

.PARAMETER InstallDir
    安装目录，默认 C:\RustDeskServer

.PARAMETER ServerVersion
    rustdesk-server 版本，默认 1.1.16

.PARAMETER Mirror
    可选的 GitHub 加速前缀，用于国内网络，例如 https://gh-proxy.com/
    会拼成 <Mirror>https://github.com/...

.PARAMETER SkipFirewall
    跳过 Windows 防火墙规则添加

.EXAMPLE
    .\install-service.ps1 -RelayServer 203.0.113.10

.EXAMPLE
    .\install-service.ps1 -RelayServer rs.example.com -InstallDir D:\RustDesk -Mirror https://gh-proxy.com/
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RelayServer,

    [string]$InstallDir = 'C:\RustDeskServer',
    [string]$ServerVersion = '1.1.16',
    [string]$WinSwVersion = 'v2.12.0',
    [string]$Mirror = '',
    [switch]$SkipFirewall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step  { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "    [!] $m" -ForegroundColor Yellow }

if ($Mirror -and -not $Mirror.EndsWith('/')) { $Mirror = "$Mirror/" }

# ---------------------------------------------------------------- 前置检查
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    throw '需要管理员权限。请用「以管理员身份运行」打开 PowerShell 后重试。'
}

Write-Host '=====================================================' -ForegroundColor White
Write-Host '  RustDesk Server 安装程序 (hbbs + hbbr)' -ForegroundColor White
Write-Host '=====================================================' -ForegroundColor White
Write-Host "  中继地址   : $RelayServer"
Write-Host "  安装目录   : $InstallDir"
Write-Host "  服务端版本 : $ServerVersion"
if ($Mirror) { Write-Host "  加速镜像   : $Mirror" }

# ---------------------------------------------------------------- 准备目录
Write-Step '准备安装目录'
foreach ($d in @($InstallDir, (Join-Path $InstallDir 'logs'), (Join-Path $InstallDir 'service'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Write-Ok $InstallDir

$tmp = Join-Path $env:TEMP ("rd-server-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    # ------------------------------------------------------------ 下载服务端
    Write-Step '下载 rustdesk-server'
    $zipUrl  = "${Mirror}https://github.com/rustdesk/rustdesk-server/releases/download/$ServerVersion/rustdesk-server-windows-x86_64-unsigned.zip"
    $zipPath = Join-Path $tmp 'server.zip'
    Write-Host "    $zipUrl"
    curl.exe -L --retry 3 --connect-timeout 20 -o $zipPath $zipUrl
    if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1MB) {
        throw "下载失败或文件不完整：$zipUrl`n（国内网络可加 -Mirror https://gh-proxy.com/ 参数重试）"
    }
    Write-Ok ("$([math]::Round((Get-Item $zipPath).Length/1MB,2)) MB")

    Write-Step '解压'
    Expand-Archive -Path $zipPath -DestinationPath $tmp -Force
    # 压缩包内是 x86_64\ 子目录
    $binDir = Join-Path $tmp 'x86_64'
    if (-not (Test-Path $binDir)) { $binDir = $tmp }
    foreach ($f in @('hbbs.exe', 'hbbr.exe', 'rustdesk-utils.exe')) {
        $src = Join-Path $binDir $f
        if (-not (Test-Path $src)) { throw "压缩包里找不到 $f" }
        Copy-Item $src (Join-Path $InstallDir $f) -Force
        Write-Ok $f
    }

    # ------------------------------------------------------------ 下载 WinSW
    Write-Step '下载 WinSW（服务包装器）'
    $winswUrl  = "${Mirror}https://github.com/winsw/winsw/releases/download/$WinSwVersion/WinSW-x64.exe"
    $winswPath = Join-Path $tmp 'WinSW-x64.exe'
    Write-Host "    $winswUrl"
    curl.exe -L --retry 3 --connect-timeout 20 -o $winswPath $winswUrl
    if (-not (Test-Path $winswPath) -or (Get-Item $winswPath).Length -lt 100KB) {
        throw "WinSW 下载失败：$winswUrl"
    }
    Write-Ok ("$([math]::Round((Get-Item $winswPath).Length/1KB,0)) KB")

    # ------------------------------------------------------------ 生成服务配置
    Write-Step '生成服务配置'
    $svcDir = Join-Path $InstallDir 'service'
    $pairs = @(
        @{ Name = 'hbbs-svc'; Tpl = 'hbbs-svc.xml.template' },
        @{ Name = 'hbbr-svc'; Tpl = 'hbbr-svc.xml.template' }
    )
    foreach ($p in $pairs) {
        $tplPath = Join-Path $PSScriptRoot $p.Tpl
        if (-not (Test-Path $tplPath)) { throw "缺少模板文件 $($p.Tpl)，请确认脚本与模板在同一目录" }
        $xml = Get-Content $tplPath -Raw -Encoding UTF8
        $xml = $xml.Replace('{{INSTALL_DIR}}',  $InstallDir)
        $xml = $xml.Replace('{{RELAY_SERVER}}', $RelayServer)
        # 必须写成不带 BOM 的 UTF-8，WinSW 才能正确解析
        [IO.File]::WriteAllText(
            (Join-Path $svcDir "$($p.Name).xml"), $xml, (New-Object Text.UTF8Encoding($false))
        )
        Copy-Item $winswPath (Join-Path $svcDir "$($p.Name).exe") -Force
        Write-Ok "$($p.Name).xml / $($p.Name).exe"
    }

    # ------------------------------------------------------------ 注册服务
    Write-Step '注册 Windows 服务'
    foreach ($svc in @('rustdesk-hbbs', 'rustdesk-hbbr')) {
        $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Warn2 "$svc 已存在，先卸载旧的"
            $exeName = if ($svc -eq 'rustdesk-hbbs') { 'hbbs-svc.exe' } else { 'hbbr-svc.exe' }
            & (Join-Path $svcDir $exeName) stop   2>&1 | Out-Null
            & (Join-Path $svcDir $exeName) uninstall 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
    }
    foreach ($p in $pairs) {
        $out = & (Join-Path $svcDir "$($p.Name).exe") install 2>&1 | Out-String
        if ($out -match 'error|错误') { Write-Warn2 $out.Trim() }
    }
    Start-Sleep -Seconds 2

    Write-Step '启动服务'
    foreach ($svc in @('rustdesk-hbbs', 'rustdesk-hbbr')) {
        Start-Service -Name $svc
    }
    Start-Sleep -Seconds 8

    Get-Service rustdesk-hbbs, rustdesk-hbbr |
        Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Host

    # ------------------------------------------------------------ 防火墙
    if (-not $SkipFirewall) {
        Write-Step '添加 Windows 防火墙放行规则'
        $r1 = Get-NetFirewallRule -DisplayName 'RustDesk Server (TCP 21115-21119)' -ErrorAction SilentlyContinue
        if (-not $r1) {
            New-NetFirewallRule -DisplayName 'RustDesk Server (TCP 21115-21119)' -Direction Inbound `
                -Action Allow -Protocol TCP -LocalPort 21115-21119 -Profile Any | Out-Null
        }
        $r2 = Get-NetFirewallRule -DisplayName 'RustDesk Server (UDP 21116)' -ErrorAction SilentlyContinue
        if (-not $r2) {
            New-NetFirewallRule -DisplayName 'RustDesk Server (UDP 21116)' -Direction Inbound `
                -Action Allow -Protocol UDP -LocalPort 21116 -Profile Any | Out-Null
        }
        Write-Ok 'TCP 21115-21119 / UDP 21116'
    }

    # ------------------------------------------------------------ 读取公钥
    Write-Step '读取服务端公钥'
    $pubPath = Join-Path $InstallDir 'id_ed25519.pub'
    $key = ''
    for ($i = 0; $i -lt 15; $i++) {
        if (Test-Path $pubPath) {
            $key = (Get-Content $pubPath -Raw).Trim()
            if ($key) { break }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $key) {
        # 退而求其次：从服务日志里抓
        $log = Join-Path $InstallDir 'logs\hbbs-svc.out.log'
        if (Test-Path $log) {
            $m = Select-String -Path $log -Pattern 'Key:\s*(\S+)' | Select-Object -Last 1
            if ($m) { $key = $m.Matches.Groups[1].Value }
        }
    }

    # ------------------------------------------------------------ 汇总
    Write-Host ''
    Write-Host '=====================================================' -ForegroundColor Green
Write-Host '  服务端安装完成' -ForegroundColor Green
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host '客户端需要填写：' -ForegroundColor White
    Write-Host "  ID 服务器   : $RelayServer"
    Write-Host "  中继服务器  : $RelayServer"
    Write-Host "  Key(公钥)   : $(if ($key) { $key } else { '（未能自动读取，见 ' + $pubPath + '）' })"
    Write-Host ''
    Write-Host '!!! 最后一步：在云控制台放行端口 !!!' -ForegroundColor Yellow
    Write-Host '  必须添加【两条】入站规则：' -ForegroundColor Yellow
    Write-Host '    规则 1:  TCP  21115-21117   来源 0.0.0.0/0'
    Write-Host '    规则 2:  UDP  21116         来源 0.0.0.0/0   <-- 漏了这条客户端会一直「未就绪」' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  注意：UDP 21116 是客户端注册的通道，只开 TCP 一定失败。' -ForegroundColor Yellow
    Write-Host '        详见 docs/troubleshooting.md'
    Write-Host ''
    Write-Host "  安装目录 : $InstallDir"
    Write-Host "  日志目录 : $InstallDir\logs"
    Write-Host ''
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
