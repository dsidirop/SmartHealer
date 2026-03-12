--Original idea of this addon is based on Ogrisch's LazySpell

local MAJOR_VERSION = "SmartHealer-1.2"
local MINOR_VERSION = "$Revision: 100 $"

-- This ensures the code is only executed if the libary doesn't already exist, or is a newer version
if not AceLibrary then error(MAJOR_VERSION .. " requires AceLibrary") end
if not AceLibrary:IsNewVersion(MAJOR_VERSION, MINOR_VERSION) then return end

if not AceLibrary:HasInstance("AceDB-2.0") then error(MAJOR_VERSION .. " requires AceDB-2.0") end
if not AceLibrary:HasInstance("AceHook-2.1") then error(MAJOR_VERSION .. " requires AceHook-2.1") end
if not AceLibrary:HasInstance("AceAddon-2.0") then error(MAJOR_VERSION .. " requires AceAddon-2.0") end
if not AceLibrary:HasInstance("AceConsole-2.0") then error(MAJOR_VERSION .. " requires AceConsole-2.0") end

if not AceLibrary:HasInstance("HealComm-1.1") then error(MAJOR_VERSION .. " requires HealComm-1.1") end
if not AceLibrary:HasInstance("SpellCache-1.0") then error(MAJOR_VERSION .. " requires SpellCache-1.0") end
if not AceLibrary:HasInstance("ItemBonusLib-1.0") then error(MAJOR_VERSION .. " requires ItemBonusLib-1.0") end

local _smartHealer = AceLibrary("AceAddon-2.0"):new("AceHook-2.1", "AceConsole-2.0", "AceDB-2.0")

_smartHealer:RegisterDB("SmartHealerDB")

_smartHealer:RegisterDefaults("account", {
    overheal = 1, -- means heal exactly the missing_hp and only that   (btw should have been called missing_hp_percentage_multiplier)

    minimumOverheal = 0.1, -- means healing only 20% of the missing_hp
    maximumOverheal = 2.2, -- means overheal the missing_hp by 120% (by healing 220% of the missing_hp)

    interpretSpellRanksAsMaxNotMin = true,

    categories = {
        ["maintanks"] = {
            overheal = 1.25,
            categoryName = "maintanks",
        },
        ["offtanks"] = {
            overheal = 1.20,
            categoryName = "offtanks",
        },
        ["melees"] = {
            overheal = 1.15,
            categoryName = "melees",
        },
    },

    registeredPlayers = {
        -- ["playerName"] = categoryConfig        
    },
})

local libHC = AceLibrary("HealComm-1.1")
local libIB = AceLibrary("ItemBonusLib-1.0")
local libSC = AceLibrary("SpellCache-1.0")

local _sessionOverhealingDelta = 0

local function _strtrim(input)
    return strmatch(input, '^%s*(.*%S)') or ''
end

local function IsTruthy(value)
    local type = type(value)
    if type == "boolean" then
        -- value is already a boolean  nothing to do 
        return value
    end

    if type == "string" then
        value = strlower(_strtrim(value))
        return value == "true" or value == "1" or value == "y" or value == "yes"
    end

    if type == "number" then
        return value >= 1
    end

    return nil -- invalid value gets mapped to nil which acts like falsy
end

local function IsOptionallyTruthy(value, defaultValue)
    if value == nil or value == "" then
        -- value is an optional parameter   if not specified then default to defaultValue
        return defaultValue
    end

    value = IsTruthy(value)
    if value == nil then
        return defaultValue
    end

    return value
end

