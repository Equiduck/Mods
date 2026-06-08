-- modmain.lua — Trade Inn Auto Fill (fast + recipe-aware)

local GLOBAL = GLOBAL
local TEMPLATES = require "widgets/redux/templates"

-----------------------------------------------------------------------
-- Resolve our modname for config lookups even when called from UI callbacks
-----------------------------------------------------------------------
local DISPLAY_FANCY_NAME = "Trade Inn Auto Fill"
local THIS_MODNAME = modname
if not THIS_MODNAME and GLOBAL.KnownModIndex then
    THIS_MODNAME = GLOBAL.KnownModIndex:GetModActualName(DISPLAY_FANCY_NAME)
end
THIS_MODNAME = THIS_MODNAME or "Trade_Inn_Auto_Fill"    -- folder fallback

-----------------------------------------------------------------------
-- UI strings
-----------------------------------------------------------------------
if GLOBAL.STRINGS and GLOBAL.STRINGS.UI and GLOBAL.STRINGS.UI.TRADESCREEN then
    GLOBAL.STRINGS.UI.TRADESCREEN.AUTO_FILL = GLOBAL.STRINGS.UI.TRADESCREEN.AUTO_FILL or "AUTO FILL"
end

-----------------------------------------------------------------------
-- Small helpers
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- Global debounce for all item selections
-----------------------------------------------------------------------
local TRADEIN_CLICK_DELAY = 0.01
local tradein_click_lock = false

local function LockTradeInClick()
    tradein_click_lock = true

    -- use a tiny dummy entity with its own inst to schedule safely
    local dummy = GLOBAL.CreateEntity()
    dummy:DoTaskInTime(TRADEIN_CLICK_DELAY, function()
        tradein_click_lock = false
        dummy:Remove()
    end)
end





-- Force the green plate to look blue and keep it through state swaps
local function Reblue(btn)
    local function tint(target)
        if not target or type(target) ~= "table" then
            return
        end
        local as = (target.GetAnimState and target:GetAnimState())
                or target.animstate
        if as then
            as:SetMultColour(0.18, 0.28, 0.95, 1)
            as:SetAddColour(0.00, 0.06, 0.40, 0)
        end
    end


    -- tint all layers the template uses
    tint(btn)            -- some builds store the animstate here
    tint(btn.bg)         -- main plate
    tint(btn.focus)      -- hover/focus overlay
    tint(btn.anim)       -- (older template variant)

    if btn.text then
        btn.text:SetColour(0.92, 0.97, 1.00, 1)    -- brighter label on blue
    end

    -- make the tint sticky across state/anim changes
    local _Enable,_Disable,_SetIdle,_SetSel = btn.Enable,btn.Disable,btn.SetIdleAnim,btn.SetSelectedAnim
    btn.Enable = function(b, ...)  local r=_Enable  and _Enable(b, ...)  or nil; tint(b); tint(b.bg); tint(b.focus); return r end
    btn.Disable = function(b, ...) local r=_Disable and _Disable(b, ...) or nil; tint(b); tint(b.bg); tint(b.focus); return r end
    btn.SetIdleAnim = function(b, ...) local r=_SetIdle and _SetIdle(b, ...) or nil; tint(b); tint(b.bg); tint(b.focus); return r end
    btn.SetSelectedAnim = function(b, ...) local r=_SetSel and _SetSel(b, ...) or nil; tint(b); tint(b.bg); tint(b.focus); return r end

    -- safety: re-apply next frame too
    btn.inst:DoTaskInTime(0, function() tint(btn); tint(btn.bg); tint(btn.focus); tint(btn.anim) end)
end



-- Safe "any element?" check that doesn't rely on global `next`
local function HasAny(t)
    if t == nil then return false end
    for _ in pairs(t) do return true end
    return false
end


local function GetConfigBool(key, default)
    local v = GLOBAL.GetModConfigData(key, THIS_MODNAME)
    if v == nil then return default end
    return v == true
end

local function CountSelected(selected_items)
    local n = 0
    for _, v in pairs(selected_items or {}) do
        if v ~= nil then n = n + 1 end
    end
    return n
end

