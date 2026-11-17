# Links this project folder into each game's AddOns folder (directory junction, no admin needed),
# so a "git pull" here updates the game.
#   _forever_  = WoW Forever      (loads P13Tweaks.toc)
#   _classic_  = MoP Classic      (loads P13Tweaks_Mists.toc)
# Finds the WoW folder itself (registry + the usual places on every drive). If AddOns\P13Tweaks is a
# plain copied folder (e.g. from the old installer) it is replaced by the link; a link that already
# points here is left alone. Run it again any time; it's safe to repeat.
param([switch]$NoPause)

$Flavors = @("_forever_", "_classic_")

function Find-WowRoots {
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
    return $roots | Select-Object -Unique
}

$linked = 0
foreach ($root in Find-WowRoots) {
    foreach ($flavor in $Flavors) {
        $addons = Join-Path $root "$flavor\Interface\AddOns"
        if (-not (Test-Path $addons)) { continue }
        $target = Join-Path $addons "P13Tweaks"
        if (Test-Path $target) {
            $item = Get-Item $target -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if (($item.Target | Select-Object -First 1) -eq $PSScriptRoot) { Write-Host "Already linked: $target"; $linked++; continue }
                $item.Delete()                              # a link to somewhere else: remove just the link
            } else {
                Remove-Item $target -Recurse -Force         # a plain copy: replace it with the link
            }
        }
        New-Item -ItemType Junction -Path $target -Target $PSScriptRoot | Out-Null
        Write-Host "Linked $target -> $PSScriptRoot"
        $linked++
    }
}
if ($linked -eq 0) { Write-Host "Couldn't find World of Warcraft (_forever_ or _classic_) on this PC." }
else { Write-Host "Done. 'git pull' in $PSScriptRoot now updates the game (fully restart WoW to see a new version number)." }

if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }
