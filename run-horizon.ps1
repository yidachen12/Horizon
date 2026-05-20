# Horizon 游戏音效早报 — 本地定时执行脚本（由 Windows 计划任务每日调用）
# 成功：Horizon 自己往飞书发早报卡片
# 失败：本脚本捕获异常，往飞书发一张红色报错卡片，避免“沉默失败”
#
# 注意：ErrorActionPreference 保持默认 Continue。uv.exe 会把正常进度信息
# 写到 stderr，若设为 Stop 会被 PowerShell 当成致命错误。这里改用显式
# $LASTEXITCODE 检查 + throw 来控制失败路径。

$repo       = "C:\Users\chenyida\game-audio-horizon"
$uv         = "C:\Users\chenyida\.local\bin\uv.exe"
$keyFile    = "C:\Users\chenyida\.anthropic_key"
$hookFile   = "C:\Users\chenyida\.horizon_webhook"
$logDir     = Join-Path $repo "logs"
$stamp      = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile    = Join-Path $logDir "run_$stamp.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$webhook = $null

function Send-FailureCard([string]$reason, [string]$tail) {
    # 标题同时含“游戏音效早报”和“Horizon”，无论机器人关键词设的是哪个都能过校验
    if (-not $webhook) { return }
    $content = "**Horizon 今日运行失败，未能生成早报。**`n`n**错误：** $reason`n`n**日志末尾：**`n``````n$tail`n``````"
    $card = @{
        msg_type = "interactive"
        card = @{
            schema = "2.0"
            header = @{
                title    = @{ tag = "plain_text"; content = "游戏音效早报 | Horizon 运行失败" }
                template = "red"
            }
            body = @{ elements = @( @{ tag = "markdown"; content = $content } ) }
        }
    }
    $json = $card | ConvertTo-Json -Depth 12
    try {
        Invoke-RestMethod -Uri $webhook -Method Post -Body $json -ContentType "application/json; charset=utf-8" | Out-Null
    } catch {
        "[$(Get-Date -Format s)] 发送失败卡片也失败了: $($_.Exception.Message)" | Out-File -FilePath $logFile -Append -Encoding utf8
    }
}

try {
    # --- 读取密钥与 webhook（缺文件直接抛） ---
    $webhook                  = (Get-Content $hookFile -Raw -ErrorAction Stop).Trim()
    $env:LILITH_LLM_KEY       = (Get-Content $keyFile  -Raw -ErrorAction Stop).Trim()
    $env:HORIZON_WEBHOOK_URL  = $webhook
    $env:PYTHONIOENCODING     = "utf-8"
    $env:UV_PYTHON            = "C:\Users\chenyida\AppData\Local\Programs\Python\Python312\python.exe"
    $env:UV_PYTHON_PREFERENCE = "only-system"

    Set-Location $repo

    # --- 同步依赖 + 跑主程序，输出落本地日志 ---
    & $uv sync 2>&1 | Tee-Object -FilePath $logFile -Append
    if ($LASTEXITCODE -ne 0) { throw "uv sync 失败 (exit $LASTEXITCODE)" }

    & $uv run horizon --hours 24 2>&1 | Tee-Object -FilePath $logFile -Append
    if ($LASTEXITCODE -ne 0) { throw "horizon 退出码 $LASTEXITCODE" }
}
catch {
    $reason = $_.Exception.Message
    $tail   = (Get-Content $logFile -Tail 25 -ErrorAction SilentlyContinue) -join "`n"
    if (-not $tail) { $tail = "(无日志输出)" }
    Send-FailureCard $reason $tail
    exit 1
}
