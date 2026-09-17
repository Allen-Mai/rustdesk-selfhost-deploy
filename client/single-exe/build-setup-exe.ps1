# 把 RustDesk 客户端 + 服务器配置打包成单个 setup exe（自包含，内嵌整份客户端）
# 用法: .\build-setup-exe.ps1 -Src <客户端目录> -Out <输出exe> [-IdServer x] [-Key x]
#
# 怎么准备 -Src（客户端目录）：
#   官方 exe 版安装包不包含 data\ 目录，必须从 MSI 里取，否则客户端启动会报
#   "Unable to start load AOT data / app.so; no such file"：
#
#     msiexec /a rustdesk-1.4.9-x86_64.msi /qn TARGETDIR=C:\rd-msi
#     # 之后用 C:\rd-msi\PFiles64\RustDesk 作为 -Src
#
#   注意：不要用 /a 解出来的顶层目录直接当 -Src，里面少 data\ 会启动失败；
#   也不要用已安装目录里手抄的文件，同样可能缺 data\。
#
# 产物：单个 exe，双击后释放客户端到 %LOCALAPPDATA%\RustDesk，
#       写入服务器配置、建桌面快捷方式并启动客户端，无需管理员权限。
param(
    [Parameter(Mandatory=$true)][string]$Src,
    [Parameter(Mandatory=$true)][string]$Out,
    [string]$IdServer = '111.229.187.4',
    [string]$RelayServer = '',
    [string]$Key = 'rFkrn3MC0Uig5qkNxxeikCFtnuWFTpejrmtLEnKL2UU=',
    [string]$Version = '1.4.9',
    [string]$Icon = ''
)
$ErrorActionPreference = 'Stop'
if (-not $RelayServer) { $RelayServer = $IdServer }

$build = $PSScriptRoot
$work  = Join-Path $build 'tmp'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null

Write-Host '==> 校验客户端源目录' -ForegroundColor Cyan
foreach ($f in @('RustDesk.exe', 'data\app.so')) {
    if (-not (Test-Path (Join-Path $Src $f))) { throw "客户端目录缺少 $f ：$Src" }
}
$files = Get-ChildItem -Recurse -File $Src
Write-Host ("    {0} 个文件, {1:N1} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum/1MB))

Write-Host '==> 生成载荷 zip' -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $work 'payload.zip'
[IO.Compression.ZipFile]::CreateFromDirectory(
    $Src, $zip, [IO.Compression.CompressionLevel]::Optimal, $false,
    (New-Object Text.UTF8Encoding($false)))
Write-Host ("    payload.zip  {0:N1} MB" -f ((Get-Item $zip).Length/1MB))

Write-Host '==> 生成配置器源码' -ForegroundColor Cyan
$cfg = [IO.File]::ReadAllText((Join-Path $build 'RustDeskSetup.cs'), (New-Object Text.UTF8Encoding($false)))
$cfg = $cfg -replace 'const string IdServer    = "[^"]*";',    "const string IdServer    = ""$IdServer"";"
$cfg = $cfg -replace 'const string RelayServer = "[^"]*";',    "const string RelayServer = ""$RelayServer"";"
$cfg = $cfg -replace 'const string PublicKey   = "[^"]*";',    "const string PublicKey   = ""$Key"";"
$cfg = $cfg -replace 'const string AppVersion  = "[^"]*";',    "const string AppVersion  = ""$Version"";"
$cs = Join-Path $work 'RustDeskSetup.cs'
# 带 BOM 写出：Windows PowerShell 5.1 对无 BOM 的中文源码会按 ANSI 解析，csc 会报错
[IO.File]::WriteAllText($cs, $cfg, (New-Object Text.UTF8Encoding($true)))
Write-Host "    ID=$IdServer  Relay=$RelayServer  Key=$($Key.Substring(0,[Math]::Min(8,$Key.Length)))..."

Write-Host '==> 生成版本信息' -ForegroundColor Cyan
$vin = Join-Path $work 'version.cs'
$versionCs = @"
using System.Reflection;
[assembly: AssemblyTitle("RustDesk Setup")]
[assembly: AssemblyProduct("RustDesk Setup")]
[assembly: AssemblyDescription("RustDesk 单文件安装包（自建服务器 $IdServer）")]
[assembly: AssemblyCompany("")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]
[assembly: AssemblyInformationalVersion("$Version (server $IdServer)")]
"@
[IO.File]::WriteAllText($vin, $versionCs, (New-Object Text.UTF8Encoding($true)))

Write-Host '==> 编译' -ForegroundColor Cyan
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "找不到 csc.exe：$csc" }
$exe = Join-Path $work 'setup.exe'
$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    "/out:$exe",
    "/resource:$zip,payload.zip",
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.IO.Compression.dll',
    '/reference:System.IO.Compression.FileSystem.dll'
)
if ($Icon -and (Test-Path $Icon)) { $cscArgs += "/win32icon:$Icon" }
$cscArgs += $cs, $vin
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "编译失败，csc 退出码 $LASTEXITCODE" }
Write-Host ("    setup exe  {0:N1} MB" -f ((Get-Item $exe).Length/1MB))

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Copy-Item $exe $Out -Force
Write-Host ''
Write-Host ("完成: {0}  ({1:N1} MB)" -f $Out, ((Get-Item $Out).Length/1MB)) -ForegroundColor Green
Write-Host ("SHA256: {0}" -f (Get-FileHash $Out -Algorithm SHA256).Hash)
