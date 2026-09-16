<#
.SYNOPSIS
    生成一套可以直接发给别人的预配置 RustDesk 客户端包。

.DESCRIPTION
    产出：
      RustDesk客户端\          可直接运行的文件夹
      RustDesk客户端.zip       可直接发送的压缩包

    包内包含官方客户端 + 配置脚本 + 预设服务器信息，
    对方解压后双击「1-一键配置并启动.bat」即可，无需手填任何地址。

.PARAMETER Server
    服务器公网 IP 或域名。必填。

.PARAMETER Key
    服务端公钥（id_ed25519.pub 的内容）。必填。

.PARAMETER Relay
    中继服务器地址，默认与 -Server 相同。

.PARAMETER ClientVersion
    客户端版本，默认 1.4.9

.PARAMETER OutDir
    输出目录，默认为脚本所在目录

.PARAMETER Mirror
    可选的 GitHub 加速前缀，例如 https://gh-proxy.com/

.EXAMPLE
    .\make-package.ps1 -Server 203.0.113.10 -Key "AbCd...="

.EXAMPLE
    .\make-package.ps1 -Server rs.example.com -Key "AbCd...=" -Mirror https://gh-proxy.com/
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [Parameter(Mandatory = $true)][string]$Key,
    [string]$Relay = '',
    [string]$ClientVersion = '1.4.9',
    [string]$OutDir = $PSScriptRoot,
    [string]$Mirror = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 引入 zip UTF-8 标志位修正函数
. (Join-Path $PSScriptRoot 'Set-ZipUtf8Flag.ps1')

if (-not $Relay) { $Relay = $Server }
if ($Mirror -and -not $Mirror.EndsWith('/')) { $Mirror = "$Mirror/" }

$pkgName = 'RustDesk客户端'
$pkgDir  = Join-Path $OutDir $pkgName
$zipPath = Join-Path $OutDir "$pkgName.zip"

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }

Write-Host '=====================================================' -ForegroundColor White
Write-Host '  RustDesk 预配置客户端打包工具' -ForegroundColor White
Write-Host '=====================================================' -ForegroundColor White
Write-Host "  服务器     : $Server"
Write-Host "  中继服务器 : $Relay"
Write-Host "  Key        : $Key"
Write-Host "  客户端版本 : $ClientVersion"

# ---------------------------------------------------------------- 准备目录
Write-Step '准备输出目录'
if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
Write-Ok $pkgDir

$tmp = Join-Path $env:TEMP ("rd-client-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    # ------------------------------------------------------------ 下载客户端
    Write-Step '下载官方 RustDesk 客户端'
    $exeUrl  = "${Mirror}https://github.com/rustdesk/rustdesk/releases/download/$ClientVersion/rustdesk-$ClientVersion-x86_64.exe"
    $exePath = Join-Path $tmp 'rustdesk.exe'
    Write-Host "    $exeUrl"
    curl.exe -L --retry 3 --connect-timeout 20 -o $exePath $exeUrl
    if (-not (Test-Path $exePath) -or (Get-Item $exePath).Length -lt 5MB) {
        throw "客户端下载失败：$exeUrl`n（国内网络可加 -Mirror https://gh-proxy.com/ 参数重试）"
    }
    Copy-Item $exePath (Join-Path $pkgDir 'rustdesk.exe') -Force
    Write-Ok ("rustdesk.exe  $([math]::Round((Get-Item $exePath).Length/1MB,2)) MB")

    # ------------------------------------------------------------ 复制脚本
    Write-Step '复制配置脚本'
    foreach ($f in @('set-server.ps1', '1-一键配置并启动.bat', '2-修改服务器设置.bat', '使用说明.txt')) {
        $src = Join-Path $PSScriptRoot $f
        if (-not (Test-Path $src)) { throw "缺少文件 $f，请确认脚本与它同目录" }
        Copy-Item $src (Join-Path $pkgDir $f) -Force
        Write-Ok $f
    }

    # ------------------------------------------------------------ 写入 ini
    Write-Step '写入预设服务器信息'
    $ini = @(
        '# RustDesk 服务器设置（改完保存，下次运行 bat 就会用这里的值）',
        "ID_SERVER=$Server",
        "RELAY_SERVER=$Relay",
        "KEY=$Key"
    ) -join "`r`n"
    # 带 BOM：让记事本和 Windows PowerShell 5.1 都能正确识别中文
    [IO.File]::WriteAllText(
        (Join-Path $pkgDir '服务器设置.ini'), "$ini`r`n", (New-Object Text.UTF8Encoding($true))
    )
    Write-Ok '服务器设置.ini'

    # ------------------------------------------------------------ 替换脚本里的预设值
    Write-Step '把预设值写进 set-server.ps1'
    $ps1Path = Join-Path $pkgDir 'set-server.ps1'
    $ps1 = [IO.File]::ReadAllText($ps1Path, [Text.UTF8Encoding]::new($false))
    $ps1 = $ps1 -replace "(?m)^\`$PresetId\s*=.*$",    "`$PresetId    = '$Server'"
    $ps1 = $ps1 -replace "(?m)^\`$PresetRelay\s*=.*$", "`$PresetRelay = '$Relay'"
    $ps1 = $ps1 -replace "(?m)^\`$PresetKey\s*=.*$",   "`$PresetKey   = '$Key'"
    if ($ps1 -match '<YOUR_SERVER_IP>|<YOUR_PUBLIC_KEY>') {
        throw '预设值替换失败，请检查 set-server.ps1 里的 $PresetId/$PresetRelay/$PresetKey 三行是否被改动过'
    }
    # 关键：Windows PowerShell 5.1 对「不带 BOM 的 UTF-8」脚本会按 ANSI 解析，
    # 脚本里的中文会变乱码甚至语法报错，所以必须带 BOM 写回。
    [IO.File]::WriteAllText($ps1Path, $ps1, (New-Object Text.UTF8Encoding($true)))
    Write-Ok 'set-server.ps1 已更新'

    # ------------------------------------------------------------ 打包
    Write-Step '打包 zip'
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # 用 .NET 打包（能正确处理中文文件名；bsdtar/tar.exe 会把中文名压坏成乱码）
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $pkgDir, $zipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $true,
        [Text.UTF8Encoding]::new($false)
    )

    # .NET 写入的条目名是 UTF-8 字节，但**不会设置 UTF-8 标志位(bit 11)**，
    # 严格按规范解析的工具（7-Zip、资源管理器）可能按 ANSI 解码而显示乱码。
    # 这里手工把标志位补上，保证各种解压工具都能正确显示中文文件名。
    $patched = Set-ZipUtf8Flag -ZipPath $zipPath
    Write-Ok ("$pkgName.zip  $([math]::Round((Get-Item $zipPath).Length/1MB,2)) MB  (已修正 $patched 个条目的 UTF-8 标志)")

    # ------------------------------------------------------------ 汇总
    Write-Host ''
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host '  打包完成' -ForegroundColor Green
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host "  文件夹 : $pkgDir"
    Write-Host "  压缩包 : $zipPath"
    Write-Host ''
    Write-Host '  发送给别人的话，说这三句：' -ForegroundColor White
    Write-Host '    1. 解压前先右键压缩包 -> 属性 -> 勾选「解除锁定」，再解压'
    Write-Host '    2. 双击「1-一键配置并启动.bat」，SmartScreen 弹窗选「仍要运行」'
    Write-Host '    3. Key 不能留空，否则会一直显示正在连接'
    Write-Host ''
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
