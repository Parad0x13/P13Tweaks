# Installs / updates P13Tweaks from GitHub into WoW on this PC (_forever_ and _classic_ folders).
#
# First time: double-click "Install P13Tweaks.bat" (next to this file). It
#   - installs the addon,
#   - copies this script to %LOCALAPPDATA%\P13Tweaks,
#   - adds a hidden update check that runs every time Windows starts,
#   - puts an "Update P13Tweaks" shortcut on the desktop (for an update right now).
# After that nothing needs doing: updates arrive by themselves the next time the PC starts.
#
# Safe on the developer's PC: an AddOns\P13Tweaks that is a link (made by link.ps1) is never touched.
param([switch]$Install, [switch]$Quiet)

$Repo   = "Parad0x13/P13Tweaks"
$Branch = "main"
# Only needed while the GitHub repo is private: a read-only fine-grained token
# (Repository access: only P13Tweaks; Permissions: Contents = Read-only). Leave "" if the repo is public.
$Token  = ""

$Flavors = @("_forever_", "_classic_")
$Skip    = @("installer", "tools", "link.ps1", "HANDOFF.md", ".gitignore", ".gitattributes")

$ErrorActionPreference = "Stop"
$Data = Join-Path $env:LOCALAPPDATA "P13Tweaks"
New-Item -ItemType Directory -Force -Path $Data | Out-Null
$Log = Join-Path $Data "update.log"

function Say($msg) {
    Add-Content -Path $Log -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"), $msg)
    if (-not $Quiet) { Write-Host $msg }
}

function Find-AddOnFolders {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in "HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                     "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft") {
        try {
            $p = (Get-ItemProperty $key -ErrorAction Stop).InstallPath
            if ($p) {
                $p = $p.TrimEnd("\")
                if ((Split-Path $p -Leaf) -like "_*_") { $p = Split-Path $p -Parent }
                $roots.Add($p)
            }
        } catch {}
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem).Root) {
        foreach ($sub in "Program Files (x86)\World of Warcraft", "Program Files\World of Warcraft",
                         "World of Warcraft", "Games\World of Warcraft") {
            $roots.Add((Join-Path $drive $sub))
        }
    }
    $found = @()
    foreach ($root in ($roots | Select-Object -Unique)) {
        foreach ($flavor in $Flavors) {
            $game = Join-Path $root $flavor
            if (Test-Path $game) { $found += (Join-Path $game "Interface\AddOns") }
        }
    }
    return $found | Select-Object -Unique
}

function Install-Shortcuts {
    $installed = Join-Path $Data "Update-P13Tweaks.ps1"
    if ($PSCommandPath -ne $installed) { Copy-Item -Force $PSCommandPath $installed }
    $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $shell = New-Object -ComObject WScript.Shell

    $startup = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Startup")) "P13Tweaks updater.lnk"))
    $startup.TargetPath = $ps
    $startup.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installed`" -Quiet"
    $startup.WindowStyle = 7   # minimized
    $startup.Save()

    $desk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "Update P13Tweaks.lnk"))
    $desk.TargetPath = $ps
    $desk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$installed`""
    $desk.IconLocation = "$ps,0"
    $desk.Save()
    Say "Automatic updates are on (checked every time Windows starts). 'Update P13Tweaks' is on your desktop."
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "P13Tweaks-updater" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    $targets = @(Find-AddOnFolders)
    if ($targets.Count -eq 0) { throw "Couldn't find World of Warcraft (_forever_ or _classic_) on this PC." }

    $sha = (Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Branch" -Headers $headers).sha
    $stamp = Join-Path $Data "installed.txt"
    $have = if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { "" }
    $missing = $targets | Where-Object { -not (Test-Path (Join-Path $_ "P13Tweaks\Core.lua")) }

    if ($have -eq $sha -and -not $missing) {
        Say "P13Tweaks is already up to date."
    } else {
        $tmp = Join-Path $env:TEMP ("P13Tweaks-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zip = Join-Path $tmp "p13.zip"
        Invoke-WebRequest "https://api.github.com/repos/$Repo/zipball/$sha" -Headers $headers -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath (Join-Path $tmp "x")
        $src = Get-ChildItem (Join-Path $tmp "x") -Directory | Select-Object -First 1

        foreach ($addons in $targets) {
            $dest = Join-Path $addons "P13Tweaks"
            if ((Test-Path $dest) -and ((Get-Item $dest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Say "Skipped $dest (it's a developer link)."
                continue
            }
            New-Item -ItemType Directory -Force -Path $addons | Out-Null
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            New-Item -ItemType Directory -Path $dest | Out-Null
            Get-ChildItem $src.FullName -Force | Where-Object { $Skip -notcontains $_.Name } |
                Copy-Item -Destination $dest -Recurse -Force
            Say "Installed the latest P13Tweaks into $dest"
        }
        Set-Content -Path $stamp -Value $sha
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Say "Done. If the game is open, type /reload in chat to load the new version."
    }

    if ($Install) { Install-Shortcuts }
} catch {
    Say ("Update failed: " + $_.Exception.Message)
}

if (-not $Quiet) { Read-Host "Press Enter to close" | Out-Null }
