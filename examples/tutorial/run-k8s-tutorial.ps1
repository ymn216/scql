<#
.SYNOPSIS
  One-shot K8s launcher for SCQL tutorial: mysql + alice engine + bob engine,
  then runs opencore-demo end-to-end. Idempotent, safe to run repeatedly.

.DESCRIPTION
  K8s equivalent of docker-compose.yml.template (TLS-disabled minimal version):
    1. Get pod IPs of mysql / alice / bob
    2. In mysql pod, docker-entrypoint bootstraps mysqld only (no user sql in initdb.d).
       Then alice_init.sql and bob_init.sql are applied via mysql client redirects (reliable vs TCP-ready-before-init race).
    3. Render gflags.conf with mysql IP, kubectl cp into both engine pods,
       nohup-launch scqlengine
    4. Cross-compile opencore-demo to linux/amd64 on the host
  5. Render example_config.k8s.json from example_config.k8s.json.tmpl,
       replace pod IPs, UTF-8 cp into alice pod /tmp/example_config.json
  6. kubectl cp opencore-demo only when the linux binary changed or AlicePod changed
       (see .opencore-demo.k8s.pushstate under scql root), then exec opencore-demo

  Change SQL in example_config.k8s.json.tmpl then re-run this script.
  Hand-editing example_config.k8s.json alone is overwritten every run by step 5.

  Windows note: kubectl cp mistakes absolute paths like D:\foo (drive colon) for remote
  specs; this script uses cwd-relative paths for all kubectl cp sources.

.PARAMETER Namespace
  K8s namespace, default yumengni.

.PARAMETER MysqlPod / AlicePod / BobPod
  Full pod names (with hash suffix; changes on pod recreation).

.PARAMETER MysqlPwd
  mysql root password, default 040216.

.PARAMETER Rebuild
  Force rebuild opencore-demo even if binary exists.

.PARAMETER ForcePushDemo
  Always kubectl cp opencore-demo into the alice pod (e.g. /tmp was wiped). Config JSON is still pushed every run.

.PARAMETER RestartMysql
  Always shutdown every mysqld, wipe datadir, re-init from sql copies — even if port 3306 is closed (fixes stuck InnoDB ibdata1 locks).
.PARAMETER RestartEngines
  Force restart alice/bob scqlengine.

.PARAMETER SkipDemo
  Only prepare environment, do not run demo.

.PARAMETER MonitorNetwork
  On alice and bob pods, sample eth0 (etc.) traffic while opencore-demo runs; pull JSON to tutorial dir and plot PNG on host.

.PARAMETER MonitorInterface
  NIC inside engine pods, default eth0 (all pod egress/ingress on that NIC).

.PARAMETER MonitorInterval
  Sample interval in seconds for run_pod_monitor.py, default 0.5.

.PARAMETER MonitorOutput
  Host path for alice monitor JSON (default: tutorial/monitor_alice.json).

.PARAMETER MonitorBobOutput
  Host path for bob monitor JSON (default: tutorial/monitor_bob.json).

.PARAMETER SkipMonitorGraph
  With -MonitorNetwork, only save JSON; do not run plot_monitor.py on the host.

.EXAMPLE
  .\run-k8s-tutorial.ps1
  .\run-k8s-tutorial.ps1 -RestartEngines
  .\run-k8s-tutorial.ps1 -Rebuild
  .\run-k8s-tutorial.ps1 -ForcePushDemo
  .\run-k8s-tutorial.ps1 -AlicePod yumengni-scql-a-NEW-HASH
  .\run-k8s-tutorial.ps1 -SkipDemo
  .\run-k8s-tutorial.ps1 -MonitorNetwork
#>
[CmdletBinding()]
param(
    [string]$Namespace      = "yumengni",
    [string]$MysqlPod       = "yumengni-mysql-yumengni-msql-7bf48bc47b-4pf45",
    [string]$AlicePod       = "yumengni-scql-a-yumengni-scql-a-5889dfc55c-pj594",
    [string]$BobPod         = "yumengni-scql-b-yumengni-scql-b-5886f85857-fbhrd",
    [string]$MysqlPwd       = "040216",
    [switch]$Rebuild,
    [switch]$ForcePushDemo,
    [switch]$RestartMysql,
    [switch]$RestartEngines,
    [switch]$SkipDemo,
    [switch]$MonitorNetwork,
    [string]$MonitorInterface = "eth0",
    [double]$MonitorInterval = 0.5,
    [string]$MonitorOutput = "",
    [string]$MonitorBobOutput = "",
    [switch]$SkipMonitorGraph
)

$ErrorActionPreference = "Stop"

# ---------- paths ----------
$Script:TutorialDir = $PSScriptRoot
$Script:ScqlRoot    = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Script:DemoBin     = Join-Path $ScqlRoot "opencore-demo"
$Script:DemoBinPushState = Join-Path $ScqlRoot ".opencore-demo.k8s.pushstate"