local _pfUIQuickCast_OnHeal_orig
function _smartHealer:OnEnable()
    if Clique and Clique.CastSpell then
        self:Hook(Clique, "CastSpell", "Clique_CastSpell")
    end

    if CM and CM.CastSpell then
        self:Hook(CM, "CastSpell", "CM_CastSpell")
    end

    if pfUI and pfUI.uf and pfUI.uf.ClickAction then
        self:Hook(pfUI.uf, "ClickAction", "pfUI_ClickAction")
    end

    if SlashCmdList and SlashCmdList.PFCAST then
        self:Hook(SlashCmdList, "PFCAST", "pfUI_PFCast")
    end

    if pfUIQuickCast and pfUIQuickCast.OnHeal then
        self:Hook(pfUIQuickCast, "OnHeal", "pfUIQuickCast_OnHeal") -- wires up our interceptor _smartHealer:pfUIQuickCast_OnHeal()

        _pfUIQuickCast_OnHeal_orig = self.hooks[pfUIQuickCast]["OnHeal"]
    end

    self:RegisterChatCommand({ "/heal" }, function(arg)
        self:CastHeal(arg)
    end, "SMARTHEALER")

    self:RegisterChatCommand({ "/sh_overheal" }, function(arg)
        local category, substitutionsCount1 = string.gsub(arg, "^%s*(%S+)%s+(%S+)%s*$", "%1")
        local overheal, substitutionsCount2 = string.gsub(arg, "^%s*(%S+)%s+(%S+)%s*$", "%2")

        if substitutionsCount1 == 1 then
            self:ConfigureOverhealing(category, overheal)
            return
        end

        category = nil
        overheal, substitutionsCount2 = string.gsub(arg, "^%s*(%S+)%s*$", "%1")
        if substitutionsCount2 == 1 then
            self:ConfigureOverhealing(overheal) -- set the default overhealing multiplier
            return
        end

        self:PrintCurrentConfiguration()
    end, "SMARTOVERHEALER")

    self:RegisterChatCommand({ "/sh_toggle_player_in_category" }, function(arg)
        local category, substitutionsCount1 = string.gsub(arg, "^%s*(%S+)%s+(%S+)%s*$", "%1")
        local playerName, _ = string.gsub(arg, "^%s*(%S+)%s+(%S+)%s*$", "%2")

        if substitutionsCount1 == 1 then
            self:TogglePlayerInCategory(category, playerName)
            return
        end

        self:TogglePlayerInCategory(arg) -- will get the player name from the mouseover target
    end, "SMARTHEALERTOGGLEPLAYERINCATEGORY")

    self:RegisterChatCommand({ "/sh_overheal_global_maximum" }, function(value)
        self:SetOverhealGlobalMaximum(value)
    end, "SMARTHEALEROVERHEALGLOBALMAXIMUM")

    self:RegisterChatCommand({ "/sh_overheal_global_minimum" }, function(value)
        self:SetOverhealGlobalMinimum(value)
    end, "SMARTHEALEROVERHEALGLOBALMINIMUM")

    self:RegisterChatCommand({ "/sh_overheal_increment" }, function(value)
        self:IncrementSessionOverhealDelta(value)
    end, "SMARTHEALEROVERHEALINCREMENT")

    self:RegisterChatCommand({ "/sh_overheal_decrement" }, function(value)
        self:DecrementSessionOverhealDelta(value)
    end, "SMARTHEALEROVERHEALDECREMENT")

    self:RegisterChatCommand({ "/sh_reset_all_categories" }, function()
        self:ResetAllCategoriesToDefaultOnes()
    end, "SMARTHEALERRESETALLCATEGORIES")

    self:RegisterChatCommand({ "/sh_delete_category" }, function(category)
        self:DeleteCategory(category)
    end, "SMARTHEALERDELETECATEGORY")

    self:RegisterChatCommand({ "/sh_clear_players_registry" }, function(optionalCategory)
        self:ClearRegistry(optionalCategory)
    end, "SMARTHEALERCLEARPLAYERSREGISTRY")

    self:RegisterChatCommand({ "/sh_interpret_spell_ranks_as_max_not_min" }, function(value)
        self:InterpretSpellRanksAsMaxNotMin(value)
    end, "SMARTHEALERINTERPRETSPELLRANKSASMAXNOTMIN")

    self:Print('loaded')
end

