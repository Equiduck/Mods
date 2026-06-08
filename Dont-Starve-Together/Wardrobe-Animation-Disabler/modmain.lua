-- modmain.lua

local Config = GetModConfigData -- shorthand

local function dbg(...)
    print("[NoFEAnims]", ...)
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Make a puppet stay on its idle loop (no emotes, no change-emotes),
-- without freezing the animation.
local function MutePuppetToIdleOnly(p)
    if not p or not p.animstate then return end

    -- Save once so we can restore if a screen reuses the puppet later.
    if p.__mod_idle_backup == nil then
        p.__mod_idle_backup = {
            EmoteUpdate                = p.EmoteUpdate,
            DoIdleEmote                = p.DoIdleEmote,
            DoChangeEmote              = p.DoChangeEmote,
            enable_idle_emotes         = p.enable_idle_emotes,
            add_change_emote_for_idle  = p.add_change_emote_for_idle,
            play_non_idle_emotes       = p.play_non_idle_emotes,
        }
    end

    -- Kill triggers
    p.enable_idle_emotes        = false
    p.add_change_emote_for_idle = false
    p.play_non_idle_emotes      = false
    p.time_to_idle_emote        = math.huge
    p.time_to_change_emote      = math.huge

    -- No-op the emote starters
    p.DoIdleEmote   = function() end
    p.DoChangeEmote = function() end

    -- Minimal update loop that just keeps us on idle and clears
    -- any temporary carry state if it was left mid-transition.
    p.EmoteUpdate = function(self, dt)
        if self.sitting then return end
        if self.item_equip and self.animstate:IsCurrentAnimation("item_in") and self.RemoveEquipped then
            self:RemoveEquipped()
        end
        local idle = self.current_idle_anim or "idle_loop"
        if not self.animstate:IsCurrentAnimation(idle) then
            self.animstate:PlayAnimation(idle, true)
        end
    end

    -- Force into idle right now (don’t pause the anim!)
    local idle = p.current_idle_anim or "idle_loop"
    p.animstate:PlayAnimation(idle, true)
    p.animstate:SetTime(math.random() * 1.5)
    if p.RemoveEquipped then p:RemoveEquipped() end
end

local function RestorePuppetIfNeeded(p)
    local b = p and p.__mod_idle_backup
    if not b then return end
    p.EmoteUpdate               = b.EmoteUpdate
    p.DoIdleEmote               = b.DoIdleEmote
    p.DoChangeEmote             = b.DoChangeEmote
    p.enable_idle_emotes        = b.enable_idle_emotes
    p.add_change_emote_for_idle = b.add_change_emote_for_idle
    p.play_non_idle_emotes      = b.play_non_idle_emotes
    p.__mod_idle_backup         = nil
end

-- Apply idle-only to any puppet-like fields we can find on a screen/widget.
local function TryPatchCommonPuppetFields(screen_or_widget, label)
    if not screen_or_widget then return 0 end
    local count = 0

    -- common fields: puppet, preview_puppet, character_puppet, etc.
    local candidates = {
        "puppet", "character", "avatar", "preview_puppet", "character_puppet",
    }
    for _,field in ipairs(candidates) do
        local p = screen_or_widget[field]
        if p and p.animstate and p.EmoteUpdate then
            MutePuppetToIdleOnly(p)
            count = count + 1
        end
    end

    -- Wardrobe/player summary “posse” list of puppets
    if screen_or_widget.posse and type(screen_or_widget.posse) == "table" then
        for _,p in pairs(screen_or_widget.posse) do
            if p and p.animstate and p.EmoteUpdate then
                MutePuppetToIdleOnly(p)
                count = count + 1
            end
        end
    end

    if count > 0 then
        dbg("Patched", count, "puppet(s) in", label or "?")
    end
    return count
end

local function RestoreCommonPuppetFields(screen_or_widget)
    if not screen_or_widget then return end
    local candidates = {
        "puppet", "character", "avatar", "preview_puppet", "character_puppet",
    }
    for _,field in ipairs(candidates) do
        local p = screen_or_widget[field]
        if p then RestorePuppetIfNeeded(p) end
    end
    if screen_or_widget.posse and type(screen_or_widget.posse) == "table" then
        for _,p in pairs(screen_or_widget.posse) do
            RestorePuppetIfNeeded(p)
        end
    end
end

-- Decorate a screen’s Close to restore puppets we changed.
local function WrapCloseToRestore(self)
    local orig_close = self.Close or function() end
    self.Close = function(scr, ...)
        RestoreCommonPuppetFields(scr)
        return orig_close(scr, ...)
    end
end

----------------------------------------------------------------------
-- Wardrobe Screen (always keep previous behavior: idle-only puppets)
----------------------------------------------------------------------

AddClassPostConstruct("screens/redux/wardrobescreen", function(self)
    -- Defer a frame to ensure widgets are built.
    self.inst:DoTaskInTime(0, function()
        TryPatchCommonPuppetFields(self, "WardrobeScreen")
        WrapCloseToRestore(self)
    end)
end)

----------------------------------------------------------------------
-- Loadout Select (keep previous behavior)
----------------------------------------------------------------------

AddClassPostConstruct("widgets/redux/loadoutselect", function(self)
    self.inst:DoTaskInTime(0, function()
        TryPatchCommonPuppetFields(self, "LoadoutSelect")
        WrapCloseToRestore(self)
    end)
end)

----------------------------------------------------------------------
-- Player Summary Screen (Item Collection) — configurable
--   Option: "Disable Item Collection Animations" (default Disabled)
----------------------------------------------------------------------

AddClassPostConstruct("screens/redux/playersummaryscreen", function(self)
    local disable_ic_anims = Config("disable_item_collection_anims") == true
    if not disable_ic_anims then
        dbg("PlayerSummaryScreen: config OFF, leaving animations as-is.")
        return
    end

    self.inst:DoTaskInTime(0, function()
        -- Hit the posse puppets (the grid of characters on the right).
        TryPatchCommonPuppetFields(self, "PlayerSummaryScreen")
        WrapCloseToRestore(self)
    end)
end)
