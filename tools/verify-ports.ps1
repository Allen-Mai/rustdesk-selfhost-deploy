<#
.SYNOPSIS
    从外网检测 RustDesk 服务器端口是否真的放行了。

.DESCRIPTION
    通过 check-host.net 的多国节点，从**外部**真实探测 TCP 端口。
    这比在服务器本机看监听状态可靠得多——本机监听正常不代表外网能连上，
    云安全组仍然可能拦着。

    重要限制：本工具**只能测 TCP**。
    在线端口检测服务基本都是 TCP，UDP 21116 无法用这种方式验证。
    判断 UDP 是否放行的唯一可靠方法，是让一个外网客户端实际注册一次，
    看它是否从「未就绪」变成「就绪」（见 docs/troubleshooting.md）。

    建议同时检测一个已知可用的端口（如 3389 RDP）作为对照组：
    如果对照组通、目标端口不通，才能确定是安全组的问题，
    而不是检测节点本身到这台机器的网络有问题。

.PARAMETER Server
    服务器公网 IP 或域名。必填。

.PARAMETER Ports
    要检测的端口，默认 21115,21116,21117

.PARAMETER ControlPort
    对照端口，默认 3389。设为 0 可跳过对照测试。

.EXAMPLE
    .\verify-ports.ps1 -Server 203.0.113.10

.EXAMPLE
    .\verify-ports.ps1 -Server rs.example.com -Ports 21115,21116,21117,21118,21119 -ControlPort 22
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int[]]$Ports = @(21115, 21116, 21117),
    [int]$ControlPort = 3389,
    [int]$Nodes = 3
)

$ErrorActionPreference = 'Stop'

function Invoke-CheckHost {
    param([string]$Target, [int]$MaxNodes)
    $h = @{ 'Accept' = 'application/json' }
    $r = Invoke-RestMethod -Uri "https://check-host.net/check-tcp?host=$Target&max_nodes=$MaxNodes" `
                           -Headers $h -TimeoutSec 30
    return $r.request_id
}

Write-Host '=====================================================' -ForegroundColor White
Write-Host '  RustDesk 服务器端口外网检测' -ForegroundColor White
Write-Host '=====================================================' -ForegroundColor White
Write-Host "  目标: $Server"
Write-Host "  端口: $($Ports -join ', ')"
if ($ControlPort -gt 0) { Write-Host "  对照: $ControlPort" }
Write-Host ''

# ---------------------------------------------------------------- 发起检测
$targets = @{}
foreach ($p in $Ports) {
    Write-Host "  正在检测 TCP $p ..." -ForegroundColor Cyan
    $targets["$p"] = Invoke-CheckHost -Target "${Server}:$p" -MaxNodes $Nodes
}
if ($ControlPort -gt 0) {
    Write-Host "  正在检测对照组 TCP $ControlPort ..." -ForegroundColor Cyan
    $targets["$ControlPort (对照)"] = Invoke-CheckHost -Target "${Server}:$ControlPort" -MaxNodes $Nodes
}

Write-Host ''
Write-Host '  等待检测节点返回结果（约 30 秒）...' -ForegroundColor DarkGray
Start-Sleep -Seconds 30

# ---------------------------------------------------------------- 汇总结果
$h = @{ 'Accept' = 'application/json' }
$results = @{}
foreach ($label in $targets.Keys) {
    try {
        $r = Invoke-RestMethod -Uri "https://check-host.net/check-result/$($targets[$label])" `
                               -Headers $h -TimeoutSec 30
        $open = 0; $closed = 0; $pending = 0
        foreach ($prop in $r.PSObject.Properties) {
            $v = $prop.Value
            if ($null -eq $v) { $pending++ }
            else {
                $x = $v[0]
                if ($null -ne $x.time -and $x.time -gt 0) { $open++ } else { $closed++ }
            }
        }
        $results[$label] = @{ Open = $open; Closed = $closed; Pending = $pending }
    }
    catch {
        $results[$label] = @{ Error = $_.Exception.Message }
    }
}

Write-Host ''
Write-Host '=====================================================' -ForegroundColor White
Write-Host '  结果' -ForegroundColor White
Write-Host '=====================================================' -ForegroundColor White
foreach ($label in ($targets.Keys | Sort-Object)) {
    $r = $results[$label]
    if ($r.Error) {
        Write-Host ("  {0,-18} 检测失败: {1}" -f $label, $r.Error) -ForegroundColor Red
        continue
    }
    $total = $r.Open + $r.Closed
    if ($total -eq 0) {
        Write-Host ("  {0,-18} 结果未返回（节点繁忙，可稍后重试）" -f $label) -ForegroundColor Yellow
    }
    elseif ($r.Open -eq $total) {
        Write-Host ("  {0,-18} OPEN   ({1}/{1} 节点通)" -f $label, $total) -ForegroundColor Green
    }
    elseif ($r.Open -eq 0) {
        Write-Host ("  {0,-18} CLOSED ({1} 个节点全部超时)" -f $label, $total) -ForegroundColor Red
    }
    else {
        Write-Host ("  {0,-18} 部分通 ({1}/{2} 节点通，可能是节点自身网络问题)" -f $label, $r.Open, $total) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 提示
Write-Host ''
$ctrlKey = ($targets.Keys | Where-Object { $_ -match '对照' } | Select-Object -First 1)
if ($ctrlKey -and $results[$ctrlKey] -and $results[$ctrlKey].Closed -eq 0 -and $results[$ctrlKey].Open -gt 0) {
    Write-Host '  对照组可连通，说明检测机制有效，上面的结果是可信的。' -ForegroundColor DarkGray
}
elseif ($ctrlKey) {
    Write-Host '  ⚠ 对照组也不通，说明检测节点到这台机器的网络本身有问题，' -ForegroundColor Yellow
    Write-Host '    此时目标端口不通【不能】说明安全组有问题。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  提醒：本工具只测 TCP。' -ForegroundColor Yellow
Write-Host '        UDP 21116 是客户端注册的通道，必须单独在云控制台确认已放行。' -ForegroundColor Yellow
Write-Host '        只开 TCP 时端口扫描会显示"通"，但客户端会一直「未就绪」。' -ForegroundColor Yellow
Write-Host '        详见 docs/troubleshooting.md'
Write-Host ''
