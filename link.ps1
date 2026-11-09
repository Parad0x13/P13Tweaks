# Links this project folder into each game's AddOns folder (directory junction, no admin needed).
#   _forever_  = WoW Forever      (loads P13Tweaks.toc)
#   _classic_  = MoP Classic      (loads P13Tweaks_Mists.toc)
$wow = "C:\Program Files (x86)\World of Warcraft"

foreach ($flavor in "_forever_", "_classic_") {
    $addons = Join-Path $wow "$flavor\Interface\AddOns"
    if (-not (Test-Path $addons)) { Write-Host "Skipped (not installed): $addons"; continue }
    $target = Join-Path $addons "P13Tweaks"
    if (Test-Path $target) {
        Write-Host "Already exists: $target"
    } else {
        New-Item -ItemType Junction -Path $target -Target $PSScriptRoot | Out-Null
        Write-Host "Linked $target -> $PSScriptRoot"
    }
}