$AliceConfTmpl = Join-Path $TutorialDir "engine\alice\conf\gflags.conf.k8s.tmpl"
$BobConfTmpl   = Join-Path $TutorialDir "engine\bob\conf\gflags.conf.k8s.tmpl"
$AliceConfOut  = Join-Path $TutorialDir "engine\alice\conf\gflags.conf"
$BobConfOut    = Join-Path $TutorialDir "engine\bob\conf\gflags.conf"
$CfgTmpl       = Join-Path $TutorialDir "example_config.k8s.json.tmpl"
$CfgOut        = Join-Path $TutorialDir "example_config.k8s.json"
function Resolve-MonitorHostPath([string]$path, [string]$defaultFileName) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return (Join-Path $TutorialDir $defaultFileName)
    }
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        return (Join-Path $TutorialDir $path)
    }
    return $path
}
$MonitorAliceOutput = Resolve-MonitorHostPath $MonitorOutput "monitor_alice.json"
$MonitorBobOutput   = Resolve-MonitorHostPath $MonitorBobOutput "monitor_bob.json"
$MonitorAliceStamp  = [System.IO.Path]::ChangeExtension($MonitorAliceOutput, ".stamp.txt")
$MonitorBobStamp    = [System.IO.Path]::ChangeExtension($MonitorBobOutput, ".stamp.txt")
$MonitorAlicePng    = [System.IO.Path]::ChangeExtension($MonitorAliceOutput, ".png")
$MonitorBobPng      = [System.IO.Path]::ChangeExtension($MonitorBobOutput, ".png")
$MonitorPy          = Join-Path $ScqlRoot "examples\system_monitor.py"
$MonitorRunnerPy    = Join-Path $ScqlRoot "examples\run_pod_monitor.py"
$MonitorPlotPy      = Join-Path $ScqlRoot "examples\plot_monitor.py"

# ---------- helpers ----------
function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "    [X]  $msg" -ForegroundColor Red; exit 1 }

function Get-PodIp($pod) {
    $ip = & kubectl -n $Namespace get pod $pod -o jsonpath='{.status.podIP}' 2>$null
    if ([string]::IsNullOrEmpty($ip)) { Die "Cannot get IP for pod [$pod], check name/namespace" }
    return $ip
}

function Pod-Exec($pod, [string]$cmd) {
    # kubectl exec propagates remote bash exit code; probes like mysqladmin ping return 1 until mysqld is up.
    # With $ErrorActionPreference = 'Stop', that surfaces as NativeCommandError and aborts the script.
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        return (& kubectl -n $Namespace exec $pod -- bash -lc "$cmd" 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $prevEa
    }
}

# Run a multi-line bash script via stdin (bash -s). Avoids Windows/PowerShell mangling of & / nohup in bash -lc "..." .
function Pod-BashStdin([string]$pod, [string]$script) {
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        return ($script | & kubectl -n $Namespace exec -i $pod -- bash -s 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $prevEa
    }
}

function Escape-BashSingleQuoted([string]$s) {
    if ($null -eq $s) { return "" }
    return $s.Replace("'", "'\''")
}

function Pod-TcpOpen($pod, $port) {
    $out = Pod-Exec $pod "(echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null && echo OPEN || echo CLOSED"
    return ($out -match "OPEN")
}

function Count-SqlInsertLines([string]$sqlPath) {
    $text = [System.IO.File]::ReadAllText($sqlPath)
    return ([regex]::Matches($text, '(?m)^\s*INSERT\s+INTO')).Count
}

# First CREATE TABLE after USE `schema`; (tutorial may use user_credit/user_stats or TPC-H-style lineitem/part).
function Get-InitTableNameAfterUse([string]$sqlPath, [string]$schema) {
    if (-not (Test-Path $sqlPath)) {
        if ($schema -eq 'alice') { return 'user_credit' }
        return 'user_stats'
    }
    $lines = [System.IO.File]::ReadAllLines($sqlPath)
    $inSchema = $false
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -match '^\s*USE\s+`([^`]+)`\s*;') {
            $inSchema = ($Matches[1] -eq $schema)
            continue
        }
        if ($inSchema -and ($t -match '^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`([^`]+)`')) {
            return $Matches[1]
        }
    }
    if ($schema -eq 'alice') { return 'user_credit' }
    return 'user_stats'
}

function Get-MysqlFedPairCounts([string]$pod, [string]$aliceTbl, [string]$bobTbl) {
    $raw = Pod-Exec $pod "mysql -h 127.0.0.1 --protocol=TCP -uroot -p$MysqlPwd --connect-timeout=15 -Nse 'SELECT (SELECT COUNT(*) FROM alice.$aliceTbl), (SELECT COUNT(*) FROM bob.$bobTbl);' 2>&1 || true"
    foreach ($line in ($raw -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -match '^(\d+)\s+(\d+)$') {
            return "$($Matches[1]) $($Matches[2])"
        }
    }
    return (($raw -replace '\s+', ' ').Trim())
}

