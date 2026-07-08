# =====================================================================
#  国服英雄联盟 个签管理器  (LOL Signature Manager)
#  轻量化 WPF 客户端 —— 保存多条个签，随时一键切换
#  功能：多签保存 / 时间灵感 / 天气灵感 / emoji 表情面板
#  依赖：Windows 自带的 .NET / WPF，无需安装任何东西
# =====================================================================

# ---------- 自动请求管理员权限 ----------
# LOL 客户端以高权限运行，读取它的命令行(获取 token)必须管理员权限。
# 打包为 exe 时用 -requireAdmin 会自带提权，此处为直接运行 .ps1 的兜底。
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $selfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ($selfPath -and $selfPath.EndsWith('.ps1')) {
        Start-Process powershell -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$selfPath`""
        )
        exit
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---------- 路径与数据存储 ----------
# 兼容 exe 运行：优先用 exe/脚本所在目录
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
             else { [System.AppDomain]::CurrentDomain.BaseDirectory }
$DataFile  = Join-Path $ScriptDir 'signatures.json'

$script:Signatures = [System.Collections.Generic.List[object]]::new()

function Load-Signatures {
    $script:Signatures.Clear()
    if (Test-Path $DataFile) {
        try {
            $json = Get-Content $DataFile -Raw -Encoding UTF8
            if ($json.Trim()) {
                $data = $json | ConvertFrom-Json
                foreach ($item in @($data)) {
                    if ($null -ne $item -and $item.PSObject.Properties['Name']) {
                        $script:Signatures.Add([pscustomobject]@{
                            Name = [string]$item.Name
                            Text = [string]$item.Text
                        })
                    }
                }
            }
        } catch { }
    }
    if ($script:Signatures.Count -eq 0) {
        $legacy = Join-Path $ScriptDir 'signature.txt'
        if (Test-Path $legacy) {
            $txt = (Get-Content $legacy -Raw -Encoding UTF8).Trim()
            if ($txt) { $script:Signatures.Add([pscustomobject]@{ Name = '默认个签'; Text = $txt }) }
        }
    }
}

function Save-Signatures {
    try {
        $arr = @($script:Signatures | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Text = $_.Text } })
        $json = if ($arr.Count -eq 0) { '[]' } else { ConvertTo-Json $arr -Depth 4 }
        [System.IO.File]::WriteAllText($DataFile, $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        [System.Windows.MessageBox]::Show("保存失败：$($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
    }
}

# ---------- LCU 客户端交互 ----------
function Get-LcuCredentials {
    $running = Get-Process -Name 'LeagueClientUx' -ErrorAction SilentlyContinue
    if (-not $running) { return @{ Error = 'notrunning' } }
    $cmd = Get-CimInstance -Query "SELECT CommandLine FROM Win32_Process WHERE name = 'LeagueClientUx.exe'" -ErrorAction SilentlyContinue |
           Select-Object -ExpandProperty CommandLine -ErrorAction SilentlyContinue
    if (-not $cmd) { return @{ Error = 'noperm' } }
    $port  = if ($cmd -match '--app-port=(\d+)') { $matches[1] } else { $null }
    $token = if ($cmd -match '--remoting-auth-token=([\w-]+)') { $matches[1] } else { $null }
    if (-not $port -or -not $token) { return @{ Error = 'noperm' } }
    return @{ Port = $port; Token = $token }
}

function Set-LolStatusMessage {
    param([string]$Message)
    $cred = Get-LcuCredentials
    if ($cred.Error -eq 'notrunning') { throw '未检测到运行中的英雄联盟客户端，请先启动游戏客户端。' }
    if ($cred.Error -eq 'noperm')     { throw '读取客户端信息失败：权限不足，请以管理员身份运行本程序。' }

    $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("riot:$($cred.Token)"))
    $url  = "https://127.0.0.1:$($cred.Port)/lol-chat/v1/me"
    $body = @{ statusMessage = $Message } | ConvertTo-Json -Depth 3
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)

    # 先试 .NET；若遇到 TLS/send 之类问题，回退到系统 curl.exe
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]'Tls12,Tls13' }
        catch { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }
        Invoke-RestMethod -Uri $url -Method Put `
            -Headers @{ Authorization = "Basic $auth" } `
            -Body $bytes -ContentType 'application/json; charset=utf-8' -ErrorAction Stop | Out-Null
        return
    } catch { $dotnetErr = $_.Exception.Message }

    # 回退：curl（body 写临时文件，UTF-8 无 BOM，用 --data-binary 保证中文正确）
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        & $curl -s -k --max-time 10 -X PUT `
            -H "Authorization: Basic $auth" -H 'Content-Type: application/json' `
            --data-binary "@$tmp" $url | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "应用失败（.NET: $dotnetErr; curl 退出码 $LASTEXITCODE）" }
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# ---------- 灵感生成：时间（多风格：热血/emo/可爱/嚣张/chill；区分经典排位 / 海克斯大乱斗等其他模式）----------
function Get-TimeSignature {
    param([bool]$IsClassic = $true)
    if (-not $IsClassic) { return (Get-TimeSignatureArena) }
    $h = (Get-Date).Hour
    $bucket =
        if     ($h -ge 0  -and $h -lt 6)  { @(
            '🌙 凌晨还在肝，这把上完就睡（真的）',
            '🦉 昼伏夜出的召唤师，深夜档才是我的主场',
            '💀 又一个通宵鏖战的夜晚，明天的事明天再说',
            '🌌 夜太美，尽管再危险，也要来把排位',
            '🥀 睡不着的人，和排队的人，都在等一个结果',
            '🖤 白天属于世界，深夜属于我和这把游戏',
            '😴 别人在睡觉，我在超神，格局差距懂？',
            '🌃 凌晨三点的召唤师峡谷，只有真爱粉',
            '☕ 熬最深的夜，送最惨的人头，摆烂但快乐',
            '🌙 又熬夜了，妈妈不知道 >.<') }
        elseif ($h -ge 6  -and $h -lt 11) { @(
            '☀️ 早安召唤师～新的一天先来一把热热身',
            '🌅 早起的鸟儿有大龙吃',
            '☕ 一杯咖啡 + 一局排位 = 完美的清晨',
            '🐔 天亮了，起来打把游戏庆祝一下',
            '🌱 新的一天，新的段位，冲就完事了',
            '🍞 早八人？不，我是早八上分人',
            '😇 今天也要元气满满地送人头呀～',
            '🌞 一日之计在于晨，一把之计在于我',
            '☀️ 早安，今天也要开心上分哦(๑•̀ㅂ•́)و✧') }
        elseif ($h -ge 11 -and $h -lt 14) { @(
            '🍜 干饭时间到，这把打完就去恰饭',
            '😎 午间小憩？不如来把大乱斗提提神',
            '🥢 中午的排位，配菜是敌方的水晶',
            '🍚 干饭不积极，打野有问题',
            '😏 午休一把，赢了心情好，输了当没睡',
            '🐟 摸鱼的中午，配一把快乐大乱斗最香',
            '🍚 午休摸鱼中，别叫我(￣▽￣)~*') }
        elseif ($h -ge 14 -and $h -lt 18) { @(
            '🔥 下午茶时段，来一把清醒清醒',
            '⚔️ 摸鱼时刻，悄悄爬个分',
            '🌤 阳光正好，微风不燥，适合上分',
            '😮‍💨 下午犯困？一波团战比咖啡还提神',
            '🦥 chill 一下，输赢随缘，快乐第一',
            '👑 下午的峡谷，也得有我一个王',
            '😪 好困，靠打游戏续命 (=ﾟωﾟ)ﾉ') }
        elseif ($h -ge 18 -and $h -lt 22) { @(
            '🌆 黄金上分时段已开启，今晚必上一段！',
            '🎮 夜幕降临，正是开黑好时候',
            '🏆 今晚目标：连胜、不掉线、不挂机',
            '🌟 忙碌了一天，用一场胜利犒劳自己',
            '😤 白天受的气，今晚全撒在对面身上',
            '🍻 开黑吗兄弟，今晚不上分不睡觉',
            '🥺 求求今晚的队友给点力好嘛',
            '⚡ 黄金局时间，谁也别想拦我上分',
            '🎮 今晚开黑走一个！(๑˃̵ᴗ˂̵)و') }
        else { @(
            '🌙 睡前再来最后一把（骗你的，肯定不止一把）',
            '✨ 夜深了，但排位不等人',
            '🛏️ 说好打完这局就睡的，你信吗',
            '🥱 就一把，真的就一把（第八把）',
            '🌙 夜里的胜利，格外让人睡得香',
            '🖤 越夜越清醒，越输越想赢',
            '🥱 明明很困还在打，救救我 qwq') }
    return (Get-Random -InputObject $bucket)
}

# 非经典模式（海克斯大乱斗/极限闪击等）专用词库：不用峡谷/上分/排位/大龙这类经典召唤师峡谷词汇
function Get-TimeSignatureArena {
    $h = (Get-Date).Hour
    $bucket =
        if     ($h -ge 0  -and $h -lt 6)  { @(
            '🌙 凌晨还在开海克斯，就为了拼那个第一名',
            '🦉 深夜大乱斗局，纯靠手感和运气',
            '💀 凌晨的名次战，输赢都是缘分',
            '🎲 半夜了，海克斯组合刷起来才睡',
            '🥀 凌晨的大乱斗，输赢都不重要了，重要的是不睡',
            '🌙 又熬夜了，妈妈不知道 >.<') }
        elseif ($h -ge 6  -and $h -lt 11) { @(
            '☀️ 早安，先来把大乱斗热热手',
            '🌅 早起冲一把海克斯，图一乐',
            '☕ 咖啡配大乱斗，早晨的仪式感',
            '🐔 起床第一件事：开一把海克斯乱斗',
            '🌱 新的一天，从抽到烂强化开始',
            '☀️ 早安，今天也要开心大乱斗哦(๑•̀ㅂ•́)و✧') }
        elseif ($h -ge 11 -and $h -lt 14) { @(
            '🍜 干饭前来把大乱斗垫垫肚子',
            '😎 午间摸鱼，来把海克斯换换脑子',
            '🎯 中午小赌怡情，赌的是这把强化',
            '🍚 干饭不积极，海克斯有问题',
            '🍚 午休摸鱼中，别叫我(￣▽￣)~*') }
        elseif ($h -ge 14 -and $h -lt 18) { @(
            '🔥 下午茶时间，来把大乱斗清醒一下',
            '⚔️ 摸鱼冲名次，悄悄地卷',
            '🎲 阳光正好，适合开把海克斯乱斗',
            '🦥 chill 一下，名次随缘，快乐第一',
            '😪 好困，靠打游戏续命 (=ﾟωﾟ)ﾉ') }
        elseif ($h -ge 18 -and $h -lt 22) { @(
            '🌆 晚上黄金时段，海克斯乱斗走一个',
            '🎮 夜幕降临，开黑大乱斗正当时',
            '🏆 今晚目标：名次前三，稳住别浪',
            '🍻 开黑吗兄弟，今晚就大乱斗见',
            '🥺 求求今晚的队友给点力好嘛',
            '🎮 今晚开黑走一个！(๑˃̵ᴗ˂̵)و') }
        else { @(
            '🌙 睡前最后一把大乱斗（不可能的）',
            '✨ 夜深了，但海克斯组合不等人',
            '🛏️ 说好打完这把就睡，你信吗',
            '🖤 越夜越清醒，越输越想赢名次',
            '🥱 明明很困还在打，救救我 qwq') }
    return (Get-Random -InputObject $bucket)
}

# ---------- 灵感生成：天气（多风格；区分经典排位 / 海克斯大乱斗等其他模式）----------
# 天气文案（cat: storm/snow/rain/fog/cloud/sun/other）
function New-WeatherLine {
    param([string]$cond, [string]$temp, [string]$cat, [bool]$IsClassic = $true)
    if (-not $IsClassic) { return (New-WeatherLineArena -cond $cond -temp $temp -cat $cat) }
    $lines = switch ($cat) {
        'storm' { @(
            "⛈️ 外面$cond，$temp，雷都劈不断我上分的决心",
            "⚡ $temp 的雷暴天，只求这把别掉线",
            "🌩️ 打雷了，但没我这把团战炸得响",
            "😤 $cond 也挡不住我,今晚就要这一段",
            "⛈️ 打雷啦，吓得我躲进召唤师峡谷 >.<") }
        'snow'  { @(
            "❄️ 下雪啦！室外 $temp 冰天雪地，室内我杀得火热",
            "☃️ $cond，$temp，堆雪人不如堆人头",
            "🥶 $temp 冷成狗，只有连胜能暖手",
            "🤍 下雪的日子，适合和你一起白给（不是）",
            "❄️ 好冷呀，缩在被窝里上分(๑´ㅁ`๑)") }
        'rain'  { @(
            "🌧️ 外面下雨（$temp），那就名正言顺宅家上分咯～",
            "☔ $cond，$temp，正好宅家猛肝几把",
            "🥀 雨天最适合emo，和被对面单杀",
            "😌 听着雨声打游戏，输了也挺chill",
            "🌧️ 下雨天心情不好，输了别怪我 (╥﹏╥)") }
        'fog'   { @(
            "🌫️ $cond，$temp，视野不好？正好练练盲区意识",
            "🌁 雾蒙蒙的 $temp，跟我打野的视野一样朦胧",
            "👀 $cond 天，敌方越雾来抓，我越来劲",
            "🌫️ 雾蒙蒙看不清，跟我这局意识一样 (>﹏<)") }
        'cloud' { @(
            "☁️ $cond，$temp，不冷不热，正是上分好天气",
            "⛅ $temp 的$cond，适合安安静静爬个段位",
            "🫧 $cond 的日子，佛系上分，赢了算惊喜",
            "☁️ 阴天心情刚好，佛系上分中(・ω・)") }
        'sun'   { @(
            "☀️ $temp 的大晴天，这么好的天气不上分对不起太阳",
            "🌞 $cond，$temp，阳光和胜利我都要",
            "😎 这么好的天不开黑？那是对不起自己",
            "🔥 $temp，太阳很晒，我更晒（对面）",
            "☀️ 大晴天心情好，今天要赢！(๑•̀ㅂ•́)و✧") }
        default { @(
            "🌈 今天 $cond，$temp，什么天气都挡不住我开一把",
            "🎮 $cond · $temp，出门不如在家来一局") }
    }
    return (Get-Random -InputObject $lines)
}

