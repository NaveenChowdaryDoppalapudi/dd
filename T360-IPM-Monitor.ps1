# =============================================================================
# T360 IPM - 13-Point Checkpoint Monitor
# Cluster  : zuse1-d003-b066-aks-p1-t360-b
# Schedule : 8am | 1pm | 6pm CST (via Windows Task Scheduler)
# Output   : Datadog Events + local log file
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
$Config = @{
    # Datadog
    DD_API_KEY         = "1aa0c33b2f44026eea8cefa819e36036"
    DD_SITE            = "us3.datadoghq.com"
    DD_TAG_CLUSTER     = "cluster:zuse1-d003-b066-aks-p1-t360-b"
    DD_TAG_ENV         = "env:prod"
    DD_TAG_APP         = "app:t360-ipm-monitor"

    # Kubernetes
    AKS_CONTEXT        = "zuse1-d003-b066-aks-p1-t360-b"

    # Item 2 - FTP
    FTP_HOST           = "zuse1pt360sftp1.wkrainier.com"
    FTP_PORT           = 21

    # Item 3 - SMTP
    SMTP_HOST          = "AUSE1-GBS-NLB-P1-INTSMTP01-697873c2c46b99c8.elb.us-east-1.amazonaws.com"
    SMTP_PORT          = 25

    # Item 8 - Thresholds
    CPU_WARN_PCT       = 80
    MEM_WARN_PCT       = 80

    # Item 11 - Azure file share
    AZURE_SUB          = "D003-B066-ELM-Z-PRD-001"
    AZURE_RG           = "zuse1-d003-b066-rgp-p1-t360-storage"
    AZURE_STORAGE_ACCT = "use1stap1t360"
    AZURE_FILE_SHARE   = "t360-prd-share"
    FILESHARE_WARN_PCT = 80
    FILESHARE_QUOTA_GB = 5120

    # Item 12 - Disk threshold
    DISK_WARN_PCT      = 75

    # Item 13 - ITP ephemeral ports
    ITP_SCRIPT         = "D:\Users\N.ChowdaryDoppalap\Scripts\Ephemeral Port Script.ps1"
    ITP_PORT_WARN      = 4000

    # Logging
    LOG_DIR            = "D:\Users\N.ChowdaryDoppalap\Logs\T360-IPM"
}

# -----------------------------------------------------------------------------
# INITIALISE
# -----------------------------------------------------------------------------
if (-not (Test-Path $Config.LOG_DIR)) {
    New-Item -ItemType Directory -Path $Config.LOG_DIR | Out-Null
}

$Script:LogFile   = Join-Path $Config.LOG_DIR "ipm-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
$Script:Results   = [ordered]@{}
$Script:Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$Script:Shift     = if ((Get-Date).Hour -lt 11) { "8am" } elseif ((Get-Date).Hour -lt 16) { "1pm" } else { "6pm" }
$Script:Tags      = @($Config.DD_TAG_CLUSTER, $Config.DD_TAG_ENV, $Config.DD_TAG_APP, "shift:$($Script:Shift)")
$Script:DDBase    = "https://api.$($Config.DD_SITE)"
$Script:Performer = $env:USERNAME

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $color = switch ($Level) {
        "OK"   { "Green"  }
        "WARN" { "Yellow" }
        "FAIL" { "Red"    }
        "HEAD" { "Cyan"   }
        default { "White" }
    }
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg"
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $Script:LogFile -Value $line
}

function Test-TcpPort {
    param([string]$Hostname, [int]$Port, [int]$TimeoutMs = 5000)
    try {
        $tcp   = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($Hostname, $Port, $null, $null)
        $wait  = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($wait -and $tcp.Connected) { $tcp.Close(); return $true }
        $tcp.Close(); return $false
    } catch { return $false }
}

function Send-DDEvent {
    param(
        [string]$Title,
        [string]$Text,
        [string]$AlertType = "info",
        [string[]]$ExtraTags = @()
    )
    $body = @{
        title      = $Title
        text       = $Text
        alert_type = $AlertType
        tags       = ($Script:Tags + $ExtraTags)
    } | ConvertTo-Json -Depth 4

    try {
        Invoke-RestMethod `
            -Uri "$Script:DDBase/api/v1/events" `
            -Method POST `
            -Headers @{ "DD-API-KEY" = $Config.DD_API_KEY; "Content-Type" = "application/json" } `
            -Body $body | Out-Null
        Write-Log "Datadog event posted: $Title" "INFO"
    } catch {
        Write-Log "Failed to post Datadog event: $_" "WARN"
    }
}