-------------------------------------------------------------------------------
-- Handler function for /heal <spell_name>[, overheal_multiplier]
-------------------------------------------------------------------------------
-- Function automatically choose which rank of heal will be casted based on
-- amount of missing life.
--
-- NOTE: Argument "spellName" should be always heal and shouldn't contain rank.
-- If there is a rank, function won't scale it. It means that "Healing Wave"
-- will use rank as needed, but "Healing Wave(Rank 3)" will always cast rank 3.
-- Argument "spellName" can contain overheal multiplier information separated
-- by "," or ";" and it should be either number (1.1) or percentage (110%).
--
-- Examples:
-- _smartHealer:CastSpell("Healing Wave")			--/heal Healing Wave
-- _smartHealer:CastSpell("Healing Wave, 1.15")		--/heal Healing Wave, 1.15
-- _smartHealer:CastSpell("Healing Wave;120%")		--/heal Healing Wave;120%
-------------------------------------------------------------------------------
function _smartHealer:CastHeal(spellName)
    if not spellName or string.len(spellName) == 0 or type(spellName) ~= "string" then
        return
    end

    spellName = string.gsub(_strtrim(spellName), "%s+", " ") -- trim the spellname and then replace all space character with a single space character

    local _, _, explicitOverhealMultiplier = string.find(spellName, "[,;]%s*(.-)$") -- tries to find overheal multiplier (number after spell name, separated by "," or ";")

    local possibleExplicitOverheal
    if explicitOverhealMultiplier then
        local _, _, percent = string.find(explicitOverhealMultiplier, "(%d+)%%")
        if percent then
            possibleExplicitOverheal = tonumber(percent) / 100
        else
            possibleExplicitOverheal = tonumber(explicitOverhealMultiplier)
        end

        spellName = string.gsub(spellName, "[,;].*", "")     --removes everything after first "," or ";"
    end

    local spell, rank = libSC:GetRanklessSpellName(spellName)
    local unit, onSelf

    if UnitExists("target") and UnitCanAssist("player", "target") then
        unit = "target"
    end

    if unit == nil then
        if GetCVar("autoSelfCast") == "1" then
            unit = "player"
            onSelf = true
        else
            return
        end
    end

    if spell and rank == nil and libHC.Spells[spell] then
        rank = self:GetOptimalRank(spell, unit, possibleExplicitOverheal)
        if rank then
            spellName = libSC:GetSpellNameText(spell, rank)
        end
    end

    --self:Print("spellname: ", spellName)

    CastSpellByName(spellName, onSelf)

    if UnitIsUnit("player", unit) then
        if SpellIsTargeting() then
            SpellTargetUnit(unit)
        end
        if SpellIsTargeting() then
            SpellStopTargeting()
        end
    end
end

function _smartHealer:getUnitIdFromMouseHoverOverPartyOrRaidMember()
    local frame = GetMouseFocus()
    if frame.label and frame.id then
        return frame.label .. frame.id
    end

    return nil
end

-------------------------------------------------------------------------------------------
-- Handler function for /sh_toggle_player_in_category <category> [<optional_player_name>]
-------------------------------------------------------------------------------------------
-- PLaces the given player in the specified category (if the player is already in another
-- category he will get removed from that one).
--
-- If the player is already in the category specified then he's removed from it.
--
-- If no player name is specified, then the player that's currently being hovered over is
-- selected.
--
-------------------------------------------------------------------------------
function _smartHealer:TogglePlayerInCategory(categoryName, optionalPlayerName)
    categoryName = _strtrim(categoryName or "")
    if categoryName == "" then
        self:Print(" [ERROR] Category name not specified")
        return
    end

    local categoryConfig = self.db.account.categories[categoryName]
    if not categoryConfig then
        self:Print(" [ERROR] Category '", categoryName, "' not found")
        return
    end

    local playerName = _strtrim(optionalPlayerName or "")
    if playerName == "" then
        local mouseHoverOverUnitId = self:getUnitIdFromMouseHoverOverPartyOrRaidMember()
        if mouseHoverOverUnitId == nil then
            self:Print(" [INFO] No explicit player-name specified and no party/raid member is currently being hovered over with the mouse - nothing to do ...")
            return
        end

        playerName = UnitName(mouseHoverOverUnitId)
    end

    if not playerName or playerName == "" then
        self:Print(" [ERROR] Player not specified")
        return
    end

    local preExistingCategoryConfig = self:TryRemovePlayerFromPreExistingCategory(playerName)
    if preExistingCategoryConfig ~= nil and preExistingCategoryConfig.categoryName == categoryName then
        self:Print("[-] Removed '", playerName, "' from category '", preExistingCategoryConfig.categoryName, "'")
        return
    end

    self.db.account.registeredPlayers[playerName] = categoryConfig

    self:Print((preExistingCategoryConfig ~= nil and "[->] Moved" or "[+] Added"), " '", playerName, "' to category '", categoryName, "'")
