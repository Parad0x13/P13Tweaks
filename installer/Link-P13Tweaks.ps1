# Sets this PC up so that "git pull" updates the game.
#   1. makes sure git is installed (installs it with winget if not),
#   2. clones the repo to  %USERPROFILE%\P13Tweaks  (or pulls it if it's already there),
#   3. replaces the copied P13Tweaks folder in each WoW AddOns folder (_forever_, _classic_) with a LINK to that clone.
# After this, running "git pull" in %USERPROFILE%\P13Tweaks (or the "Update P13Tweaks" desktop shortcut) updates the game.
#
# While the GitHub repo is private it needs a read-only token. If $Token is empty it reuses the one
# from the older installer (%LOCALAPPDATA%\P13Tweaks\Update-P13Tweaks.ps1), else git asks you to sign in.
param([switch]$NoPause)

$Repo   = "Parad0x13/P13Tweaks"
$Branch = "main"
$Token  = ""

$Flavors = @("_forever_", "_classic_")
$Dest    = Join-Path $env:USERPROFILE "P13Tweaks"
$Data    = Join-Path $env:LOCALAPPDATA "P13Tweaks"
New-Item -ItemType Directory -Force -Path $Data | Out-Null
$Log = Join-Path $Data "link.log"

function Say($msg) {
    Add-Content -Path $Log -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"), $msg)
    Write-Host $msg
}

function Find-Git {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in "$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
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

function Run-Git([string[]]$gitArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $script:git @gitArgs
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return $code
}

try {
    # Token: this script, else the older installer's copy.
    if (-not $Token) {
        $oldScript = Join-Path $Data "Update-P13Tweaks.ps1"
        if (Test-Path $oldScript) {
            $m = Select-String -Path $oldScript -Pattern '^\$Token\s*=\s*"([^"]+)"' | Select-Object -First 1
            if ($m) { $Token = $m.Matches[0].Groups[1].Value }
        }
    }

    $targets = @(Find-AddOnFolders)
    if ($targets.Count -eq 0) { throw "Couldn't find World of Warcraft (_forever_ or _classic_) on this PC." }

    # 1. git
    $script:git = Find-Git
    if (-not $script:git) {
        Say "Git isn't installed - installing it (this takes a minute)..."
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            & winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
            $ErrorActionPreference = $old
        }
        $script:git = Find-Git
        if (-not $script:git) {
            throw "Couldn't install git automatically. Install it from https://git-scm.com/download/win (all defaults), then run this again."
        }
    }

    # 2. clone or pull
    $url = if ($Token) { "https://x-access-token:$Token@github.com/$Repo.git" } else { "https://github.com/$Repo.git" }
    if (Test-Path (Join-Path $Dest ".git")) {
        Say "Updating $Dest ..."
        [void](Run-Git @("-C", $Dest, "remote", "set-url", "origin", $url))
        if ((Run-Git @("-C", $Dest, "pull", "--ff-only", "--quiet", "origin", $Branch)) -ne 0) { throw "git pull failed." }
    } else {
        if (Test-Path $Dest) { throw "$Dest exists but isn't a git copy. Rename or delete it, then run this again." }
        Say "Downloading P13Tweaks to $Dest ..."
        if ((Run-Git @("clone", "--quiet", "--branch", $Branch, $url, $Dest)) -ne 0) {
            throw "git clone failed (wrong or expired token, or no internet)."
        }
    }

    # 3. link it into WoW
    foreach ($addons in $targets) {
        $link = Join-Path $addons "P13Tweaks"
        if (Test-Path $link) {
            $item = Get-Item $link -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($item.Target -and ($item.Target | Select-Object -First 1) -eq $Dest) { Say "Already linked: $link"; continue }
                $item.Delete()   # a link to somewhere else: remove just the link
            } else {
                Remove-Item $link -Recurse -Force   # the copied folder from the older installer
            }
        }
        New-Item -ItemType Junction -Path $link -Target $Dest | Out-Null
        Say "Linked $link -> $Dest"
    }

    # 4. desktop shortcut that does the pull
    $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $shell = New-Object -ComObject WScript.Shell
    $desk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "Update P13Tweaks.lnk"))
    $desk.TargetPath = $ps
    $desk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $desk.IconLocation = "$ps,0"
    $desk.Save()
    Copy-Item -Force $PSCommandPath (Join-Path $Data "Link-P13Tweaks.ps1")
    $desk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Data 'Link-P13Tweaks.ps1')`""
    $desk.Save()

    Say "Done. The game now reads P13Tweaks straight from $Dest."
    Say "To update later: run 'git pull' in that folder, or use the 'Update P13Tweaks' desktop shortcut. Then type /reload in the game."
} catch {
    Say ("Failed: " + $_.Exception.Message)
}

if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }
