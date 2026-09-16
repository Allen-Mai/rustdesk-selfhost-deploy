<#
.SYNOPSIS
    把 zip 里所有条目的 UTF-8 标志位(bit 11)补上，让中文文件名在各解压工具里都正常显示。

.DESCRIPTION
    .NET 的 ZipArchive 写入条目名时用的是 UTF-8 字节，但不会设置
    general purpose bit 11（UTF-8 标志）。按 ZIP 规范，标志位未设置时
    文件名应按 CP437/ANSI 解码，于是 7-Zip、资源管理器等工具可能显示乱码。

    本函数按 ZIP 规范**精确遍历中央目录**（不靠扫描字节特征，避免误伤
    压缩数据），同时修正「中央目录头」和「本地文件头」里的标志位。

.PARAMETER ZipPath
    zip 文件路径（原地修改）

.OUTPUTS
    被修正的条目数量
#>
function Set-ZipUtf8Flag {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    $b = [IO.File]::ReadAllBytes($ZipPath)

    # --- 1. 从尾部找 EOCD (End of Central Directory, 签名 0x06054b50) ---
    $eocd = -1
    for ($i = $b.Length - 22; $i -ge 0; $i--) {
        if ($b[$i] -eq 0x50 -and $b[$i+1] -eq 0x4B -and
            $b[$i+2] -eq 0x05 -and $b[$i+3] -eq 0x06) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw '找不到 zip 的 EOCD 记录，文件可能已损坏' }

    $count = [BitConverter]::ToUInt16($b, $eocd + 10)   # 条目总数
    $pos   = [BitConverter]::ToUInt32($b, $eocd + 16)   # 中央目录起始偏移

    # --- 2. 遍历中央目录 ---
    $patched = 0
    for ($n = 0; $n -lt $count; $n++) {
        if (-not ($b[$pos] -eq 0x50 -and $b[$pos+1] -eq 0x4B -and
                  $b[$pos+2] -eq 0x01 -and $b[$pos+3] -eq 0x02)) {
            Write-Warning "第 $n 个条目签名异常，停止处理"
            break
        }
        # 中央目录头布局：
        #   +8  通用标志位(2 字节)
        #   +28 文件名长度(2)  +30 扩展字段长度(2)  +32 注释长度(2)
        #   +42 对应本地文件头的偏移(4)
        $flags = [BitConverter]::ToUInt16($b, $pos + 8) -bor 0x0800
        $fb = [BitConverter]::GetBytes([uint16]$flags)
        $b[$pos + 8] = $fb[0]; $b[$pos + 9] = $fb[1]

        $nameLen    = [BitConverter]::ToUInt16($b, $pos + 28)
        $extraLen   = [BitConverter]::ToUInt16($b, $pos + 30)
        $commentLen = [BitConverter]::ToUInt16($b, $pos + 32)
        $localOff   = [BitConverter]::ToUInt32($b, $pos + 42)

        # 本地文件头布局：签名 0x04034b50，+6 为通用标志位
        if ($b[$localOff] -eq 0x50 -and $b[$localOff+1] -eq 0x4B -and
            $b[$localOff+2] -eq 0x03 -and $b[$localOff+3] -eq 0x04) {
            $lf = [BitConverter]::ToUInt16($b, $localOff + 6) -bor 0x0800
            $lb = [BitConverter]::GetBytes([uint16]$lf)
            $b[$localOff + 6] = $lb[0]; $b[$localOff + 7] = $lb[1]
            $patched++
        }
        $pos += 46 + $nameLen + $extraLen + $commentLen
    }

    [IO.File]::WriteAllBytes($ZipPath, $b)
    return $patched
}

# 直接运行本文件时提示用法（本函数通常被 make-package.ps1 调用）
if ($MyInvocation.InvocationName -ne '.' -and -not $MyInvocation.Line) {
    Write-Host 'Set-ZipUtf8Flag -ZipPath <zip 文件路径>'
    Write-Host '修正 zip 内中文文件名的 UTF-8 标志位。通常由 client\make-package.ps1 调用。'
}