end

-- utility function to remove a player from a category
function _smartHealer:TryRemovePlayerFromPreExistingCategory(playerName)
    if not playerName or playerName == "" then
        self:Print(" [ERROR] Player name not specified")
        return nil
    end

    local categoryConfig = self.db.account.registeredPlayers[playerName]
    if categoryConfig == nil then
        return nil
    end

    self.db.account.registeredPlayers[playerName] = nil

    return categoryConfig
end

-------------------------------------------------------------------------------
-- Handler function for /sh_overheal [<category>] <overheal_multiplier>
-------------------------------------------------------------------------------
-- Sets the overheal multiplier% for the specified category of players. If only the
-- multiplier% is specified then it sets the default overheal-multiplier%.
-- If no argument is specified, it prints the current overheal multiplier%.
--
-- Examples:
--
-- /sh_overheal 1.15   -- sets the default overheal multiplier to 115%
-- /sh_overheal 115%   -- same as above
--
-- /sh_overheal maintanks 1.25   -- sets the overheal multiplier for maintanks to 115%
-- /sh_overheal maintanks 125%   -- same as above
--
-- /sh_overheal offtanks 1.15   -- sets the overheal multiplier for offtanks to 115%
-- /sh_overheal offtanks 115%   -- same as above
--
-- /sh_overheal     -- prints the current overheal multiplier for all categories
--
-------------------------------------------------------------------------------
function _smartHealer:ConfigureOverhealing(categoryName, overheal)
    if not overheal or overheal == "" then
        overheal = categoryName
    end

    if overheal and type(overheal) == "string" then
        overheal = _strtrim(overheal)

        local _, _, percent = string.find(overheal, "(%d+)%%")
        if percent then
            overheal = tonumber(percent) / 100
        else
            overheal = tonumber(overheal)
        end
    end

    if type(overheal) ~= "number" then
        self:Print(" [ERROR] Invalid overheal multiplier supplied (type '", type(overheal), "' is not a string-number or a number)")
        return
    end

    overheal = math.floor(overheal * 1000 + 0.5) / 1000

    categoryName = _strtrim(categoryName or "")
    if categoryName == "" then
        self.db.account.overheal = overheal
        return
    end

    self.db.account.categories[categoryName] = self.db.account.categories[categoryName] or {
        categoryName = categoryName,
        overheal = 1
    }

    self.db.account.categories[categoryName].overheal = overheal
end

local maxBuffs = 32;

function _smartHealer:GetDefaultOverhealing()
    return self.db.account.overheal + _sessionOverhealingDelta
end

function _smartHealer:GetProperOverhealingForPlayer(playerName)
    local assignedCategoryConfig = self.db.account.registeredPlayers[playerName]
    if assignedCategoryConfig and assignedCategoryConfig.overheal ~= nil then
        -- self:Print(" [DEBUG] Using overheal multiplier '", overheal, "' for player '", playerName, "' from category '", assignedCategoryConfig.categoryName, "'")

        return assignedCategoryConfig.overheal + _sessionOverhealingDelta
    end

    local overheal = self:GetDefaultOverhealing()
    -- self:Print(" [DEBUG] Using default overheal multiplier '", overheal, "' for player '", playerName, "' based on the default overhealing value.")

    return overheal
end

-------------------------------------------------------------------------------
-- Handler function for /sh_overheal (without any parameters)
-------------------------------------------------------------------------------
function _smartHealer:PrintCurrentConfiguration()
    self:Print("Overheal multipliers:")
    self:Print("- default: ", self:GetDefaultOverhealing(), "(", self:GetDefaultOverhealing() * 100, "%)")
    for categoryName, _ in pairs(self.db.account.categories) do
        local playerNamesForCategory = {}
        for playerName, categoryConfig in pairs(self.db.account.registeredPlayers) do
            if categoryConfig.categoryName == categoryName then
                table.insert(playerNamesForCategory, playerName)
            end
        end

        self:Print(
                "- category '", categoryName, "': ",
                self:GetOverhealingForCategory(categoryName), "(", self:GetOverhealingForCategory(categoryName) * 100, "%) -> ",
                table.getn(playerNamesForCategory) == 0
                        and "(no players registered)"
                        or table.concat(playerNamesForCategory, ", ")
        )
    end

    self:Print("")
    self:Print("Global overheal [min, max]: [", self.db.account.minimumOverheal, ", ", self.db.account.maximumOverheal, "]")
