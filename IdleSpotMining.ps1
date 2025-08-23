# =========================
# IdleSpotMining.ps1 (NHQM HTTP API control, one-shot)
# - Checks price once, calls miner.start/stop via NHQM HTTP API, then exits.
# - .env support (NHQM_DIR / NHQM_CONF) + nhqm.conf auto-discovery.
# =========================

$ErrorActionPreference = 'Stop'

# --- SETTINGS ---
$ThresholdCents = 6.0                      # cutoff in c/kWh
$JustNowUrl     = "https://api.spot-hinta.fi/JustNow"

# --- LOGGING ---
$LogDir     = "C:\Scripts"
$LogFile    = Join-Path $LogDir "miner-switch.log"
$Transcript = Join-Path $LogDir "miner-switch.transcript.txt"

# --- LOG ROTATION ---
$MaxLogBytes = 1MB
$MaxLogFiles = 3

# --- ENSURE DIRS ---
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Rotate-Log {
    param([Parameter(Mandatory=$true)][string]$Path,[int64]$MaxBytes=$MaxLogBytes,[int]$Keep=$MaxLogFiles)
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

function Is-Admin {
    try {
        $pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# --- Simple .env loader (process-scoped env vars) ---
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

# Load .env from script directory (optional)
try { Load-DotEnv (Join-Path $PSScriptRoot ".env") } catch {}

# --- NHQM config path resolution ---
# You can override via env:
#   NHQM_CONF = full path to nhqm.conf
#   or NHQM_DIR = folder containing nhqm.conf
$NHQMConfigPath = $Env:NHQM_CONF
if (-not $NHQMConfigPath -or -not (Test-Path -LiteralPath $NHQMConfigPath)) {
    $nhqmDir = $Env:NHQM_DIR
    if ($nhqmDir -and (Test-Path -LiteralPath $nhqmDir)) {
        $candidate = Join-Path $nhqmDir 'nhqm.conf'
        if (Test-Path -LiteralPath $candidate) { $NHQMConfigPath = $candidate }
    }
}

# Fallback: try common install paths
if (-not $NHQMConfigPath -or -not (Test-Path -LiteralPath $NHQMConfigPath)) {
    $candidates = @(
        "C:\NiceHash\NiceHash QuickMiner\nhqm.conf",
        "$Env:ProgramFiles\NiceHash QuickMiner\nhqm.conf",
        "$Env:ProgramData\NiceHash\NiceHash QuickMiner\nhqm.conf",
        "$Env:LOCALAPPDATA\Programs\NiceHash QuickMiner\nhqm.conf",
        "$Env:ProgramFiles\NiceHash\NiceHash QuickMiner\nhqm.conf"
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

# --- PRICE ---
function Get-PriceNowCents {
    try {
        $r = Invoke-RestMethod -UseBasicParsing -Uri $JustNowUrl -TimeoutSec 12
        if ($null -eq $r) { return $null }
        $val = if ($r.PriceWithTax -ne $null) { $r.PriceWithTax } elseif ($r.Price -ne $null) { $r.Price } else { $null }
        if ($val -eq $null) { return $null }
        [double]$val * 100.0
    } catch { Log "API error: $($_.Exception.Message)"; $null }
}

# --- NHQM HTTP API HELPERS ---
$NHQM = [ordered]@{ HostCandidates=@(); Port=$null; Token=$null }
try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}

function Load-NHQMConfig {
    try {
        if (-not $NHQMConfigPath -or -not (Test-Path -LiteralPath $NHQMConfigPath)) {
            Log "nhqm.conf not found (NHQMConfigPath is empty or missing)."
            return $false
        }
        $j = Get-Content -LiteralPath $NHQMConfigPath -Raw | ConvertFrom-Json

        # Use a non-reserved variable name (avoid $host)
        $apiHost   = if ($j.watchDogAPIHost) { [string]$j.watchDogAPIHost } else { "localhost" }
        $NHQM.Port = if ($j.watchDogAPIPort) { [int]$j.watchDogAPIPort } else { 18000 }
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

    if (-not $NHQM.Token -or -not $NHQM.Port -or -not $NHQM.HostCandidates -or $NHQM.HostCandidates.Count -eq 0) {
        if (-not (Load-NHQMConfig)) { return $null }
    }

    # URL-encode JSON (ilman turhia kenoviivoja)
    $encoded = $Json
    try {
        if ([type]::GetType("System.Web.HttpUtility")) {
            $encoded = [System.Web.HttpUtility]::UrlEncode($Json)
        } else {
            $encoded = [uri]::EscapeDataString($Json)
        }
    } catch {}

    foreach ($h in $NHQM.HostCandidates) {
        $url = 'http://{0}:{1}/api?command={2}' -f $h, $NHQM.Port, $encoded
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Headers @{ Authorization = $NHQM.Token } -Uri $url -TimeoutSec $TimeoutSec
            if ($resp.StatusCode -ne 200) {
                Log ("NHQM-Call warning: HTTP {0} from {1}" -f $resp.StatusCode, $url)
            }
            return $resp
        } catch {
            # kokeile seuraavaa hostia
            continue
        }
    }

    Log "NHQM-Call error: Unable to connect (hosts tried: $($NHQM.HostCandidates -join ', '):$($NHQM.Port))"
    return $null
}

function Is-MiningActive {
    $r = NHQM-Call '{"id":1,"method":"worker.list","params":[]}' 3
    if ($r -and $r.Content) {
        try {
            $o = $r.Content | ConvertFrom-Json
            if ($o.result -and $o.result.workers) {
                foreach ($w in $o.result.workers) {
                    if ($w.paused -ne $true -and $w.status -ne "paused") { return $true }
                }
                return $false
            }
        } catch {}
    }
    $r2 = NHQM-Call '{"id":2,"method":"algorithm.list","params":[]}' 3
    if ($r2 -and $r2.Content) {
        try {
            $o2 = $r2.Content | ConvertFrom-Json
            if ($o2.result -and $o2.result.algorithms) {
                foreach ($a in $o2.result.algorithms) {
                    if (($a.status -ne "stopped" -and $a.status -ne "paused") -or ($a.speed -and $a.speed -gt 0)) {
                        return $true
                    }
                }
                return $false
            }
        } catch {}
    }
    $false
}

function Stop-Mining {
    $r = NHQM-Call '{"id":10,"method":"miner.stop","params":[]}'
    if ($r -and $r.Content) {
        try {
            $o = $r.Content | ConvertFrom-Json
            if ($o.result -ne $null -and "$($o.result)" -match 'ok|true') {
                Log "NHQM miner.stop acknowledged."
            } else {
                Log "NHQM miner.stop response: $($r.Content)"
            }
        } catch {
            Log "NHQM miner.stop parse error: $($_.Exception.Message)"
        }
    } else {
        Log "miner.stop failed (no response)"
        return $false
    }
    Start-Sleep -Seconds 2
    -not (Is-MiningActive)
}

function Start-Mining {
    $r = NHQM-Call '{"id":11,"method":"miner.start","params":[]}'
    if ($r -and $r.Content) {
        try {
            $o = $r.Content | ConvertFrom-Json
            if ($o.result -ne $null -and "$($o.result)" -match 'ok|true') {
                Log "NHQM miner.start acknowledged."
            } else {
                Log "NHQM miner.start response: $($r.Content)"
            }
        } catch {
            Log "NHQM miner.start parse error: $($_.Exception.Message)"
        }
    } else {
        Log "miner.start failed (no response)"
        return $false
    }

    for ($i=0; $i -lt 10; $i++) { Start-Sleep -Seconds 2; if (Is-MiningActive) { return $true } }
    return (Is-MiningActive)
}

# --- MAIN (one-shot) ---
Log "=== IdleSpotMining (one-shot) ==="
try { $who=[Security.Principal.WindowsIdentity]::GetCurrent().Name; Log "Running as: $who | Admin=$((Is-Admin))" } catch {}

if (-not (Load-NHQMConfig)) {
    Log "WARNING: Could not load NHQM config. Set NHQM_CONF or NHQM_DIR in .env or install in a default path."
    exit 1
}

$priceC = Get-PriceNowCents
if ($priceC -eq $null) {
    Log "Price=N/A -> STOP (fail-closed)"
    $ok = Stop-Mining
    Log ("Stop -> {0}" -f $ok)
    exit (if($ok){0}else{2})
}

$action = if ($priceC -gt $ThresholdCents) { "STOP" } else { "START" }
Log ("Now={0:N2} c/kWh (thr {1:N2}) -> {2}" -f $priceC,$ThresholdCents,$action)

if ($action -eq "STOP") {
    $ok = Stop-Mining
    Log ("Stop -> {0}" -f $ok)
    exit (if($ok){0}else{3})
} else {
    if (-not (Is-MiningActive)) {
        $ok = Start-Mining
        Log ("Start -> {0}" -f $ok)
        exit (if($ok){0}else{4})
    } else {
        Log "Already running."
        exit 0
    }
}