local function BuildInUseMaps(self)
    -- Track item_ids already in a slot or moving, and counts per item name already in-use
    local used_ids = {}
    local inuse_by_item = {}
    for _, it in pairs(self.selected_items or {}) do
        if it then
            if it.item_id then used_ids[it.item_id] = true end
            inuse_by_item[it.item] = (inuse_by_item[it.item] or 0) + 1
        end
    end
    for _, mv in pairs(self.moving_items_list or {}) do
        if mv and mv.item then
            local it = mv.item
            if it.item_id then used_ids[it.item_id] = true end
            inuse_by_item[it.item] = (inuse_by_item[it.item] or 0) + 1
        end
    end
    return used_ids, inuse_by_item
end

-- Rebuild the "items in use" table the way TradeScreen does internally
local function ItemsInUse(selected_items, moving_items_list)
    local items_in_use = {}
    for i,item in pairs(selected_items or {}) do
        items_in_use[i] = item
    end
    if moving_items_list then
        for _,moving_item in pairs(moving_items_list) do
            if moving_item and moving_item.target_slot_index then
                items_in_use[moving_item.target_slot_index] = moving_item.item
            end
        end
    end
    return items_in_use
end

-----------------------------------------------------------------------
-- UI refresh squelch + autofill task management
-----------------------------------------------------------------------
local function CancelAutofill(self)
    -- Invalidate any queued steps and mark not running
    self._autofill_epoch = (self._autofill_epoch or 0) + 1
    self._autofill_running = nil

    if self._autofill_task then self._autofill_task:Cancel() end
    self._autofill_task = nil

    if self._batch_timer then self._batch_timer:Cancel() end
    self._batch_timer = nil
    self._batch_add_active = false

    -- clear any stuck state
    self._force_rarity = nil
    self._pending_ids = {}

    -- restore RefreshUIState if squelched
    if self._autofill_savedRefresh then
        self.RefreshUIState = self._autofill_savedRefresh
        self._autofill_savedRefresh = nil
    end
    self._autofill_squelch = false

    -- unlock input if we locked it
    if self._input_lock_active then
        if self._saved_EnableInput then
            self.popup.EnableInput = self._saved_EnableInput
            self._saved_EnableInput = nil
        end
        self._input_lock_active = nil
        if self.popup then self.popup:EnableInput() end
    end
end


local function PushUiSquelch(self)
    self._ui_squelch_depth = (self._ui_squelch_depth or 0) + 1
    if self._ui_squelch_depth == 1 then
        self._ui_savedRefresh = self.RefreshUIState
        self.RefreshUIState = function() end -- swallow mid-animation refreshes
    end
end

local function PopUiSquelch(self, do_refresh)
    if not self._ui_squelch_depth then return end
    self._ui_squelch_depth = self._ui_squelch_depth - 1
    if self._ui_squelch_depth <= 0 then
        self._ui_squelch_depth = nil
        if self._ui_savedRefresh then
            self.RefreshUIState = self._ui_savedRefresh
            self._ui_savedRefresh = nil
        end
        if do_refresh then self:RefreshUIState() end
    end
end

local function WaitUntilNoMoving(self, then_fn)
    if self._wait_nomove then self._wait_nomove:Cancel() end
    local function poll()
        local moving = 0
        for _, mv in pairs(self.moving_items_list or {}) do
            if mv and mv.moving then moving = moving + 1 end
        end
        if moving == 0 then
            self._wait_nomove = nil
            then_fn()
        else
            self._wait_nomove = self.inst:DoTaskInTime(GLOBAL.FRAMES, poll)
        end
    end
    poll()
end

-- Input lock used only during automated autofill
local function LockPopupInput(self)
    if self._input_lock_active or not (self.popup and self.popup.EnableInput) then return end
    self._input_lock_active = true
    self._saved_EnableInput = self.popup.EnableInput
    self.popup.EnableInput = function() end
    self.popup:DisableInput()
end

local function UnlockPopupInput(self)
    if not self._input_lock_active then return end
    if self._saved_EnableInput then
        self.popup.EnableInput = self._saved_EnableInput
        self._saved_EnableInput = nil
    end
    self._input_lock_active = nil
    if self.popup then self.popup:EnableInput() end
end

