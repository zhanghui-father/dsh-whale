# UI Automation runs in a separate process so a hung target cannot freeze the widget.
[CmdletBinding()]
param([string]$RequestPath)
$ErrorActionPreference = 'Stop'

function Get-EditorRank {
    param([string]$Name, [string]$Id, [string]$ClassName)
    $hint = $Name + ' ' + $Id + ' ' + $ClassName
    if ($hint -match '(?i)search|find|address|omnibox|urlbar|搜索|查找|地址|筛选|密码|password') { return -1 }
    if ($hint -match '(?i)composer|chat[-_ ]?(input|editor)|message[-_ ]?(input|editor)|prompt[-_ ]?(input|editor)|输入.*(消息|问题|内容)|发送消息|向.*提问|询问|说点什么|输入框') { return 100 }
    if ($hint -match '(?i)message|prompt|ask|提问|消息|输入|textarea') { return 50 }
    return 0
}

function Get-EditorText {
    param($Element)
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        return @{ Readable = $true; Text = [string]$pattern.Current.Value }
    }
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
        return @{ Readable = $true; Text = [string]$pattern.DocumentRange.GetText(-1) }
    }
    return @{ Readable = $false; Text = '' }
}

function Normalize-EditorText {
    param([string]$Text)
    return ($Text.Replace("`r`n", "`n").Replace("`r", "`n")).TrimEnd([char[]]"`n")
}

function Get-ExpectedOccurrences {
    param([string]$Text, [string]$Expected)
    if (-not $Expected) { return 0 }
    return [regex]::Matches($Text, [regex]::Escape($Expected)).Count
}

function Select-ComposerCandidate {
    param([object[]]$Candidates, [string]$RuntimeId)
    if ($RuntimeId) {
        $same = @($Candidates | Where-Object RuntimeId -eq $RuntimeId)
        if ($same.Count -eq 1) { return $same[0] }
        return $null
    }
    $ranked = @($Candidates | Sort-Object Rank -Descending)
    if ($ranked.Count -and ($ranked.Count -eq 1 -or $ranked[0].Rank -gt $ranked[1].Rank)) { return $ranked[0] }
    if ($ranked.Count) {
        $focused = @($ranked | Where-Object { $_.Rank -eq $ranked[0].Rank -and $_.Focused })
        if ($focused.Count -eq 1) { return $focused[0] }
    }
    return $null
}

function Invoke-ComposerRequest {
    param($Request)
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    $h = [IntPtr][long]$Request.WindowHandle
    if ($h -eq [IntPtr]::Zero) { throw '目标窗口不存在' }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit)
    $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    $candidates = @()
    $rootBounds = $root.Current.BoundingRectangle
    foreach ($edit in $edits) {
        try {
            $c = $edit.Current
            if (-not $c.IsEnabled -or $c.IsOffscreen -or -not $c.IsKeyboardFocusable) { continue }
            $vp = $null
            if ($edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) -and $vp.Current.IsReadOnly) { continue }
            $rank = Get-EditorRank -Name $c.Name -Id $c.AutomationId -ClassName $c.ClassName
            if ($rank -lt 0) { continue }
            $bounds = $c.BoundingRectangle
            # Unnamed editors require a large editing area in the lower half of the app.
            # Geometry is only a fallback; an explicit composer name always ranks higher.
            if ($rank -eq 0) {
                if ($bounds.Width -lt 200 -or $bounds.Height -lt 35 -or $bounds.Top -lt ($rootBounds.Top + $rootBounds.Height * 0.5)) { continue }
                $rank = 10
            }
            $candidates += [pscustomobject]@{
                Element = $edit; Rank = $rank; RuntimeId = ($edit.GetRuntimeId() -join ',')
                Name = $c.Name; Id = $c.AutomationId; Focused = $c.HasKeyboardFocus
            }
        } catch { }
    }
    $details = @($candidates | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Id=$_.Id; Rank=$_.Rank; Focused=$_.Focused } })
    if ($Request.Mode -eq 'Inspect') {
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        $types = @($all | ForEach-Object { $_.Current.ControlType.ProgrammaticName })
        return @{ Ok=$true; Stage='inspect'; Candidates=$details; EditCount=$edits.Count; WindowName=$root.Current.Name; Framework=$root.Current.FrameworkId; ControlTypes=$types }
    }
    $chosen = Select-ComposerCandidate -Candidates $candidates -RuntimeId $Request.RuntimeId
    if (-not $chosen) {
        return @{ Ok=$false; Stage='locate'; Error='无法唯一识别 DSH 聊天输入框，请点一下输入框后重试'; Candidates=$details }
    }
    if ($Request.Mode -eq 'Focus') {
        $chosen.Element.SetFocus()
        Start-Sleep -Milliseconds 60
    }
    if (-not $chosen.Element.Current.HasKeyboardFocus) {
        return @{ Ok=$false; Stage='focus'; Error='聊天输入框没有获得焦点，截图和备注已保留' }
    }
    $value = Get-EditorText $chosen.Element
    $normalized = Normalize-EditorText $value.Text
    $expected = Normalize-EditorText ([string]$Request.ExpectedText)
    $occurrences = Get-ExpectedOccurrences $normalized $expected
    $result = @{
        Ok=$true; Stage=$Request.Mode; RuntimeId=$chosen.RuntimeId
        Readable=$value.Readable; TextLength=$normalized.Length; Occurrences=$occurrences
    }
    if ($Request.Mode -eq 'VerifyText') {
        $result.Verified = $value.Readable -and $occurrences -gt [int]$Request.BeforeOccurrences
    }
    return $result
}

# Dot-sourcing defines the helpers for isolated tests without touching the desktop.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $request = [IO.File]::ReadAllText($RequestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $response = Invoke-ComposerRequest $request
    } catch {
        $response = @{ Ok=$false; Stage='automation'; Error=('读取 DSH 输入框失败：' + $_.Exception.Message) }
    }
    $json = ConvertTo-Json -InputObject $response -Depth 5 -Compress
    # Redirected stdout from Windows PowerShell otherwise uses the legacy console encoding.
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::WriteLine($json)
}
