<#
.SYNOPSIS
    卸载 RustDesk Server 的 Windows 服务。

.DESCRIPTION
    停止并卸载 rustdesk-hbbs / rustdesk-hbbr 两个服务，并删除防火墙规则。
    默认保留安装目录（含私钥和数据库），除非指定 -RemoveFiles。

.PARAMETER InstallDir
    安装目录，默认 C:\RustDeskServer

.PARAMETER RemoveFiles
    连同安装目录一起删除。
    ⚠️ 会一并删除 id_ed25519 私钥和 db_v2.sqlite3 数据库，
       重装后所有客户端都要重新填 Key。请先确认已备份。

.EXAMPLE
    .\uninstall-service.ps1

.EXAMPLE
    .\uninstall-service.ps1 -RemoveFiles
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\RustDeskServer',
    [switch]$RemoveFiles
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw '需要管理员权限。' }

$svcDir = Join-Path $InstallDir 'service'

foreach ($name in @('hbbs-svc', 'hbbr-svc')) {
    $exe = Join-Path $svcDir "$name.exe"
    if (Test-Path $exe) {
        Write-Host "停止并卸载 $name ..." -ForegroundColor Cyan
        & $exe stop      2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & $exe uninstall 2>&1 | Out-Null
    }
}

Start-Sleep -Seconds 2
Get-Service rustdesk-hbbs, rustdesk-hbbr -ErrorAction SilentlyContinue |
    Select-Object Name, Status | Format-Table -AutoSize | Out-String | Write-Host

foreach ($dn in @('RustDesk Server (TCP 21115-21119)', 'RustDesk Server (UDP 21116)')) {
    Get-NetFirewallRule -DisplayName $dn -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

if ($RemoveFiles) {
    if (Test-Path (Join-Path $InstallDir 'id_ed25519')) {
        Write-Host '⚠️  正在删除私钥 id_ed25519 和数据库，此操作不可恢复' -ForegroundColor Yellow
    }
    Remove-Item $InstallDir -Recurse -Force
    Write-Host "已删除 $InstallDir" -ForegroundColor Green
}
else {
    Write-Host "服务已卸载。安装目录保留在 $InstallDir" -ForegroundColor Green
    Write-Host '（如需彻底删除，请加 -RemoveFiles 参数，注意会删除私钥和数据库）'
}