-----------------------------------------------------------------------
-- Core: AutoFill (two-pass: dupes-only, then relax to fill)
-----------------------------------------------------------------------
local function AutoFill(self)
    if self.machine_in_use or self.specials_mode or self.transitioning or self.quitting then
        return
    end

    CancelAutofill(self)

    if self.resetbtn and not self.machine_in_use and not self.transitioning and not self.quitting then
        self.resetbtn:Enable()
    end

    local epoch = self._autofill_epoch or 0
    self._autofill_running = epoch


    local need = (self.current_num_trade_items or 9) - CountSelected(self.selected_items)
    if need <= 0 then return end

    local list = (self.popup and self.popup.skins_list) or {}
    if #list == 0 then
        if self.innkeeper then
            self.innkeeper:Say(GLOBAL.STRINGS.UI.TRADESCREEN.SKIN_COLLECTOR_SPEECH.START_EMPTY)
        end
        return
    end

    local used_ids, inuse_by_item = BuildInUseMaps(self)
    local total_by_item = GLOBAL.GetOwnedItemCounts() or {}
    local taking_now_by_item = {}
    local startpos = self.popup and self.popup.scroll_list
        and self.popup.scroll_list.position_marker:GetWorldPosition()
        or self:GetWorldPosition()

    local picks = {}
    local target_rarity = nil

    local function collect(strict_dupes)
        for _, v in ipairs(list) do
            if need <= 0 then break end
            if not used_ids[v.item_id] then
                local r = GLOBAL.GetRarityForItem(v.item)
                if target_rarity == nil or r == target_rarity then
                    local total = total_by_item[v.item] or 0
                    local already_inuse = inuse_by_item[v.item] or 0
                    local taking_now = taking_now_by_item[v.item] or 0
                    local available_now = total - already_inuse - taking_now
                    local must_leave_one = strict_dupes and GetConfigBool("DUPES_ONLY", true)
                    local ok = available_now > (must_leave_one and 1 or 0)
                    if ok then
                        target_rarity = target_rarity or r
                        table.insert(picks, v)
                        taking_now_by_item[v.item] = taking_now + 1
                        used_ids[v.item_id] = true
                        need = need - 1
                    end
                end
            end
        end
    end

    collect(true)
    if need > 0 and GetConfigBool("RELAX_TO_FILL", true) then
        collect(false)
    end

    if #picks == 0 then
        if self.innkeeper then
            self.innkeeper:Say(GLOBAL.STRINGS.UI.TRADESCREEN.SKIN_COLLECTOR_SPEECH.ADDMORE)
        end
        return
    end

    -- Squelch mid-queue refresh; single final refresh at the end.
    local savedRefresh = self.RefreshUIState
    self._autofill_savedRefresh = savedRefresh
    self._autofill_squelch = true
    self.RefreshUIState = function(s, ...) if not s._autofill_squelch then return savedRefresh(s, ...) end end

    -- Automated sequence: lock input
    LockPopupInput(self)

    local i = 1
    local function step()
        -- If a reset/new run happened, abandon this run silently
        if self._autofill_running ~= epoch then return end

        local moving = 0
        for _, mv in pairs(self.moving_items_list or {}) do
            if mv and mv.moving then moving = moving + 1 end
        end
        if moving > 0 then
            if self._autofill_task then self._autofill_task:Cancel() end
            self._autofill_task = self.inst:DoTaskInTime(GLOBAL.FRAMES, step)
            return
        end

        local entry = picks[i]
        if not entry then
            self._autofill_running = nil
            CancelAutofill(self)      -- also unlocks and restores RefreshUIState
            self:RefreshUIState()
            return
        end

        self:StartAddSelectedItem({ type = entry.type, item = entry.item, item_id = entry.item_id }, startpos)
        i = i + 1
        if self._autofill_task then self._autofill_task:Cancel() end
        self._autofill_task = self.inst:DoTaskInTime(GLOBAL.FRAMES, step)
    end

    step()
end

