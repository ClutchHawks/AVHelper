--[[
    Absolute Virtue Helper (avhelper) - Ashita v4 addon for CatsEyeXI (Final Fantasy XI private server)

    Trigger with /avh - Ashita intercepts every slash command before it reaches the server, the
    same way its own /addon, /bind, etc. work, so a single slash is correct here (not // - that
    was wrong in an earlier version of this file).

    Detects Absolute Virtue's own "special ability" reactions (Mighty Strikes, Manafont, etc.) as
    they happen, shows an on-screen alert + countdown for the follow-up player SP that locks them
    out, and keeps a persistent table of every trigger ability's lock state for the current pull.

    Built with Ashita's Dear ImGui binding (same approach as CraftGuard) rather than hand-placed
    fonts/primitives - this gives a single real window (drag/resize/close as one native unit)
    instead of a collection of independently movable text/box objects.

    IMPORTANT - about the lock window timing:
    CatsEyeXI's public "base" branch Absolute_Virtue.lua (github.com/CatsAndBoats/catseyexi)
    hard-codes a 3-second lock window, but the live server actually runs a private override script
    this addon's author doesn't have access to - confirmed via in-game testing that the real
    window is 10 seconds, not 3. The 10-second window is hard-coded as a constant (LOCK_WINDOW,
    below) rather than a setting, precisely so it can't drift out of sync with the tested value.
    The mob-skill ids (see MOB_SKILL_IDS) and ability list originally came from the public base
    branch, and have since been confirmed working end-to-end in-game (see README.md).

    Commands:
      /avh                     - Toggle the window.
      /avh show / hide         - Show/hide the window.
      /avh reset               - Clear all lock/unlock state (start of a new pull).
      /avh mute / unmute       - Toggle sound alerts.
      /avh speechreset on/off  - Toggle auto-reset when AV's engage speech is seen in chat.
      /avh abilities           - List tracked abilities and resolved ids.
      /avh help                - Print this command list.
--]]

addon.name      = 'avhelper';
addon.author    = 'ClutchHawks';
addon.version   = '4.1';
addon.desc      = 'Absolute Virtue SP-ability trigger/lock tracker.';
addon.link      = '';

require('common');

local chat      = require('chat');
local imgui     = require('imgui');
local settings  = require('settings');
local ffi       = require('ffi');
local bit       = require('bit');

ffi.cdef[[
    bool PlaySoundA(const char* pszSound, void* hmod, uint32_t fdwSound);
]];
local winmm_ok, winmm = pcall(ffi.load, 'winmm');

local SND_FILENAME  = 0x00020000;
local SND_ASYNC     = 0x00000001;
local SND_NODEFAULT = 0x00000002;

--------------------------------------------------------------------------------------------------
-- Default (per-character) settings
--------------------------------------------------------------------------------------------------
local default_settings = T{
    visible = T{ true, },

    general = T{
        enabled             = true,    -- master on/off switch
        mob_name            = 'Absolute Virtue', -- must match the entity's in-game name exactly (case-insensitive)
        auto_reset_on_zone  = true,    -- clear all lock/unlock state whenever you change zones (new pull)
        auto_reset_on_speech= true,    -- clear all lock/unlock state when AV's own engage speech is seen in chat
        play_sound          = true,
        -- These point at stock Windows sound files so alerts work out of the box.
        -- Replace with your own .wav paths (e.g. C:\FFXI\config\addons\avhelper\alert.wav) if you like.
        sound_trigger       = 'C:\\Windows\\Media\\Windows Notify System Generic.wav',
        sound_lock          = 'C:\\Windows\\Media\\Windows Notify Calendar.wav',
    },

    -- Fragments of Absolute Virtue's own spoken/emote lines, used to auto-detect a fresh pull
    -- starting (see auto_reset_on_speech above). Matching is done against a *normalized* copy of
    -- each incoming chat line: lowercased, with runs of repeated "s" collapsed to one (AV's speech
    -- is rendered with a stretched-out sibilant, e.g. "lassst", "sssscattered", so the number of
    -- s's isn't reliable) and stripped of color/control bytes. Keep these entries lowercase, with
    -- single s's, and as short/distinctive substrings rather than whole lines - /avh addphrase /
    -- /avh delphrase manage this list without editing the file by hand.
    speech_phrases = T{
        'at last the time has come',
        'scattered fragments of my thoughts',
    },

    -- Which of the trigger abilities to watch/display. Set to false to ignore one, or use
    -- /avh enable|disable <name> instead of editing this by hand.
    -- Mijin Gakure / Familiar / Astral Flow are NOT included at all - per in-game testing,
    -- Absolute Virtue cannot use them, even though they exist in CatsEyeXI's public source.
    abilities = T{
        ['Mighty Strikes']     = true,
        ['Benediction']        = true,
        ['Hundred Fists']      = true,
        ['Manafont']           = true,
        ['Chainspell']         = true,
        ['Perfect Dodge']      = true,
        ['Invincible']         = true,
        ['Blood Weapon']       = true,
        ['Soul Voice']         = true,
        ['Meikyo Shisui']      = true,
        ['Eagle Eye Shot']     = true,
        ['Call Wyvern']        = true,
    },
};