end

-------------------------------------------------------------------------------
-- Handler function for /sh_overheal_global_maximum <value>
-------------------------------------------------------------------------------
function _smartHealer:SetOverhealGlobalMaximum(value)
    value = tonumber(value)
    if value < 0 then
        self:Print(" [ERROR] Value must be a positive number")
        return
    end

    self.db.account.maximumOverheal = value
end

-------------------------------------------------------------------------------
-- Handler function for /sh_overheal_global_minimum <value>
-------------------------------------------------------------------------------
function _smartHealer:SetOverhealGlobalMinimum(value)
    value = tonumber(value)
    if value < 0 then
        self:Print(" [ERROR] Value must be a positive number")
        return
    end

    self.db.account.minimumOverheal = value
end

-------------------------------------------------------------------------------
-- Handler function for /sh_overheal_increment <value>
-------------------------------------------------------------------------------
function _smartHealer:IncrementSessionOverhealDelta(value)
    value = value == nil
            and 0.1
            or value

    value = tonumber(value)
    if value < 0 then
        self:Print(" [ERROR] Value must be a positive number")
        return
    end

    local newSessionOverhealingDelta = _sessionOverhealingDelta + value
    newSessionOverhealingDelta = math.abs(newSessionOverhealingDelta - 0.001) < 0.01
            and 0
            or newSessionOverhealingDelta

    if self.db.account.overheal + newSessionOverhealingDelta > self.db.account.maximumOverheal then
        self:Print(" [ERROR] Cannot exceed max-overhealing-multiplier value '", self.db.account.maximumOverheal, "'")
        return
    end

    _sessionOverhealingDelta = newSessionOverhealingDelta

    self:Print(" [INFO] Default overhealing-multiplier incremented to ", self:GetDefaultOverhealing(), " (mod: ", _sessionOverhealingDelta, ")")
end

-------------------------------------------------------------------------------
-- Handler function for /sh_overheal_decrement <value>
-------------------------------------------------------------------------------
function _smartHealer:DecrementSessionOverhealDelta(value)
    value = value == nil
            and 0.1
            or value

    value = tonumber(value)
    if value < 0 then
        self:Print(" [ERROR] Value must be a positive number")
        return
    end

    value = -1 * value

    local newSessionOverhealingDelta = _sessionOverhealingDelta + value
    newSessionOverhealingDelta = math.abs(newSessionOverhealingDelta - 0.001) < 0.01
            and 0
            or newSessionOverhealingDelta

    if self.db.account.overheal + newSessionOverhealingDelta < self.db.account.minimumOverheal then
        self:Print(" [ERROR] Cannot exceed min-overhealing-multiplier value '", self.db.account.minimumOverheal, "'")
        return
    end

    _sessionOverhealingDelta = newSessionOverhealingDelta

    self:Print(" [INFO] Default overhealing multiplier decremented to ", self:GetDefaultOverhealing(), " (mod: ", _sessionOverhealingDelta, ")")
end

-------------------------------------------------------------------------------
-- Handler function for /sh_reset_all_categories
-------------------------------------------------------------------------------
function _smartHealer:ResetAllCategoriesToDefaultOnes()
    self:ClearRegistry() -- remove all players from all categories

    self.db.account.categories = {
        ["maintanks"] = {
            overheal = 1.25,
            categoryName = "maintanks",
        },
        ["offtanks"] = {
            overheal = 1.20,
            categoryName = "offtanks",
        },
        ["melees"] = {
            overheal = 1.15,
            categoryName = "melees",
        },
    }
end

-------------------------------------------------------------------------------
-- Handler function for /sh_interpret_spell_ranks_as_max_not_min <true/false>
-------------------------------------------------------------------------------
function _smartHealer:InterpretSpellRanksAsMaxNotMin(value)
    value = IsOptionallyTruthy(value, true)
    if value == nil then
        self:Print(" [ERROR] Invalid value specified")
        return
    end

    self.db.account.interpretSpellRanksAsMaxNotMin = value
end

