@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul

rem 設定定数。保存先はこのファイルを置いたフォルダーです。
set "OSE_SOURCE=\\10.10.100.1\log"
set "OSE_DESTINATION=%~dp0"
set "OSE_MAXMBPS=10"
set "OSE_PAUSE=1"

rem ----------------------------------------
rem 引数は不要です。ダブルクリックで未取得データを取得します。
rem OSE_MAXMBPS は速度の目安で、4.2 以上 100000 以下を指定します。
rem OSE_PAUSE=0 にすると終了時のキー入力待ちを省略します。
set "OSE_SCRIPT=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$text=[IO.File]::ReadAllText($env:OSE_SCRIPT,[Text.Encoding]::UTF8); $body=($text -split '(?m)^# OSE_POWERSHELL\r?$',2)[1]; if(-not $body){exit 2}; & ([scriptblock]::Create($body))"
set "OSE_EXITCODE=%ERRORLEVEL%"
echo.
if "%OSE_PAUSE%"=="1" pause
exit /b %OSE_EXITCODE%

# OSE_POWERSHELL
<#
機能: 新形式の共有データを同じ相対パスで取得する単一ファイルのツールです。
引数: なし。設定はファイル先頭の定数を編集します。
返り値: 終了コード [int]。0 は成功、1 は一部転送失敗、2 は準備失敗です。
既存ファイルは上書きせず、未圧縮の JSONL と先物 CSV だけを取得します。
gzip 圧縮は別工程です。gzip だけ存在しても、生 JSONL がなければ取得します。
途中データと実行記録は保存先の .fetchdata に保持し、再実行時に再開します。
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Source = $env:OSE_SOURCE
$Destination = $env:OSE_DESTINATION
[double]$MaxMbps = 0
$exitCode = 2
$mutex = $null
$hasLock = $false
$summaryPath = $null
$copied = 0
$skipped = 0
$failed = 0
[long]$copiedBytes = 0