-- Display order (matches the order AV's own ability pool is built in, in CatsEyeXI's public
-- source, minus Mijin Gakure / Familiar / Astral Flow - see the note above).
local ABILITY_ORDER = T{
    'Mighty Strikes', 'Benediction', 'Hundred Fists', 'Manafont', 'Chainspell',
    'Perfect Dodge', 'Invincible', 'Blood Weapon', 'Soul Voice', 'Meikyo Shisui',
    'Eagle Eye Shot', 'Call Wyvern',
};

-- AV's own "mob ability" ids for each reaction, taken from CatsEyeXI's public
-- scripts/enum/job_special_ability.lua (xi.jsa.*) - these are what should show up in the action
-- packet when ABSOLUTE VIRTUE performs the reaction (category 11, "mob_tp_finish"), as opposed to
-- the player's own job ability id (category 6), which is resolved dynamically further down.
-- Eagle Eye Shot uses the "Aern"-model-specific variant since AV is an Aern. These ids started as
-- a guess from the public source (the live server runs a private override - see header comment),
-- and have since been confirmed correct in-game for all 12 tracked abilities.
local MOB_SKILL_IDS = T{
    ['Mighty Strikes']     = 688,
    ['Benediction']        = 689,
    ['Hundred Fists']      = 690,
    ['Manafont']           = 691,
    ['Chainspell']         = 692,
    ['Perfect Dodge']      = 693,
    ['Invincible']         = 694,
    ['Blood Weapon']       = 695,
    ['Soul Voice']         = 696,
    ['Meikyo Shisui']      = 730,
    ['Call Wyvern']        = 732,
    ['Eagle Eye Shot']     = 1389, -- EES_AERN
};

local ALERT_DISPLAY_SECONDS = 4.0; -- how long the top alert line holds a message before going idle

-- Seconds a player has, after Absolute Virtue uses a tracked ability, to counter it with the
-- matching real SP and lock it out for the rest of the pull. Fixed at 10.0 (confirmed in-game;
-- see the header comment) - deliberately NOT a setting, so it can't end up stuck at a stale value
-- in an old settings file the way lock_window used to.
local LOCK_WINDOW = 10.0;

-- Fixed window width (pixels) - see render() for why this isn't just AlwaysAutoResize.
local WINDOW_WIDTH = 360.0;

--------------------------------------------------------------------------------------------------
-- Addon state
--------------------------------------------------------------------------------------------------
local avh = T{
    settings        = settings.load(default_settings),
    ability_ids     = T{},     -- name -> resolved numeric PLAYER ability id
    id_to_name      = T{},     -- offset-corrected PLAYER ability id (matches the real packet) -> name
    mobskill_to_name= T{},     -- mob skill id -> name (built from MOB_SKILL_IDS, filtered by enabled abilities)
    unresolved      = T{},     -- player ability names we could NOT resolve on this server
    state           = T{},     -- name -> { status, armed, armed_time }
    alert_text      = 'No activity yet.',
    alert_color     = T{ 0.60, 0.63, 0.67, 1.0 },
    alert_set_at    = 0,
    bar_active      = false,
    bar_start       = 0,
    bar_window      = 0,
    last_speech_reset_at = 0,
};

--------------------------------------------------------------------------------------------------
-- Colors (RGBA 0-1, as ImGui expects)
--------------------------------------------------------------------------------------------------
local COLOR_IDLE            = T{ 0.60, 0.63, 0.67, 1.0 };
local COLOR_ARMED           = T{ 1.00, 0.40, 0.27, 1.0 }; -- needs a response right now
local COLOR_LOCKED          = T{ 0.33, 0.87, 0.33, 1.0 }; -- successfully locked (good outcome)
local COLOR_UNLOCKED        = T{ 0.88, 0.75, 0.38, 1.0 }; -- still a live threat, no active window
local COLOR_WARNING         = T{ 1.00, 0.85, 0.30, 1.0 };

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------
local function print_msg(str)
    print(chat.header(addon.name):append(chat.message(str)));
end

local function reset_state()
    for _, name in ipairs(ABILITY_ORDER) do
        avh.state[name] = T{
            status      = 'unlocked',
            armed       = false,
            armed_time  = 0,
        };
    end
    avh.bar_active   = false;
    avh.alert_text   = 'No activity yet.';
    avh.alert_color  = COLOR_IDLE;
    avh.alert_set_at = 0;
end

-- Ashita's resource manager places job abilities into one merged ability-id space starting at
-- 512 (weaponskills, mob skills, etc. occupy other ranges of the same merged space), but the
-- actual 0x028 action packet's Id field for a job ability is the raw, un-offset id - confirmed
-- in-game via /avh debug: Blood Weapon resolved to resource id 535 but its real packet carried
-- Id=23 (535-512=23), and Call Wyvern resolved to 573 but carried Id=61 (573-512=61). Every
-- counter-SP lookup has to subtract this back out, or every single one silently never matches.
local JOB_ABILITY_ID_OFFSET = 512;