-------------------------------------------------------------------------------
-- Handler function for /sh_delete_category <category>
-------------------------------------------------------------------------------
function _smartHealer:DeleteCategory(category)
    category = _strtrim(category)
    if category == "" then
        self:Print(" [ERROR] Category name not specified")
        return
    end

    self.db.account.categories[category] = nil
end

-------------------------------------------------------------------------------
-- Handler function for /sh_clear_players_registry [<category>]
-------------------------------------------------------------------------------
function _smartHealer:ClearRegistry(optionalCategoryName)
    optionalCategoryName = _strtrim(optionalCategoryName or "")
    if optionalCategoryName == "" then
        self.db.account.registeredPlayers = {}
        self:Print(" [INFO] All players removed from all categories")
        return
    end

    for playerName, categoryConfig in pairs(self.db.account.registeredPlayers) do
        if categoryConfig.categoryName == optionalCategoryName then
            self.db.account.registeredPlayers[playerName] = nil
        end
    end

    self:Print(" [INFO] All players removed from category '", optionalCategoryName, "'")
end

-------------------------------------------------------------------------------
-- Function selects optimal spell rank to cast based on unit's missing HP
-------------------------------------------------------------------------------
-- spell	                - spell name to cast ("Healing Wave")
-- unit	 	                - unitId ("player", "target", ...)
-- possibleExplicitOverheal	- overheal multiplier. If nil, then using self.db.account.overheal.
-------------------------------------------------------------------------------
function _smartHealer:GetOptimalRank(spell, unit, possibleExplicitOverheal)
    if libSC.data[spell] == nil then
        self:Print("[ERROR] Smartheal spell-registry doesn't contain spell '", spell, "'")
        return
    end
    local bonus, power, mod
    if TheoryCraft == nil then
        bonus = tonumber(libIB:GetBonus("HEAL"))
        power, mod = libHC:GetUnitSpellPower(unit, spell)
        local buffpower, buffmod = libHC:GetBuffSpellPower()
        bonus = bonus + buffpower
        mod = mod * buffmod
    end

    local missing = UnitHealthMax(unit) - UnitHealth(unit)
    local max_rank = tonumber(libSC.data[spell].Rank)

    local rank = max_rank
    local overheal = possibleExplicitOverheal
    if overheal == nil then
        overheal = self:GetProperOverhealingForPlayer(UnitName(unit))
    end

    local mana = UnitMana("player")
    for i = max_rank, 1, -1 do
        spellData = TheoryCraft ~= nil and TheoryCraft_GetSpellDataByName(spell, i)
        if spellData then
            if mana >= spellData.manacost then
                if spellData.averagehealnocrit > (missing * overheal) then
                    rank = i
                else
                    break
                end
            else
                rank = i > 1 and i - 1 or 1
            end
        else
            if libHC.Spells[spell] and libHC.Spells[spell][i] then
                local heal = (libHC.Spells[spell][i](bonus) + power) * mod -- This is line 184
                if heal > (missing * overheal) then
                    rank = i
                else
                    break
                end
            else
                -- If we get here, it means the library is missing data for this spell.
                -- We can't continue, so we break out of the loop.
                self:Print("Warning: libHC missing data for " .. spell .. " Rank " .. i)
                break
            end
        end
    end
	
	-- Why does this API have no logical way to check if you have a specific buff?
	index = 1
	while (index <= maxBuffs) do
		bIndex, _ = GetPlayerBuff(index, "HELPFUL|PASSIVE");
		icon = GetPlayerBuffTexture(bIndex);
		if (icon ~= nil) then
			-- I hate this. This is the icon Clearcasting uses.
			if (icon == "Interface\\Icons\\Spell_Shadow_ManaBurn") then
				rank = max_rank
			end
		end
		index = index + 1
	end
	
    return rank
end

-------------------------------------------------------------------------------
-- Support for Clique
-------------------------------------------------------------------------------
function _smartHealer:Clique_CastSpell(clique, spellName, unit)
    unit = unit or clique.unit

    if UnitExists(unit) then
        local spell, rank = libSC:GetRanklessSpellName(spellName)

        if spell and rank == nil and libHC.Spells[spell] then
            rank = self:GetOptimalRank(spellName, unit)
            if rank then
                spellName = libSC:GetSpellNameText(spell, rank)
            end
        end
    end

    self.hooks[Clique]["CastSpell"](clique, spellName, unit)