# 非经典模式（海克斯大乱斗/极限闪击等）专用天气词库
function New-WeatherLineArena {
    param([string]$cond, [string]$temp, [string]$cat)
    $lines = switch ($cat) {
        'storm' { @(
            "⛈️ 外面$cond，$temp，雷都劈不断我冲名次的决心",
            "⚡ $temp 的雷暴天，海克斯照样炸场",
            "⛈️ 打雷啦，吓得我躲进大乱斗 >.<") }
        'snow'  { @(
            "❄️ 下雪啦！室外 $temp 冰天雪地，室内大乱斗照样杀得火热",
            "☃️ $cond，$temp，堆雪人不如堆强化装备",
            "❄️ 好冷呀，缩在被窝里大乱斗(๑´ㅁ`๑)") }
        'rain'  { @(
            "🌧️ 外面下雨（$temp），正好宅家来几把大乱斗",
            "☔ $cond，$temp，雨天海克斯，宅家真香",
            "🌧️ 下雨天心情不好，输了别怪我 (╥﹏╥)") }
        'fog'   { @(
            "🌫️ $cond，$temp，视野不好？大乱斗靠的是手速",
            "🌁 雾蒙蒙的 $temp，跟决赛圈一样看不清",
            "🌫️ 雾蒙蒙看不清，跟我这局意识一样 (>﹏<)") }
        'cloud' { @(
            "☁️ $cond，$temp，不冷不热，适合来把海克斯",
            "⛅ $temp 的$cond，佛系冲个名次",
            "☁️ 阴天心情刚好，佛系大乱斗中(・ω・)") }
        'sun'   { @(
            "☀️ $temp 的大晴天，这么好的天气不开把海克斯说不过去",
            "🌞 $cond，$temp，阳光和好名次我都要",
            "☀️ 大晴天心情好，今天要赢！(๑•̀ㅂ•́)و✧") }
        default { @(
            "🌈 今天 $cond，$temp，什么天气都挡不住我开把大乱斗",
            "🎮 $cond · $temp，出门不如在家海克斯一把") }
    }
    return (Get-Random -InputObject $lines)
}