# kubectl does not throw; always check exit code (do not pipe to Out-Null on cp).
function Kubectl-Must {
    param(
        [Parameter(Mandatory)] [string[]] $Args,
        [string] $ErrMsg = "kubectl command failed"
    )
    & kubectl @Args
    if ($LASTEXITCODE -ne 0) {
        Die "$ErrMsg (exit code $LASTEXITCODE)"
    }
}

# Avoid PS 5.1 Set-Content UTF-16LE default (breaks JSON / kubectl expectations).
function Write-TextUtf8NoBom([string]$path, [string]$content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
}

function Should-PushDemoBinary([string]$pod, [string]$binPath, [string]$statePath, [bool]$force) {
    if ($force) { return $true }
    if (-not (Test-Path -LiteralPath $binPath)) { return $true }
    $curHash = (Get-FileHash -LiteralPath $binPath -Algorithm SHA256).Hash
    if (-not (Test-Path -LiteralPath $statePath)) { return $true }
    $lines = @(Get-Content -LiteralPath $statePath -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 2) { return $true }
    $prevPod = $lines[0].Trim()
    $prevHash = $lines[1].Trim()
    return ($prevPod -ne $pod) -or ($prevHash -ne $curHash)
}

function Save-DemoBinPushState([string]$pod, [string]$binPath, [string]$statePath) {
    $h = (Get-FileHash -LiteralPath $binPath -Algorithm SHA256).Hash
    Write-TextUtf8NoBom $statePath ($pod + "`n" + $h)
}

# mysql official image often has no pkill/killall; use mysqladmin shutdown + scan /proc/*/comm.
# Duplicate mysqld (multiple nohup starts) causes InnoDB "Unable to lock ./ibdata1 error: 11".
# Kill by comm and by cmdline (-a for binary cmdline); repeat rounds; then wipe datadir.
$BashKillMysqldAndWipeDatadir = 'set +e; mysqladmin -h 127.0.0.1 --protocol=TCP -uroot -p__MYSQL_PWD__ shutdown 2>/dev/null; sleep 3; for r in 1 2 3; do for d in /proc/[0-9]*; do pid="${d#/proc/}"; [ -r "$d/comm" ] && grep -qx mysqld "$d/comm" 2>/dev/null && kill -9 "$pid" 2>/dev/null; [ -r "$d/cmdline" ] && grep -aq mysqld "$d/cmdline" 2>/dev/null && kill -9 "$pid" 2>/dev/null; done; sleep 2; done; rm -rf /var/lib/mysql/* /docker-entrypoint-initdb.d/* 2>/dev/null'

function Kill-ProcessByComm([string]$pod, [string]$commName) {
    $bash = ('for d in /proc/[0-9]*; do pid="${d#/proc/}"; [ -r "$d/comm" ] || continue; grep -qx __COMM__ "$d/comm" 2>/dev/null && kill -9 "$pid" 2>/dev/null; done; sleep 2').Replace('__COMM__', $commName)
    Pod-Exec $pod $bash | Out-Null
}

function Kill-ProcessByCmdline([string]$pod, [string]$pattern, [string]$signal = "TERM") {
    $patQ = Escape-BashSingleQuoted $pattern
    $sigQ = Escape-BashSingleQuoted $signal
    $bash = @"
for d in /proc/[0-9]*; do
  pid="`${d#/proc/}"
  [ -r "`$d/cmdline" ] || continue
  tr '\0' ' ' < "`$d/cmdline" | grep -q '$patQ' && kill -$sigQ "`$pid" 2>/dev/null
done
sleep 2
"@
    Pod-Exec $pod $bash | Out-Null
}

function Get-PodUnixTime([string]$pod) {
    $raw = Pod-Exec $pod "python3 -c 'import time; print(time.time())' 2>/dev/null || true"
    $t = ($raw -replace '\s+', '').Trim()
    if ($t -match '^\d+(\.\d+)?$') { return $t }
    return $null
}

function Assert-PodMonitorDeps([string]$pod, [string]$label) {
    foreach ($p in @($MonitorPy, $MonitorRunnerPy)) {
        if (-not (Test-Path -LiteralPath $p)) { Die "MonitorNetwork: missing host file $p" }
    }
    $ver = (Pod-Exec $pod "python3 --version 2>&1 || true").Trim()
    if ($ver -notmatch 'Python') {
        Die "MonitorNetwork: $label pod has no python3 ($ver). Install Python in the engine image or drop -MonitorNetwork."
    }
    $chk = Pod-Exec $pod "python3 -c 'import psutil' 2>&1 || true"
    if ($chk -match 'ModuleNotFoundError|No module named') {
        Die "MonitorNetwork: $label pod needs psutil ($chk). pip install psutil in the pod/image."
    }
    Ok "$label pod monitor deps: $ver, psutil OK"
}

function Push-MonitorScriptsToPod([string]$pod, [string]$label) {
    Push-Location $ScqlRoot
    try {
        Kubectl-Must @("-n", $Namespace, "cp", "examples/system_monitor.py", "${pod}:/tmp/system_monitor.py") "kubectl cp system_monitor.py -> $label"
        Kubectl-Must @("-n", $Namespace, "cp", "examples/run_pod_monitor.py", "${pod}:/tmp/run_pod_monitor.py") "kubectl cp run_pod_monitor.py -> $label"
    } finally {
        Pop-Location
    }
    Ok "monitor scripts pushed to ${label}:/tmp"
}

function Test-MonitorPidAlive([string]$pod, [string]$monitorPid) {
    if ([string]::IsNullOrWhiteSpace($monitorPid)) { return $false }
    $out = Pod-Exec $pod "kill -0 $monitorPid 2>/dev/null && echo ALIVE || echo DEAD"
    return ($out -match 'ALIVE')
}

function Get-MonitorPidOnPod([string]$pod) {
    $raw = (Pod-Exec $pod "cat /tmp/monitor.pid 2>/dev/null || true").Trim()
    if ($raw -match '^\d+$') { return $raw }
    $pg = (Pod-Exec $pod "pgrep -fn /tmp/run_pod_monitor.py 2>/dev/null | head -n1 || true").Trim()
    if ($pg -match '^\d+$') { return $pg }
    return $null
}

function Test-MonitorProcessRunning([string]$pod) {
    $monitorPid = Get-MonitorPidOnPod $pod
    if ($monitorPid) { return (Test-MonitorPidAlive $pod $monitorPid) }
    return $false
}

function Start-PodMonitor([string]$pod, [string]$label) {
    Kill-ProcessByCmdline $pod "run_pod_monitor.py" "TERM"
    Kill-ProcessByCmdline $pod "run_pod_monitor.py" "9"
    Pod-Exec $pod "rm -f /tmp/monitor.json /tmp/monitor.log /tmp/monitor.pid 2>/dev/null || true" | Out-Null

    $ifaceQ = Escape-BashSingleQuoted $MonitorInterface
    # setsid: survive kubectl exec session exit (plain nohup background may get SIGHUP).
    $startSh = @"
set -e
: > /tmp/monitor.log
rm -f /tmp/monitor.pid
if ! ip link show '$ifaceQ' >/dev/null 2>&1; then
  echo "WARN: interface '$ifaceQ' not found; ip link:" >> /tmp/monitor.log
  ip -o link show >> /tmp/monitor.log 2>&1 || true
fi
setsid python3 -u /tmp/run_pod_monitor.py --interface='$ifaceQ' --interval=$MonitorInterval --output=/tmp/monitor.json \
  >> /tmp/monitor.log 2>&1 </dev/null &
sleep 1
mpid=""
if [ -r /tmp/monitor.pid ]; then mpid=`$(cat /tmp/monitor.pid); fi
if [ -z "`$mpid" ]; then mpid=`$(pgrep -fn /tmp/run_pod_monitor.py 2>/dev/null | head -n1); fi
if [ -n "`$mpid" ] && kill -0 "`$mpid" 2>/dev/null; then
  echo monitor_pid=`$mpid
  echo monitor_alive=1
else
  echo monitor_alive=0
  cat /tmp/monitor.log 2>/dev/null || true
  exit 1
fi
"@
    $startOut = (Pod-BashStdin $pod $startSh).Trim()
    if ($startOut) { Write-Host "    [$label] $startOut" }
    $mpid = $null
    if ($startOut -match 'monitor_pid=(\d+)') { $mpid = $Matches[1] }

    $alive = $false
    for ($i = 1; $i -le 5; $i++) {
        if (-not $mpid) { $mpid = Get-MonitorPidOnPod $pod }
        if ($mpid -and (Test-MonitorPidAlive $pod $mpid)) { $alive = $true; break }
        if (Test-MonitorProcessRunning $pod) { $alive = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $alive) {
        $diag = Pod-Exec $pod @"
echo '--- monitor.log ---'
cat /tmp/monitor.log 2>/dev/null || true
echo '--- ps python ---'
ps aux 2>/dev/null | grep -E '[p]ython|run_pod_monitor' || true
echo '--- ip link ---'
ip -o link show 2>/dev/null || true
"@
        Die "MonitorNetwork [$label]: run_pod_monitor.py did not stay running. Diagnostics:`n$diag"
    }
    Ok "[$label] network monitor on $MonitorInterface (pid=$mpid, interval=${MonitorInterval}s)"
}