function Set-Result {
    param([int]$Item, [string]$Name, [bool]$OK, [string]$Detail = "", [string]$Value = "")
    $Script:Results[$Item] = @{ Name = $Name; OK = $OK; Detail = $Detail; Value = $Value }
    $level = if ($OK) { "OK" } else { "FAIL" }
    Write-Log "Item $Item — $Name : $level | $Detail" $level
}

# =============================================================================
# CHECKS
# =============================================================================

# -----------------------------------------------------------------------------
# Item 1 — Pod availability
# -----------------------------------------------------------------------------
function Check-Item1 {
    Write-Log "--- Item 1: Pod availability ---" "HEAD"
    try {
        $notRunning = kubectl get pods -A `
            --context $Config.AKS_CONTEXT `
            --field-selector="status.phase!=Running" `
            --no-headers 2>$null
        $count  = if ($notRunning) { ($notRunning | Measure-Object -Line).Lines } else { 0 }
        $ok     = ($count -eq 0)
        $detail = if ($ok) { "All pods running" } else { "$count pod(s) not running" }
        if (-not $ok) { Write-Log "Non-running pods:`n$($notRunning -join "`n")" "WARN" }
        Set-Result 1 "Pod availability" $ok $detail
    } catch {
        Set-Result 1 "Pod availability" $false "Error: $_"
    }
}

# -----------------------------------------------------------------------------
# Item 2 — FTP server availability
# -----------------------------------------------------------------------------
function Check-Item2 {
    Write-Log "--- Item 2: FTP server availability ---" "HEAD"
    $ok     = Test-TcpPort $Config.FTP_HOST $Config.FTP_PORT
    $detail = if ($ok) { "$($Config.FTP_HOST):$($Config.FTP_PORT) reachable" } `
                       else { "UNREACHABLE — Create INCIDENT ticket immediately" }
    Set-Result 2 "FTP server availability" $ok $detail
}

# -----------------------------------------------------------------------------
# Item 3 — SMTP server availability
# -----------------------------------------------------------------------------
function Check-Item3 {
    Write-Log "--- Item 3: SMTP server availability ---" "HEAD"
    $ok     = Test-TcpPort $Config.SMTP_HOST $Config.SMTP_PORT
    $detail = if ($ok) { "$($Config.SMTP_HOST):$($Config.SMTP_PORT) reachable" } `
                       else { "UNREACHABLE — Create INCIDENT ticket immediately" }
    Set-Result 3 "SMTP server availability" $ok $detail
}

