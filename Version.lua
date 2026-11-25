-- The addon version. Keep it equal to "## Version:" in both .toc files and bump all three on every update.
-- It lives in a Lua file (not only the .toc) because /reload re-reads Lua files but not .toc files,
-- so after a "git pull" a /reload is enough to show the new version number.
local ADDON_NAME, ns = ...
ns.version = "0.31.13"