function Stop-PodMonitorAndPull([string]$pod, [string]$label, [string]$localOutput) {
    $mpid = (Pod-Exec $pod "cat /tmp/monitor.pid 2>/dev/null || true").Trim()
    if ($mpid -match '^\d+$') {
        Pod-Exec $pod "kill -TERM $mpid 2>/dev/null || true" | Out-Null
        Start-Sleep -Seconds 2
        Pod-Exec $pod "kill -9 $mpid 2>/dev/null || true" | Out-Null
    }
    Kill-ProcessByCmdline $pod "run_pod_monitor.py" "TERM"
    Start-Sleep -Seconds 2
    Kill-ProcessByCmdline $pod "run_pod_monitor.py" "9"

    $remoteJson = Pod-Exec $pod "test -s /tmp/monitor.json && echo OK || echo MISSING"
    if ($remoteJson -notmatch 'OK') {
        $tail = Pod-Exec $pod "tail -40 /tmp/monitor.log 2>/dev/null || true"
        Warn "MonitorNetwork [$label]: /tmp/monitor.json missing or empty. Log:`n$tail"
        return $false
    }

    $localDir = Split-Path -Parent $localOutput
    if (-not (Test-Path -LiteralPath $localDir)) {
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    }
    $outFull = [System.IO.Path]::GetFullPath($localOutput)
    $tutorialFull = [System.IO.Path]::GetFullPath($TutorialDir)
    if ($outFull.StartsWith($tutorialFull)) {
        Push-Location $TutorialDir
        try {
            $relOut = $outFull.Substring($tutorialFull.Length).TrimStart('\', '/')
            Kubectl-Must @("-n", $Namespace, "cp", "${pod}:/tmp/monitor.json", $relOut) "kubectl cp monitor.json <- $label"
        } finally {
            Pop-Location
        }
    } else {
        Push-Location $localDir
        try {
            $relOut = [System.IO.Path]::GetFileName($localOutput)
            Kubectl-Must @("-n", $Namespace, "cp", "${pod}:/tmp/monitor.json", $relOut) "kubectl cp monitor.json <- $label"
        } finally {
            Pop-Location
        }
    }
    if (-not (Test-Path -LiteralPath $localOutput)) {
        Warn "MonitorNetwork [$label]: failed to pull monitor JSON to $localOutput"
        return $false
    }
    Ok "[$label] monitor JSON -> $localOutput"
    return $true
}

function Write-MonitorDemoStampFile([string]$stampPath, [string]$start, [string]$end) {
    if ([string]::IsNullOrWhiteSpace($start) -or [string]::IsNullOrWhiteSpace($end)) { return }
    Write-TextUtf8NoBom $stampPath ("Key = demo start = $start end = $end`n")
}

function Invoke-MonitorGraphForParty([string]$label, [string]$jsonPath, [string]$pngPath, [string]$stampPath) {
    if ($SkipMonitorGraph) {
        Info "[$label] SkipMonitorGraph: PNG skipped"
        return
    }
    if (-not (Test-Path -LiteralPath $MonitorPlotPy)) {
        Warn "plot_monitor.py not found, skip $label graph"
        return
    }
    if (-not (Test-Path -LiteralPath $jsonPath)) {
        Warn "[$label] monitor JSON not found: $jsonPath"
        return
    }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) {
        Warn "host python not found; plot $label manually: python examples/plot_monitor.py $jsonPath"
        return
    }
    $plotArgs = @($MonitorPlotPy, $jsonPath, "-o", $pngPath)
    if (Test-Path -LiteralPath $stampPath) {
        $plotArgs += @("--stamp", $stampPath)
    }
    Info "[$label] plot: $($py.Source) $($plotArgs -join ' ')"
    & $py.Source @plotArgs
    if ($LASTEXITCODE -ne 0) {
        Warn "[$label] plot_monitor.py failed (exit=$LASTEXITCODE). Install: pip install numpy matplotlib"
        return
    }
    if (Test-Path -LiteralPath $pngPath) {
        Ok "[$label] monitor graph -> $pngPath"
    }
}
# ---------- Step 1: pod IPs ----------
Step "Step 1/6: get pod IPs"
$MysqlIp = Get-PodIp $MysqlPod
$AliceIp = Get-PodIp $AlicePod
$BobIp   = Get-PodIp $BobPod
Ok "MYSQL=$MysqlIp  ALICE=$AliceIp  BOB=$BobIp"