--------------------------------------------------------------------------------------------------
-- Resolves the numeric PLAYER ability ids for every tracked ability name by scanning the resource
-- manager's ability range. This is only used to recognize a player's counter-SP use; AV's own use
-- is matched via the hard-coded MOB_SKILL_IDS table above.
--------------------------------------------------------------------------------------------------
local function resolve_abilities()
    avh.ability_ids      = T{};
    avh.id_to_name        = T{};
    avh.mobskill_to_name  = T{};
    avh.unresolved        = T{};

    local resmgr = AshitaCore:GetResourceManager();
    if (resmgr == nil) then
        return;
    end

    for id = 0, 1535 do
        local ok, ability = pcall(function () return resmgr:GetAbilityById(id); end);
        if (ok and ability ~= nil and ability.Name ~= nil and ability.Name[1] ~= nil and #ability.Name[1] > 0) then
            local nm = ability.Name[1];
            for _, tracked in ipairs(ABILITY_ORDER) do
                if (avh.settings.abilities[tracked] and nm:lower() == tracked:lower()) then
                    -- Displayed via /avh abilities as the resource id (matches what you'd look up
                    -- elsewhere), but the packet-matching table uses the offset-corrected id.
                    avh.ability_ids[tracked] = id;
                    avh.id_to_name[id - JOB_ABILITY_ID_OFFSET] = tracked;
                end
            end
        end
    end

    for _, tracked in ipairs(ABILITY_ORDER) do
        if (avh.settings.abilities[tracked]) then
            if (avh.ability_ids[tracked] == nil) then
                avh.unresolved:append(tracked);
            end
            local skill_id = MOB_SKILL_IDS[tracked];
            if (skill_id ~= nil) then
                avh.mobskill_to_name[skill_id] = tracked;
            end
        end
    end

    if (#avh.unresolved > 0) then
        print(chat.header(addon.name):append(chat.error('Warning: Could not resolve the following tracked PLAYER abilities (check spelling / server data):')));
        avh.unresolved:each(function (name)
            print(chat.header(addon.name):append(chat.error('  - ')):append(chat.message(name)));
        end);
        print_msg('Locking will not work for them until this is fixed (the ARMED alert from AV will still show).');
    end
end

--------------------------------------------------------------------------------------------------
-- Returns true + the member's display name if the given server id belongs to someone in your
-- current party/alliance.
--------------------------------------------------------------------------------------------------
local function get_ally_name(server_id)
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party == nil) then
        return false, nil;
    end

    for i = 0, 17 do
        local ok, sid = pcall(function () return party:GetMemberServerId(i); end);
        if (ok and sid ~= nil and sid ~= 0 and sid == server_id) then
            local active_ok, active = pcall(function () return party:GetMemberActive(i); end);
            -- GetMemberActive's return type isn't consistently documented (boolean vs 0/1), so
            -- accept either form; if the call fails entirely, fall back to trusting the server id match.
            local is_active = (not active_ok) or (active == true) or (active == 1) or (type(active) == 'number' and active ~= 0);
            if (is_active) then
                local name_ok, name = pcall(function () return party:GetMemberName(i); end);
                if (name_ok and name ~= nil and #name > 0) then
                    return true, name;
                end
                return true, ('id:%u'):fmt(server_id);
            end
        end
    end

    return false, nil;
end

--------------------------------------------------------------------------------------------------
-- Scans the zone's mob target-index range (0-1023: NPCs/mobs are 0-1023, PCs 1024-1791,
-- trusts/pets 1792-2303) for an entity with the given server id, and returns its name if found.
-- Used to confirm a mob-ability use actually came from Absolute Virtue and not some unrelated
-- monster that happens to share a mob skill id.
--------------------------------------------------------------------------------------------------
local function resolve_mob_name(server_id)
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    if (entity == nil) then
        return nil;
    end

    for i = 0, 1023 do
        local ok, sid = pcall(function () return entity:GetServerId(i); end);
        if (ok and sid ~= nil and sid == server_id) then
            local name_ok, name = pcall(function () return entity:GetName(i); end);
            if (name_ok and name ~= nil and #name > 0) then
                return name;
            end
            return nil;
        end
    end

    return nil;
end

--------------------------------------------------------------------------------------------------
-- Action packet (0x028) parsing.
--
-- Adapted from the community-standard Ashita v4 action-packet parser pattern (see e.g.
-- ThornyFFXI/tTimers' actionpacket.lua) - the incoming action packet is a tightly packed
-- bitstream, not byte-aligned fields, so it has to be unpacked bit by bit.
--------------------------------------------------------------------------------------------------
local function parse_action_packet(e)
    local bit_offset = 40;

    local function unpack_bits(length)
        local value = ashita.bits.unpack_be(e.data_raw, 0, bit_offset, length);
        bit_offset = bit_offset + length;
        return value;
    end

    local pkt = T{};
    pkt.UserId  = unpack_bits(32);
    local target_count = unpack_bits(6);
    bit_offset  = bit_offset + 4;
    pkt.Type    = unpack_bits(4);
    pkt.Id      = unpack_bits(17);
    bit_offset  = bit_offset + 15;
    pkt.Recast  = unpack_bits(32);

    -- We don't need per-target hit data for this addon, but we still have to walk past it
    -- correctly in case something downstream cares about later bytes.
    pkt.Targets = T{};
    for _ = 1, target_count do
        local target = T{ Id = unpack_bits(32) };
        local action_count = unpack_bits(4);
        for _ = 1, action_count do
            unpack_bits(5);     -- Reaction
            unpack_bits(12);    -- Animation
            unpack_bits(7);     -- SpecialEffect
            unpack_bits(3);     -- Knockback
            unpack_bits(17);    -- Param
            unpack_bits(10);    -- Message
            unpack_bits(31);    -- Flags

            if (unpack_bits(1) == 1) then
                unpack_bits(10); unpack_bits(17); unpack_bits(10); -- additional effect
            end
            if (unpack_bits(1) == 1) then
                unpack_bits(10); unpack_bits(14); unpack_bits(10); -- spikes effect
            end
        end
        pkt.Targets:append(target);
    end

    return pkt;
end

-- Action packet categories (per Windower/Ashita's shared action-event categories).
-- NOTE: 2-hour/SP abilities are instant, no-telegraph job abilities, and in-game testing found
-- that real SP use (e.g. Meikyo Shisui) arrives as category 14 ("job ability, unblinkable"), not
-- plain category 6 - AV's own use of the reaction (category 11) was detected fine, but a genuine
-- player counter-SP wasn't recognized at all until both 6 and 14 were treated as job-ability use.
local CATEGORY_JOB_ABILITY              = 6;
local CATEGORY_JOB_ABILITY_UNBLINKABLE  = 14;
local CATEGORY_MOB_TP_MOVE              = 11;

--------------------------------------------------------------------------------------------------
-- Chat text normalization + AV speech detection.
--
-- Strips Ashita/FFXI color and control bytes from an incoming chat-log line the same way
-- TreeFidyDad/lsbridge does (0x1E/0x1F/0x7F are 2-byte color/format codes, remaining control and
-- high-bit bytes are just noise for our purposes), then lowercases and collapses runs of "s" down
-- to one - AV's engage speech is rendered with a stretched sibilant ("lassst", "sssscattered")
-- and the exact number of repeated letters isn't something worth matching against.
--------------------------------------------------------------------------------------------------
local function normalize_chat_text(msg)
    if (msg == nil) then
        return '';
    end
    local clean = msg
        :gsub('\x1E.', '')
        :gsub('\x1F.', '')
        :gsub('\x7F.', '')
        :gsub('[%c]', '')
        :gsub('[\128-\255]', '');
    clean = clean:lower();
    clean = clean:gsub('s+', 's');
    return clean;
end

local function check_speech_reset(raw_message)
    if (not avh.settings.general.enabled or not avh.settings.general.auto_reset_on_speech) then
        return;
    end

    local clean = normalize_chat_text(raw_message);
    if (#clean == 0) then
        return;
    end

    for _, phrase in ipairs(avh.settings.speech_phrases) do
        if (clean:find(phrase, 1, true)) then
            -- The same line can sometimes reach text_in more than once (e.g. echoed to multiple
            -- log tabs); a short cooldown keeps one engage from triggering several resets.
            local now = os.clock();
            if ((now - avh.last_speech_reset_at) > 5.0) then
                avh.last_speech_reset_at = now;
                reset_state();
                print_msg(chat.success('New Absolute Virtue pull detected (engage speech) - state reset.'));
            end
            return;
        end
    end
end

--------------------------------------------------------------------------------------------------
-- Sound
--------------------------------------------------------------------------------------------------
local function play_sound(path)
    if (not avh.settings.general.play_sound) then
        return;
    end
    if (not winmm_ok or winmm == nil) then
        return;
    end
    if (path == nil or #path == 0 or not ashita.fs.exists(path)) then
        return;
    end
    winmm.PlaySoundA(path, nil, bit.bor(SND_FILENAME, SND_ASYNC, SND_NODEFAULT));
end

--------------------------------------------------------------------------------------------------
-- Core trigger handling
--
-- handle_av_use:     Absolute Virtue itself performed the reaction -> arm the countdown.
-- handle_player_use: An ally used the matching real SP -> lock it if it's currently armed.
--------------------------------------------------------------------------------------------------
local function set_alert(text, color)
    avh.alert_text   = text;
    avh.alert_color  = color;
    avh.alert_set_at = os.clock();
end

local function handle_av_use(name)
    local st = avh.state[name];
    if (st == nil or st.status == 'locked') then
        return; -- shouldn't happen (AV's own pool should exclude locked abilities), but be defensive
    end

    st.armed      = true;
    st.armed_time = os.clock();

    print_msg(chat.warning(('Absolute Virtue used %s! Counter within %.1fs to lock it.'):fmt(name, LOCK_WINDOW)));
    set_alert(('%s used by AV - counter now!'):fmt(name), COLOR_ARMED);

    avh.bar_active = true;
    avh.bar_start  = os.clock();
    avh.bar_window = LOCK_WINDOW;

    play_sound(avh.settings.general.sound_trigger);
end

local function handle_player_use(name, actor_name)
    local st = avh.state[name];
    if (st == nil) then
        return;
    end

    if (st.status == 'locked') then
        return; -- already neutralized, nothing to do
    end

    local now = os.clock();

    if (st.armed and (now - st.armed_time) <= LOCK_WINDOW) then
        st.status = 'locked';
        st.armed  = false;

        print_msg(chat.success(('%s LOCKED by %s!'):fmt(name, actor_name)));
        set_alert(('%s LOCKED by %s!'):fmt(name, actor_name), COLOR_LOCKED);
        play_sound(avh.settings.general.sound_lock);
        avh.bar_active = false;
    else
        -- Used outside any active window - informational only, doesn't change any state.
        print_msg(chat.message(('%s used %s (Absolute Virtue hasn\'t shown it recently - no effect).'):fmt(actor_name, name)));
    end
end

--------------------------------------------------------------------------------------------------
-- Renders the main window.
--------------------------------------------------------------------------------------------------
local function render()
    if (not avh.settings.visible[1]) then
        return;
    end

    -- Auto-expire armed windows and the top alert line so the display reflects reality even with
    -- no new packets since the last frame.
    local now = os.clock();
    for _, name in ipairs(ABILITY_ORDER) do
        local st = avh.state[name];
        if (st ~= nil and st.armed and (now - st.armed_time) > LOCK_WINDOW) then
            st.armed = false;
        end
    end
    if (avh.bar_active and (now - avh.bar_start) > avh.bar_window) then
        avh.bar_active = false;
    end
    if (avh.alert_set_at > 0 and (now - avh.alert_set_at) > ALERT_DISPLAY_SECONDS) then
        avh.alert_text   = 'No activity yet.';
        avh.alert_color  = COLOR_IDLE;
        avh.alert_set_at = 0;
    end

    -- Fixed width, auto height: AlwaysAutoResize recomputes width every frame to fit whatever
    -- text is currently longest (the alert line, "ARMED 10.0s" labels, etc.), which made the
    -- window visibly grow and shrink as the countdown text changed. Passing a fixed width with
    -- height 0 every frame (ImGuiCond_Always) keeps the width constant while the height still
    -- auto-fits the content, and ImGuiWindowFlags_NoResize hides the now-pointless resize grip.
    imgui.SetNextWindowSize({ WINDOW_WIDTH, 0, }, ImGuiCond_Always);
    if (imgui.Begin('Absolute Virtue Helper', avh.settings.visible, ImGuiWindowFlags_NoResize)) then
        imgui.TextColored(avh.alert_color, avh.alert_text);

        if (avh.bar_active) then
            local remaining = math.max(0, avh.bar_window - (now - avh.bar_start));
            local frac = (avh.bar_window > 0) and (remaining / avh.bar_window) or 0;
            imgui.ProgressBar(frac, { -1, 0 }, ('%.1fs'):fmt(remaining));
        end

        imgui.Separator();

        if (imgui.BeginTable('avh_table', 2, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_SizingStretchProp))) then
            imgui.TableSetupColumn('Ability');
            imgui.TableSetupColumn('Status');
            imgui.TableHeadersRow();

            for _, name in ipairs(ABILITY_ORDER) do
                if (avh.settings.abilities[name]) then
                    imgui.TableNextRow();

                    imgui.TableNextColumn();
                    imgui.Text(name);

                    imgui.TableNextColumn();
                    local st = avh.state[name];
                    if (st == nil or st.status == 'unlocked' and not st.armed) then
                        imgui.TextColored(COLOR_UNLOCKED, 'unlocked');
                    elseif (st.status == 'locked') then
                        imgui.TextColored(COLOR_LOCKED, 'LOCKED');
                    elseif (st.armed) then
                        local remaining = math.max(0, LOCK_WINDOW - (now - st.armed_time));
                        imgui.TextColored(COLOR_ARMED, ('ARMED %.1fs'):fmt(remaining));
                    else
                        imgui.TextColored(COLOR_UNLOCKED, 'unlocked');
                    end
                end
            end

            imgui.EndTable();
        end

        imgui.Separator();
        imgui.TextDisabled(('Sound: %s'):fmt(avh.settings.general.play_sound and 'On' or 'Muted'));
        imgui.TextDisabled(('Auto-reset on AV speech: %s'):fmt(avh.settings.general.auto_reset_on_speech and 'On' or 'Off'));

        if (#avh.unresolved > 0) then
            imgui.Separator();
            imgui.TextColored(COLOR_WARNING, 'Unresolved (see chat log):');
            avh.unresolved:each(function (name)
                imgui.BulletText(name);
            end);
        end
    end
    imgui.End();
end

--------------------------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------------------------
local function print_help()
    print(chat.header(addon.name):append(chat.message('Available commands:')));

    local cmds = T{
        { '/avh',                      'Toggle the window.', },
        { '/avh show',                 'Show the window.', },
        { '/avh hide',                 'Hide the window.', },
        { '/avh reset',                'Clear all lock/unlock state (start of a new pull).', },
        { '/avh mute / unmute',        'Toggle sound alerts.', },
        { '/avh speechreset on/off',   'Toggle auto-reset when AV\'s engage speech is seen in chat.', },
        { '/avh abilities',            'List tracked abilities and resolved ids.', },
        { '/avh help',                 'Shows this help.', },
    };

    cmds:each(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

ashita.events.register('command', 'avh_command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/avh') then
        return;
    end
    e.blocked = true;

    if (#args == 1) then
        avh.settings.visible[1] = not avh.settings.visible[1];
        settings.save();
        return;
    end

    local sub = args[2]:lower();

    if (sub == 'help') then
        print_help();
    elseif (sub == 'show') then
        avh.settings.visible[1] = true;
        settings.save();
    elseif (sub == 'hide') then
        avh.settings.visible[1] = false;
        settings.save();
    elseif (sub == 'reset') then
        reset_state();
        print_msg('State reset - all abilities unlocked.');
    elseif (sub == 'mute') then
        avh.settings.general.play_sound = false;
        settings.save();
        print_msg('Sound alerts muted.');
    elseif (sub == 'unmute') then
        avh.settings.general.play_sound = true;
        settings.save();
        print_msg('Sound alerts unmuted.');
    elseif (sub == 'speechreset') then
        local val = (args[3] or ''):lower();
        if (val == 'on') then
            avh.settings.general.auto_reset_on_speech = true;
            settings.save();
            print_msg('Auto-reset on AV engage speech: ON.');
        elseif (val == 'off') then
            avh.settings.general.auto_reset_on_speech = false;
            settings.save();
            print_msg('Auto-reset on AV engage speech: OFF.');
        else
            print_msg(('Auto-reset on AV engage speech is currently %s. Usage: /avh speechreset on|off'):fmt(
                avh.settings.general.auto_reset_on_speech and 'ON' or 'OFF'));
        end
    elseif (sub == 'abilities') then
        print_msg('Tracked abilities (player-side id used to detect the counter-SP):');
        for _, name in ipairs(ABILITY_ORDER) do
            if (avh.settings.abilities[name]) then
                local id = avh.ability_ids[name];
                print_msg(('  %-16s -> %s  (AV mob-skill id: %s)'):fmt(
                    name,
                    id ~= nil and tostring(id) or 'NOT FOUND',
                    tostring(MOB_SKILL_IDS[name])
                ));
            end
        end
    else
        print_help();
    end
end);

--------------------------------------------------------------------------------------------------
-- event: load
--------------------------------------------------------------------------------------------------
ashita.events.register('load', 'avh_load_cb', function ()
    resolve_abilities();
    reset_state();
    print_msg(('Loaded (v%s). Use /avh help for commands.'):fmt(addon.version));
end);

--------------------------------------------------------------------------------------------------
-- event: packet_in
--------------------------------------------------------------------------------------------------
ashita.events.register('packet_in', 'avh_packet_in_cb', function (e)
    if (not avh.settings.general.enabled) then
        return;
    end

    -- Zone change: treat as a new pull and reset all lock/unlock state.
    if (e.id == 0x000A and avh.settings.general.auto_reset_on_zone) then
        reset_state();
        return;
    end

    if (e.id ~= 0x0028) then
        return;
    end

    local ok, pkt = pcall(parse_action_packet, e);
    if (not ok or pkt == nil) then
        return;
    end

    if (pkt.Type == CATEGORY_MOB_TP_MOVE) then
        -- Is this one of AV's tracked reaction ids?
        local ability_name = avh.mobskill_to_name[pkt.Id];
        if (ability_name == nil) then
            return;
        end

        -- Confirm the actor is actually Absolute Virtue, not some unrelated monster that happens
        -- to share a mob skill id (several are reused across many NMs).
        local actor_name = resolve_mob_name(pkt.UserId);
        if (actor_name == nil or actor_name:lower() ~= avh.settings.general.mob_name:lower()) then
            return;
        end

        handle_av_use(ability_name);
        return;
    end

    if (pkt.Type == CATEGORY_JOB_ABILITY or pkt.Type == CATEGORY_JOB_ABILITY_UNBLINKABLE) then
        local ability_name = avh.id_to_name[pkt.Id];
        if (ability_name == nil) then
            return;
        end

        local is_ally, ally_name = get_ally_name(pkt.UserId);
        if (not is_ally) then
            return;
        end

        handle_player_use(ability_name, ally_name);
        return;
    end
end);

--------------------------------------------------------------------------------------------------
-- event: text_in (incoming chat-log text - used to auto-detect a fresh pull via AV's own speech)
--------------------------------------------------------------------------------------------------
ashita.events.register('text_in', 'avh_text_in_cb', function (e)
    if (e.injected) then
        return; -- ignore lines injected by other addons (avoids feedback loops)
    end
    check_speech_reset(e.message);
end);

--------------------------------------------------------------------------------------------------
-- event: d3d_present
--------------------------------------------------------------------------------------------------
ashita.events.register('d3d_present', 'avh_present_cb', function ()
    render();
end);

--------------------------------------------------------------------------------------------------
-- event: unload
--------------------------------------------------------------------------------------------------
ashita.events.register('unload', 'avh_unload_cb', function ()
    settings.save();
end);