function Get-CondCat {
    param([string]$c, [switch]$Chinese)
    if ($Chinese) {
        if     ($c -match '雷')             { 'storm' }
        elseif ($c -match '雪|冰')          { 'snow' }
        elseif ($c -match '雨')             { 'rain' }
        elseif ($c -match '雾|霾|沙|尘')    { 'fog' }
        elseif ($c -match '云|阴')          { 'cloud' }
        elseif ($c -match '晴')             { 'sun' }
        else                                { 'other' }
    } else {
        $l = $c.ToLower()
        if     ($l -match 'thunder|storm')          { 'storm' }
        elseif ($l -match 'snow|sleet|blizzard|ice'){ 'snow' }
        elseif ($l -match 'rain|drizzle|shower')    { 'rain' }
        elseif ($l -match 'fog|mist|haze|smoke')    { 'fog' }
        elseif ($l -match 'cloud|overcast')         { 'cloud' }
        elseif ($l -match 'sun|clear')              { 'sun' }
        else                                        { 'other' }
    }
}

# 返回原始天气 @{ cond; temp; cat } 或 $null（供 AI 或模板使用）。
# 依次尝试多个免key国内源 + 国外兜底，任何一个失败都会把原因记到 $script:LastWeatherError，方便定位问题。
$script:LastWeatherError = ''
function Invoke-CurlGetText {
    param([string]$Url, [int]$TimeoutSec = 10)
    # 用 Accept-Encoding: identity 明确要求不压缩，避免依赖 curl 是否内置了 zlib 解压能力（--compressed 在部分精简版 curl 上可能失败）
    $curl = if (Test-Path $script:CurlPath) { $script:CurlPath } else { 'curl.exe' }
    $rf = [System.IO.Path]::GetTempFileName()
    try {
        & $curl -s -k --max-time $TimeoutSec -H 'Accept-Encoding: identity' -o $rf $Url 2>$null | Out-Null
        $code = $LASTEXITCODE
        if ($code -ne 0) { return @{ ok = $false; err = "curl退出码$code" } }
        $raw = [System.IO.File]::ReadAllText($rf, [System.Text.Encoding]::UTF8)
        if (-not $raw) { return @{ ok = $false; err = '返回内容为空' } }
        return @{ ok = $true; text = $raw }
    } catch {
        return @{ ok = $false; err = $_.Exception.Message }
    } finally { Remove-Item $rf -Force -ErrorAction SilentlyContinue }
}

function Get-WeatherRaw {
    param([string]$City)
    $city = $City.Trim()
    $errs = @()

    if ($city) {
        # 源1：中国天气网 weather_mini（免key、国内直连）
        try {
            $u = 'http://wthrcdn.etouch.cn/weather_mini?city=' + [uri]::EscapeDataString($city)
            $r = Invoke-CurlGetText -Url $u
            if ($r.ok) {
                $j = $r.text | ConvertFrom-Json
                if ($j.data -and $j.data.forecast) {
                    $cond = [string]$j.data.forecast[0].type
                    if ($cond) {
                        $temp = if ($j.data.wendu) { "$($j.data.wendu)℃" } else { (($j.data.forecast[0].high -replace '[^\d]', '') + '℃') }
                        return @{ cond = $cond; temp = $temp; cat = (Get-CondCat $cond -Chinese) }
                    }
                    $errs += 'wthrcdn: 返回数据里没有天气字段'
                } else { $errs += 'wthrcdn: 返回数据结构不对（可能该服务已下线或改版）' }
            } else { $errs += "wthrcdn: $($r.err)" }
        } catch { $errs += "wthrcdn: $($_.Exception.Message)" }

        # 源2：oioweb 免key天气接口（备用，国内直连），字段名尽量多试几种
        try {
            $u2 = 'https://api.oioweb.cn/api/weather/GetWeather?city=' + [uri]::EscapeDataString($city)
            $r2 = Invoke-CurlGetText -Url $u2
            if ($r2.ok) {
                $j2 = $r2.text | ConvertFrom-Json
                $d2 = if ($j2.data) { $j2.data } else { $j2 }
                $cond2 = $null; $temp2 = $null
                foreach ($f in @('weather', 'type', 'condition')) { if (-not $cond2 -and $d2.$f) { $cond2 = [string]$d2.$f } }
                foreach ($f in @('temperature', 'temp', 'wendu')) { if (-not $temp2 -and $d2.$f) { $temp2 = [string]$d2.$f } }
                if ($cond2) {
                    if ($temp2 -and $temp2 -notmatch '℃|°') { $temp2 = "$temp2℃" }
                    if (-not $temp2) { $temp2 = '' }
                    return @{ cond = $cond2; temp = $temp2; cat = (Get-CondCat $cond2 -Chinese) }
                }
                $errs += 'oioweb: 返回数据结构不对'
            } else { $errs += "oioweb: $($r2.err)" }
        } catch { $errs += "oioweb: $($_.Exception.Message)" }
    } else {
        $errs += '未填写城市名（国内源必须填城市名才能查）'
    }

    # 兜底：wttr.in（国内经常被墙，仅作最后尝试）
    try {
        $loc = if ($city) { [uri]::EscapeDataString($city) } else { '' }
        $url = 'https://wttr.in/' + $loc + '?format=%C|%t&m'
        $resp = Invoke-RestMethod -Uri $url -UserAgent 'curl/8.0' -TimeoutSec 8 -ErrorAction Stop
        $parts = ("$resp").Split('|')
        if ($parts.Count -ge 2) {
            $cond = $parts[0].Trim()
            $temp = $parts[1].Trim().TrimStart('+')
            return @{ cond = $cond; temp = $temp; cat = (Get-CondCat $cond) }
        }
        $errs += 'wttr.in: 返回格式不对'
    } catch { $errs += "wttr.in: $($_.Exception.Message)" }

    $script:LastWeatherError = ($errs -join '；')
    return $null
}

# ---------- 战绩读取（走 curl，避开 .NET 的 TLS 问题；写临时文件按 UTF-8 读，避免中文乱码）----------
$script:CurlPath = Join-Path $env:WINDIR 'System32\curl.exe'
$script:ChampMap = $null

function Get-LcuAuth {
    $cred = Get-LcuCredentials
    if ($cred.Port) {
        $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("riot:$($cred.Token)"))
        return @{ Port = $cred.Port; Auth = $auth }
    }
    return $cred   # 含 .Error
}

function Get-LcuJson {
    param($Port, $Auth, $Path)
    if (-not (Test-Path $script:CurlPath)) { $script:CurlPath = 'curl.exe' }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        & $script:CurlPath -s -k --max-time 10 -o $tmp -H "Authorization: Basic $Auth" "https://127.0.0.1:$Port$Path" | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $json = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        if (-not $json) { return $null }
        return ($json | ConvertFrom-Json)
    } catch { return $null } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-ChampMap {
    param($Port, $Auth)
    if ($script:ChampMap) { return $script:ChampMap }
    $arr = Get-LcuJson $Port $Auth '/lol-game-data/assets/v1/champion-summary.json'
    $m = @{}
    if ($arr) { foreach ($c in $arr) { $m[[string]$c.id] = $c.name } }
    if ($m.Count -gt 0) { $script:ChampMap = $m }
    return $m
}

$script:ItemMap = $null
function Get-ItemMap {
    param($Port, $Auth)
    if ($script:ItemMap) { return $script:ItemMap }
    $arr = Get-LcuJson $Port $Auth '/lol-game-data/assets/v1/items.json'
    $m = @{}
    if ($arr) { foreach ($it in $arr) { if ($it.id) { $m[[string]$it.id] = $it.name } } }
    if ($m.Count -gt 0) { $script:ItemMap = $m }
    return $m
}

# 读取当前账号最近一局的 gameId。查询范围与客户端"近期对局(最近20场)"面板一致（begIndex=0,endIndex=19），
# 避免只查1条时把客户端自身战绩列表的响应式缓存"挤"成只剩这一条（曾导致客户端战绩面板打乱）。
function Get-LatestGameId {
    $a = Get-LcuAuth
    if (-not $a.Port) { return $null }
    $list = Get-LcuJson $a.Port $a.Auth '/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=19'
    return $list.games.games[0].gameId
}