# ---------- Step 2: mysql ----------
Step "Step 2/6: ensure mysql is running"
$aliceSqlPath = Join-Path $TutorialDir "mysql\initdb\alice_init.sql"
$bobSqlPath   = Join-Path $TutorialDir "mysql\initdb\bob_init.sql"
$aliceFedTbl  = Get-InitTableNameAfterUse $aliceSqlPath 'alice'
$bobFedTbl    = Get-InitTableNameAfterUse $bobSqlPath 'bob'
$mysqlAlive = Pod-TcpOpen $MysqlPod 3306
if ($mysqlAlive -and -not $RestartMysql) {
    Ok "mysql already listening on 3306 (use -RestartMysql to force restart)"
} else {
    # Always shutdown+wipe when -RestartMysql, even if 3306 probe is false (otherwise stale mysqld / locked ibdata1).
    if ($RestartMysql) {
        Warn "RestartMysql: stop every mysqld, wipe datadir (fixes InnoDB ibdata1 lock / duplicate instances)"
        $mysqlKill = $BashKillMysqldAndWipeDatadir.Replace('__MYSQL_PWD__', $MysqlPwd)
        Pod-Exec $MysqlPod $mysqlKill | Out-Null
        Start-Sleep -Seconds 2
    }

    Info "copy init sql into mysql pod"
    # Windows: kubectl cp treats absolute paths like D:\... as remote (colon). Use cwd-relative paths.
    Push-Location $TutorialDir
    try {
        Kubectl-Must @("-n", $Namespace, "cp", "mysql/initdb/alice_init.sql", "${MysqlPod}:/tmp/alice_init.sql") "kubectl cp alice_init.sql -> mysql pod"
        Kubectl-Must @("-n", $Namespace, "cp", "mysql/initdb/bob_init.sql",   "${MysqlPod}:/tmp/bob_init.sql")   "kubectl cp bob_init.sql -> mysql pod"
    } finally {
        Pop-Location
    }

    Info "background-launch docker-entrypoint.sh mysqld (stdin script; detached, returns immediately on Windows)"
    $pwdQ = Escape-BashSingleQuoted $MysqlPwd
    $startSh = @"
set -e
mkdir -p /docker-entrypoint-initdb.d
rm -f /docker-entrypoint-initdb.d/*.sql /docker-entrypoint-initdb.d/*.sh 2>/dev/null || true
export MYSQL_ROOT_PASSWORD='$pwdQ'
export TZ=Asia/Shanghai
nohup docker-entrypoint.sh mysqld >> /tmp/mysqld.log 2>&1 </dev/null &
printf 'started pid=%s\n' `$!
"@
    $startOut = (Pod-BashStdin $MysqlPod $startSh).Trim()
    if ($startOut) { Write-Host $startOut }

    Info "wait for mysqld ready (port 3306 + SELECT 1, up to ~90s) ..."
    $ready = $false
    for ($i = 1; $i -le 45; $i++) {
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 2
        if (-not (Pod-TcpOpen $MysqlPod 3306)) { continue }
        # mysqladmin ping output/locale varies; use client WITH connect-timeout to avoid kubectl exec hanging.
        $one = Pod-Exec $MysqlPod "mysql -h 127.0.0.1 --protocol=TCP -uroot -p$MysqlPwd --connect-timeout=5 -Nse 'SELECT 1' 2>/dev/null || true"
        $one = ($one -replace '\s+', '').Trim()
        if ($one -eq '1') { $ready = $true; break }
    }
    Write-Host ""
    if (-not $ready) {
        $tail = Pod-Exec $MysqlPod "tail -40 /tmp/mysqld.log"
        Write-Host $tail
        Die "mysql startup timeout, see /tmp/mysqld.log above"
    }
    Ok "mysql ready"

    $aliceInsExpected = Count-SqlInsertLines $aliceSqlPath
    $bobInsExpected   = Count-SqlInsertLines $bobSqlPath

    Info "apply alice via mysql client (/tmp/alice_init.sql -> $aliceInsExpected INSERT lines)"
    $applyAliceSh = @"
export MYSQL_PWD='$pwdQ'
mysql -h127.0.0.1 --protocol=TCP -uroot --connect-timeout=120 --default-character-set=utf8mb4 < /tmp/alice_init.sql > /tmp/alice_apply.log 2>&1
ec=`$?
cat /tmp/alice_apply.log
echo __ALICE_APPLY_EXIT__=`$ec
unset MYSQL_PWD
exit `$ec
"@
    $applyAliceOut = Pod-BashStdin $MysqlPod $applyAliceSh
    if ($applyAliceOut) { Write-Host $applyAliceOut.TrimEnd() }
    if ($applyAliceOut -notmatch '__ALICE_APPLY_EXIT__=0') {
        Die "alice_init.sql failed to apply (see __ALICE_APPLY_EXIT__ and mysql messages above)"
    }

    Info "apply bob via mysql client (/tmp/bob_init.sql -> $bobInsExpected INSERT lines)"
    $applyBobSh = @"
export MYSQL_PWD='$pwdQ'
mysql -h127.0.0.1 --protocol=TCP -uroot --connect-timeout=120 --default-character-set=utf8mb4 < /tmp/bob_init.sql > /tmp/bob_apply.log 2>&1
ec=`$?
cat /tmp/bob_apply.log
echo __BOB_APPLY_EXIT__=`$ec
unset MYSQL_PWD
exit `$ec
"@
    $applyOut = Pod-BashStdin $MysqlPod $applyBobSh
    if ($applyOut) { Write-Host $applyOut.TrimEnd() }
    if ($applyOut -notmatch '__BOB_APPLY_EXIT__=0') {
        Die "bob_init.sql failed to apply (see __BOB_APPLY_EXIT__ and mysql messages above)"
    }
    $pair = Get-MysqlFedPairCounts $MysqlPod $aliceFedTbl $bobFedTbl
    $expectPair = "$aliceInsExpected $bobInsExpected"
    if ($pair -ne $expectPair) {
        Warn "expected row counts [$expectPair] but got [$pair] (check alice/bob_init INSERT counts vs tables)"
    }
}

# verify row counts
$counts = Get-MysqlFedPairCounts $MysqlPod $aliceFedTbl $bobFedTbl
if ($counts -match '^\d+\s+\d+$') {
    Ok "row counts alice.$aliceFedTbl | bob.$bobFedTbl : $counts"
} else {
    Warn "unexpected COUNT output: [$counts]"
}

# ---------- Step 3: render and push gflags.conf ----------
Step "Step 3/6: render and push alice/bob gflags.conf"
$aliceConfBody = (Get-Content $AliceConfTmpl -Raw) -replace '__MYSQL_HOST__', $MysqlIp
$bobConfBody   = (Get-Content $BobConfTmpl -Raw)   -replace '__MYSQL_HOST__', $MysqlIp
Write-TextUtf8NoBom $AliceConfOut $aliceConfBody
Write-TextUtf8NoBom $BobConfOut   $bobConfBody
Kubectl-Must @("-n", $Namespace, "exec", $AlicePod, "--", "mkdir", "-p", "/home/admin/engine/conf") "mkdir engine conf (alice)"
Kubectl-Must @("-n", $Namespace, "exec", $BobPod,   "--", "mkdir", "-p", "/home/admin/engine/conf") "mkdir engine conf (bob)"
Push-Location $TutorialDir
try {
    Kubectl-Must @("-n", $Namespace, "cp", "engine/alice/conf/gflags.conf", "${AlicePod}:/home/admin/engine/conf/gflags.conf") "kubectl cp gflags.conf -> alice"
    Kubectl-Must @("-n", $Namespace, "cp", "engine/bob/conf/gflags.conf",   "${BobPod}:/home/admin/engine/conf/gflags.conf")   "kubectl cp gflags.conf -> bob"
} finally {
    Pop-Location
}
Ok "gflags.conf pushed (host=$MysqlIp)"

# ---------- Step 4: launch engines ----------
Step "Step 4/6: ensure alice & bob engines are running"
function Ensure-Engine($pod, $name) {
    if (-not $RestartEngines -and (Pod-TcpOpen $pod 8003)) {
        Ok "$name engine already listening on 8003"
        return
    }
    if ($RestartEngines) {
        Info "[$name] force restart: kill old scqlengine (no pkill; use /proc)"
        Kill-ProcessByComm $pod "scqlengine"
    }
    Info "[$name] background-launch scqlengine"
    Pod-Exec $pod ("nohup /home/admin/bin/scqlengine --flagfile=/home/admin/engine/conf/gflags.conf " +
                   "> /tmp/engine.log 2>&1 < /dev/null & echo pid=`$!") | Out-Host
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 1
        if (Pod-TcpOpen $pod 8003) { Ok "$name engine ready"; return }
        Write-Host "." -NoNewline
    }
    Write-Host ""
    $tail = Pod-Exec $pod "tail -40 /tmp/engine.log"
    Write-Host $tail
    Die "$name engine startup timeout"
}
Ensure-Engine $AlicePod "alice"
Ensure-Engine $BobPod   "bob"

# ---------- Step 5: build opencore-demo ----------
Step "Step 5/6: build opencore-demo (linux/amd64)"
if ((Test-Path $DemoBin) -and -not $Rebuild) {
    Ok "binary exists at $DemoBin (use -Rebuild to force)"
} else {
    Push-Location $ScqlRoot
    try {
        $env:GOTOOLCHAIN = "auto"
        $env:GOOS        = "linux"
        $env:GOARCH      = "amd64"
        $env:CGO_ENABLED = "0"
        Info "go build -o opencore-demo ./examples/opencore-demo/main.go"
        & go build -o opencore-demo ./examples/opencore-demo/main.go
        if ($LASTEXITCODE -ne 0) { Die "go build failed (exit=$LASTEXITCODE)" }
        if (-not (Test-Path $DemoBin)) { Die "build artifact not found: $DemoBin" }
        Ok "built $DemoBin"
    } finally {
        Pop-Location
    }
}

# ---------- Step 6: push config & demo, run query ----------
Step "Step 6/6: push example_config.json + opencore-demo into alice pod"
$cfgBody = (Get-Content $CfgTmpl -Raw) `
    -replace '__ALICE_IP__', $AliceIp `
    -replace '__BOB_IP__',   $BobIp
Write-TextUtf8NoBom $CfgOut $cfgBody
$pushDemoBin = Should-PushDemoBinary $AlicePod $DemoBin $DemoBinPushState $ForcePushDemo
Push-Location $ScqlRoot
try {
    if ($pushDemoBin) {
        Kubectl-Must @("-n", $Namespace, "cp", "opencore-demo", "${AlicePod}:/tmp/opencore-demo") "kubectl cp opencore-demo -> alice pod"
    } else {
        Ok "opencore-demo unchanged for this pod, skip kubectl cp (+ chmod)"
    }
    Kubectl-Must @("-n", $Namespace, "cp", "examples/tutorial/example_config.k8s.json", "${AlicePod}:/tmp/example_config.json") "kubectl cp example_config.k8s.json -> alice pod /tmp/example_config.json"
} finally {
    Pop-Location
}
if ($pushDemoBin) {
    Kubectl-Must @("-n", $Namespace, "exec", $AlicePod, "--", "chmod", "+x", "/tmp/opencore-demo") "chmod opencore-demo"
    Save-DemoBinPushState $AlicePod $DemoBin $DemoBinPushState
}

Ok "pushed"

if ($MonitorNetwork) {
    if ($SkipDemo) {
        Warn "MonitorNetwork ignored with -SkipDemo (no demo window to sample)"
    } else {
        Step "MonitorNetwork: push scripts and start samplers on alice + bob pods"
        Assert-PodMonitorDeps $AlicePod "alice"
        Assert-PodMonitorDeps $BobPod "bob"
        Push-MonitorScriptsToPod $AlicePod "alice"
        Push-MonitorScriptsToPod $BobPod "bob"
        Start-PodMonitor $AlicePod "alice"
        Start-PodMonitor $BobPod "bob"
    }
}

if ($SkipDemo) {
    Step "Environment ready (demo skipped)"
    Write-Host ""
    Write-Host "Run manually:" -ForegroundColor Cyan
    Write-Host "  kubectl -n $Namespace exec $AlicePod -- /tmp/opencore-demo --config=/tmp/example_config.json"
    if ($MonitorNetwork) {
        Write-Host "  (with monitor: re-run without -SkipDemo, or start /tmp/run_pod_monitor.py manually)"
    }
    exit 0
}

Step "Run: opencore-demo --config=example_config.json"
Write-Host ""
$demoTsStart = $null
$demoTsEnd   = $null
if ($MonitorNetwork) {
    $demoTsStart = Get-PodUnixTime $AlicePod
}
& kubectl -n $Namespace exec $AlicePod -- /tmp/opencore-demo --config=/tmp/example_config.json
$rc = $LASTEXITCODE
if ($MonitorNetwork) {
    $demoTsEnd = Get-PodUnixTime $AlicePod
    Step "MonitorNetwork: stop samplers and pull results (alice + bob)"
    $aliceMonOk = Stop-PodMonitorAndPull $AlicePod "alice" $MonitorAliceOutput
    $bobMonOk   = Stop-PodMonitorAndPull $BobPod "bob" $MonitorBobOutput
    if ($aliceMonOk -or $bobMonOk) {
        Write-MonitorDemoStampFile $MonitorAliceStamp $demoTsStart $demoTsEnd
        Write-MonitorDemoStampFile $MonitorBobStamp $demoTsStart $demoTsEnd
        if ($aliceMonOk) { Invoke-MonitorGraphForParty "alice" $MonitorAliceOutput $MonitorAlicePng $MonitorAliceStamp }
        if ($bobMonOk)   { Invoke-MonitorGraphForParty "bob" $MonitorBobOutput $MonitorBobPng $MonitorBobStamp }
    }
}
Write-Host ""
if ($rc -eq 0) {
    Ok "Demo finished, exit=0"
    if ($MonitorNetwork) {
        if (Test-Path -LiteralPath $MonitorAliceOutput) { Ok "Alice monitor: $MonitorAliceOutput" }
        if (Test-Path -LiteralPath $MonitorBobOutput)   { Ok "Bob monitor:   $MonitorBobOutput" }
        if (-not $SkipMonitorGraph) {
            if (Test-Path -LiteralPath $MonitorAlicePng) { Ok "Alice graph:   $MonitorAlicePng" }
            if (Test-Path -LiteralPath $MonitorBobPng)   { Ok "Bob graph:     $MonitorBobPng" }
        }
    }
    Write-Host ""
    Write-Host "To run a different SQL:" -ForegroundColor Cyan
    Write-Host "  1) edit the 'sql' field in example_config.k8s.json.tmpl"
    Write-Host "  2) re-run: .\run-k8s-tutorial.ps1"
    if ($MonitorNetwork) {
        Write-Host "     add -MonitorNetwork to sample alice+bob pod NICs during the demo"
    } else {
        Write-Host "     (engine/mysql already running will be skipped, only re-push config + run demo)"
    }
} else {
    Warn ("Demo exit code = " + $rc + ", check above output and:")
    Write-Host "  kubectl -n $Namespace exec $AlicePod -- tail -100 /tmp/engine.log"
    Write-Host "  kubectl -n $Namespace exec $BobPod   -- tail -100 /tmp/engine.log"
    if ($MonitorNetwork) {
        Write-Host "  kubectl -n $Namespace exec $AlicePod -- tail -50 /tmp/monitor.log"
        Write-Host "  kubectl -n $Namespace exec $BobPod   -- tail -50 /tmp/monitor.log"
    }
    exit $rc
}
