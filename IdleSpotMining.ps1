# =========================
# IdleSpotMining.ps1 (NHQM HTTP API control, one-shot)
# - Checks electricity price once, calls miner.stop / restart via NHQM HTTP API, then exits.
# - .env support (NHQM_DIR / NHQM_CONF) + nhqm.conf auto-discovery.
# - Robust restart handling (socket may close mid-flight), IPv6/IPv4 host fallbacks.
# - Debug logging for worker.list / algorithm.list responses when parsing is unclear.
# =========================

# --- LOAD .ENV (optional) ---
$dotenvPath = Join-Path $PSScriptRoot ".env"
if (Test-Path $dotenvPath) {
  Get-Content $dotenvPath | ForEach-Object {
    if ($_ -match '^\s*#') { return }      # comment lines
    if ($_ -match '^\s*$') { return }      # blank lines
    $idx = $_.IndexOf('=')
    if ($idx -gt 0) {
      $k = $_.Substring(0, $idx).Trim()
      $v = $_.Substring($idx + 1).Trim()
      if ($k) { [Environment]::SetEnvironmentVariable($k, $v, 'Process') }
    }
  }
}

$ErrorActionPreference = 'Stop'

# --- SETTINGS ---
# Allow overriding via .env: THRESHOLD_CENTS and JUSTNOW_URL
# THRESHOLD_CENTS must be numeric (dot as decimal separator).
$ThresholdCents = 6.0  # default cutoff in c/kWh
if ($env:THRESHOLD_CENTS) {
  $parsed = 0.0
  if ([double]::TryParse($env:THRESHOLD_CENTS, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
    $ThresholdCents = $parsed
  } else {
    Write-Warning "Invalid THRESHOLD_CENTS in .env: '$($env:THRESHOLD_CENTS)'. Using default $ThresholdCents."
  }
}

$JustNowUrl = if ($env:JUSTNOW_URL) { $env:JUSTNOW_URL } else { "https://api.spot-hinta.fi/JustNow" }

# --- LOGGING ---
# Prefer LOGFILE from .env; otherwise use default. Derive log directory from path.
$LogFile = if ($env:LOGFILE) { $env:LOGFILE } else { ".\miner-switch.log" }
$LogDir  = Split-Path -Path $LogFile -Parent
if (-not $LogDir) { $LogDir = "." }

# Allow TRANSCRIPT to be overridden via .env; otherwise default in the same folder
$Transcript = if ($env:TRANSCRIPT) { $env:TRANSCRIPT } else { Join-Path $LogDir "miner-switch.transcript.txt" }

# Ensure the log directory exists
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# --- LOG ROTATION ---
$MaxLogBytes = 1MB
$MaxLogFiles = 3

# --- ENSURE DIRECTORIES ---
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Rotate-Log {
    param([string]$Path,[int64]$MaxBytes=$MaxLogBytes,[int]$Keep=$MaxLogFiles)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -lt $MaxBytes) { return }
        for ($i = $Keep-1; $i -ge 1; $i--) {
            $src = "$Path.$i"; $dst = "$Path." + ($i+1)
            if (Test-Path -LiteralPath $src) {
                Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
                Rename-Item -LiteralPath $src -NewName (Split-Path -Leaf $dst) -Force
            }
        }
        $first = "$Path.1"
        Remove-Item -LiteralPath $first -Force -ErrorAction SilentlyContinue
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $first) -Force
        New-Item -ItemType File -Path $Path -Force | Out-Null
    } catch { Write-Host "LOG ROTATE ERROR: $($_.Exception.Message)" }
}

try { Rotate-Log -Path $Transcript; Start-Transcript -Path $Transcript -Append -ErrorAction SilentlyContinue | Out-Null } catch {}

function Log($m) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$ts | $m"
    Write-Host $line
    try { Rotate-Log -Path $LogFile; Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

# --- ADMIN CHECK (diagnostic only) ---
function Is-Admin {
    try {
        $pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# --- Simple .env loader (process-scope) ---
function Load-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Get-Content -LiteralPath $Path | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^\s*$' -or $line -match '^\s*#') { return }
            $kv = $line -split '=', 2
            if ($kv.Count -eq 2) {
                $k = $kv[0].Trim()
                $v = $kv[1].Trim().Trim('"')
                if ($k) { [Environment]::SetEnvironmentVariable($k, $v, 'Process') }
            }
        }
        Log "Loaded .env from $Path"
    } catch {
        Log "Failed to load .env: $($_.Exception.Message)"
    }
}

