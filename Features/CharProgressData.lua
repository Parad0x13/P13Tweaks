-- P13Tweaks: advice for the Character Progression tab (Features/CharProgress.lua), researched for WoW FOREVER only
-- (Blizzard news + dev notes, warcraft.wiki.gg, maxroll, method.gg, warcrafttavern, zockify, wowforever.co etc.,
-- November 2026). Forever is still being patched; talent names that no longer exist in game are skipped by the tab.
--
-- classes[TOKEN] = {
--   roles, intro, armor = { {level, "type"} }, weapons, usesRanged,
--   trees = { { name, what, best } }          -- in the game's tree order
--   builds = { { name, tree, role, levelling, why, stats, weights = { STR = 1, ... }, rotation = {..},
--                points = { "Talent Name 5", ... } } }   -- in order; the number is the rank to reach (cumulative)
--   abilities = { { level, "Spell Name", "when to press it" } },
--   gear, endgame, mistakes, forever = { "lines" },
-- }
-- weights keys: STR AGI STA INT SPI AP RAP SP HEAL HIT CRIT HASTE DEF DODGE PARRY BLOCK MP5 HP5 ARMOR DPS RDPS
-- (only used when RestedXP Guides isn't loaded - its Forever weights are preferred)
local ADDON_NAME, ns = ...

local D = { updated = "Nov 2026", classes = {} }
ns.ProgressData = D

-- { from, to, zone } - usual levelling zones (games.gg / warcraft.wiki.gg, about +-2 levels)
local contestedEK = {
    { 15, 25, "Redridge Mountains" }, { 19, 30, "Duskwood" }, { 20, 31, "Hillsbrad Foothills" }, { 20, 30, "Wetlands" },
    { 27, 39, "Alterac Mountains" }, { 30, 40, "Arathi Highlands" }, { 30, 44, "Stranglethorn Vale" },
    { 36, 45, "Badlands" }, { 35, 45, "Riverglades (new)" }, { 36, 43, "Swamp of Sorrows" }, { 41, 49, "The Hinterlands" },
    { 43, 48, "Searing Gorge" }, { 46, 55, "Blasted Lands" }, { 46, 57, "Western Plaguelands" },
    { 50, 59, "Burning Steppes" }, { 54, 59, "Eastern Plaguelands" },
}
local contestedK = {
    { 15, 25, "Stonetalon Mountains" }, { 19, 30, "Ashenvale" }, { 24, 35, "Thousand Needles" }, { 30, 39, "Desolace" },
    { 35, 45, "Shen'dralas (new)" }, { 36, 43, "Dustwallow Marsh" }, { 40, 50, "Tanaris" }, { 41, 50, "Feralas" },
    { 42, 55, "Azshara" }, { 47, 54, "Felwood" }, { 48, 55, "Un'Goro Crater" }, { 55, 59, "Silithus" },
    { 55, 60, "Winterspring" }, { 60, 60, "Mount Hyjal (new, level 60)" },
}
local function Join(...)
    local out = {}
    for i = 1, select("#", ...) do for _, z in ipairs((select(i, ...))) do out[#out + 1] = z end end
    return out
end
D.zones = {
    Alliance = Join({
        { 1, 12, "Zephras Isle (Skyborne start)" }, { 1, 10, "Elwynn Forest" }, { 1, 12, "Dun Morogh" }, { 1, 11, "Teldrassil" },
        { 9, 18, "Westfall" }, { 10, 18, "Loch Modan" }, { 11, 19, "Darkshore" },
    }, contestedEK, contestedK),
    Horde = Join({
        { 1, 12, "Zephras Isle (Skyborne start)" }, { 1, 10, "Durotar" }, { 1, 10, "Mulgore" }, { 1, 12, "Tirisfal Glades" },
        { 10, 20, "Silverpine Forest" }, { 10, 25, "The Barrens" },
    }, contestedEK, contestedK),
}

-- { from, to, name, where }
D.dungeons = {
    { 13, 18, "Ragefire Chasm", "Orgrimmar" },
    { 13, 20, "Hall of Thanes (new)", "under Ironforge" },
    { 15, 22, "Ruins of Lordaeron (new)", "Tirisfal Glades" },
    { 15, 24, "Wailing Caverns", "The Barrens" },
    { 17, 26, "The Deadmines", "Westfall" },
    { 20, 30, "Shadowfang Keep", "Silverpine Forest" },
    { 24, 32, "Blackfathom Deeps", "Ashenvale" },
    { 24, 32, "The Stockade", "Stormwind" },
    { 24, 33, "Excavation Site (new)", "Wetlands" },
    { 28, 35, "City of Dalaran (new)", "Alterac Mountains" },
    { 29, 38, "Razorfen Kraul", "The Barrens" },
    { 29, 38, "Gnomeregan", "Dun Morogh" },
    { 30, 46, "Scarlet Monastery", "Tirisfal Glades" },
    { 35, 42, "The Drowned City (new)", "Stranglethorn coast" },
    { 37, 46, "Razorfen Downs", "The Barrens" },
    { 40, 47, "Krol'dok Stronghold (new)", "Riverglades" },
    { 41, 51, "Uldaman", "Badlands" },
    { 44, 54, "Zul'Farrak", "Tanaris" },
    { 46, 55, "Maraudon", "Desolace" },
    { 48, 55, "Alcaz Prison (new)", "Dustwallow Marsh" },
    { 50, 60, "Sunken Temple", "Swamp of Sorrows" },
    { 52, 60, "Blackrock Depths", "Blackrock Mountain" },
    { 54, 60, "Dire Maul", "Feralas" },
    { 55, 60, "Blackrock Spire", "Blackrock Mountain" },
    { 55, 60, "Blackmaw Hold (new)", "Azshara" },
    { 58, 60, "Shaper's Terrace (new)", "Un'Goro Crater" },
    { 58, 60, "Stratholme", "Eastern Plaguelands" },
    { 58, 60, "Scholomance", "Western Plaguelands" },
}

-- { text, max = only shown up to this level }
D.general = {
    { max = 12, text = "Talents start at level 10: one point per level, 51 by level 60. Each tree has big one-point talents at 11, 16, 21 and 31 points (the 16 one is new in Forever)." },
    { text = "Visit your class trainer every even level. Total training 1-60 costs about 207 gold, so don't be shy." },
    { text = "Changed your mind on talents? Your class trainer resets them: 1 gold the first time, more each time (it slowly gets cheaper again)." },
    { max = 40, text = "Level 40: riding (about 100 gold, mount included) and dual spec at your class trainer (about 50 gold). Start saving gold around level 30." },
    { min = 40, text = "Dual spec (level 40, class trainer): keep a levelling/damage set of talents AND a dungeon set (tank or healer) and swap for free outside combat." },
    { text = "Weapon skill is gone in Forever - Expertise on gear replaces it, so any weapon type you can use works straight away. Hit and Crit on gear count for melee, ranged and spells alike." },
    { text = "Spells you learn no longer jump onto your action bars - drag them from the spellbook (P) yourself." },
    { text = "Most bag items: quest rewards are your main upgrades until 60. Pick the reward with YOUR best stats (above), not the one that sells for the most." },
    { text = "Finishing a zone's quest chapters earns account-wide Legacy Points (spent at the class trainer on non-combat perks like more rested XP)." },
    { max = 30, text = "Set your hearthstone at the inn of each new quest hub. Logging out in an inn or city (or with the Cozy Sleeping Bag) builds rested XP = double XP from kills." },
    { text = "Dungeons give good XP in Forever (raised by hotfixes) and the best gear while levelling - do each once with its quests." },
}

local C = D.classes

---------------------------------------------------------------------------
-- WARRIOR
---------------------------------------------------------------------------
C.WARRIOR = {
    roles = "Tank or melee damage",
    usesRanged = true,
    intro = "You hit things with big weapons and run on Rage, which you get by hitting and being hit (it drains when you're out of combat). "
        .. "Your weapon is almost all of your damage, so a better weapon is always your biggest upgrade. Stances: Battle (start), Defensive (tanking), Berserker (level 30).",
    armor = { { 1, "Cloth" }, { 1, "Leather" }, { 1, "Mail" }, { 1, "Shields" }, { 40, "Plate (learn it at your trainer)" } },
    weapons = "Almost everything: axes, maces, swords (one- or two-handed), daggers, fist weapons, staves; polearms from a weapon master at 20. A bow/gun/crossbow/thrown in the ranged slot for pulling. Dual wield at 20.",
    trees = {
        { name = "Arms", what = "slow two-handed weapon, Rend, Overpower and Mortal Strike for big hits.", best = "group levelling, PvP" },
        { name = "Fury", what = "two weapons at once, lots of crits that give lots of Rage. Weak before level 30, strong after.", best = "levelling after 30, dungeon damage" },
        { name = "Protection", what = "shield tanking - holding enemies on you so your group survives. Vanguard lets you Charge in Defensive Stance.", best = "dungeon tanking, safe solo levelling" },
    },
    builds = {
        { name = "Levelling: Fury (19/32/0)", tree = "Fury", role = "Solo levelling", levelling = true,
          why = "Maxroll's Forever levelling build. Use two one-handed weapons from level 20 (or a two-hander until you have two good ones).",
          stats = "Weapon damage > Strength > Stamina > Agility",
          weights = { STR = 2, AGI = 0.9, STA = 0.75, AP = 1, HIT = 7, CRIT = 8, HASTE = 7, DPS = 14, ARMOR = 0.03, SPI = 0.3 },
          rotation = {
              "Battle Shout up, Charge in, Rend if the mob will live a while.",
              "Press Overpower and Victory Rush whenever they light up - they're cheap and strong.",
              "Bloodthirst / Slam on cooldown; Heroic Strike only when you have lots of extra Rage.",
              "2+ mobs: Thunder Clap, Cleave, Whirlwind (36). Don't waste Rage on a nearly dead mob - keep it for the next pull.",
          },
          points = { "Cruelty 5", "Unbridled Wrath 5", "Blood Craze 3", "Enrage 2", "Dual Wield Specialization 5", "Gore Drinker 2",
              "Death Wish 1", "Enrage 4", "Flurry 3", "Improved Whirlwind 2", "Bloodthirst 1", "Improved Rend 3", "Deflection 2",
              "Improved Tactical Mastery 3", "Improved Overpower 2", "Anger Management 1", "Deep Wounds 3", "Enrage 5",
              "Deflection 3", "Impale 2", "Deflection 5" } },
        { name = "Levelling: Arms two-hander", tree = "Arms", role = "Group levelling with a big two-handed weapon", levelling = true,
          why = "Method's Arms order (ranks are P13's fill-in). Good if you found a great two-hander or level with friends.",
          stats = "Weapon damage > Strength > Stamina > Agility",
          weights = { STR = 2, AGI = 0.9, STA = 0.75, AP = 1, HIT = 7, CRIT = 8, HASTE = 7, DPS = 14, ARMOR = 0.03, SPI = 0.3 },
          rotation = {
              "Charge, Rend, then Mortal Strike on cooldown; Overpower and Victory Rush when they light up.",
              "Sweeping Strikes + Cleave/Whirlwind when there are 2 mobs.",
          },
          points = { "Improved Rend 3", "Improved Tactical Mastery 3", "Deflection 5", "Deep Wounds 3", "Bloodthrill 2",
              "Sweeping Strikes 1", "Weaponmaster 5", "Two-Handed Weapon Specialization 3", "Impale 2", "Improved Slam 2",
              "Mortal Strike 1", "Anger Management 1", "Cruelty 5", "Unbridled Wrath 5", "Enrage 5" } },
        { name = "Endgame: Fury damage (11/40/0)", tree = "Fury", role = "Dungeon / raid damage at 60",
          why = "Wowhead's Forever Fury build. Raids open in December, so expect this to change.",
          stats = "Hit (until capped) > Strength > Crit > Agility",
          weights = { STR = 2, AGI = 1, STA = 0.5, AP = 1, HIT = 9, CRIT = 9, HASTE = 7, DPS = 14 },
          rotation = { "Bloodthirst and Whirlwind on cooldown, Heroic Strike with extra Rage, Execute under 20% health." },
          points = { "Cruelty 5", "Unbridled Wrath 5", "Deflection 5", "Improved Tactical Mastery 3", "Improved Overpower 2",
              "Anger Management 1", "Furious Precision 3", "Blood Craze 3", "Enrage 5", "Dual Wield Specialization 5",
              "Reckless Swings 1", "Improved Execute 2", "Improved Berserker Rage 2", "Death Wish 1", "Gore Drinker 2",
              "Improved Whirlwind 2", "Flurry 3", "Bloodthirst 1" } },
        { name = "Dungeon tank: Protection", tree = "Protection", role = "Tanking",
          why = "Method's Prot order (ranks are P13's fill-in). Use a one-hander + shield, stay in Defensive Stance.",
          stats = "Stamina > Armor > Defense > Strength",
          weights = { STA = 1.5, STR = 0.8, AGI = 0.6, ARMOR = 0.1, DEF = 1.5, DODGE = 2, PARRY = 2, BLOCK = 1, HIT = 3, DPS = 4 },
          rotation = {
              "Charge (Vanguard lets you do it in Defensive Stance), Thunder Clap, Sunder Armor / Shield Slam.",
              "Revenge whenever it lights up; Demoralizing Shout on packs; Taunt anything hitting your healer.",
          },
          points = { "Shield Specialization 5", "Improved Thunder Clap 3", "Improved Bloodrage 2", "Master of Defense 3",
              "Last Stand 1", "Improved Revenge 3", "Vanguard 1", "Defiance 3", "Bastion 3", "Concussion Blow 1",
              "Focused Rage 3", "Shield Slam 1" } },
    },
    abilities = {
        { 1, "Battle Shout", "keep it up all the time" },
        { 1, "Heroic Strike", "spend extra Rage" },
        { 4, "Charge", "start every fight with it - it gives Rage" },
        { 4, "Rend", "bleed - only on mobs that will live a while" },
        { 6, "Thunder Clap", "hits and slows everything around you" },
        { 8, "Hamstring", "slows a mob that runs away" },
        { 10, "Sunder Armor", "tanking: builds threat" },
        { 12, "Overpower", "cheap big hit after the mob dodges - press it when it lights up" },
        { 14, "Revenge", "Defensive Stance: press it when it lights up" },
        { 20, "Victory Rush", "free hit + heal after you kill something" },
        { 20, "Cleave", "Heroic Strike for 2 mobs" },
        { 20, "Slam", "solid hit, 15 s cooldown" },
        { 24, "Execute", "finisher when the mob is under 20% health" },
        { 30, "Berserker Rage", "free Rage, breaks fear" },
        { 36, "Whirlwind", "hits everything around you - strong in every spec" },
        { 50, "Recklessness", "big crit cooldown for hard fights" },
    },
    gear = {
        "Weapon first: a slow (high speed number) weapon with high damage. Your weapon is ~95% of your damage while levelling.",
        "Ignore Intellect and Spirit - warriors have no mana.",
        "Class quests: level 10 (Defensive Stance), 20 (a mail chest), 30 (Berserker Stance) - do them.",
        "Weapon quests worth doing: Axe of Orgrimmar / Ironforge Greathammer (14), Heavehammer (27, Wetlands), Whirlwind Axe (30, class quest).",
    },
    endgame = {
        "Damage: Fury with two weapons (or Arms with a big two-hander). Raids open on 9 December 2026, so 60 builds are still settling.",
        "Tank: deep Protection with a shield. Dual spec at 40 lets you keep a damage set too.",
    },
    mistakes = {
        "Spending all your Rage on a nearly dead mob - save it for the next pull.",
        "Swapping stances without thinking (you keep only 10 Rage).",
        "Never using Retaliation, Intimidating Shout or Shield Wall - they're there to save you, use them.",
        "Keeping an old weapon: check every quest reward and dungeon drop for a better one.",
    },
    forever = {
        "Victory Rush (20) heals you and is free after a kill. Thunder Clap works in Defensive Stance with a 6 s cooldown.",
        "Slam is now a 15 s cooldown ability. Whirlwind hits with both weapons. Tactical Mastery is free at 14.",
        "Defensive Stance gives much more threat (80%). Battle Shout reaches the whole raid.",
        "New talents: Spearing Strike, Weaponmaster, Bloodthrill (Arms); Reckless Swings, Gore Drinker, Furious Precision (Fury); Vanguard, Master of Defense, Focused Rage (Prot).",
    },
}

---------------------------------------------------------------------------
-- ROGUE
---------------------------------------------------------------------------
C.ROGUE = {
    roles = "Melee damage",
    usesRanged = true,
    intro = "You fight up close with Energy (refills fast) and Combo Points (built on one target, then spent on a finisher). "
        .. "You can sneak in Stealth, stun, and escape. Your main-hand weapon matters most.",
    armor = { { 1, "Cloth" }, { 1, "Leather" } },
    weapons = "Daggers, one-handed axes (new in Forever) and thrown from the start; one-handed swords, maces, fist weapons, bows, guns and crossbows from a weapon master. Dual wield at 10.",
    trees = {
        { name = "Assassination", what = "poisons and daggers (Mutilate at 31). Not a good starter spec.", best = "dungeon damage later" },
        { name = "Combat", what = "steady sword/axe/mace fighting with Sinister Strike, Blade Flurry and Adrenaline Rush.", best = "solo levelling, raid damage" },
        { name = "Subtlety", what = "stealth tricks and dagger burst (Hemorrhage, Death Mark).", best = "PvP" },
    },
    builds = {
        { name = "Levelling: Combat (16/35/0)", tree = "Combat", role = "Solo levelling and raids", levelling = true,
          why = "Method's Forever Combat build. Use a sword, axe or mace in the main hand - not a dagger.",
          stats = "Agility > Attack Power > Strength > Stamina",
          weights = { AGI = 2, STR = 1, STA = 0.5, AP = 1, HIT = 7, CRIT = 8, HASTE = 7, DPS = 14, SPI = 0.2 },
          rotation = {
              "Just walk up (no need to stealth every mob). Shank on cooldown - it gives Energy.",
              "Sinister Strike for combo points; Slice and Dice, then Eviscerate at 3-5 points.",
              "2+ mobs or an elite: Blade Flurry and Adrenaline Rush. In trouble: Evasion, Gouge, or Vanish.",
          },
          points = { "Remorseless Attacks 2", "Efficient Strikes 2", "Coup de Grace 3", "Deflection 3", "Precision 2", "Riposte 1",
              "Precision 3", "Endurance 2", "Lightning Reflexes 1", "Flawless Execution 1", "Aggression 3", "Weapon Expertise 1",
              "Blade Flurry 1", "Weapon Expertise 2", "Dual Wield Specialization 2", "Hack and Slash 5", "Flash of Steel 1",
              "Adrenaline Rush 1", "Malice 3", "Improved Slice and Dice 3", "Ruthlessness 2", "Malice 5", "Lethality 2",
              "Ruthlessness 3", "Cold Blood 1", "Flash of Steel 5" } },
    },
    abilities = {
        { 1, "Sinister Strike", "your main combo point builder" },
        { 1, "Eviscerate", "finisher: spend 3-5 combo points for damage" },
        { 1, "Stealth", "sneak past or open on a mob" },
        { 4, "Backstab", "big hit from behind (dagger only)" },
        { 6, "Gouge", "stops a mob for a few seconds" },
        { 8, "Evasion", "emergency: dodge almost everything" },
        { 10, "Slice and Dice", "finisher: faster attacks - keep it up" },
        { 10, "Sprint", "run fast" },
        { 12, "Kick", "interrupt a spell" },
        { 22, "Vanish", "escape a fight that's going wrong" },
        { 24, "Shank", "press on cooldown - it gives Energy" },
        { 26, "Cheap Shot", "stun opener from Stealth" },
        { 30, "Kidney Shot", "finisher stun" },
    },
    gear = {
        "The highest damage weapon goes in your main hand. Combat: swords, axes or maces, not daggers.",
        "Poisons (from the level 20 class quest): Instant Poison on a slow weapon, Deadly on a fast one. They stack with sharpening stones now.",
        "Ignore Intellect and Spirit.",
        "Worth getting: Blade of Cunning (10, class quest), Meteor Shard (Shadowfang Keep), Toxic Revenger (Gnomeregan), Ruby-Adorned Blade (30+, class quest).",
    },
    endgame = { "Combat (16/35/0, the same build) is the usual raid build. Assassination with Mutilate is the dagger option." },
    mistakes = {
        "Opening every mob from Stealth - it's slow. Just attack.",
        "Changing target with combo points up - they stay on the old target.",
        "Daggers in a Combat build.",
        "Forgetting Shank on cooldown or letting Slice and Dice drop.",
    },
    forever = {
        "New: Shank (24) - a cheap off-hand stab that GIVES Energy. Poised (18): your first attack from full Energy costs less.",
        "Poisons last longer, can crit and get stronger with Attack Power. Rogues can use one-handed axes.",
        "Sap no longer breaks Stealth. Weapon specialisations are combined into Hack and Slash (Combat).",
    },
}

---------------------------------------------------------------------------
-- HUNTER
---------------------------------------------------------------------------
C.HUNTER = {
    roles = "Ranged damage (with a pet)",
    usesRanged = true,
    intro = "You shoot from range while your pet holds the enemy. The pet is your tank - let it get the mob's attention first. "
        .. "Your bow/gun/crossbow is your biggest upgrade. Auto Shot needs you to stand still for half a second.",
    armor = { { 1, "Cloth" }, { 1, "Leather" }, { 40, "Mail (learn it at your trainer)" } },
    weapons = "Ranged: bows, guns, crossbows (you need ammo). Melee: axes, swords, daggers, fist weapons, staves, polearms (20) - mostly for their stats.",
    trees = {
        { name = "Beast Mastery", what = "a stronger pet plus summoned Hawks do the damage. Fastest and safest levelling.", best = "solo levelling" },
        { name = "Marksmanship", what = "your own shots hit harder; Trueshot Aura helps the whole group.", best = "dungeon / raid damage" },
        { name = "Survival", what = "traps and melee strikes (Mongoose Bite bleeds). Harder to level.", best = "PvP, if you like melee" },
    },
    builds = {
        { name = "Levelling: Beast Mastery (33/17/0)", tree = "Beast Mastery", role = "Solo levelling", levelling = true,
          why = "Maxroll's Forever levelling build: pet + two Hawks do the work.",
          stats = "Agility > Attack Power > Intellect > Stamina",
          weights = { AGI = 2.6, STR = 0.2, INT = 0.6, STA = 0.75, SPI = 0.6, AP = 1, RAP = 1, HIT = 6, CRIT = 6.7, HASTE = 6, RDPS = 14, DPS = 1.5, MP5 = 3 },
          rotation = {
              "Aspect of the Hawk on. Send the pet in, wait for it to Growl twice, then start shooting.",
              "Summon Hawk (keep two up), Aimed Shot or Multi-Shot, Arcane Shot. Serpent Sting only on long fights.",
              "Elites: Bestial Wrath + Rapid Fire. If a mob reaches you: Wing Clip or Concussive Shot and step back; Feign Death to escape.",
          },
          points = { "Deadly Aspects 5", "Improved Revive Pet 2", "Focused Fire 2", "Endurance Training 1", "Bestial Swiftness 1",
              "Pathfinding 2", "Unleashed Fury 2", "Summon Hawk 1", "Unleashed Fury 5", "Ferocity 1", "Intimidation 1",
              "Bestial Discipline 2", "Ferocity 5", "Frenzy 3", "Bestial Wrath 1", "Hawk Eye 3", "Lethal Attacks 2",
              "Careful Aim 5", "Rapid Killing 2", "Efficiency 3", "Trueshot Aura 1", "Frenzy 5", "Lethal Attacks 4" } },
        { name = "Endgame: Beast Mastery (31/20/0)", tree = "Beast Mastery", role = "Damage at 60",
          why = "Community 60 build (provisional - raids open in December). A Marksmanship raid build will probably appear later.",
          stats = "Agility > Attack Power > Crit > Intellect",
          weights = { AGI = 2.6, INT = 0.8, STA = 0.5, SPI = 0.4, AP = 1, RAP = 1, HIT = 7, CRIT = 7, HASTE = 6, RDPS = 14, DPS = 1, MP5 = 3 },
          rotation = { "Keep Hawks and your pet up, Aimed Shot / Multi-Shot / Arcane Shot on cooldown, Bestial Wrath + Rapid Fire on bosses." },
          points = { "Deadly Aspects 5", "Improved Revive Pet 2", "Focused Fire 2", "Endurance Training 1", "Bestial Swiftness 1",
              "Pathfinding 2", "Unleashed Fury 5", "Summon Hawk 1", "Ferocity 5", "Intimidation 1", "Bestial Discipline 2",
              "Frenzy 4", "Bestial Wrath 1", "Hawk Eye 3", "Lethal Attacks 5", "Careful Aim 5", "Efficiency 3", "Trueshot Aura 1",
              "Rapid Killing 2" } },
    },
    abilities = {
        { 1, "Auto Shot", "your basic shooting - stand still" },
        { 4, "Serpent Sting", "poison - only on mobs that live a while" },
        { 6, "Arcane Shot", "instant damage" },
        { 8, "Concussive Shot", "slows a mob that's running at you" },
        { 10, "Aspect of the Hawk", "keep it on in combat" },
        { 10, "Tame Beast", "get a pet at level 10 (class quest) - your pet is your tank" },
        { 12, "Mend Pet", "heal your pet" },
        { 12, "Wing Clip", "slow a mob that's hitting you, then step back" },
        { 18, "Multi-Shot", "hits several mobs (shares a cooldown with Aimed Shot)" },
        { 20, "Aimed Shot", "big hit" },
        { 20, "Freezing Trap", "freezes one extra mob - traps work in combat now" },
        { 20, "Aspect of the Cheetah", "fast travel - never in combat" },
        { 26, "Rapid Fire", "faster shooting for hard fights" },
        { 30, "Feign Death", "play dead to drop out of a fight" },
    },
    gear = {
        "Your ranged weapon first. Good ones: Barbaric Crossbow (Ragefire Chasm), Venomstrike (Wailing Caverns), Master Hunter's Rifle/Bow (Nesingwary in Stranglethorn), Golemsight Long Gun (Wetlands), Truthseeker's Bow (40, library books).",
        "Agility is king. Intellect gets better later (Careful Aim turns it into Attack Power).",
        "Keep ammo stocked (buy a quiver / ammo pouch for faster shooting).",
    },
    endgame = { "Beast Mastery is the safe choice; Marksmanship (Trueshot Aura, Sniper Shot) is the likely raid build once raids open." },
    mistakes = {
        "Taking Lone Wolf (no pet) while levelling - your pet is your tank.",
        "Shooting before your pet has the mob's attention.",
        "Staying in Aspect of the Cheetah or Pack in a fight (you get dazed).",
        "Moving all the time - Auto Shot needs you to stand still for half a second.",
    },
    forever = {
        "Aimed Shot is a normal spell at 20 (not a talent). Multi-Shot and Aimed Shot share a cooldown.",
        "New talent Summon Hawk (16-point Beast Mastery): Hawks fight next to your pet.",
        "Traps can be used in combat. Pets get stronger from YOUR gear (Attack Power and crit). New pet family: Fox.",
    },
}

---------------------------------------------------------------------------
-- PALADIN (both factions in Forever: Human, Dwarf, Undead)
---------------------------------------------------------------------------
C.PALADIN = {
    roles = "Tank, healer or melee damage",
    intro = "A holy knight in heavy armor. You put up a Seal (a buff that adds holy damage to your swings), then Judge it onto the enemy. "
        .. "You can heal yourself and others, bubble when in danger, and Lay on Hands for a full heal. Paladin changed more than any other class in Forever.",
    armor = { { 1, "Cloth" }, { 1, "Leather" }, { 1, "Mail" }, { 1, "Shields" }, { 40, "Plate (learn it at your trainer)" } },
    weapons = "One- and two-handed axes, maces and swords; polearms from 20 (new in Forever). Levelling Retribution wants a slow two-hander. Librams go in the relic slot.",
    trees = {
        { name = "Holy", what = "big heals with crits that refund mana.", best = "healing, duo levelling" },
        { name = "Protection", what = "shield tanking with strong defensive cooldowns. Very safe but slow solo.", best = "tanking, safe solo" },
        { name = "Retribution", what = "two-handed weapon plus seals and judgements for burst; Intellect becomes spell damage later.", best = "solo levelling, dungeon damage" },
    },
    builds = {
        { name = "Levelling: Retribution (12/8/31)", tree = "Retribution", role = "Solo levelling and dungeon damage", levelling = true,
          why = "Maxroll's Forever levelling build (also the usual level 60 Ret build). Names checked against the live client on 13 Nov.",
          stats = "Weapon damage (slow two-hander) > Hit > Strength > Intellect > Agility",
          weights = { STR = 2, AGI = 0.8, INT = 0.7, STA = 0.75, SPI = 0.3, AP = 1, SP = 0.6, HIT = 7, CRIT = 7, HASTE = 6, DPS = 14, MP5 = 2 },
          rotation = {
              "Blessing of Might and Retribution Aura on. Seal of Righteousness (Seal of Command once you have it and a slow weapon).",
              "Judgement and Holy Strike together, on cooldown, and keep auto-attacking. Your Seal stays up after Judgement - don't recast it.",
              "Consecration only for 3+ mobs (it costs lots of mana). In trouble: Divine Protection / Divine Shield, heal yourself, Lay on Hands.",
          },
          points = { "Benediction 5", "Conviction 3", "Sanctified Judgement 2", "Seal of Command 1", "Pursuit of Justice 2",
              "Sanctified Judgement 3", "Improved Judgement 1", "Two-Handed Weapon Specialization 3", "Sacred Arbiter 1",
              "Improved Judgement 2", "Vengeance 3", "Repentance 1", "Deflection 1", "Champion of the Light 5", "Unsealed Wrath 1",
              "Divine Strength 5", "Reverence 2", "Improved Seals 5", "Divine Intellect 5", "Precision 3" } },
    },
    abilities = {
        { 1, "Seal of Righteousness", "your basic damage Seal - keep it up" },
        { 4, "Judgement", "hits the enemy with your Seal's power; press with Holy Strike" },
        { 4, "Blessing of Might", "melee buff - keep it on" },
        { 6, "Holy Strike", "new instant strike - press on cooldown" },
        { 6, "Holy Light", "big slow heal" },
        { 6, "Divine Protection", "short invulnerability when it goes wrong" },
        { 8, "Hammer of Justice", "stun - stops a caster or runner" },
        { 10, "Lay on Hands", "full heal, 20 min cooldown" },
        { 10, "Seal of Fury", "tanking Seal (with Righteous Fury)" },
        { 16, "Retribution Aura", "damages things that hit you" },
        { 20, "Consecration", "damage around you - for packs of 3+" },
        { 20, "Flash of Light", "fast cheap heal" },
        { 34, "Divine Shield", "bubble: nothing can hurt you" },
        { 46, "Hammer of Wrath", "finisher on low-health enemies" },
    },
    gear = {
        "Retribution: a slow two-handed weapon is your biggest upgrade. Strength first; Intellect gets good once you have Champion of the Light (~35).",
        "Level 20 class quest weapon: Verigan's Fist (Alliance) / Wolfsbane (Horde). Worth chasing: Corpse Chopper (Ruins of Lordaeron), Arced War Axe (Shadowfang Keep).",
        "Protection: Stamina, Defense, Armor, shield Block - plus Spell Power for threat. Holy: Healing/Spell Power > Intellect > Crit.",
    },
    endgame = {
        "Damage: Retribution 12/8/31 (same as the levelling plan).",
        "Tank: Protection about 8/43/0 - Templar's Bulwark, Swift Judgement, Iron Creed, Holy Shield, Shieldsworn.",
        "Healer: Holy about 31/9/11 - Reverence, Illumination, Oath of Light (on the tank), Holy Shock, Light's Vigil. Dual spec at 40 lets you keep one of these next to Ret.",
    },
    mistakes = {
        "Recasting your Seal after Judgement - in Forever it stays up.",
        "Spamming Consecration and running out of mana.",
        "Using Judgement and Holy Strike at different times - press them together so your mana starts coming back sooner.",
        "Following old guides: Salvation, Twist of Light and seal-twisting are gone in Forever.",
    },
    forever = {
        "Horde can be a Paladin (Undead). New button Holy Strike (6). Seal of Fury + Righteous Fury from 10 for tanking.",
        "Judgement no longer uses up your Seal. Consecration is baseline at 20. Blessing of Kings is baseline; Salvation is removed.",
        "Lots of new talents: Templar's Bulwark, Swift Judgement, Shieldsworn (Prot), Sacred Arbiter, Champion of the Light, Unsealed Wrath (Ret), Oath of Light, Light's Vigil (Holy).",
    },
}

---------------------------------------------------------------------------
-- SHAMAN (both factions in Forever: Orc, Tauren, Troll, Windshaper Skyborne, Dwarf)
---------------------------------------------------------------------------
C.SHAMAN = {
    roles = "Healer, melee damage or ranged spell damage",
    intro = "You fight with elemental spells, a weapon buffed by an imbue, and totems you drop on the ground (each gives a buff or does something). "
        .. "Enhancement (melee) is the easy, fast way to level. Get your totems from the class quests at 4, 10, 20 and 30.",
    armor = { { 1, "Cloth" }, { 1, "Leather" }, { 1, "Shields" }, { 40, "Mail (learn it at your trainer)" } },
    weapons = "One-handed maces and staves to start; daggers, fist weapons, one- and two-handed axes and two-handed maces from weapon masters. Enhancement can use two-handers without a talent. Totems go in the relic slot.",
    trees = {
        { name = "Elemental", what = "ranged Lightning Bolt / Chain Lightning crits. Mana hungry and slower to level.", best = "dungeon / raid damage, PvP" },
        { name = "Enhancement", what = "melee with a big weapon, Stormstrike and instant Lightning Bolts (Maelstrom Weapon).", best = "solo levelling, melee damage" },
        { name = "Restoration", what = "group healing with Chain Heal, Riptide and totems.", best = "healing" },
    },
    builds = {
        { name = "Levelling: Enhancement (18/25/8)", tree = "Enhancement", role = "Solo levelling", levelling = true,
          why = "Maxroll's Forever levelling build. It was written before the 10 Nov nerfs to Stormstrike and Mental Dexterity, so Strength now matters a bit more than Intellect.",
          stats = "Weapon damage (slow two-hander) > Strength > Attack Power > Intellect",
          weights = { STR = 2, AGI = 0.8, INT = 0.6, STA = 0.75, SPI = 0.4, AP = 1, SP = 0.4, HIT = 7, CRIT = 6, HASTE = 6, DPS = 14, MP5 = 2 },
          rotation = {
              "Lightning Shield and Strength of Earth Totem up; weapon imbue on (Rockbiter, Windfury Weapon from 30).",
              "Pull with a low-rank Lightning Bolt, then melee. Stormstrike on cooldown, Earth Shock (Flame Shock on long fights).",
              "Spend Maelstrom Weapon stacks on an instant Lightning Bolt (or a heal). Fire Nova for packs if you have spare mana.",
          },
          points = { "Thundering Strikes 5", "Mental Dexterity 3", "Improved Lightning Shield 2", "Elemental Weapons 3",
              "Shamanistic Focus 1", "Anticipation 1", "Stormstrike 1", "Improved Ghost Wolf 2", "Flurry 2", "Improved Stormstrike 2",
              "Mental Quickness 2", "Spirit Weapons 1", "Concussion 5", "Elemental Devastation 3", "Call of Flame 3",
              "Elemental Focus 1", "Convection 3", "Trial by Fire 2", "Earthbound 1", "Tidal Focus 5", "Mindfulness 3" } },
    },
    abilities = {
        { 1, "Lightning Bolt", "ranged spell - pull with it" },
        { 1, "Healing Wave", "heal yourself between fights" },
        { 4, "Earth Shock", "instant damage, also interrupts a spell" },
        { 8, "Rockbiter Weapon", "weapon imbue - keep it on until Windfury Weapon" },
        { 8, "Lightning Shield", "keep it up" },
        { 10, "Flame Shock", "burn over time - only on mobs that live a while" },
        { 10, "Strength of Earth Totem", "Strength for you and your group" },
        { 10, "Searing Totem", "a little turret" },
        { 14, "Fire Nova", "damage around your fire totem - for packs" },
        { 20, "Ghost Wolf", "run faster (works indoors now)" },
        { 20, "Frost Shock", "slows a runner" },
        { 20, "Call of the Elements", "drops your whole totem set in one press" },
        { 30, "Windfury Weapon", "best melee imbue" },
        { 30, "Reincarnation", "come back to life on the spot" },
        { 40, "Chain Heal", "heals several people" },
    },
    gear = {
        "Enhancement: a slow two-handed axe or mace (more Windfury and Maelstrom procs). A one-hander + shield is safer but slower.",
        "Strength first, then Attack Power; Intellect less since the 10 Nov nerf. Mail at 40.",
        "Worth getting: Ironforge Greathammer / Axe of Orgrimmar quests; dungeons Hall of Thanes, Deadmines, Shadowfang Keep, Blackfathom Deeps.",
    },
    endgame = {
        "Melee: Enhancement about 8/35/8 - Stormstrike, Flurry, Maelstrom Weapon, Rage of the Farseer.",
        "Caster: Elemental about 31/9/11 - Lightning Overload, Call of Thunder, Lightning Mastery (needs Mindfulness and Water Shield for mana).",
        "Healer: Restoration about 0/10/41 - Riptide, Mana Tide Totem, Nature's Swiftness, Water Shield.",
    },
    mistakes = {
        "Casting too much and running out of mana - auto-attack more as Enhancement.",
        "Refreshing Flame Shock on a mob that's about to die.",
        "Chain Lightning without a Clearcasting proc (very expensive now).",
        "Following old guides: Lava Burst is gone (removed 2 Nov), Stormstrike is 100% weapon damage / 8 s now.",
    },
    forever = {
        "Alliance can be Shaman (Dwarf). Windfury and Flametongue are group totems; totem buffs last 5 minutes and reach the whole raid.",
        "Call of the Elements (20) drops a whole totem set at once. Totemic Call (24) pulls your totems to you.",
        "No Bloodlust: Rage of the Farseer is a personal speed-up. Elemental Mastery is now Lightning Mastery.",
    },
}

---------------------------------------------------------------------------
-- DRUID (Night Elf, Tauren, both Skyborne)
---------------------------------------------------------------------------
C.DRUID = {
    roles = "Tank (bear), melee damage (cat), spell damage (moonkin) or healer",
    intro = "A shapeshifter. Cat Form for melee damage, Bear Form to tank or survive, caster form to heal and cast. "
        .. "Feral (cat) is the usual way to level. Do the form quests: Bear at 10, Aquatic at 16, Cat at 20.",
    armor = { { 1, "Cloth" }, { 1, "Leather" } },
    weapons = "Daggers, fist weapons, maces, staves; polearms from 20 (new). In Forever your weapon's damage DOES count in cat and bear form, so upgrade it. Idols go in the relic slot.",
    trees = {
        { name = "Balance", what = "ranged Moonkin caster (Starfire, Wrath, Eclipse). Little AoE before Hurricane at 40.", best = "dungeon / raid damage, PvP" },
        { name = "Feral Combat", what = "cat melee damage or bear tanking with almost no downtime.", best = "solo levelling, tanking, damage" },
        { name = "Restoration", what = "heals over time - very safe, low damage.", best = "healing" },
    },
    builds = {
        { name = "Levelling: Feral cat (7/34/10)", tree = "Feral Combat", role = "Solo levelling", levelling = true,
          why = "Maxroll's Forever levelling build, names checked against the live client on 13 Nov.",
          stats = "Weapon damage > Agility > Strength > Attack Power",
          weights = { AGI = 2, STR = 1.8, STA = 0.6, INT = 0.3, SPI = 0.3, AP = 1, HIT = 7, CRIT = 7, HASTE = 5, DPS = 6, ARMOR = 0.02 },
          rotation = {
              "Before 20: Wrath and Moonfire, then finish in Bear Form to save mana. Root extra mobs with Entangling Roots.",
              "Cat: Prowl, Ravage (or Pounce), Rake, then Shred from behind / Claw from the front for combo points.",
              "Finish with Rip (long fights) or Ferocious Bite (to kill). Shifting Power refills Energy from 40.",
              "Packs: Rake each, go Bear and Swipe. Going badly: Bear Form, Frenzied Regeneration, heal in caster form.",
          },
          points = { "Furor 5", "Feral Swiftness 2", "Feral Instinct 3", "Feral Charge 1", "Sharpened Claws 2", "Shredding Attacks 2",
              "Predatory Discipline 1", "Predatory Strikes 3", "Blood Frenzy 1", "Leader of the Pack 1", "Natural Instinct 2",
              "Blood Frenzy 2", "Shredding Attacks 3", "Rend and Tear 5", "Shifting Power 1", "Heart of the Wild 5", "Naturalist 5",
              "Genesis 5", "Nature's Majesty 2", "Savage Fury 2", "Ferocity 1" } },
    },
    abilities = {
        { 1, "Wrath", "basic damage spell" },
        { 1, "Healing Touch", "big heal" },
        { 4, "Moonfire", "instant damage + burn" },
        { 4, "Rejuvenation", "heal over time" },
        { 8, "Entangling Roots", "roots an extra mob in place" },
        { 10, "Bear Form", "tank / survive (form quest at 10)" },
        { 10, "Mark of the Wild", "buff - keep it on" },
        { 12, "Regrowth", "fast heal + heal over time" },
        { 14, "Bash", "stun in bear" },
        { 16, "Swipe", "bear: hits everything in front" },
        { 20, "Cat Form", "melee damage (form quest at 20)" },
        { 24, "Rake", "cat: bleed, combo point" },
        { 28, "Rip", "cat finisher: big bleed" },
        { 30, "Shred", "cat: big hit from behind" },
        { 30, "Travel Form", "run fast outdoors" },
        { 32, "Ferocious Bite", "cat finisher: burst damage" },
        { 36, "Frenzied Regeneration", "bear: heal yourself" },
        { 40, "Innervate", "lots of mana back" },
    },
    gear = {
        "Feral: leather with Agility and Strength, and a good weapon (staff or polearm at 20) - weapon damage counts in forms in Forever.",
        "Worth chasing: Smite's Mighty Hammer (Deadmines), Fang set (Wailing Caverns), Fenrus' Hide (Shadowfang Keep), Witherbite Bracers (Ruins of Lordaeron).",
        "Balance / Restoration: Spell or Healing Power, Intellect, Spirit.",
    },
    endgame = {
        "Tank: Bear about 0/41/10 - Lacerate, Primal Bite, Thick Hide, Leader of the Pack.",
        "Healer: Restoration about 11/0/40 - Wild Growth, Bloom, Swiftmend, Nature's Swiftness.",
        "Caster: Balance about 41/0/10 - Eclipse, Nature's Grace, Moonkin Form. (A raid cat build isn't settled yet.)",
    },
    mistakes = {
        "Skipping the form quests (Bear 10, Aquatic 16, Cat 20).",
        "Not going Bear when a fight goes badly.",
        "Fighting extra mobs instead of rooting them.",
        "Following old guides: Berserk and Tiger's Fury are gone; Lacerate is a talent now.",
    },
    forever = {
        "Weapon damage counts in cat and bear form. Potions, racials and weapon enchants no longer break your form.",
        "Omen of Clarity is baseline at 20, Nature's Grasp at 10, Revive (out-of-combat resurrect) at 12.",
        "Feral has two 16-point and two 31-point talents (one bear, one cat) - you can take both. Leader of the Pack reaches the whole raid.",
    },
}

-- (abilities with a 4th value "?" have a level no Forever source confirmed - shown as "about level N")

---------------------------------------------------------------------------
-- MAGE
---------------------------------------------------------------------------
C.MAGE = {
    roles = "Ranged spell damage",
    intro = "A glass cannon: huge damage from range, very little health. Frost slows and freezes enemies so they never reach you. "
        .. "You conjure your own food and water - drink between fights instead of resting.",
    armor = { { 1, "Cloth" } },
    weapons = "Staves and wands from the start; daggers and one-handed swords from a weapon master. Off-hand items are fine. A wand is your free damage when out of mana.",
    trees = {
        { name = "Arcane", what = "mana-powered burst: stack Arcane Blast, spend with Arcane Wrath and free Arcane Missiles.", best = "dungeon / raid damage" },
        { name = "Fire", what = "crits that make Pyroblast fast; big numbers.", best = "raid damage later" },
        { name = "Frost", what = "slows, roots and Ice Lance on frozen targets. Safest by far.", best = "solo levelling, AoE farming" },
    },
    builds = {
        { name = "Levelling: Frost (0/5/46)", tree = "Frost", role = "Solo levelling", levelling = true,
          why = "wowforeverbuilds' Frost levelling order. Every guide agrees Frost is the safest and fastest way to level a mage.",
          stats = "Spell Damage / Intellect > Stamina / Spirit",
          weights = { INT = 1, SPI = 0.8, STA = 0.75, SP = 1.2, HIT = 6, CRIT = 5, HASTE = 5, MP5 = 2, ARMOR = 0.01 },
          rotation = {
              "Frostbolt from max range - it slows them, keep casting while they walk in.",
              "When they reach you: Frost Nova, step back, Ice Lance while they're frozen. Fire Blast to finish (it shares a cooldown with Ice Lance).",
              "Out of mana: wand. From 41: Ice Barrier before every pull. Drink conjured water between fights.",
          },
          points = { "Precision 3", "Improved Frostbolt 2", "Frostbite 3", "Ice Shards 2", "Ice Lance 1", "Permafrost 3", "Ice Shards 5",
              "Frost Channeling 3", "Shatter 1", "Improved Frostbolt 5", "Frost Warding 2", "Shatter 3", "Improved Frost Nova 2",
              "Cold Snap 1", "Ice Barrier 1", "Ice Block 1", "Fingers of Frost 2", "Improved Blizzard 3", "Arctic Reach 2",
              "Improved Cone of Cold 3", "Incineration 5", "Winter's Chill 3" } },
    },
    abilities = {
        { 1, "Fireball", "basic nuke at first" },
        { 1, "Frost Armor", "armor buff - keep it on" },
        { 4, "Frostbolt", "your main spell (slows the target)" },
        { 6, "Fire Blast", "instant finisher" },
        { 1, "Arcane Intellect", "Intellect buff - keep it on", "?" },
        { 10, "Frost Nova", "freezes everything near you - then step away", "?" },
        { 8, "Polymorph", "turns a second mob into a sheep", "?" },
        { 6, "Conjure Water", "make your own drinks", "?" },
        { 16, "Arcane Explosion", "hits everything around you", "?" },
        { 20, "Blink", "teleport a short way forward - escape", "?" },
        { 24, "Counterspell", "interrupt a caster", "?" },
        { 20, "Evocation", "get lots of mana back", "?" },
        { 26, "Cone of Cold", "slows everything in front of you", "?" },
        { 20, "Blizzard", "AoE for big pulls", "?" },
        { 40, "Frostfire Bolt", "new: frost + fire bolt with a burn and a slow" },
    },
    gear = {
        "Cloth with Intellect and Spell Damage. Ignore Strength and Agility.",
        "Wands: Lesser Magic Wand (Enchanting, 5) -> Greater Magic Wand (13) -> any better wand you find.",
        "Staves worth getting: Staff of Westfall, Emberstone Staff. Tailoring + Enchanting suits mages.",
    },
    endgame = {
        "Arcane about 38/10/3 - Arcane Blast, Arcane Wrath, Missile Barrage, Presence of Mind, Arcane Power.",
        "Frost about 20/0/31 - Precision, Fingers of Frost, Ice Barrier. Fire about 14/34/3 - Heating Up, Combustion. (All still theory until raids open.)",
    },
    mistakes = {
        "Spamming Arcane Blast - each stack costs double the mana.",
        "Ice Lance on targets that aren't frozen (it's only strong on frozen ones).",
        "Expecting long Blizzard / Cone of Cold kiting - both were weakened in Forever.",
        "Not putting new spells on your bars - Forever doesn't do it for you.",
    },
    forever = {
        "New: Ice Lance (Frost 11-point talent), Arcane Wrath, Heating Up, Frostfire Bolt at 40 (everyone).",
        "Comprehension: a new mini-skill - read the scrolls mobs drop (Comprehend Scroll).",
        "Precision gives hit for all your spells. Ice Block is a 16-point Frost talent now.",
    },
}

---------------------------------------------------------------------------
-- WARLOCK
---------------------------------------------------------------------------
C.WARLOCK = {
    roles = "Ranged spell damage (with a demon)",
    intro = "You curse enemies with damage-over-time spells and let a demon pet fight beside you (the Voidwalker tanks). "
        .. "Life Tap turns your health into mana, and Drain Life puts it back - so you rarely stop to rest.",
    armor = { { 1, "Cloth" } },
    weapons = "Daggers and wands from the start; one-handed swords and staves from a weapon master. Firestone / Spellstone are now weapon imbues.",
    trees = {
        { name = "Affliction", what = "damage-over-time spells and drains with lots of self-healing.", best = "solo levelling, raid damage" },
        { name = "Demonology", what = "a stronger, tougher demon and Soul Link.", best = "safe solo, PvP" },
        { name = "Destruction", what = "Fire and Shadow nukes, Conflagrate burst, Incinerate.", best = "dungeon damage, PvP burst" },
    },
    builds = {
        { name = "Levelling: Affliction (40/0/11)", tree = "Affliction", role = "Solo levelling", levelling = true,
          why = "kami-labs' Forever levelling build (12 Nov). Lots of DoTs, Siphon Life and Wrack keep you alive.",
          stats = "Spell / Shadow Damage > Spirit > Intellect > Stamina",
          weights = { INT = 0.8, SPI = 1, STA = 0.9, SP = 1.2, HIT = 6, CRIT = 4, HASTE = 4, MP5 = 2, ARMOR = 0.01 },
          rotation = {
              "Send your demon in. Bane of Agony, Corruption, then Immolate on mobs that will live (Siphon Life once you have it).",
              "Wand before ~30; after that Drain Life (Life Tap first if your health is full).",
              "From 40: all DoTs first, then channel Wrack. Life Tap whenever your health is higher than your mana - then eat, don't drink.",
              "Second mob: Fear it (don't hit a Feared mob, it breaks the Fear).",
          },
          points = { "Improved Corruption 5", "Suppression 4", "Improved Drains 3", "Fel Concentration 3", "Soul Harvest 2",
              "Nightfall 2", "Grim Reach 1", "Siphon Life 1", "Soul Siphon 3", "Grim Reach 2", "Shadow Mastery 5", "Wrack 1",
              "Improved Bane of Agony 2", "Pandemic 3", "Amplify Curse 1", "Curse of Exhaustion 1", "Malevolence 2",
              "Improved Shadow Bolt 5", "Bane 5", "Shadowburn 1" } },
    },
    abilities = {
        { 1, "Shadow Bolt", "basic nuke" },
        { 1, "Demon Skin", "armor buff - keep it on", "?" },
        { 1, "Summon Imp", "your first demon", "?" },
        { 4, "Corruption", "damage over time - put it on everything", "?" },
        { 2, "Bane of Agony", "damage over time (was Curse of Agony)", "?" },
        { 6, "Life Tap", "health into mana", "?" },
        { 10, "Summon Voidwalker", "tank demon - use it while levelling", "?" },
        { 8, "Fear", "sends an extra mob running", "?" },
        { 14, "Drain Life", "steal health - your main filler later", "?" },
        { 10, "Drain Soul", "on a dying mob for a Soul Shard", "?" },
        { 10, "Create Healthstone", "free emergency heal", "?" },
        { 20, "Summon Sayaad", "damage demon (was Succubus)", "?" },
        { 30, "Siphon Life", "talent: drain over time" },
        { 40, "Wrack", "talent: makes your DoTs tick faster" },
    },
    gear = {
        "Cloth with Spell / Shadow Damage, Spirit (Life Tap now scales with it), Stamina.",
        "Wands until ~30: Lesser / Greater Magic Wand (Enchanting), Gravestone Scepter (Blackfathom Deeps quest), Dancing Flame (26, Horde quest).",
        "Warlock-only quest: Staff or Orb of Soran'ruk - take one. Tailoring robes: Filigreed Shadow Gown (Affliction).",
    },
    endgame = {
        "Affliction about 40/11/0 - Pandemic, Wrack, Soul Siphon, Demonic Sacrifice.",
        "Demonology 0/31/20 (Demonic Pact) or Destruction 9/11/31 (Incinerate, Bane of Havoc). All still theory until raids open.",
    },
    mistakes = {
        "Drain Life at full health, or wanding with full mana.",
        "Putting DoTs on mobs that are about to die.",
        "Hitting a Feared mob (breaks the Fear) or Curse of Recklessness on one you want to Fear.",
        "Forgetting Demon Skin / Armor and new demon spell ranks.",
    },
    forever = {
        "Curse of Agony is now Bane of Agony - one Bane AND one Curse can be on a target. Curse of Shadows is gone.",
        "Life Tap scales with Spirit. Demons get stronger from your stats. Succubus is called Sayaad.",
        "New talents: Wrack (Affliction 31), Demonic Pact (Demonology 31), Bane of Havoc and Incinerate (Destruction). Free mount quest at 40 from Strahad Farsan in Ratchet.",
    },
}

---------------------------------------------------------------------------
-- PRIEST
---------------------------------------------------------------------------
C.PRIEST = {
    roles = "Healer, or ranged shadow damage",
    intro = "The best pure healer, or a Shadow caster with damage-over-time and Mind Flay. Shield yourself before every fight so casts aren't interrupted. "
        .. "Level as Shadow (or Discipline with a wand) - Holy is very slow solo. Your race gives you extra priest spells.",
    armor = { { 1, "Cloth" } },
    weapons = "One-handed maces and wands from the start; daggers and staves from a weapon master. The wand is your most important item until about 40.",
    trees = {
        { name = "Discipline", what = "shields, Penance and a stronger wand.", best = "tank healing, low-downtime levelling" },
        { name = "Holy", what = "big group and raid healing (Prayer of Mending).", best = "raid healing" },
        { name = "Shadow", what = "damage over time, Mind Flay and self-healing; Shadowform at 31.", best = "solo levelling, dungeon damage" },
    },
    builds = {
        { name = "Levelling: Shadow (15/3/33)", tree = "Shadow", role = "Solo levelling", levelling = true,
          why = "kami-labs' Forever Shadow build (from Mobalytics). Discipline with a wand is the other good way to level.",
          stats = "Shadow / Spell Damage and wand > Spirit > Intellect > Stamina",
          weights = { INT = 0.8, SPI = 1, STA = 0.75, SP = 1.2, HEAL = 0.2, HIT = 6, CRIT = 4, HASTE = 4, MP5 = 2, ARMOR = 0.01 },
          rotation = {
              "Power Word: Shield yourself, Mind Blast, Shadow Word: Pain.",
              "Mind Flay or wand to finish. Mind Blast on cooldown.",
              "Shadow Word: Death only when it will kill (it costs 30% of your health if it doesn't). Devouring Plague when you have mana.",
          },
          points = { "Wand Specialization 2", "Spirit Tap 5", "Improved Shadow Word: Pain 2", "Shadow Reach 2", "Shadow Focus 3",
              "Mind Flay 1", "Improved Mind Flay 2", "Vampiric Embrace 1", "Shadow Weaving 3", "Shadow Focus 5", "Silence 1",
              "Devouring Contagion 2", "Improved Mind Blast 1", "Early Demise 2", "Darkness 5", "Shadowform 1", "Twilight Focus 3",
              "Twin Disciplines 5", "Mental Strength 4", "Meditation 3", "Inner Focus 1" } },
    },
    abilities = {
        { 1, "Smite", "basic holy damage" },
        { 1, "Lesser Heal", "heal" },
        { 1, "Power Word: Fortitude", "Stamina buff - keep it on everyone" },
        { 4, "Shadow Word: Pain", "damage over time" },
        { 6, "Power Word: Shield", "shield yourself before each fight", "?" },
        { 10, "Mind Blast", "big shadow hit - on cooldown" },
        { 8, "Renew", "heal over time", "?" },
        { 12, "Inner Fire", "armor buff - keep it on" },
        { 14, "Psychic Scream", "scares mobs away - careful near other packs", "?" },
        { 8, "Fade", "drop threat in a group", "?" },
        { 20, "Flash Heal", "fast heal", "?" },
        { 20, "Devouring Plague", "strong damage over time (everyone has it in Forever)" },
        { 20, "Fear Ward", "blocks one fear" },
        { 30, "Divine Spirit", "Spirit buff (baseline now)" },
        { 32, "Shadow Word: Death", "finisher - only use it when it kills" },
    },
    gear = {
        "The wand is your biggest upgrade until ~40: Lesser / Greater Magic Wand (Enchanting), Sizzle Stick (Wailing Caverns quest), Gravestone Scepter (Blackfathom Deeps quest), Charred Wand (Hillsbrad quest), Dancing Flame (Arathi).",
        "Cloth with Spell Damage / Intellect / Spirit. Healing: Healing Power > Spirit > Intellect.",
        "Tailoring + Enchanting suits priests.",
    },
    endgame = {
        "Holy healer about 18/33/0 - Holy Binding, Spirit of Redemption, Prayer of Mending.",
        "Discipline healer about 32/19/0 - Penance, Soul Warding, Divine Aegis, Power Infusion.",
        "Shadow about 18/0/33 - Shadowform, Darkness, Shadow Weaving. (Theory until raids open.)",
    },
    mistakes = {
        "Levelling as Holy - kills are very slow.",
        "Shadow Word: Death as a filler (30% of your health when it doesn't kill).",
        "Only ever casting Greater Heal - you run out of mana; mix your heals.",
        "Psychic Scream near other packs - they run into more mobs.",
    },
    forever = {
        "Every priest gets Fear Ward and Devouring Plague at 20, Divine Spirit at 30 and Shadow Word: Death at 32. Gnomes can be priests.",
        "Racial priest spells changed (e.g. Human Divine Grace, Dwarf Chastise, Gnome Contingency Plan, Undead Dark Sacrifice).",
        "New talents: Penance and Soul Warding (Discipline), Holy Binding and Prayer of Mending (Holy). Shadowform lets you cast any non-healing spell.",
    },
}