# ----------------------------------------
function Assert-OrdinaryPath {
    <#
    機能: パスの既存部分にリンクや接合点がないことを確認します。
    引数: Path [string] は確認する絶対パス。
    返り値: [void]。リンクがある場合は例外を送出します。
    #>
    param([string]$Path)
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "リンクまたは接合点を含むため処理できません: $current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Get-HistoryFiles {
    <#
    機能: 新形式の先物と OP の完成ファイルだけを列挙します。
    引数: Root [string] は共有ログのルート。
    返り値: [IO.FileInfo[]]。旧形式・一時ファイル・OP 分足は含めません。
    #>
    param([string]$Root)
    foreach ($relativeRoot in @('future\NK225', 'future\TOPIX', 'op')) {
        $dataRoot = Join-Path $Root $relativeRoot
        Assert-OrdinaryPath -Path $dataRoot
        if (-not (Test-Path -LiteralPath $dataRoot)) { continue }
        if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
            throw "データフォルダーの位置にファイルがあります: $dataRoot"
        }
        foreach ($session in Get-ChildItem -LiteralPath $dataRoot -Directory -Force | Sort-Object Name) {
            if ($session.Name -cnotmatch '^\d{4}-\d{2}-\d{2}_(Day|Night)$') { continue }
            $date = [DateTime]::MinValue
            if (-not [DateTime]::TryParseExact($session.Name.Substring(0, 10), 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { continue }
            Assert-OrdinaryPath -Path $session.FullName
            foreach ($file in Get-ChildItem -LiteralPath $session.FullName -File -Force | Sort-Object Name) {
                if ($relativeRoot -eq 'op') {
                    if ($file.Name -cnotmatch '^NK225op_\d{4}(0[1-9]|1[0-2])_[CP]_[1-9]\d*\.jsonl$') { continue }
                } elseif ($file.Name -cnotin @('book.jsonl', 'candle_1min.csv', 'candle_5min.csv')) {
                    continue
                }
                Assert-OrdinaryPath -Path $file.FullName
                $file
            }
        }
    }
}

function Write-Record {
    <#
    機能: ファイルごとの処理結果を実行記録へ追記します。
    引数: Path [string] は記録先、Status [string] は結果、RelativePath [string] は相対パス。
          Bytes [long] はサイズ、Detail [string] は補足です。
    返り値: [void]。
    #>
    param([string]$Path, [string]$Status, [string]$RelativePath, [long]$Bytes, [string]$Detail)
    [ordered]@{
        '日時' = (Get-Date).ToString('o')
        '結果' = $Status
        '相対パス' = $RelativePath
        'バイト数' = $Bytes
        '補足' = $Detail
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Test-ResumeState {
    <#
    機能: 途中ファイルと管理情報が今回のコピー元に対応するか確認します。
    引数: File [string] は途中ファイル、Info [string] は管理情報。
          Length [long] はコピー元のサイズ、Ticks [long] は UTC 更新日時です。
    返り値: [bool]。サイズと日時が同じ取得元の途中データなら true です。
    #>
    param([string]$File, [string]$Info, [long]$Length, [long]$Ticks)
    Assert-OrdinaryPath -Path $File
    Assert-OrdinaryPath -Path $Info
    if (-not (Test-Path -LiteralPath $File -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Info -PathType Leaf)) { return $false }
    try {
        $old = Get-Content -LiteralPath $Info -Raw -Encoding UTF8 | ConvertFrom-Json
        return ($old.'サイズ' -eq $Length -and $old.'更新日時' -eq $Ticks -and
            (Get-Item -LiteralPath $File).Length -le $Length)
    } catch { return $false }
}

# ----------------------------------------
try {
    if (-not [double]::TryParse($env:OSE_MAXMBPS, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$MaxMbps) -or
        [double]::IsNaN($MaxMbps) -or [double]::IsInfinity($MaxMbps) -or
        $MaxMbps -lt 4.2 -or $MaxMbps -gt 100000) {
        throw '先頭の OSE_MAXMBPS には 4.2 以上 100000 以下の数値を指定してください。'
    }
    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Destination)) {
        throw '先頭の取得元・保存先を指定してください。'
    }
    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ($destinationRoot -notmatch '^[A-Za-z]:\\.+') { throw '保存先はローカルドライブ内のフォルダーにしてください。' }
    if ($sourceRoot -eq $destinationRoot -or
        $destinationRoot.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $sourceRoot.StartsWith($destinationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'コピー元と保存先は、互いに含まれない別のフォルダーにしてください。'
    }
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "コピー元を開けません。VPN・共有名・読み取り権限を確認してください: $sourceRoot"
    }
    Assert-OrdinaryPath -Path $sourceRoot
    Assert-OrdinaryPath -Path $destinationRoot
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'future') -PathType Container) -and
        -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'op') -PathType Container)) {
        throw 'コピー元に新形式の future または op フォルダーがありません。'
    }
    $robocopy = (Get-Command robocopy.exe -ErrorAction Stop).Source
    $helpText = & $robocopy /? | Out-String
    if ($helpText -notmatch '(?i)/IoRate:') { throw 'この Robocopy は速度制限に対応していません。' }
    [long]$rateBytes = [Math]::Floor($MaxMbps * 1000000 / 8)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($destinationRoot.ToUpperInvariant()))
        $lockKey = ([BitConverter]::ToString($digest)).Replace('-', '').Substring(0, 24)
    } finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\OSEDataReceive_' + $lockKey))
    try { $hasLock = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $hasLock = $true }
    if (-not $hasLock) { throw '同じ保存先への取得処理がすでに動いています。' }

    # ----------------------------------------
    $stateRoot = Join-Path $destinationRoot '.fetchdata'
    $stageRoot = Join-Path $stateRoot 'staging'
    $resumeRoot = Join-Path $stateRoot 'resume'
    $logRoot = Join-Path $stateRoot 'logs'
    foreach ($path in @($stageRoot, $resumeRoot, $logRoot)) {
        Assert-OrdinaryPath -Path $path
        [void][IO.Directory]::CreateDirectory($path)
    }
    $stateInfo = Join-Path $stateRoot 'source.json'
    Assert-OrdinaryPath -Path $stateInfo
    if (Test-Path -LiteralPath $stateInfo) {
        $previous = Get-Content -LiteralPath $stateInfo -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($previous.'コピー元' -ne $sourceRoot -or $previous.'保存先' -ne $destinationRoot) {
            throw '別の取得元・保存先の途中データがあります。.fetchdata の配置を確認してください。'
        }
    } else {
        [ordered]@{'コピー元' = $sourceRoot; '保存先' = $destinationRoot} |
            ConvertTo-Json | Set-Content -LiteralPath $stateInfo -Encoding UTF8
    }
    $runName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $recordPath = Join-Path $logRoot ($runName + '-files.jsonl')
    $robocopyLog = Join-Path $logRoot ($runName + '-transfer.log')
    $summaryPath = Join-Path $logRoot ($runName + '-summary.json')
    Write-Host "取得元: $sourceRoot"
    Write-Host "保存先: $destinationRoot"
    Write-Host "速度の目安: $MaxMbps Mbps。未取得の生 JSONL と先物 CSV を単一転送します。"
    Write-Host '新形式のファイル一覧を確認しています。既存ファイルは省略します。'

    # ----------------------------------------
    $pending = New-Object 'Collections.Generic.List[object]'
    [long]$requiredBytes = 0
    foreach ($file in Get-HistoryFiles -Root $sourceRoot) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1)
        $target = Join-Path $destinationRoot $relative
        Assert-OrdinaryPath -Path $target
        if (Test-Path -LiteralPath $target) {
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                throw "ファイルの保存位置にフォルダーがあります: $relative"
            }
            $skipped++
            Write-Record $recordPath '既存のため省略' $relative $file.Length ''
            continue
        }
        $pending.Add([pscustomobject]@{Path = $file.FullName; Relative = $relative; Length = $file.Length})
        $stageFile = Join-Path $stageRoot $relative
        $resumeInfo = Join-Path $resumeRoot ($relative + '.json')
        [long]$needed = $file.Length
        if (Test-ResumeState $stageFile $resumeInfo $file.Length $file.LastWriteTimeUtc.Ticks) {
            $needed -= (Get-Item -LiteralPath $stageFile).Length
        }
        $requiredBytes += $needed
    }
    $driveInfo = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($destinationRoot))
    if ($requiredBytes -gt $driveInfo.AvailableFreeSpace) { throw "空き容量が不足しています。必要量は $requiredBytes バイトです。" }
    Write-Host ("未取得: {0} 件、既存: {1} 件" -f $pending.Count, $skipped)

    # ----------------------------------------
    $index = 0
    foreach ($entry in $pending) {
        $index++
        $relative = $entry.Relative
        $target = Join-Path $destinationRoot $relative
        Write-Host ("[{0}/{1}] {2}" -f $index, $pending.Count, $relative)
        try {
            Assert-OrdinaryPath -Path $target
            if (Test-Path -LiteralPath $target) {
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw '保存位置にフォルダーが作成されました。' }
                $skipped++
                Write-Record $recordPath '既存のため省略' $relative $entry.Length '一覧確認後に作成された項目'
                continue
            }
            Assert-OrdinaryPath -Path $entry.Path
            $before = Get-Item -LiteralPath $entry.Path -Force
            [long]$beforeLength = $before.Length
            [long]$beforeTicks = $before.LastWriteTimeUtc.Ticks
            $stageFile = Join-Path $stageRoot $relative
            $stageDirectory = [IO.Path]::GetDirectoryName($stageFile)
            $resumeInfo = Join-Path $resumeRoot ($relative + '.json')
            $canResume = Test-ResumeState $stageFile $resumeInfo $beforeLength $beforeTicks
            [void][IO.Directory]::CreateDirectory($stageDirectory)
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resumeInfo))
            if ((Test-Path -LiteralPath $stageFile) -and -not $canResume) {
                $absoluteStage = [IO.Path]::GetFullPath($stageFile)
                if (-not $absoluteStage.StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
                    -not (Test-Path -LiteralPath $absoluteStage -PathType Leaf)) {
                    throw '途中データの削除対象が検証済みの一時フォルダー内のファイルではありません。'
                }
                Remove-Item -LiteralPath $absoluteStage -Force
            }
            [long]$needed = $beforeLength
            if (Test-Path -LiteralPath $stageFile -PathType Leaf) { $needed -= (Get-Item -LiteralPath $stageFile).Length }
            if ($needed -gt $driveInfo.AvailableFreeSpace) { throw '取得途中でローカルの空き容量が不足しました。' }
            [ordered]@{'サイズ' = $beforeLength; '更新日時' = $beforeTicks} |
                ConvertTo-Json | Set-Content -LiteralPath $resumeInfo -Encoding UTF8
            $roboArgs = @(
                ($before.DirectoryName.TrimEnd('\') + '\.'), ($stageDirectory.TrimEnd('\') + '\.'), $before.Name,
                '/Z', '/IS', '/IT', '/COPY:DAT', '/NODCOPY', '/R:2', '/W:3',
                "/IORATE:$rateBytes", '/THRESHOLD:0', '/NP', '/NJH', '/NJS', '/BYTES', '/FP', '/TS',
                "/UNILOG+:$robocopyLog"
            )
            & $robocopy @roboArgs | Out-Null
            $roboCode = $LASTEXITCODE
            if ($roboCode -lt 0 -or $roboCode -gt 7) { throw "転送が完了しませんでした。Robocopy 終了コード: $roboCode" }
            Assert-OrdinaryPath -Path $entry.Path
            Assert-OrdinaryPath -Path $stageFile
            $after = Get-Item -LiteralPath $entry.Path -Force
            $staged = Get-Item -LiteralPath $stageFile -Force
            if ($beforeLength -ne $after.Length -or $beforeTicks -ne $after.LastWriteTimeUtc.Ticks -or
                $staged.Length -ne $beforeLength -or $staged.LastWriteTimeUtc.Ticks -ne $beforeTicks) {
                throw '取得中にコピー元が変化したか、受信後のサイズ・更新日時が一致しません。途中データを保留します。'
            }
            Assert-OrdinaryPath -Path $target
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $absoluteTarget = [IO.Path]::GetFullPath($target)
            if (-not $absoluteTarget.StartsWith($destinationRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
                -not ([IO.Path]::GetFullPath($stageFile)).StartsWith($stageRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw '公開するファイルが検証済みの取得先・一時フォルダー外です。'
            }
            try { [IO.File]::Move($stageFile, $absoluteTarget) }
            catch [IO.IOException] {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    $skipped++
                    Write-Record $recordPath '既存のため省略' $relative $beforeLength '転送中に作成された保存先を保護'
                    continue
                }
                throw
            }
            $copied++
            $copiedBytes += $beforeLength
            Write-Record $recordPath '取得完了' $relative $beforeLength '転送成功とサイズ・更新日時を確認'
        } catch {
            $failed++
            Write-Record $recordPath '失敗・次回再取得' $relative $entry.Length $_.Exception.Message
            Write-Warning ("{0}: {1}" -f $relative, $_.Exception.Message)
        }
    }
    if ($failed -eq 0) { $exitCode = 0 } else { $exitCode = 1 }
} catch {
    Write-Warning $_.Exception.Message
    $exitCode = 2
} finally {
    # ----------------------------------------
    try {
        if ($summaryPath) {
            [ordered]@{
                '終了日時' = (Get-Date).ToString('o')
                'コピー元' = $Source
                '保存先' = $Destination
                '速度目安Mbps' = $MaxMbps
                '取得件数' = $copied
                '取得バイト数' = $copiedBytes
                '既存のため省略した件数' = $skipped
                '転送失敗件数' = $failed
                '終了コード' = $exitCode
            } | ConvertTo-Json | Set-Content -LiteralPath $summaryPath -Encoding UTF8
        }
    } catch {
        $exitCode = 2
        Write-Warning ("実行記録を保存できませんでした: {0}" -f $_.Exception.Message)
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}
Write-Host ("取得: {0} 件 / {1:N0} バイト、既存省略: {2} 件、転送失敗: {3} 件" -f $copied, $copiedBytes, $skipped, $failed)
if ($summaryPath) { Write-Host "実行記録: $summaryPath" }
if ($exitCode -eq 0) { Write-Host '完了しました。' }
else { Write-Warning '未完了です。原因を解消して同じファイルを再実行してください。' }
exit $exitCode