# Load .env from script directory
try { Load-DotEnv (Join-Path $PSScriptRoot ".env") } catch {}

# --- NHQM config path resolution ---
$NHQMConfigPath = $Env:NHQM_CONF
if (-not $NHQMConfigPath -or -not (Test-Path -LiteralPath $NHQMConfigPath)) {
    $nhqmDir = $Env:NHQM_DIR
    if ($nhqmDir -and (Test-Path -LiteralPath $nhqmDir)) {
        $candidate = Join-Path $nhqmDir 'nhqm.conf'
        if (Test-Path -LiteralPath $candidate) { $NHQMConfigPath = $candidate }
    }
}
if (-not $NHQMConfigPath -or -not (Test-Path -LiteralPath $NHQMConfigPath)) {
    $candidates = @(
        "C:\NiceHash\NiceHash QuickMiner\nhqm.conf",
        "$Env:ProgramFiles\NiceHash QuickMiner\nhqm.conf",
        "$Env:ProgramData\NiceHash\NiceHash QuickMiner\nhqm.conf",
        "$Env:LOCALAPPDATA\Programs\NiceHash QuickMiner\nhqm.conf"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $NHQMConfigPath = $c; break }
    }
}

if ($NHQMConfigPath) {
    Log "Using nhqm.conf: $NHQMConfigPath"
} else {
    Log "WARNING: nhqm.conf not found via env or default locations."
}

# --- PRICE FETCH ---
function Get-PriceNowCents {
    try {
        $r = Invoke-RestMethod -UseBasicParsing -Uri $JustNowUrl -TimeoutSec 12
        if ($null -eq $r) { return $null }
        $val = if ($r.PriceWithTax -ne $null) { $r.PriceWithTax } elseif ($r.Price -ne $null) { $r.Price } else { $null }
        if ($val -eq $null) { return $null }
        [double]$val * 100.0
    } catch { Log "API error: $($_.Exception.Message)"; $null }
}

# --- NHQM HTTP API ---
$NHQM = [ordered]@{ HostCandidates=@(); Port=$null; Token=$null }
try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}

function Load-NHQMConfig {
    try {
        if (-not $NHQMConfigPath -or -not (Test-Path -LiteralPath $NHQMConfigPath)) {
            Log "nhqm.conf not found."
            return $false
        }
        $j = Get-Content -LiteralPath $NHQMConfigPath -Raw | ConvertFrom-Json
        $apiHost    = if ($j.watchDogAPIHost) { [string]$j.watchDogAPIHost } else { "localhost" }
        $NHQM.Port  = if ($j.watchDogAPIPort) { [int]$j.watchDogAPIPort } else { 18000 }
        $NHQM.Token = $j.watchDogAPIAuth

        $c = @()
        if ($apiHost -eq "localhost") { $c += "[::1]"; $c += "127.0.0.1" } else { $c += $apiHost }
        $NHQM.HostCandidates = $c

        if ([string]::IsNullOrWhiteSpace($NHQM.Token)) {
            Log "watchDogAPIAuth missing in nhqm.conf"
            return $false
        }
        Log "NHQM config loaded (hosts=$($NHQM.HostCandidates -join ', '), port=$($NHQM.Port))"
        return $true
    } catch {
        Log "Load-NHQMConfig error: $($_.Exception.Message)"
        return $false
    }
}

function NHQM-Call {
    param([string]$Json,[int]$TimeoutSec=5)
    if (-not $NHQM.Token -or -not $NHQM.Port -or -not $NHQM.HostCandidates) {
        if (-not (Load-NHQMConfig)) { return $null }
    }
    $encoded = try {
        if ([type]::GetType("System.Web.HttpUtility")) {
            [System.Web.HttpUtility]::UrlEncode($Json)
        } else {
            [uri]::EscapeDataString($Json)
        }
    } catch { $Json }

    foreach ($h in $NHQM.HostCandidates) {
        $url = 'http://{0}:{1}/api?command={2}' -f $h, $NHQM.Port, $encoded
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Headers @{ Authorization = $NHQM.Token } -Uri $url -TimeoutSec $TimeoutSec
            return $resp
        } catch {
            # if restart closes the socket, try next host or continue
            continue
        }
    }
    Log "NHQM-Call error: Unable to connect (hosts tried: $($NHQM.HostCandidates -join ', '):$($NHQM.Port))"
    return $null
}