-----------------------------------------------------------------------
-- Hook TradeScreen (UI button + batched manual add/remove/reset)
-----------------------------------------------------------------------
AddClassPostConstruct("screens/tradescreen", function(self)
    -- AUTO FILL button styled like RESET/TRADE, then tinted blue
    self.autofillbtn = self.claw_machine:AddChild(
        TEMPLATES.old.AnimTextButton(
            "button",
            { idle = "idle_green", over = "up_green", disabled = "down_green" }, -- use green frames
            1,
            function() AutoFill(self) end,
            GLOBAL.STRINGS.UI.TRADESCREEN.AUTO_FILL or "AUTO FILL",
            30
        )
    )
    self.autofillbtn:SetScale(0.9)
    self.autofillbtn:SetPosition(0, -500)     -- stays between the birds
    self.autofillbtn:Show()
    self.autofillbtn:Enable()
    Reblue(self.autofillbtn)


    -- Keep button enabled/disabled with state + allow Reset during autofill
    local _RefreshUIState = self.RefreshUIState
    self.RefreshUIState = function(s, ...)
        if not s._autofill_squelch then
            _RefreshUIState(s, ...)
        end

        -- AUTO FILL button gating
        if s.autofillbtn then
            local enable = (not s.machine_in_use)
                        and (not s.specials_mode)
                        and (not s.transitioning)
                        and (not s.quitting)
            if enable and (s.current_num_trade_items == 9) then
                s.autofillbtn:Enable()
            else
                s.autofillbtn:Disable()
            end
        end

        -- NEW: allow Reset even when tray is still "empty" but autofill is running
        if s.resetbtn then
            local has_any = HasAny(s.selected_items) or HasAny(s.moving_items_list) or (s._autofill_running ~= nil)
            if has_any and not s.machine_in_use then
                s.resetbtn:Enable()
            else
                s.resetbtn:Disable()
            end
        end
    end


    local function ClearSelectorCaches(scr)
        if scr and scr.popup then
            scr.popup._cached_full = nil
        end
    end

    -- Reset (instant clear, even mid-autofill; skips 9 fly-back animations)
    local _Reset = self.Reset
    self.Reset = function(s, ...)
        -- kill automation and unlock
        CancelAutofill(s)
        UnlockPopupInput(s)
        s._force_rarity = nil

        -- stop any active moves right away (prevents queued lag)
        if s.CancelPendingMoves then s:CancelPendingMoves() end

        -- batch UI work to a single heavy refresh at the end
        PushUiSquelch(s)

        -- override FinishReset to ALWAYS skip move_items animations
        local _FinishReset = s.FinishReset
        s.FinishReset = function(ss, move_items)
            -- make sure nothing is still moving
            if ss.CancelPendingMoves then ss:CancelPendingMoves() end
            return _FinishReset(ss, false)  -- <- no item fly-back animations
        end

        local ret = _Reset(s, ...)

        -- restore FinishReset after everything is settled
        WaitUntilNoMoving(s, function()
            s.FinishReset = _FinishReset
            PopUiSquelch(s, true)  -- one final refresh
        end)

        return ret
    end


    -- Removing items: when tray empties, clear forced rarity; batch one refresh
    local _RemoveSelectedItem = self.RemoveSelectedItem
    self.RemoveSelectedItem = function(s, ...)
        CancelAutofill(s)
        PushUiSquelch(s)
        local ret = _RemoveSelectedItem(s, ...)
        if s._batch_timer then s._batch_timer:Cancel(); s._batch_timer = nil end
        WaitUntilNoMoving(s, function()
            if CountSelected(s.selected_items) == 0 then
                s._force_rarity = nil
            end
            -- Pop the squelch but avoid forcing a full heavy rebuild; do a light refresh.
            PopUiSquelch(s, false)
            if s.RefreshUIState and not s._ui_squelch_depth then
                s:RefreshUIState()
            end

        end)
        return ret
    end

    -- Fast manual add with recipe-aware lightweight UpdateData on first pick
    local _StartAddSelectedItem = self.StartAddSelectedItem
    self.StartAddSelectedItem = function(s, item, start_pos)
        if not s._autofill_running then
            CancelAutofill(s)
        end

        s._pending_ids = s._pending_ids or {}
        if item and item.item_id then s._pending_ids[item.item_id] = true end

        if not s._batch_add_active then
            s._batch_add_active = true
            PushUiSquelch(s)
        end

        local first_pick = (CountSelected(s.selected_items) == 0)
        if first_pick and item and item.item then
            s._force_rarity = GLOBAL.GetRarityForItem(item.item)

            if s.popup and s.popup.UpdateData then
                local inuse = ItemsInUse(s.selected_items, s.moving_items_list)
                local filters
                if not s.specials_mode then
                    local recipe_name = GLOBAL.GetBasicRecipeMatch(inuse)
                    filters = GLOBAL.GetBasicFilters(recipe_name)
                else
                    local recipe_index = s.specials_list and s.specials_list:GetRecipeIndex()
                    filters = (recipe_index and s.recipes)
                        and GLOBAL.GetSpecialFilters(s.recipes[recipe_index], inuse)
                        or {}
                end

                -- lightweight UpdateData with official filters, pruned by rarity in our override
                s.popup:UpdateData(inuse, filters)
                if s.popup.scroll_list and s.popup.scroll_list.ResetScroll then
                    s.popup.scroll_list:ResetScroll()
                end
            end
        end

        local ret = _StartAddSelectedItem(s, item, start_pos)

        -- Debounce the heavy pass
        if s._batch_timer then s._batch_timer:Cancel() end
        local function finish_batch()
            WaitUntilNoMoving(s, function()
                s._pending_ids = {}
                if CountSelected(s.selected_items) == 0 then
                    s._force_rarity = nil
                end
                -- Light refresh only (prevents big UI spikes on fast click bursts)
                PopUiSquelch(s, false)
                if s.RefreshUIState and not s._ui_squelch_depth then
                    s:RefreshUIState()
                end
                s._batch_add_active = false

            end)
        end
        s._batch_timer = s.inst:DoTaskInTime(6 * GLOBAL.FRAMES, finish_batch)

        return ret
    end

    -- Quit: clean timers + caches
    local _Quit = self.Quit
    if _Quit then
        self.Quit = function(s, ...)
            CancelAutofill(s)
            UnlockPopupInput(s)
            if s._batch_timer then s._batch_timer:Cancel(); s._batch_timer = nil end
            s._pending_ids = {}
            s._force_rarity = nil
            if s.popup then s.popup._cached_full = nil end
            return _Quit(s, ...)
        end
    end
end)