# 读取当前对局阶段（None/Lobby/ChampSelect/InProgress/WaitingForStats/EndOfGame 等）。
# 用于自动模式：只在"刚打完一局"这一刻才去访问战绩接口，而不是持续轮询，减少对客户端自身战绩缓存的干扰。
function Get-GameflowPhase {
    $a = Get-LcuAuth
    if (-not $a.Port) { return $null }
    $phase = Get-LcuJson $a.Port $a.Auth '/lol-gameflow/v1/gameflow-phase'
    if ($null -eq $phase) { return $null }
    return [string]$phase
}

# 常见 queueId -> 中文模式名兜底表（当客户端本地化查询失败时使用）
$script:QueueFallbackNames = @{
    '420' = '排位赛-单双排'; '440' = '排位赛-灵活组排'; '400' = '匹配赛-征召模式'; '430' = '匹配赛-经典模式'
    '450' = '极限闪击'; '900' = '无限火力'; '1900' = '无限火力'
    '1700' = '斗魂竞技场'; '1710' = '斗魂竞技场'; '2400' = '海克斯大乱斗'
    '1300' = '云顶之弈-炫斗模式'; '1020' = '一血模式'; '830' = '人机-新手'; '840' = '人机-初级'; '850' = '人机-中级'
}

# 检测"最近在玩的模式"，供 AI/本地模板选词用。5分钟内缓存，避免频繁访问。
# IsClassic：是否经典召唤师峡谷相关模式（排位/匹配/训练）——只有这类模式才适合用"峡谷/上分/大龙/水晶"等词。
function Get-CurrentModeInfo {
    if ($script:ModeProfile -and ((Get-Date) - $script:ModeProfileAt).TotalMinutes -lt 5) {
        return $script:ModeProfile
    }
    $default = @{ Name = ''; IsClassic = $true }
    $a = Get-LcuAuth
    if (-not $a.Port) { return $default }
    try {
        $list = Get-LcuJson $a.Port $a.Auth '/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=19'
        $g0 = $list.games.games[0]
        if (-not $g0) { return $default }
        $gameMode = [string]$g0.gameMode
        $queueId = [string]$g0.queueId

        $name = $null
        try {
            $qi = Get-LcuJson $a.Port $a.Auth "/lol-game-queues/v1/queues/$queueId"
            if ($qi) {
                if ($qi.description) { $name = [string]$qi.description }
                elseif ($qi.name) { $name = [string]$qi.name }
            }
        } catch { }
        if ((-not $name) -and $script:QueueFallbackNames.ContainsKey($queueId)) { $name = $script:QueueFallbackNames[$queueId] }

        # 只有经典召唤师峡谷相关模式（gameMode = CLASSIC，涵盖排位/匹配/训练）才适合峡谷/上分/大龙这类词
        $isClassic = ($gameMode -eq 'CLASSIC')

        $result = @{ Name = $name; IsClassic = $isClassic }
        $script:ModeProfile = $result
        $script:ModeProfileAt = Get-Date
        return $result
    } catch { return $default }
}

# 根据战绩拼一句感想（多风格 + 五杀/伤害/连杀等亮点；IsClassic=$false 时避免"段位/上分"等排位专属措辞）
function New-MatchLine {
    param($champ, $k, $d, $a, $win, $fed, $carry, $maxMulti, $dmg, $spree, [bool]$IsClassic = $true)
    $ratio = ($k + $a) / [Math]::Max(1, $d)
    $kda = "$k/$d/$a"
    $wan = if ($dmg -gt 0) { [math]::Round($dmg / 10000, 1) } else { 0 }
    $rankWord = if ($IsClassic) { '段位' } else { '名次' }
    $pool = New-Object System.Collections.Generic.List[string]

    # 亮点：多杀（优先，命中就加进池子增加惊喜）
    if ($maxMulti -ge 5) {
        $pool.Add("这把$champ 一个五杀直接封神☠️")
        $pool.Add("$champ 五杀了！这把我说了算🔥")
        $pool.Add("对面：$champ 你礼貌吗？（人家刚五杀）😏")
    } elseif ($maxMulti -eq 4) {
        $pool.Add("$champ 一个四杀，就差一个头的神🎯")
        $pool.Add("这把$champ 四杀，超神就在一线之间")
    } elseif ($maxMulti -eq 3) {
        $pool.Add("$champ 一波三杀，手感来了谁也挡不住😎")
    }
    if ($spree -ge 8) { $pool.Add("$champ $kda，一条龙杀穿全场，爽！🐉") }

    # 胜负 + 多风格
    if ($win) {
        if ($carry) {
            $pool.AddRange([string[]]@(
                "这把$champ 带飞！$kda 稳如老狗😎",
                "$champ carry 全场，$wan 万伤害谁扛得住🔥",
                "赢麻了，$champ $kda 这把我最靓✨",
                "$champ $kda，对面$fed 在我面前也就那样😏",
                "$wan 万伤害的$champ，今晚这$rankWord 我要定了👑",
                "爽！$champ $kda 战斗爽！(≧▽≦)",
                "$champ 这把杀爽了 $kda (｀・ω・´)"))
        } else {
            $pool.AddRange([string[]]@(
                "赢啦！$champ $kda 心情起飞🎉",
                "这把$champ 躺赢也是赢，谢谢队友带飞💕",
                "$champ $kda，又是被队友宠爱的一天😌",
                "不管过程，反正$champ 赢了就完事🏆",
                "$champ 苟到最后，$kda 悄悄拿下这把😎",
                "赢了赢了！$champ $kda (๑•̀ㅂ•́)و✧"))
        }
    } else {
        if ($ratio -lt 1) {
            $pool.AddRange([string[]]@(
                "这把$champ 演砸了…$kda 我先去自闭了🫠",
                "别问，问就是$champ 被打自闭 $kda 😭",
                "$champ $kda，这把当我没来过🥀",
                "我的$champ 今天不在状态，下把找回来😔",
                "输了不可怕，$champ $kda 才可怕（对不起队友）",
                "可恶！$champ $kda 这把不算 >.<",
                "$champ $kda，呜呜呜下把一定行 (╥﹏╥)"))
        } else {
            $pool.AddRange([string[]]@(
                "这把$champ 尽力了QAQ 对面$fed 太肥了",
                "$champ $kda 打出$wan 万伤害还是输，绷不住了😮‍💨",
                "不是$champ 不行，是对面$fed 起飞了🥲",
                "$champ $kda 单核带不动，心累但不服🔥",
                "$champ 都$kda 了还输，这队友我给满分（反讽）🙃",
                "可恶，明明$champ 都$kda 了 (╥_╥)",
                "$champ 尽力了555 $kda 也没能赢 qwq"))
        }
    }
    return (Get-Random -InputObject $pool)
}

