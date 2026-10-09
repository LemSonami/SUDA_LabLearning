Set-StrictMode -Version 2

function Get-RunningBrowser {
    $seen = @{}
    foreach ($process in Get-Process -Name msedge,chrome,firefox -ErrorAction SilentlyContinue) {
        if ($process.MainWindowHandle -eq 0) { continue }
        $kind = switch ($process.ProcessName) { msedge { 'Edge' }; chrome { 'Chrome' }; firefox { 'Firefox' } }
        $exe = $process.Path
        if (-not $exe -or $seen.ContainsKey($exe)) { continue }
        $seen[$exe] = $true
        $command = ''
        try { $command = (Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction Stop).CommandLine } catch { }
        $root = switch ($kind) {
            Edge { Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data' }
            Chrome { Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' }
            Firefox { Join-Path $env:APPDATA 'Mozilla\Firefox' }
        }
        if ($kind -ne 'Firefox' -and $command -match '--user-data-dir=(?:"([^"]+)"|(\S+))') {
            $root = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        }
        [pscustomobject]@{ Kind=$kind; Exe=$exe; Root=$root; Label="$kind — $($process.MainWindowTitle)" }
    }
}

function Get-BrowserProfiles($Browser) {
    if ($Browser.Kind -eq 'Firefox') {
        $ini = Join-Path $Browser.Root 'profiles.ini'
        if (-not (Test-Path -LiteralPath $ini)) { return }
        $content = Get-Content -LiteralPath $ini -Raw
        foreach ($section in ($content -split '(?m)^\[')) {
            if ($section -notmatch '^Profile') { continue }
            $pathMatch = [regex]::Match($section, '(?m)^Path=(.+)\r?$')
            if (-not $pathMatch.Success) { continue }
            $path = $pathMatch.Groups[1].Value.Trim()
            if ($section -match '(?m)^IsRelative=1') { $path = Join-Path $Browser.Root $path }
            $nameMatch = [regex]::Match($section, '(?m)^Name=(.+)\r?$')
            if (Test-Path -LiteralPath $path) { [pscustomobject]@{ Name=$nameMatch.Groups[1].Value.Trim(); Path=$path } }
        }
        return
    }
    $cache = $null
    try { $cache = (Get-Content -LiteralPath (Join-Path $Browser.Root 'Local State') -Raw -Encoding UTF8 | ConvertFrom-Json).profile.info_cache } catch { }
    foreach ($dir in Get-ChildItem -LiteralPath $Browser.Root -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name -ne 'Default' -and $dir.Name -notlike 'Profile *') { continue }
        $name = $dir.Name
        if ($cache) {
            $entry = $cache.PSObject.Properties[$dir.Name]
            if ($entry -and $entry.Value.name) { $name = "$($entry.Value.name) ($($dir.Name))" }
        }
        [pscustomobject]@{ Name=$name; Path=$dir.FullName }
    }
}

function Get-TampermonkeyStatus([string]$Kind, [string]$ProfilePath, [ref]$Reason) {
    $Reason.Value = ''
    if ($Kind -eq 'Firefox') {
        try {
            $data = Get-Content -LiteralPath (Join-Path $ProfilePath 'extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $addons = @($data.addons | Where-Object { $_.id -eq 'firefox@tampermonkey.net' })
            if ($addons.Count -eq 0) { return 'Absent' }
            if ($addons.Count -ne 1) { $Reason.Value='发现重复的油猴记录。'; return 'Unknown' }
            $addon = $addons[0]
            if ($addon.active -eq $true) { return 'Enabled' }
            if ($addon.userDisabled -eq $true -or $addon.appDisabled -eq $true -or $addon.active -eq $false) { return 'Disabled' }
            $Reason.Value='Firefox记录缺少启用状态。'; return 'Unknown'
        } catch { $Reason.Value='无法读取Firefox扩展配置。'; return 'Unknown' }
    }
    $ids = if ($Kind -eq 'Edge') { @('iikmkjmpaadaobahmlepeloendndfphd','dhdgffkkebhmkfjojejmpbldmpobfkfo') } else { @('dhdgffkkebhmkfjojejmpbldmpobfkfo') }
    $documents = @()
    $readErrors = 0
    foreach ($file in @('Secure Preferences','Preferences')) {
        $path = Join-Path $ProfilePath $file
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try { $documents += Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $readErrors++ }
    }
    if ($documents.Count -eq 0) { $Reason.Value='没有可读取的浏览器扩展配置。'; return 'Unknown' }
    $states = @()
    foreach ($id in $ids) {
        $entries = @()
        foreach ($doc in $documents) {
            $extensionsProp = $doc.PSObject.Properties['extensions']
            if (-not $extensionsProp) { continue }
            $settingsProp = $extensionsProp.Value.PSObject.Properties['settings']
            if (-not $settingsProp) { continue }
            $entry = $settingsProp.Value.PSObject.Properties[$id]
            if ($entry) { $entries += $entry.Value }
        }
        if (-not $entries.Count) { continue } # Residual files alone never prove installation.
        $liveEntries = @($entries | Where-Object {
            $_.PSObject.Properties['state'] -or $_.PSObject.Properties['disable_reasons'] -or
            $_.PSObject.Properties['path'] -or $_.PSObject.Properties['manifest']
        })
        if (-not $liveEntries.Count) { continue } # Uninstall tombstones may outlive residual payload files.
        $payload = $false
        $folder = Join-Path $ProfilePath "Extensions\$id"
        if (Test-Path -LiteralPath $folder) {
            $payload = @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') }).Count -gt 0
        }
        foreach ($entry in $entries) {
            $pathProp = $entry.PSObject.Properties['path']
            if ($pathProp -and $pathProp.Value) {
                $extensionPath = [string]$pathProp.Value
                if (-not [IO.Path]::IsPathRooted($extensionPath)) { $extensionPath = Join-Path $ProfilePath $extensionPath }
                if (Test-Path -LiteralPath (Join-Path $extensionPath 'manifest.json')) { $payload = $true }
            }
        }
        if (-not $payload) { continue } # Empty Secure Preferences tombstones after uninstall.
        $found = $false
        foreach ($entry in $entries) {
            $disable = $entry.PSObject.Properties['disable_reasons']
            $state = $entry.PSObject.Properties['state']
            if ($state -and $null -ne $state.Value -and [string]$state.Value -match '^[02]$') {
                $states += 'Disabled'; $found = $true; break
            }
            if ($disable -and $null -ne $disable.Value) {
                $reasons = @($disable.Value)
                if (@($reasons | Where-Object { [string]$_ -ne '0' }).Count) { $states += 'Disabled' }
                else { $states += 'Enabled' }
                $found = $true; break
            }
            if ($state -and $null -ne $state.Value -and [string]$state.Value -match '^[012]$') {
                $states += $(if ([int]$state.Value -eq 1) { 'Enabled' } else { 'Disabled' })
                $found = $true; break
            }
        }
        if (-not $found) { $states += 'Unknown' }
    }
    if ($states -contains 'Enabled') { return 'Enabled' }
    if ($states -contains 'Disabled') { return 'Disabled' }
    if ($states -contains 'Unknown' -or $readErrors) { $Reason.Value='已发现扩展文件，但配置缺少有效state/disable_reasons，或部分配置不能读取。'; return 'Unknown' }
    return 'Absent'
}

function Get-TampermonkeyStore([string]$Kind) {
    switch ($Kind) {
        Edge { 'https://microsoftedge.microsoft.com/addons/detail/iikmkjmpaadaobahmlepeloendndfphd' }
        Chrome { 'https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo' }
        Firefox { 'https://addons.mozilla.org/zh-CN/firefox/addon/tampermonkey/' }
    }
}

function Open-BrowserPage($Browser, $Profile, [string]$Url) {
    if ($Browser.Kind -eq 'Firefox') {
        $arguments = @('-profile', ('"'+$Profile.Path+'"'), ('"'+$Url+'"'))
    } else {
        $arguments = @(('--user-data-dir="'+$Browser.Root+'"'), ('--profile-directory="'+(Split-Path $Profile.Path -Leaf)+'"'), ('"'+$Url+'"'))
    }
    Start-Process -FilePath $Browser.Exe -ArgumentList $arguments -WindowStyle Hidden
}

Export-ModuleMember -Function Get-RunningBrowser,Get-BrowserProfiles,Get-TampermonkeyStatus,Get-TampermonkeyStore,Open-BrowserPage