end

-------------------------------------------------------------------------------
-- Support for ClassicMouseover
-------------------------------------------------------------------------------
function _smartHealer:CM_CastSpell(cm, spellName, unit)
    if UnitExists(unit) then
        local spell, rank = libSC:GetRanklessSpellName(spellName)

        if spell and rank == nil and libHC.Spells[spell] then
            rank = self:GetOptimalRank(spellName, unit)
            if rank then
                spellName = libSC:GetSpellNameText(spell, rank)
            end
        end
    end

    self.hooks[CM]["CastSpell"](cm, spellName, unit)
end

-------------------------------------------------------------------------------
-- Support for pfUI Click-Casting
-------------------------------------------------------------------------------
function _smartHealer:pfUI_ClickAction(pfui_uf, button)
    local spellName = ""
    local key = "clickcast"

    if button == "LeftButton" then
        local unit = (this.label or "") .. (this.id or "")

        if UnitExists(unit) then
            if this.config.clickcast == "1" then
                if IsShiftKeyDown() then
                    key = key .. "_shift"
                elseif IsAltKeyDown() then
                    key = key .. "_alt"
                elseif IsControlKeyDown() then
                    key = key .. "_ctrl"
                end

                spellName = pfUI_config.unitframes[key]

                if spellName ~= "" then
                    local spell, maxDesiredRank = libSC:GetRanklessSpellName(spellName)

                    if spell and maxDesiredRank == nil and libHC.Spells[spell] then
                        local optimalRank = self:GetOptimalRank(spellName, unit)
                        if optimalRank then
                            if maxDesiredRank ~= nil then
                                -- if the user has specified a rank then consider it as the max possible rank
                                optimalRank = math.min(optimalRank, maxDesiredRank)
                            end

                            pfUI_config.unitframes[key] = libSC:GetSpellNameText(spell, optimalRank)
                        end
                    end
                end
            end
        end
    end

    self.hooks[pfUI.uf]["ClickAction"](pfui_uf, button)

    if spellName ~= "" then
        pfUI_config.unitframes[key] = spellName
    end
end

-------------------------------------------------------------------------------
-- Support for pfUI /pfcast and /pfmouse commands
-------------------------------------------------------------------------------

-- Inspired by how pfui deduces the intended target inside the implementation of /pfcast
-- Must be kept in sync with the pfui codebase   otherwise there might be cases where the
-- wrong target is assumed here thus leading to wrong healing rank calculations

-- Prepare a list of units that can be used via SpellTargetUnit
local st_units = { [1] = "player", [2] = "target", [3] = "mouseover" }
for i = 1, MAX_PARTY_MEMBERS do
    table.insert(st_units, "party" .. i)
end
for i = 1, MAX_RAID_MEMBERS do
    table.insert(st_units, "raid" .. i)
end

-- Try to find a valid (friendly) unitstring that can be used for
-- SpellTargetUnit(unit) to avoid another target switch
function _smartHealer:getUnitString(unit)
    for _, unitstr in pairs(st_units) do
        if UnitIsUnit(unit, unitstr) then
            return unitstr
        end
    end

    return nil
end

function _smartHealer:getIntendedTargetForPFCastSpell()
    local unit = "mouseover"
    if not UnitExists(unit) then
        local frame = GetMouseFocus()
        if frame.label and frame.id then
            unit = frame.label .. frame.id
        elseif UnitExists("target") then
            unit = "target"
        elseif GetCVar("autoSelfCast") == "1" then
            unit = "player"
        else
            return
        end
    end

    -- If target and mouseover are friendly units, we can't use spell target as it
    -- would cast on the target instead of the mouseover. However, if the mouseover
    -- is friendly and the target is not, we can try to obtain the best unitstring
    -- for the later SpellTargetUnit() call.
    return ((not UnitCanAssist("player", "target") and UnitCanAssist("player", unit) and self:getUnitString(unit)) or "player")
end