# --- DEBUG: dump helpers ---
function Debug-Dump($label, $raw) {
    try {
        if ($raw) { Log ("DEBUG {0}: {1}" -f $label, $raw) }
    } catch { }
}

# --- ACTIVE MINING DETECTION ---
function Is-MiningActive {
    # worker.list first
    $r = NHQM-Call '{"id":100,"method":"worker.list","params":[]}' 4
    if ($r -and $r.Content) {
        try {
            $o = $r.Content | ConvertFrom-Json
            if ($o.result -and $o.result.workers) {
                foreach ($w in $o.result.workers) {
                    $status = "$($w.status)"
                    $paused = $false
                    if ($null -ne $w.paused) { $paused = [bool]$w.paused }
                    elseif ($status) { $paused = ($status -match 'paused|stopped') }

                    $speed = $null
                    if ($null -ne $w.speed)     { $speed = [double]$w.speed }
                    elseif ($null -ne $w.hashrate){ $speed = [double]$w.hashrate }

                    if (-not $paused -and ($speed -eq $null -or $speed -gt 0)) { return $true }
                }
                return $false
            } else {
                Debug-Dump "worker.list raw" $r.Content
            }
        } catch {
            Log "DEBUG worker.list parse error: $($_.Exception.Message)"
            Debug-Dump "worker.list raw" $r.Content
        }
    }

    # algorithm.list fallback
    $r2 = NHQM-Call '{"id":101,"method":"algorithm.list","params":[]}' 4
    if ($r2 -and $r2.Content) {
        try {
            $o2 = $r2.Content | ConvertFrom-Json
            if ($o2.result -and $o2.result.algorithms) {
                foreach ($a in $o2.result.algorithms) {
                    $astatus = "$($a.status)"
                    $aspeed  = $null
                    if ($null -ne $a.speed)       { $aspeed = [double]$a.speed }
                    elseif ($null -ne $a.hashrate) { $aspeed = [double]$a.hashrate }

                    if ($astatus -notmatch 'paused|stopped' -or ($aspeed -and $aspeed -gt 0)) {
                        return $true
                    }

                    if ($a.workers) {
                        foreach ($w in $a.workers) {
                            $wstatus = "$($w.status)"
                            $wpaused = $false
                            if ($null -ne $w.paused) { $wpaused = [bool]$w.paused }
                            elseif ($wstatus) { $wpaused = ($wstatus -match 'paused|stopped') }

                            $wspeed = $null
                            if ($null -ne $w.speed)       { $wspeed = [double]$w.speed }
                            elseif ($null -ne $w.hashrate) { $wspeed = [double]$w.hashrate }

                            if (-not $wpaused -and ($wspeed -eq $null -or $wspeed -gt 0)) { return $true }
                        }
                    }
                }
                return $false
            } else {
                Debug-Dump "algorithm.list raw" $r2.Content
            }
        } catch {
            Log "DEBUG algorithm.list parse error: $($_.Exception.Message)"
            Debug-Dump "algorithm.list raw" $r2.Content
        }
    }

    # last resort: process + external TLS connection (nhmp over 443)
    try {
        $proc = Get-Process -Name excavator -ErrorAction SilentlyContinue
        if ($proc) {
            $conns = Get-NetTCPConnection -OwningProcess $proc.Id -State Established -ErrorAction SilentlyContinue |
                     Where-Object { $_.RemotePort -eq 443 -and $_.RemoteAddress -notmatch '^(127\.0\.0\.1|::1)$' }
            if ($conns) { return $true }
        }
    } catch {}

    return $false
}