# 主流程：读最近一局 -> 生成个签。返回 @{ ok; text; gameId } 或 @{ ok=$false; msg }
function Get-MatchSignature {
    $a = Get-LcuAuth
    if (-not $a.Port) {
        $msg = if ($a.Error -eq 'noperm') { '权限不足，请以管理员身份运行' } else { '未检测到英雄联盟客户端' }
        return @{ ok = $false; msg = $msg }
    }
    $me = Get-LcuJson $a.Port $a.Auth '/lol-summoner/v1/current-summoner'
    if (-not $me) { return @{ ok = $false; msg = '读取召唤师信息失败（连接客户端异常）' } }
    $list = Get-LcuJson $a.Port $a.Auth '/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=19'
    $g0 = $list.games.games[0]
    if (-not $g0) { return @{ ok = $false; msg = '没有找到最近对局，先打一把再来试试～' } }
    $gameId = $g0.gameId
    $champMap = Get-ChampMap $a.Port $a.Auth
    $detail = Get-LcuJson $a.Port $a.Auth "/lol-match-history/v1/games/$gameId"
    if (-not $detail -or -not $detail.participants) { return @{ ok = $false; msg = '读取对局详情失败' } }

    # 这局的模式（用于选词：只有经典召唤师峡谷相关模式才适合"峡谷/上分/大龙"这类词）
    $queueId = [string]$g0.queueId
    $modeName = $null
    try {
        $qi = Get-LcuJson $a.Port $a.Auth "/lol-game-queues/v1/queues/$queueId"
        if ($qi) { $modeName = if ($qi.description) { [string]$qi.description } elseif ($qi.name) { [string]$qi.name } }
    } catch { }
    if ((-not $modeName) -and $script:QueueFallbackNames.ContainsKey($queueId)) { $modeName = $script:QueueFallbackNames[$queueId] }
    if (-not $modeName) { $modeName = [string]$g0.gameMode }
    $isClassicMode = ([string]$g0.gameMode -eq 'CLASSIC')

    $pidToPuuid = @{}
    foreach ($pi in $detail.participantIdentities) { $pidToPuuid[[string]$pi.participantId] = $pi.player.puuid }
    $mine = $null
    foreach ($p in $detail.participants) { if ($pidToPuuid[[string]$p.participantId] -eq $me.puuid) { $mine = $p; break } }
    if (-not $mine) { return @{ ok = $false; msg = '没在这局里找到你的数据' } }

    $champ = $champMap[[string]$mine.championId]; if (-not $champ) { $champ = '我' }
    $s = $mine.stats
    $k = [int]$s.kills; $d = [int]$s.deaths; $as = [int]$s.assists
    $win = [bool]$s.win
    $enemies = $detail.participants | Where-Object { $_.teamId -ne $mine.teamId }
    $fed = $enemies | Sort-Object { $_.stats.kills } -Descending | Select-Object -First 1
    $fedName = if ($fed) { $champMap[[string]$fed.championId] } else { '对面' }
    if (-not $fedName) { $fedName = '对面' }

    # 更丰富的数据（这些字段各服/各模式基本都在）
    $maxMulti = [int]$s.largestMultiKill
    $dmg   = [int]$s.totalDamageDealtToChampions
    $gold  = [int]$s.goldEarned
    $spree = [int]$s.largestKillingSpree
    $cs    = [int]$s.totalMinionsKilled + [int]$s.neutralMinionsKilled
    $lvl   = [int]$s.champLevel
    $myTeamMaxK = ($detail.participants | Where-Object { $_.teamId -eq $mine.teamId } | ForEach-Object { $_.stats.kills } | Measure-Object -Maximum).Maximum
    $carry = ($k -ge $myTeamMaxK -and $k -gt 0)

    # 出装（尽力而为，失败就跳过）
    $itemNames = @()
    try {
        $itemMap = Get-ItemMap $a.Port $a.Auth
        if ($itemMap.Count -gt 0) {
            foreach ($n in 0..6) {
                $iid = [int]$s."item$n"
                if ($iid -gt 0 -and $itemMap[[string]$iid]) { $itemNames += $itemMap[[string]$iid] }
            }
        }
    } catch { }

    # 优先用 AI 现写（把丰富数据喂给它，每次随机风格）；失败/未配置回退模板
    $text = $null
    if ($script:AiConfig.Provider -ne 'off' -and $script:AiConfig.Key) {
        $res = if ($win) { '赢了' } else { '输了' }
        $multiTxt = switch ($maxMulti) { 5 { '拿了个五杀' } 4 { '拿了个四杀' } 3 { '拿了个三杀' } default { '' } }
        $wan = [math]::Round($dmg / 10000, 1)
        $facts = "这是我刚打完的一把《英雄联盟》：`n" +
                 "- 对局模式：$modeName`n- 我用的英雄：$champ`n- 结果：$res`n- 我的KDA：$k/$d/$a`n- 对面发挥最好的英雄：$fedName`n" +
                 "- 我的英雄伤害：约 $wan 万`n- 最高连杀：$spree`n- 等级：$lvl"
        if ($isClassicMode) { $facts += "`n- 补刀：$cs" }
        if ($multiTxt) { $facts += "`n- 高光：$multiTxt" }
        if ($itemNames.Count -gt 0) { $facts += "`n- 出装：" + (($itemNames | Select-Object -First 4) -join '、') }
        $text = Get-AiInspiration -Facts $facts -ModeName $modeName -IsClassic $isClassicMode -Win $win
    }
    if (-not $text) {
        $text = New-MatchLine -champ $champ -k $k -d $d -a $as -win $win -fed $fedName -carry $carry -maxMulti $maxMulti -dmg $dmg -spree $spree -IsClassic $isClassicMode
    }
    return @{ ok = $true; text = $text; gameId = $gameId }
}

# ---------- AI 智能生成（可选，需自备 key；外网 HTTPS 走 curl）----------
$script:AiConfigFile = Join-Path $ScriptDir 'ai_config.json'
$script:AiConfig = @{ Provider = 'off'; Key = ''; Model = '' }
$script:AiProviders = @{
    'claude'   = @{ Endpoint = 'https://api.anthropic.com/v1/messages';                 DefaultModel = 'claude-haiku-4-5' }
    'glm'      = @{ Endpoint = 'https://open.bigmodel.cn/api/paas/v4/chat/completions';  DefaultModel = 'glm-4-flash' }
    'deepseek' = @{ Endpoint = 'https://api.deepseek.com/chat/completions';              DefaultModel = 'deepseek-chat' }
}