# -----------------------------------------------------------------------------
# Item 7 — AKS node disk pressure
# -----------------------------------------------------------------------------
function Check-Item7 {
    Write-Log "--- Item 7: Disk space (AKS node disk pressure) ---" "HEAD"
    try {
        $nodes     = kubectl get nodes --context $Config.AKS_CONTEXT -o json 2>$null | ConvertFrom-Json
        $pressured = $nodes.items | Where-Object {
            ($_.status.conditions | Where-Object { $_.type -eq "DiskPressure" -and $_.status -eq "True" })
        }
        $count  = ($pressured | Measure-Object).Count
        $ok     = ($count -eq 0)
        $detail = if ($ok) { "No disk pressure on any node" } `
                           else { "$count node(s) under disk pressure: $($pressured.metadata.name -join ', ')" }
        Set-Result 7 "Disk space" $ok $detail
    } catch {
        Set-Result 7 "Disk space" $false "Error: $_"
    }
}

# -----------------------------------------------------------------------------
# Item 8 — AKS node CPU and memory
# -----------------------------------------------------------------------------
function Check-Item8 {
    Write-Log "--- Item 8: AKS node CPU/Memory ---" "HEAD"
    try {
        $topOutput = kubectl top nodes --context $Config.AKS_CONTEXT --no-headers 2>$null
        $allOk     = $true
        $details   = @()
        foreach ($line in $topOutput) {
            $parts  = $line -split '\s+'
            $node   = $parts[0]
            $cpu    = [int]($parts[2] -replace '%', '')
            $mem    = [int]($parts[4] -replace '%', '')
            $nodeOk = ($cpu -lt $Config.CPU_WARN_PCT -and $mem -lt $Config.MEM_WARN_PCT)
            if (-not $nodeOk) { $allOk = $false }
            $flag    = if (-not $nodeOk) { " WARN" } else { "" }
            $details += "$node CPU:${cpu}% MEM:${mem}%$flag"
            Write-Log "  $node — CPU: ${cpu}% | MEM: ${mem}%" $(if($nodeOk) { "OK" } else { "WARN" })
        }
        Set-Result 8 "AKS node CPU/Memory" $allOk ($details -join " | ")
    } catch {
        Set-Result 8 "AKS node CPU/Memory" $false "Error: $_"
    }
}

# -----------------------------------------------------------------------------
# Item 9 — VM (node) availability
# -----------------------------------------------------------------------------
function Check-Item9 {
    Write-Log "--- Item 9: VM availability ---" "HEAD"
    try {
        $nodes     = kubectl get nodes --context $Config.AKS_CONTEXT --no-headers 2>$null
        $total     = ($nodes | Measure-Object -Line).Lines
        $notReady  = $nodes | Where-Object { $_ -notmatch "\bReady\b" }
        $downCount = if ($notReady) { ($notReady | Measure-Object -Line).Lines } else { 0 }
        $ok        = ($downCount -eq 0)
        $detail    = if ($ok) { "All $total nodes Ready" } else { "$downCount/$total nodes NOT Ready" }
        Set-Result 9 "VM availability" $ok $detail
    } catch {
        Set-Result 9 "VM availability" $false "Error: $_"
    }
}

# -----------------------------------------------------------------------------
# Item 11 — Azure file share size
# -----------------------------------------------------------------------------
function Check-Item11 {
    Write-Log "--- Item 11: File share size ---" "HEAD"
    try {
        az account set --subscription $Config.AZURE_SUB 2>$null
        $bytes  = az storage share-rm show `
            --storage-account $Config.AZURE_STORAGE_ACCT `
            --resource-group $Config.AZURE_RG `
            --name $Config.AZURE_FILE_SHARE `
            --expand "stats" `
            --query "shareUsageBytes" `
            -o tsv 2>$null
        $usedGB = [math]::Round([double]$bytes / 1GB, 2)
        $usedTB = [math]::Round($usedGB / 1024, 2)
        $pct    = [math]::Round(($usedGB / $Config.FILESHARE_QUOTA_GB) * 100, 1)
        $ok     = ($pct -lt $Config.FILESHARE_WARN_PCT)
        $detail = "Used: ${usedTB} TB (${pct}% of $([math]::Round($Config.FILESHARE_QUOTA_GB/1024,0)) TB quota)"
        Set-Result 11 "File share size" $ok $detail "${usedTB} TB"
    } catch {
        Set-Result 11 "File share size" $false "Error: $_"
    }
}

# -----------------------------------------------------------------------------
# Item 12 — AKS node disk space (allocatable vs capacity)
# -----------------------------------------------------------------------------
function Check-Item12 {
    Write-Log "--- Item 12: AKS node disk space ---" "HEAD"
    try {
        $nodes   = kubectl get nodes --context $Config.AKS_CONTEXT -o json 2>$null | ConvertFrom-Json
        $allOk   = $true
        $details = @()
        foreach ($node in $nodes.items) {
            $name     = $node.metadata.name
            $capRaw   = $node.status.capacity."ephemeral-storage"
            $allocRaw = $node.status.allocatable."ephemeral-storage"
            $cap      = if ($capRaw   -match "Ki$") { [double]($capRaw   -replace 'Ki', '') * 1024 } else { [double]$capRaw }
            $alloc    = if ($allocRaw -match "Ki$") { [double]($allocRaw -replace 'Ki', '') * 1024 } else { [double]$allocRaw }
            $usedPct  = if ($cap -gt 0) { [math]::Round((($cap - $alloc) / $cap) * 100, 1) } else { 0 }
            $nodeOk   = ($usedPct -lt $Config.DISK_WARN_PCT)
            if (-not $nodeOk) { $allOk = $false }
            $flag     = if (-not $nodeOk) { " WARN" } else { "" }
            $details += "$name ${usedPct}%$flag"
            Write-Log "  $name — Disk used: ${usedPct}%" $(if($nodeOk) { "OK" } else { "WARN" })
        }
        Set-Result 12 "AKS node disk space" $allOk ($details -join " | ")
    } catch {
        Set-Result 12 "AKS node disk space" $false "Error: $_"
    }
}

# -----------------------------------------------------------------------------
# Item 13 — ITP ephemeral ports
# -----------------------------------------------------------------------------
function Check-Item13 {
    Write-Log "--- Item 13: ITP ephemeral ports ---" "HEAD"
    try {
        $output    = powershell -File $Config.ITP_SCRIPT 2>&1
        $availLine = $output | Where-Object { $_ -match "No. of Available port" }
        $boundLine = ($output | Where-Object { $_ -match "1\. bound" })[0]
        $available = [int]([regex]::Match($availLine, "(\d+)/\d+").Groups[1].Value)
        $bound     = [int]([regex]::Match($boundLine, "bound : (\d+)").Groups[1].Value)
        $ok        = ($available -gt $Config.ITP_PORT_WARN)
        $detail    = "Available: $available | Bound: $bound"
        if (-not $ok) { $detail += " — CRITICAL: Create Sev-3 INCIDENT, restart T360 Network Processing Service on zuse1p1t360itp1" }
        Set-Result 13 "ITP ephemeral ports" $ok $detail "$available available / $bound bound"
    } catch {
        Set-Result 13 "ITP ephemeral ports" $false "Error running ITP script: $_"
    }
}

# =============================================================================
# SUMMARY REPORT — post to Datadog
# =============================================================================
function Send-Summary {
    $passed    = ($Script:Results.Values | Where-Object { $_.OK }).Count
    $failed    = ($Script:Results.Values | Where-Object { -not $_.OK }).Count
    $total     = $Script:Results.Count
    $allOk     = ($failed -eq 0)
    $alertType = if ($allOk) { "success" } else { "error" }

    $title = if ($allOk) {
        "T360 IPM [$Script:Shift CST] All $total checks PASSED"
    } else {
        "T360 IPM [$Script:Shift CST] $failed of $total checks FAILED"
    }

    # Build report text (Datadog markdown)
    $lines = @(
        "%%%"
        "**Cluster:** zuse1-d003-b066-aks-p1-t360-b"
        "**Shift:** $Script:Shift CST  |  **Time:** $Script:Timestamp  |  **By:** $Script:Performer"
        ""
        "| Item | Check | Status | Detail |"
        "|------|-------|--------|--------|"
    )
    foreach ($key in $Script:Results.Keys) {
        $r      = $Script:Results[$key]
        $status = if ($r.OK) { "OK" } else { "FAIL" }
        $lines += "| $key | $($r.Name) | $status | $($r.Detail) |"
    }
    $lines += ""
    $lines += "**Result: $passed/$total checks passed**"
    $lines += "%%%"

    # Post summary event
    Send-DDEvent $title ($lines -join "`n") $alertType @("report:summary")

    # Post individual failure events so they show up separately
    foreach ($key in $Script:Results.Keys) {
        $r = $Script:Results[$key]
        if (-not $r.OK) {
            Send-DDEvent `
                "T360 IPM Item $key FAILED: $($r.Name)" `
                "$($r.Detail)`n`nShift: $Script:Shift CST | Time: $Script:Timestamp" `
                "error" `
                @("item:$key")
        }
    }

    # Console summary
    Write-Log "" "INFO"
    Write-Log "============================================" "HEAD"
    Write-Log "RESULT  : $passed/$total checks passed" $(if($allOk) { "OK" } else { "FAIL" })
    Write-Log "Shift   : $Script:Shift CST | $Script:Timestamp" "HEAD"
    Write-Log "Log     : $Script:LogFile" "HEAD"
    Write-Log "Datadog : https://app.us3.datadoghq.com/event/explorer" "HEAD"
    Write-Log "============================================" "HEAD"
}

# =============================================================================
# MAIN
# =============================================================================
Write-Log "============================================" "HEAD"
Write-Log "T360 IPM Monitor — Shift: $Script:Shift CST" "HEAD"
Write-Log "Time: $Script:Timestamp | User: $Script:Performer" "HEAD"
Write-Log "============================================" "HEAD"

Check-Item1
Check-Item2
Check-Item3
Check-Item7
Check-Item8
Check-Item9
Check-Item11
Check-Item12
Check-Item13

Send-Summary