# --- STOP / RESTART ---
function Stop-Mining {
    $r = NHQM-Call '{"id":10,"method":"miner.stop","params":[]}' 8
    if ($r -and $r.Content) {
        try {
            $o = $r.Content | ConvertFrom-Json
            if (($o.result -and "$($o.result)" -match 'ok|true') -or ($null -eq $o.error)) {
                Log "NHQM miner.stop acknowledged."
            } else {
                Log "NHQM miner.stop response: $($r.Content)"
            }
        } catch {
            Log "NHQM miner.stop parse error: $($_.Exception.Message)"
            Debug-Dump "miner.stop raw" $r.Content
        }
    } else {
        Log "miner.stop failed (no response)"
        return $false
    }
    Start-Sleep -Seconds 2
    return -not (Is-MiningActive)
}

function Start-Mining {
    # Helper: wait until API responds again after restart
    function Wait-ApiUp([int]$timeoutSec = 90) {
        $probe = '{"id":99,"method":"algorithm.list","params":[]}'
        $t0 = Get-Date
        while ((Get-Date) - $t0 -lt [TimeSpan]::FromSeconds($timeoutSec)) {
            $r = NHQM-Call $probe 4
            if ($r -and $r.Content) { return $true }
            Start-Sleep -Seconds 2
        }
        return $false
    }

    # Send restart; treat socket-close during restart as acceptable
    $accepted = $false
    try {
        $r = NHQM-Call '{"id":2,"method":"quit","params":[]}' 8
        if ($r -and $r.Content) {
            try {
                $o = $r.Content | ConvertFrom-Json
                if (($o.result -and "$($o.result)" -match 'ok|true') -or ($null -eq $o.error)) {
                    Log "NHQM restart acknowledged."
                    $accepted = $true
                } else {
                    Log "NHQM restart response: $($r.Content)"
                    $accepted = $true   # even non-ok often means restart is in-flight
                }
            } catch {
                Log "NHQM restart parse error: $($_.Exception.Message)"
                Debug-Dump "restart raw" $r.Content
                $accepted = $true
            }
        } else {
            # If no response, it may still be restarting; continue optimistically
            Log "restart returned no content; assuming in-flight restart."
            $accepted = $true
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'connection was closed|forcibly closed|closed unexpectedly') {
            Log "restart likely accepted; connection closed during restart"
            $accepted = $true
        } else {
            Log "restart error: $msg"
            $accepted = $false
        }
    }

    if (-not $accepted) { return $false }

    # Give Excavator/QuickMiner time to cycle down/up
    Start-Sleep -Seconds 3
    if (-not (Wait-ApiUp 90)) {
        Log "API did not come back within timeout after restart."
        return $false
    }

    # Confirm mining becomes active
    $totalWait = 90
    $step = 3
    $elapsed = 0
    while ($elapsed -lt $totalWait) {
        if (Is-MiningActive) { return $true }
        Start-Sleep -Seconds $step
        $elapsed += $step
    }
    return (Is-MiningActive)
}

# --- MAIN (one-shot) ---
Log "=== IdleSpotMining (one-shot) ==="
try { $who=[Security.Principal.WindowsIdentity]::GetCurrent().Name; Log "Running as: $who | Admin=$((Is-Admin))" } catch {}

if (-not (Load-NHQMConfig)) {
    Log "Could not load NHQM config. Set NHQM_CONF or NHQM_DIR in .env or install in a default path."
    exit 1
}

$priceC = Get-PriceNowCents
if ($priceC -eq $null) {
    Log "Price=N/A -> STOP (fail-closed)"
    $ok = Stop-Mining
    Log ("Stop -> {0}" -f $ok)
    if ($ok) { exit 0 } else { exit 2 }
}

$action = if ($priceC -gt $ThresholdCents) { "STOP" } else { "START" }
Log ("Now={0:N2} c/kWh (thr {1:N2}) -> {2}" -f $priceC,$ThresholdCents,$action)

if ($action -eq "STOP") {
    $ok = Stop-Mining
    Log ("Stop -> {0}" -f $ok)
    if ($ok) { exit 0 } else { exit 3 }
} else {
    if (-not (Is-MiningActive)) {
        $ok = Start-Mining
        Log ("Start -> {0}" -f $ok)
        if ($ok) { exit 0 } else { exit 4 }
    } else {
        Log "Already running."
        exit 0
    }
}