-----------------------------------------------------------------------
-- ItemSelector hooks:
--   - ignore duplicate clicks while an item is moving
--   - lightweight, recipe-aware UpdateData:
--       * cache full list once (GetInventorySkinsList(true))
--       * ApplyFilters(filters_list) (official recipe legality)
--       * if forced rarity, prune by rarity
--       * subtract items-in-use by item_id
-----------------------------------------------------------------------
AddClassPostConstruct("widgets/itemselector", function(sel)
    -- Ignore stale double-clicks while an entry is moving or queued
        -- Cooldown in seconds to ignore repeated clicks on the same entry
    local CLICK_COOLDOWN = 0.01

    local last_clicks = {}

    local _OnItemSelect = sel.OnItemSelect

    sel.OnItemSelect = function(self, type, item, item_id, itemimage)
        local screen = self.owner

        -- global debounce shared across all selectors
        if tradein_click_lock then
            return
        end
        LockTradeInClick()

        -- if an item is mid-animation, skip
        if screen and screen.moving_items_list then
            for _, mv in pairs(screen.moving_items_list) do
                if mv and mv.moving then
                    return
                end
            end
        end

        -- skip if queued already
        if screen and screen._pending_ids and item_id and screen._pending_ids[item_id] then
            return
        end

        return _OnItemSelect(self, type, item, item_id, itemimage)
    end




    local _UpdateData = sel.UpdateData
    sel.UpdateData = function(self, selections, filters_list)
        local screen = self.owner
        local forced_r = screen and screen._force_rarity

        -- Build cache once (true matches base ItemSelector usage)
        if not self._cached_full then
            self._cached_full = GLOBAL.GetInventorySkinsList(true)
        end

        -- Respect official recipe filters
        local filtered = GLOBAL.ApplyFilters(self._cached_full, filters_list or {})

        -- If a forced rarity is set (first pick in batch), prune to that rarity
        if forced_r then
            local tmp = {}
            for _, v in ipairs(filtered) do
                if GLOBAL.GetRarityForItem(v.item) == forced_r then
                    tmp[#tmp+1] = v
                end
            end
            filtered = tmp
        end

        -- Remove anything already in use (selected or moving) by item_id
        local used_ids = {}
        for _, it in pairs(selections or {}) do
            if it and it.item_id then used_ids[it.item_id] = true end
        end
        if screen and screen.moving_items_list then
            for _, mv in pairs(screen.moving_items_list) do
                if mv and mv.item and mv.item.item_id then
                    used_ids[mv.item.item_id] = true
                end
            end
        end

        local compact = {}
        for _, v in ipairs(filtered) do
            if not used_ids[v.item_id] then
                compact[#compact+1] = v
            end
        end

        self.full_skins_list = self._cached_full
        self.skins_list = compact
        self.scroll_list:SetItemsData(self.skins_list)
    end
end)