function Load-AiConfig {
    if (Test-Path $script:AiConfigFile) {
        try {
            $j = Get-Content $script:AiConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j) {
                if ($j.PSObject.Properties['Provider']) { $script:AiConfig.Provider = [string]$j.Provider }
                if ($j.PSObject.Properties['Key'])      { $script:AiConfig.Key      = [string]$j.Key }
                if ($j.PSObject.Properties['Model'])    { $script:AiConfig.Model    = [string]$j.Model }
            }
        } catch { }
    }
}
function Save-AiConfig {
    try {
        $o = [pscustomobject]@{ Provider = $script:AiConfig.Provider; Key = $script:AiConfig.Key; Model = $script:AiConfig.Model }
        [System.IO.File]::WriteAllText($script:AiConfigFile, ($o | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

function Invoke-Ai {
    param([string]$Prompt)
    $p = $script:AiConfig.Provider
    if ($p -eq 'off' -or -not $script:AiProviders.ContainsKey($p)) { return $null }
    $key = $script:AiConfig.Key
    if (-not $key) { return $null }
    $meta  = $script:AiProviders[$p]
    $model = if ($script:AiConfig.Model.Trim()) { $script:AiConfig.Model.Trim() } else { $meta.DefaultModel }

    if ($p -eq 'claude') {
        $body    = @{ model = $model; max_tokens = 200; messages = @(@{ role = 'user'; content = $Prompt }) } | ConvertTo-Json -Depth 6
        $headers = @('-H', "x-api-key: $key", '-H', 'anthropic-version: 2023-06-01', '-H', 'content-type: application/json')
    } else {
        $body    = @{ model = $model; messages = @(@{ role = 'user'; content = $Prompt }); max_tokens = 200; temperature = 1.0 } | ConvertTo-Json -Depth 6
        $headers = @('-H', "Authorization: Bearer $key", '-H', 'content-type: application/json')
    }

    $curl = if (Test-Path $script:CurlPath) { $script:CurlPath } else { 'curl.exe' }
    $bodyFile = [System.IO.Path]::GetTempFileName()
    $respFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($bodyFile, $body, [System.Text.UTF8Encoding]::new($false))
        $cargs = @('-s', '--max-time', '25', '-X', 'POST', $meta.Endpoint) + $headers + @('--data-binary', "@$bodyFile", '-o', $respFile)
        & $curl @cargs | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $raw = [System.IO.File]::ReadAllText($respFile, [System.Text.Encoding]::UTF8)
        if (-not $raw) { return $null }
        $r = $raw | ConvertFrom-Json
        $text = if ($p -eq 'claude') { $r.content[0].text } else { $r.choices[0].message.content }
        if (-not $text) { return $null }
        $line = ($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $line) { return $null }
        $line = $line.Trim().Trim('"', '“', '”', '「', '」', "'")
        if ($line.Length -gt 60) { $line = $line.Substring(0, 60) }
        return $line
    } catch { return $null } finally {
        Remove-Item $bodyFile, $respFile -Force -ErrorAction SilentlyContinue
    }
}

# ModeName/IsClassic 用于按实际游玩模式选词。
# Win：$null 表示这次没有真实对局结果（时间/天气场景，不该编造输赢）；$true/$false 表示这次确有真实胜负（战绩场景），情绪要贴合这个真实结果。
function Get-AiInspiration {
    param([string]$Facts, [string]$ModeName = '', [bool]$IsClassic = $true, [object]$Win = $null)
    $vibe = Get-Random -InputObject @('热血中二', 'emo伤感', '可爱软萌', '嚣张拽炫', '佛系chill', '阴阳怪气吐槽')

    if ($IsClassic) {
        $vocabRule = "多使用召唤师、峡谷、上分/掉分、排位、开黑、大龙/小龙、水晶、五杀、走位、团战 这类贴合英雄联盟本身的词汇"
    } else {
        $vocabRule = "多使用名次、组队、开黑、乱斗、强化、团战、队友 这类更通用或符合这个模式氛围的词汇（这局不是经典召唤师峡谷排位模式，峡谷、上分、排位、大龙、小龙、水晶、补刀这类词换掉不用）"
    }

    if ($null -eq $Win) {
        $resultRule = "这不是在描述某一局具体比赛的输赢结果，请只结合上面的时间/天气本身，营造一种想开黑/想上号打游戏的心情和氛围，不要提及连胜、连败、这局输了/赢了之类你并不知道的战绩信息"
    } elseif ($Win) {
        $resultRule = "这一局真实赢了，请表达痛快、兴奋这类正面情绪，可以用『爽！』『战斗爽！』这种短促痛快的感叹句式，只针对这一局说，不要提连胜"
    } else {
        $resultRule = "这一局真实输了，请表达带点小情绪但可爱/卖萌卖惨的负面情绪，可以用『可恶』『呜呜呜』这类词，只针对这一局说，不要提连败"
    }

    $prompt = "你是一个爱玩《英雄联盟》(League of Legends)的中国年轻玩家，正在给国服LOL客户端设置个性签名。`n" +
              "$Facts`n" +
              "请写一句可以直接当这个游戏内个性签名的话，整体风格偏「$vibe」。`n" +
              "写作要求：`n" +
              "1. $vocabRule；`n" +
              "2. $resultRule；`n" +
              "3. 如果上面给了具体的对局数据（英雄、KDA、多杀等）可以真实引用，用你确定真实存在的英雄/装备名字；不确定是否真实存在的具体强化/装备/技能名字就不要编，用『强化』『装备』这类通用说法即可；也不要把具体的游戏模式名称原文写进这句话里（比如不要出现「海克斯大乱斗」这几个字本身）；`n" +
              "4. 可以用『>.<』『qwq』『555』『(≧▽≦)』『(╥﹏╥)』这类中文/日式颜文字，或者常规emoji，不要用『;)』这类中文语境里少见的西式颜文字；`n" +
              "5. 中文，22字以内，直接输出这一句话本身，不要引号，不要任何解释或前后缀。"
    return (Invoke-Ai -Prompt $prompt)
}

# ---------- 界面 (XAML) ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="国服 LOL 个签管理器" Height="730" Width="860"
        WindowStartupLocation="CenterScreen" MinHeight="620" MinWidth="760"
        Background="#1E1F26" FontFamily="Microsoft YaHei UI" FontSize="13">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#3A3D4A"/>
            <Setter Property="Foreground" Value="#EDEDED"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="12,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#4A4E5E"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#C89B3C"/>
            <Setter Property="Foreground" Value="#1E1F26"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#E0B24A"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="Chip" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#2F5D50"/>
            <Setter Property="Padding" Value="10,6"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#3C7A69"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#2A2C36"/>
            <Setter Property="Foreground" Value="#EDEDED"/>
            <Setter Property="BorderBrush" Value="#3A3D4A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="CaretBrush" Value="#EDEDED"/>
        </Style>
    </Window.Resources>

    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- 顶部状态栏 -->
        <Border Grid.Row="0" Background="#2A2C36" CornerRadius="8" Padding="12,8" Margin="0,0,0,12">
            <Grid>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse x:Name="StatusDot" Width="12" Height="12" Fill="#888" Margin="0,0,8,0"/>
                    <TextBlock x:Name="StatusText" Text="正在检测客户端..." Foreground="#CFCFCF" VerticalAlignment="Center"/>
                </StackPanel>
                <Button x:Name="RefreshBtn" Content="重新检测" HorizontalAlignment="Right" Width="90"/>
            </Grid>
        </Border>

        <!-- 主体 -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="230"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- 左侧列表 -->
            <DockPanel Grid.Column="0">
                <TextBlock DockPanel.Dock="Top" Text="我的个签" Foreground="#C89B3C" FontWeight="Bold" Margin="2,0,0,6"/>
                <ListBox x:Name="SigList" Background="#2A2C36" Foreground="#EDEDED" BorderBrush="#3A3D4A"
                         DisplayMemberPath="Name">
                    <ListBox.ItemContainerStyle>
                        <Style TargetType="ListBoxItem">
                            <Setter Property="Padding" Value="8,7"/>
                            <Setter Property="Foreground" Value="#EDEDED"/>
                        </Style>
                    </ListBox.ItemContainerStyle>
                </ListBox>
            </DockPanel>

            <!-- 右侧编辑 -->
            <Grid Grid.Column="2">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" Text="名称（方便自己区分）" Foreground="#9DA1AD" Margin="0,0,0,4"/>
                <TextBox   Grid.Row="1" x:Name="NameBox" Margin="0,0,0,10"/>

                <TextBlock Grid.Row="2" Text="个签内容" Foreground="#9DA1AD" Margin="0,0,0,4"/>
                <TextBox   Grid.Row="3" x:Name="TextBox_Content" AcceptsReturn="True" TextWrapping="Wrap"
                           MinHeight="70" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>

                <!-- 灵感生成 -->
                <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,10,0,6">
                    <Button x:Name="TimeBtn"    Style="{StaticResource Chip}" Content="🕐 时间灵感" Margin="0,0,8,0"/>
                    <Button x:Name="WeatherBtn" Style="{StaticResource Chip}" Content="🌤 天气灵感" Margin="0,0,8,0"/>
                    <Button x:Name="MatchBtn"   Style="{StaticResource Chip}" Content="🎮 战绩灵感" Margin="0,0,8,0"/>
                    <TextBlock Text="城市:" Foreground="#9DA1AD" VerticalAlignment="Center" Margin="4,0,4,0"/>
                    <TextBox x:Name="CityBox" Width="110" VerticalContentAlignment="Center"
                             ToolTip="国内请填写中文城市名（如 上海、成都）。留空只会尝试可能被墙的国外源。"/>
                </StackPanel>

                <!-- 自动模式开关 -->
                <CheckBox Grid.Row="5" x:Name="AutoChk" Foreground="#CFCFCF" Margin="0,2,0,6"
                          Content="🔁 打完一把后，自动把个签改成这把的战绩感想"
                          ToolTip="勾选后每打完一局，程序会自动读取战绩、生成感想并应用（需保持本程序开启）"/>

                <!-- AI 智能生成（可选） -->
                <Expander Grid.Row="6" x:Name="AiExpander" Foreground="#9DA1AD" Margin="0,0,0,6"
                          Header="⚙ AI 智能生成（可选：填了 key，时间/天气/战绩个签都由 AI 现写，每次不重样）">
                    <Grid Margin="4,8,0,2">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="服务" Foreground="#9DA1AD" VerticalAlignment="Center" Margin="0,0,8,6"/>
                        <ComboBox  Grid.Row="0" Grid.Column="1" x:Name="AiProviderBox" Margin="0,0,0,6" SelectedIndex="0">
                            <ComboBoxItem>关闭（用固定模板）</ComboBoxItem>
                            <ComboBoxItem>Claude (Anthropic)</ComboBoxItem>
                            <ComboBoxItem>智谱 GLM-4-Flash（免费）</ComboBoxItem>
                            <ComboBoxItem>DeepSeek</ComboBoxItem>
                        </ComboBox>
                        <TextBlock  Grid.Row="1" Grid.Column="0" Text="Key" Foreground="#9DA1AD" VerticalAlignment="Center" Margin="0,0,8,6"/>
                        <PasswordBox Grid.Row="1" Grid.Column="1" x:Name="AiKeyBox" Margin="0,0,0,6"/>
                        <TextBlock  Grid.Row="2" Grid.Column="0" Text="模型" Foreground="#9DA1AD" VerticalAlignment="Center" Margin="0,0,8,6"/>
                        <Grid Grid.Row="2" Grid.Column="1" Margin="0,0,0,6">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBox Grid.Column="0" x:Name="AiModelBox" VerticalContentAlignment="Center"
                                     ToolTip="留空用默认。Claude默认 claude-haiku-4-5（便宜快），想更聪明可改 claude-opus-4-8；GLM默认 glm-4-flash；DeepSeek默认 deepseek-chat"/>
                            <Button  Grid.Column="1" x:Name="AiTestBtn" Content="测试" Width="70" Margin="8,0,0,0"/>
                        </Grid>
                        <TextBlock Grid.Row="3" Grid.ColumnSpan="2" x:Name="AiStatus" Foreground="#8A8F9C" TextWrapping="Wrap"
                                   Text="提示：Claude 国内需自备代理；GLM/DeepSeek 国内可直连。key 仅保存在本地 ai_config.json。"/>
                    </Grid>
                </Expander>

                <!-- 表情面板 -->
                <TextBlock Grid.Row="7" Text="表情（点击插入到个签光标处）" Foreground="#9DA1AD" Margin="0,4,0,4"/>
                <Border Grid.Row="8" Background="#23252E" CornerRadius="6" Padding="6" Margin="0,0,0,4">
                    <WrapPanel x:Name="EmojiPanel"/>
                </Border>

                <!-- 操作按钮 -->
                <StackPanel Grid.Row="9" Orientation="Horizontal" Margin="0,8,0,0">
                    <Button x:Name="NewBtn"  Content="新建" Width="78" Margin="0,0,8,0"/>
                    <Button x:Name="SaveBtn" Content="保存" Width="78" Margin="0,0,8,0"/>
                    <Button x:Name="DelBtn"  Content="删除" Width="78"/>
                </StackPanel>
            </Grid>
        </Grid>

        <!-- 底部应用按钮 -->
        <Grid Grid.Row="2" Margin="0,14,0,0">
            <Button x:Name="ApplyBtn" Style="{StaticResource Accent}" Content="✔  应用到客户端"
                    Height="44" FontSize="15"/>
        </Grid>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 获取控件
$SigList     = $window.FindName('SigList')
$NameBox     = $window.FindName('NameBox')
$ContentBox  = $window.FindName('TextBox_Content')
$NewBtn      = $window.FindName('NewBtn')
$SaveBtn     = $window.FindName('SaveBtn')
$DelBtn      = $window.FindName('DelBtn')
$ApplyBtn    = $window.FindName('ApplyBtn')
$RefreshBtn  = $window.FindName('RefreshBtn')
$StatusDot   = $window.FindName('StatusDot')
$StatusText  = $window.FindName('StatusText')
$TimeBtn     = $window.FindName('TimeBtn')
$WeatherBtn  = $window.FindName('WeatherBtn')
$MatchBtn    = $window.FindName('MatchBtn')
$AutoChk     = $window.FindName('AutoChk')
$CityBox     = $window.FindName('CityBox')
$EmojiPanel  = $window.FindName('EmojiPanel')
$AiProviderBox = $window.FindName('AiProviderBox')
$AiKeyBox      = $window.FindName('AiKeyBox')
$AiModelBox    = $window.FindName('AiModelBox')
$AiTestBtn     = $window.FindName('AiTestBtn')
$AiStatus      = $window.FindName('AiStatus')

# ---------- 构建表情面板 ----------
$Emojis = @(
    '❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💗','💓','💕','💞','💘','💝','💔',
    '⚔️','🗡️','🛡️','👑','🔥','💀','☠️','🎮','🕹️','🏆','⭐','✨','💥','🎯','⚡','🌟',
    '🐉','🦁','🌙','☀️','🌈','😎','😏','😈','🤖','👻'
)
$InsertEmoji = {
    param($senderObj, $eventArgs)
    $emoji = [string]$senderObj.Content
    $pos = $ContentBox.CaretIndex
    $ContentBox.Text = $ContentBox.Text.Insert($pos, $emoji)
    $ContentBox.CaretIndex = $pos + $emoji.Length
    $ContentBox.Focus() | Out-Null
}
foreach ($em in $Emojis) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $em
    $b.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Emoji')
    $b.FontSize = 17
    $b.Width = 36; $b.Height = 34
    $b.Margin = New-Object System.Windows.Thickness(2)
    $b.Background = [System.Windows.Media.Brushes]::Transparent
    $b.ToolTip = '点击插入'
    $b.Add_Click($InsertEmoji)
    $EmojiPanel.Children.Add($b) | Out-Null
}

# ---------- 界面刷新逻辑 ----------
function Refresh-List {
    param($selectName)
    $SigList.Items.Clear()
    foreach ($s in $script:Signatures) { $SigList.Items.Add($s) | Out-Null }
    if ($selectName) {
        foreach ($item in $SigList.Items) {
            if ($item.Name -eq $selectName) { $SigList.SelectedItem = $item; break }
        }
    }
}

function Update-Status {
    $cred = Get-LcuCredentials
    if ($cred.Port) {
        $StatusDot.Fill = [System.Windows.Media.Brushes]::LimeGreen
        $StatusText.Text = "客户端已连接  (端口 $($cred.Port))"
    } elseif ($cred.Error -eq 'noperm') {
        $StatusDot.Fill = [System.Windows.Media.Brushes]::Orange
        $StatusText.Text = '检测到客户端，但权限不足，请以管理员身份运行'
    } else {
        $StatusDot.Fill = [System.Windows.Media.Brushes]::IndianRed
        $StatusText.Text = '未检测到英雄联盟客户端，请先启动游戏'
    }
}

# ---------- 事件绑定 ----------
$SigList.Add_SelectionChanged({
    $sel = $SigList.SelectedItem
    if ($sel) { $NameBox.Text = $sel.Name; $ContentBox.Text = $sel.Text }
})

$SigList.Add_MouseDoubleClick({
    if ($SigList.SelectedItem) {
        $ApplyBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
})

$NewBtn.Add_Click({
    $SigList.SelectedItem = $null
    $NameBox.Text = ''; $ContentBox.Text = ''
    $NameBox.Focus() | Out-Null
})

$SaveBtn.Add_Click({
    $name = $NameBox.Text.Trim()
    $text = $ContentBox.Text
    if (-not $name) {
        [System.Windows.MessageBox]::Show('请填写名称', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $existing = $null
    foreach ($s in $script:Signatures) { if ($s.Name -eq $name) { $existing = $s; break } }
    if ($existing) { $existing.Text = $text }
    else { $script:Signatures.Add([pscustomobject]@{ Name = $name; Text = $text }) }
    Save-Signatures
    Refresh-List -selectName $name
})

$DelBtn.Add_Click({
    $sel = $SigList.SelectedItem
    if (-not $sel) {
        [System.Windows.MessageBox]::Show('请先在左侧选择要删除的个签', '提示', 'OK', 'Information') | Out-Null
        return
    }
    if ([System.Windows.MessageBox]::Show("确定删除「$($sel.Name)」？", '确认', 'YesNo', 'Question') -eq 'Yes') {
        $toRemove = $null
        foreach ($s in $script:Signatures) { if ($s.Name -eq $sel.Name) { $toRemove = $s; break } }
        if ($toRemove) { $script:Signatures.Remove($toRemove) | Out-Null }
        Save-Signatures
        Refresh-List
        $NameBox.Text = ''; $ContentBox.Text = ''
    }
})

$TimeBtn.Add_Click({
    $TimeBtn.IsEnabled = $false
    $old = $TimeBtn.Content; $TimeBtn.Content = '生成中…'
    $TimeBtn.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        $mode = Get-CurrentModeInfo
        $line = $null
        if ($script:AiConfig.Provider -ne 'off' -and $script:AiConfig.Key) {
            $h = (Get-Date).Hour
            $seg = if ($h -lt 6) { '深夜/凌晨' } elseif ($h -lt 11) { '早上' } elseif ($h -lt 14) { '中午' } elseif ($h -lt 18) { '下午' } elseif ($h -lt 22) { '晚上' } else { '深夜' }
            $modeTxt = if ($mode.Name) { $mode.Name } else { '排位/大乱斗' }
            $line = Get-AiInspiration -Facts "现在是$seg（$h 点），我平时/最近主要玩的模式是「$modeTxt」，想结合这个时间段写一句英雄联盟主题的个性签名。" -ModeName $mode.Name -IsClassic $mode.IsClassic
        }
        if (-not $line) { $line = Get-TimeSignature -IsClassic $mode.IsClassic }
        $ContentBox.Text = $line; $ContentBox.Focus() | Out-Null
    } finally { $TimeBtn.Content = $old; $TimeBtn.IsEnabled = $true }
})

$WeatherBtn.Add_Click({
    $WeatherBtn.IsEnabled = $false
    $old = $WeatherBtn.Content
    $WeatherBtn.Content = '获取中…'
    # 让界面先刷新出"获取中"
    $WeatherBtn.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        $w = Get-WeatherRaw -City $CityBox.Text
        if ($w) {
            $mode = Get-CurrentModeInfo
            $line = $null
            if ($script:AiConfig.Provider -ne 'off' -and $script:AiConfig.Key) {
                $modeTxt = if ($mode.Name) { $mode.Name } else { '排位/大乱斗' }
                $line = Get-AiInspiration -Facts "今天天气：$($w.cond)，气温 $($w.temp)。我平时/最近主要玩的模式是「$modeTxt」，想结合这个天气写一句英雄联盟主题的个性签名。" -ModeName $mode.Name -IsClassic $mode.IsClassic
            }
            if (-not $line) { $line = New-WeatherLine -cond $w.cond -temp $w.temp -cat $w.cat -IsClassic $mode.IsClassic }
            $ContentBox.Text = $line
        }
        else {
            $detail = if ($script:LastWeatherError) { "`n`n详细原因：$script:LastWeatherError" } else { '' }
            [System.Windows.MessageBox]::Show("天气获取失败。`n国内请在「城市」栏填写中文城市名（如 上海、成都）后重试。$detail", '提示', 'OK', 'Information') | Out-Null
        }
    } finally {
        $WeatherBtn.Content = $old
        $WeatherBtn.IsEnabled = $true
    }
})

$MatchBtn.Add_Click({
    $MatchBtn.IsEnabled = $false
    $old = $MatchBtn.Content
    $MatchBtn.Content = '读取中…'
    $MatchBtn.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        $res = Get-MatchSignature
        if ($res.ok) { $ContentBox.Text = $res.text; $ContentBox.Focus() | Out-Null }
        else { [System.Windows.MessageBox]::Show($res.msg, '提示', 'OK', 'Information') | Out-Null }
    } finally {
        $MatchBtn.Content = $old
        $MatchBtn.IsEnabled = $true
    }
})

# 勾选自动模式时，记录当前最近对局 + 当前对局阶段，之后只在"打完新的一局"那一刻触发一次
$AutoChk.Add_Checked({
    $script:LastGameId = Get-LatestGameId
    $script:LastPhase = Get-GameflowPhase
    $script:PendingSince = $null
    $StatusText.Text = '自动模式已开启：打完下一把会自动更新个签'
})
$AutoChk.Add_Unchecked({ Update-Status })

$ApplyBtn.Add_Click({
    $text = $ContentBox.Text
    if (-not $text) {
        [System.Windows.MessageBox]::Show('个签内容为空', '提示', 'OK', 'Information') | Out-Null
        return
    }
    try {
        $ApplyBtn.IsEnabled = $false
        $ApplyBtn.Content = '正在应用...'
        Set-LolStatusMessage -Message $text
        Update-Status
        [System.Windows.MessageBox]::Show('个签修改成功！', '成功', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, '失败', 'OK', 'Error') | Out-Null
    } finally {
        $ApplyBtn.IsEnabled = $true
        $ApplyBtn.Content = '✔  应用到客户端'
    }
})

$RefreshBtn.Add_Click({ Update-Status })

# ---------- 定时检测客户端连接 ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(4)
$timer.Add_Tick({ Update-Status })
$timer.Start()

# ---------- 自动模式：监听"对局阶段"，离开对局后持续等待新战绩出现，再读一次 ----------
# 说明：早期实现是每 20 秒轮询一次战绩列表接口（只查1条），高频窄范围访问会让客户端自身
# "近期对局"面板的响应式缓存被"顶替"打乱（已修复）。第二版改成"跳变到 EndOfGame 后固定等5秒、只读一次"，
# 但如果 Riot 服务器写入战绩记录比5秒慢（或该模式的结算阶段名称/时机不同），就会永久错过这次触发。
# 现在改为：监听"是否还在对局中"（InProgress/Reconnect），一旦离开对局，就在最多90秒内每隔6秒
# 用轻量的宽范围查询检查一次是否出现新的 gameId，出现了才去读一次完整战绩——不再是"赌一次能不能踩中时机"。
$script:LastGameId = $null
$script:LastPhase = $null
$script:PendingSince = $null
$script:PlayingPhases = @('InProgress', 'Reconnect')
$autoTimer = New-Object System.Windows.Threading.DispatcherTimer
$autoTimer.Interval = [TimeSpan]::FromSeconds(6)
$autoTimer.Add_Tick({
    if (-not $AutoChk.IsChecked) { return }
    $phase = Get-GameflowPhase
    if (-not $phase) { return }

    # 刚从"对局中"离开：开始等待战绩记录写入完成
    if (($script:LastPhase -in $script:PlayingPhases) -and ($phase -notin $script:PlayingPhases) -and (-not $script:PendingSince)) {
        $script:PendingSince = Get-Date
    }
    $script:LastPhase = $phase

    if ($script:PendingSince) {
        if (((Get-Date) - $script:PendingSince).TotalSeconds -gt 90) {
            $script:PendingSince = $null   # 超时放弃，避免一直重试（比如只是进了训练模式又退出）
        } else {
            $gid = Get-LatestGameId
            if ($gid -and $gid -ne $script:LastGameId) {
                $script:PendingSince = $null
                $res = Get-MatchSignature
                if ($res.ok) {
                    $script:LastGameId = $res.gameId
                    $ContentBox.Text = $res.text
                    try {
                        Set-LolStatusMessage -Message $res.text
                        $StatusText.Text = '已自动更新个签：' + $res.text
                    } catch {
                        $StatusText.Text = '自动生成成功，但应用失败：' + $_.Exception.Message
                    }
                }
            }
        }
    }
})
$autoTimer.Start()

# ---------- AI 设置：载入 + 事件 ----------
$script:AiProviderCodes = @('off', 'claude', 'glm', 'deepseek')
Load-AiConfig
$aiIdx = [Array]::IndexOf($script:AiProviderCodes, $script:AiConfig.Provider)
if ($aiIdx -lt 0) { $aiIdx = 0 }
$AiProviderBox.SelectedIndex = $aiIdx
$AiKeyBox.Password = $script:AiConfig.Key
$AiModelBox.Text   = $script:AiConfig.Model

$AiProviderBox.Add_SelectionChanged({
    $i = $AiProviderBox.SelectedIndex
    if ($i -ge 0) { $script:AiConfig.Provider = $script:AiProviderCodes[$i]; Save-AiConfig }
})
$AiKeyBox.Add_PasswordChanged({ $script:AiConfig.Key = $AiKeyBox.Password; Save-AiConfig })
$AiModelBox.Add_TextChanged({ $script:AiConfig.Model = $AiModelBox.Text.Trim(); Save-AiConfig })

$AiTestBtn.Add_Click({
    $script:AiConfig.Provider = $script:AiProviderCodes[$AiProviderBox.SelectedIndex]
    $script:AiConfig.Key = $AiKeyBox.Password
    $script:AiConfig.Model = $AiModelBox.Text.Trim()
    Save-AiConfig
    if ($script:AiConfig.Provider -eq 'off') { $AiStatus.Text = '当前是“关闭”，请先选一个服务。'; return }
    if (-not $script:AiConfig.Key) { $AiStatus.Text = '请先填写 key。'; return }
    $AiTestBtn.IsEnabled = $false; $old = $AiTestBtn.Content; $AiTestBtn.Content = '测试中…'
    $AiTestBtn.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        $r = Invoke-Ai -Prompt '用不超过10个字，俏皮地说一句"测试成功"，只输出这句话，不要引号。'
        if ($r) { $AiStatus.Text = 'AI 已连通 ✅  返回：' + $r }
        else    { $AiStatus.Text = '连接失败 ❌  请检查 key / 网络（Claude需代理）/ 模型名，或换个服务。' }
    } finally { $AiTestBtn.Content = $old; $AiTestBtn.IsEnabled = $true }
})

# ---------- 启动 ----------
Load-Signatures
Refresh-List
if ($SigList.Items.Count -gt 0) { $SigList.SelectedIndex = 0 }
Update-Status

$window.Add_Closed({ $timer.Stop(); $autoTimer.Stop() })
$window.ShowDialog() | Out-Null