function _smartHealer:pfUI_PFCast(msg)
    if type(msg) ~= "string" or string.len(msg) == 0 then
        self.hooks[SlashCmdList]["PFCAST"](msg) -- fallback if the message is a func or invalid
        return
    end
    
    local spell, maxDesiredRank = libSC:GetRanklessSpellName(msg)
    if spell and maxDesiredRank == nil and libHC.Spells[spell] then
        local unitstr = self:getIntendedTargetForPFCastSpell()
        if unitstr == nil then
            return
        end

        local optimalRank = self:GetOptimalRank(msg, unitstr)
        if optimalRank then
            if maxDesiredRank ~= nil then
                -- if the user has specified a rank then consider it as the max possible rank
                optimalRank = math.min(optimalRank, maxDesiredRank)
            end

            local optimalHeal = libSC:GetSpellNameText(spell, optimalRank)
            _smartHealer.hooks[SlashCmdList]["PFCAST"](optimalHeal) -- mission accomplished
            return
        end
    end

    _smartHealer.hooks[SlashCmdList]["PFCAST"](msg) -- fallback if we can't find optimal rank
end

--------------------------------------------------------------------------------------------------------------------------------------------
-- Support for /pfquickcast:heal* family of commands - these commands are provided by the pfUI-QuickCast addon which is separate from pfUI
--------------------------------------------------------------------------------------------------------------------------------------------

local _pfGetSpellIndex = pfUI
        and pfUI.api
        and pfUI.api.libspell
        and pfUI.api.libspell.GetSpellIndex

function _smartHealer:tryGetOptimalSpell(spellNameRaw, explicitlySpecifiedRank, intendedTarget)
    if not spellNameRaw or not libHC.Spells[spellNameRaw] then
        return nil, nil, nil -- fallback if the spell doesnt exist in the spellbook because for example the player hasnt specced for it 
    end

    local optimalRank = self:GetOptimalRank(spellNameRaw, intendedTarget)
    -- print("** [_smartHealer:pfUIQuickCast_OnHeal] maxDesiredRank='" .. tostring(maxDesiredRank) .. "'")

    if not optimalRank then
        return nil, nil, nil -- fallback if we can't find optimal rank
    end

    if explicitlySpecifiedRank ~= nil then
        if self.db.account.interpretSpellRanksAsMaxNotMin == nil then
            self.db.account.interpretSpellRanksAsMaxNotMin = true -- auto-migrate the db setting for users who just updated the addon
        end

        if self.db.account.interpretSpellRanksAsMaxNotMin then
            optimalRank = math.min(optimalRank, explicitlySpecifiedRank) -- the optimalrank must not exceed the explicitly specified rank
        else
            optimalRank = math.max(optimalRank, explicitlySpecifiedRank) -- the optimalrank must not fall below the explicitly specified rank
        end
    end

    local rankedSpell = libSC:GetSpellNameText(spellNameRaw, optimalRank)

    local rankedSpellId, spellBookType = _pfGetSpellIndex(spellNameRaw, "Rank " .. optimalRank)

    return rankedSpell, rankedSpellId, spellBookType
end

--- Interceptor for the vanilla pfUIQuickCast.OnHeal()
---
--- This is where we deduce the optimal spell rank for the /pfquickcast:heal* family of commands
---
function _smartHealer:pfUIQuickCast_OnHeal(spell, spell_id, spell_book_type, proper_target, intention_is_focus_cast, is_instant_cast, future_arg1, future_arg2, future_arg3, future_arg4, future_arg5)
    local spellNameRaw, explicitlySpecifiedRank = libSC:GetRanklessSpellName(spell)

    local rankedSpell, rankedSpellId, rankedSpellBookType = self:tryGetOptimalSpell(
            spellNameRaw,
            explicitlySpecifiedRank,
            proper_target
    )

    _pfUIQuickCast_OnHeal_orig(
            rankedSpell or spell,
            rankedSpellId or spell_id,
            rankedSpellBookType or spell_book_type,
            proper_target,
            intention_is_focus_cast,
            is_instant_cast,
            future_arg1, -- just to be sure we wont miss
            future_arg2, -- out on any future arguments
            future_arg3, -- we can set explicit names for
            future_arg4, -- these when and if they will be added to the pfUIQuickCast:heal* API while
            future_arg5 --  in the meantime the addon will work just fine without the need for a new release
    )
end

SmartHealer = AceLibrary:Register(_smartHealer, MAJOR_VERSION, MINOR_VERSION) --deadlast   finally register it as a global symbol
