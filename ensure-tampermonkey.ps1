[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Tampermonkey.psm1') -Force

function Select-Item([object[]]$Items, [string]$Prompt) {
    if ($Items.Count -eq 0) { throw '没有找到可用项目，请先打开浏览器普通窗口。' }
    if ($Items.Count -eq 1) { return $Items[0] }
    for ($i=0; $i -lt $Items.Count; $i++) {
        $item=$Items[$i]
        $label=if ($item.PSObject.Properties['Label']) { $item.Label } else { "$($item.Name) — $($item.Path)" }
        Write-Host "[$($i+1)] $label"
    }
    while ($true) {
        $number=0
        if ([int]::TryParse((Read-Host $Prompt),[ref]$number) -and $number -ge 1 -and $number -le $Items.Count) { return $Items[$number-1] }
        Write-Host '请输入列表中的序号。'
    }
}

try {
    Write-Host '苏州大学实验室安全教育自动完成脚本desu'
    $browser=Select-Item @(Get-RunningBrowser) '请选择浏览器'
    $profiles=@(Get-BrowserProfiles $browser)
    if ($profiles.Count -gt 1) { Write-Host '请选择当前窗口的配置。Edge/Chrome可在版本页面核对Profile Path，Firefox可在about:profiles核对。' }
    $profile=Select-Item $profiles '请选择配置'
    $reason=''
    $status=Get-TampermonkeyStatus $browser.Kind $profile.Path ([ref]$reason)
    Write-Host "浏览器：$($browser.Kind)；配置：$($profile.Name)"
    if ($CheckOnly) {
        Write-Host "状态：$status $reason"
        switch ($status) { Enabled {exit 0}; Disabled {exit 4}; Absent {exit 3}; default {exit 2} }
    }
    while ($status -ne 'Enabled') {
        if ($status -eq 'Absent') {
            Write-Host '未安装。请在官方商店点击获取。'
            Open-BrowserPage $browser $profile (Get-TampermonkeyStore $browser.Kind)
        } else {
            Write-Host "请启用油猴并核对扩展状态。当前状态：$status。$reason"
            $url=switch ($browser.Kind) { Edge {'edge://extensions/'}; Chrome {'chrome://extensions/'}; Firefox {'about:addons'} }
            Open-BrowserPage $browser $profile $url
        }
        if ((Read-Host '安装/启用完成后按Enter重新检测；输入Q退出') -eq 'Q') { exit 3 }
        $reason=''
        $status=Get-TampermonkeyStatus $browser.Kind $profile.Path ([ref]$reason)
    }
    Write-Host '已确认油猴已安装、已启用。' -ForegroundColor Green
    $bank=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'question-bank\question-bank.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($bank.format -ne 'suda-reference-bank-v1' -or @($bank.questions).Count -eq 0) { throw '题库格式错误或没有题目。' }
    $bank=[pscustomobject]@{
        format='suda-reference-bank-v1'
        questionCount=@($bank.questions).Count
        scope='面向所有用户的通用参考题库；按题干、题型、选项全文匹配，不依赖试卷编号。'
        questions=@($bank.questions)
    }
    $scriptPath=Join-Path $PSScriptRoot 'suda-lab-workflow.user.js'
    $template=Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    $pattern='(?s)/\* BANK_START \*/.*?/\* BANK_END \*/'
    if ([regex]::Matches($template,$pattern).Count -ne 1) { throw '合并脚本的题库标记损坏。' }
    $replacement='/* BANK_START */' + "`n" + 'const BANK = ' + ($bank | ConvertTo-Json -Depth 50 -Compress) + ';' + "`n" + '/* BANK_END */'
    $script=[regex]::Replace($template,$pattern,[System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement })
    [IO.File]::WriteAllText($scriptPath,$script,(New-Object System.Text.UTF8Encoding($false)))
    Set-Clipboard -Value $script
    Write-Host '油猴图标 → 添加新脚本 → Ctrl+A全选 → Ctrl+V粘贴 → Ctrl+S保存脚本。'
    Write-Host '⚠注意⚠脚本已经复制，直接复制（Ctrl+V）就可以。'
    if ((Read-Host '保存脚本后按Enter打开平台；输入Q退出') -eq 'Q') { exit 0 }
    $status=Get-TampermonkeyStatus $browser.Kind $profile.Path ([ref]$reason)
    if ($status -ne 'Enabled') { throw "油猴复查未通过：$status。$reason" }
    Open-BrowserPage $browser $profile 'https://my.suda.edu.cn/lab'
    Write-Host '请自行登录并打开试卷。右下角面板直接读取题目并♥自动♥填入匹配选项。'
} catch {
    Write-Host "操作未完成捏：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}