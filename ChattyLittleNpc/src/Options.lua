---@class Options: table, AceConsole-3.0
local Options = LibStub("AceAddon-3.0"):NewAddon("Options", "AceConsole-3.0")

---@class ChattyLittleNpc: AceAddon-3.0, AceConsole-3.0, AceEvent-3.0
local CLN

-- Store a reference to ChattyLittleNpc
function Options:SetChattyLittleNpcReference(reference)
    CLN = reference
end

local options = {
    name = "Chatty Little Npc",
    handler = CLN,
    type = 'group',
    args = {
        DebuggingImprovements = {
            order = 100,
            type = 'group',
            name = 'Debugging and Improvements',
            inline = true,
            args = {
                printMissingFiles = {
                    type = 'toggle',
                    name = 'Print Missing Files',
                    desc = 'Toggle to print missing voiceover files.',
                    get = function(info) return CLN.db.profile.printMissingFiles end,
                    set = function(info, value) CLN.db.profile.printMissingFiles = value end,
                },
                logNpcTexts = {
                    type = 'toggle',
                    name = 'Track NPC data',
                    desc = 'Toggle to save all the texts that an npc has to saved variables. (Enable if you want to contribute to addon development by helping to gather data for voiceover generation. Contact us on discord if you want to help.)',
                    get = function(info) return CLN.db.profile.logNpcTexts end,
                    set = function(info, value)
                        CLN.db.profile.logNpcTexts = value
                        if (not value) then
                            CLN.db.profile.printNpcTexts = false
                        end
                    end,
                },
                overwriteExistingGossipValues = {
                    type = 'toggle',
                    name = 'Overwrite existing values.',
                    desc = 'Overwrite existing values of gathered npc texts when interacting not the first time.',
                    get = function(info) return CLN.db.profile.overwriteExistingGossipValues end,
                    set = function(info, value) CLN.db.profile.overwriteExistingGossipValues = value end,
                },
                printNpcTexts = {
                    type = 'toggle',
                    name = 'Print NPC data (if tracking enabled)',
                    desc = 'Toggle to print the data that is being collected by npc dialog tracker (if it is enabled).',
                    get = function(info) return CLN.db.profile.printNpcTexts end,
                    set = function(info, value) CLN.db.profile.printNpcTexts = value end,
                },
                debugMode = {
                    type = 'toggle',
                    name = 'Print Debug Messages',
                    desc = 'Toggle to print debug messages.',
                    get = function(info) return CLN.db.profile.debugMode end,
                    set = function(info, value) 
                        CLN.db.profile.debugMode = value 
                        -- no additional action required; gates read dynamically
                    end,
                },
                debugNoAnim = {
                    type = 'toggle',
                    name = 'Disable Animations (Debug Camera)',
                    desc = 'Freeze all model/emote animations to debug camera framing. Camera logs remain active.',
                    get = function(info) return CLN.db.profile.debugNoAnim end,
                    set = function(info, value)
                        CLN.db.profile.debugNoAnim = value
                        if CLN.ReplayFrame and CLN.ReplayFrame.SetNoAnimDebug then
                            CLN.ReplayFrame:SetNoAnimDebug(value)
                            if CLN.ReplayFrame._UpdateModelOnUpdateHook then
                                CLN.ReplayFrame:_UpdateModelOnUpdateHook()
                            end
                        end
                    end,
                },
                debugAnimations = {
                    type = 'toggle',
                    name = 'Animation Debug',
                    desc = 'Reduce noise: only print animation-related debug when enabled.',
                    get = function(info) return CLN.db.profile.debugAnimations end,
                    set = function(info, value) CLN.db.profile.debugAnimations = value end,
                },
                debugAnimCategoriesAll = {
                    type = 'toggle',
                    name = 'Animation Categories: All',
                    desc = 'When enabled, all animation debug categories are printed. Disable to pick specific categories below.',
                    disabled = function()
                        return not (CLN.db.profile.debugMode and CLN.db.profile.debugAnimations)
                    end,
                    get = function(info)
                        return CLN.db.profile.debugAnimCategories == 'all'
                    end,
                    set = function(info, value)
                        if value then
                            CLN.db.profile.debugAnimCategories = 'all'
                        else
                            CLN.db.profile.debugAnimCategories = {}
                        end
                    end,
                },
                debugAnimCategories = {
                    type = 'multiselect',
                    name = 'Animation Categories',
                    desc = 'Choose which categories of animation debug logs to print. Applies only when Debug Mode and Animation Debug are enabled.',
                    values = function()
                        return {
                            camera = 'Camera',
                            framing = 'Framing',
                            projection = 'Projection',
                            host = 'Host/Backend',
                            modelFrame = 'Model Frame',
                            fsm = 'State Machine',
                        }
                    end,
                    disabled = function()
                        return not (CLN.db.profile.debugMode and CLN.db.profile.debugAnimations) or CLN.db.profile.debugAnimCategories == 'all'
                    end,
                    get = function(info, key)
                        local cats = CLN.db.profile.debugAnimCategories
                        if cats == 'all' then return true end
                        if cats == nil then return true end -- treat nil as all selected
                        if type(cats) == 'table' then return cats[key] == true end
                        if type(cats) == 'string' then
                            local s = string.lower(cats)
                            if s == 'all' then return true end
                            for token in s:gmatch('[^,%s]+') do
                                if token == string.lower(key) then return true end
                            end
                        end
                        return false
                    end,
                    set = function(info, key, state)
                        local function allKeys()
                            return { 'camera', 'framing', 'projection', 'host', 'modelFrame', 'fsm' }
                        end
                        local cats = CLN.db.profile.debugAnimCategories
                        if cats == 'all' or cats == nil or type(cats) ~= 'table' then
                            -- Start from "all selected" baseline
                            local map = {}
                            for _, k in ipairs(allKeys()) do map[k] = true end
                            cats = map
                        end
                        cats[key] = state and true or nil
                        -- If all keys are true, collapse to 'all'; if none, keep empty table
                        local any, all = false, true
                        local present = {}
                        for _, k in ipairs(allKeys()) do
                            if cats[k] then any = true else all = false end
                            present[k] = true
                        end
                        -- remove any unknown keys
                        for k, _ in pairs(cats) do
                            if not present[k] then cats[k] = nil end
                        end
                        if all then
                            CLN.db.profile.debugAnimCategories = 'all'
                        else
                            -- keep map (possibly empty => logs disabled for all categories)
                            CLN.db.profile.debugAnimCategories = cats
                        end
                    end,
                },
                debugAnimCategoriesNone = {
                    type = 'execute',
                    name = 'Disable All Categories',
                    desc = 'Quickly disable all animation debug categories (nothing will print).',
                    disabled = function()
                        return not (CLN.db.profile.debugMode and CLN.db.profile.debugAnimations)
                    end,
                    func = function()
                        CLN.db.profile.debugAnimCategories = {}
                    end,
                },
                showGossipEditor = {
                    type = 'toggle',
                    name = 'Show Gossip Editor',
                    desc = 'Toggle to show the Gossip Editor window (used for editing/fixing collected npc gossip lines).',
                    get = function(info) return CLN.Editor.Frame:IsShown() end,
                    set = function(info, value)
                        if value then
                            CLN.Editor.Frame:Show()
                        else
                            CLN.Editor.Frame:Hide()
                        end
                    end,
                },
                printLoadedVoiceoverPackMetadata = {
                    type = 'execute',
                    name = 'Print VO Pack metadata',
                    desc = 'Print what VO packs were loaded, what kind of voiceovers they support and how many voiceovers they have.',
                    func = function() CLN:PrintLoadedVoiceoverPacks() end,
                },
            },
        },
        ReplayFrame = {
            order = 10,
            type = 'group',
            name = 'Replay Frame',
            inline = true,
            args = {
                advancedCameraFitting = {
                    type = 'toggle',
                    name = 'Advanced Camera Fitting (ModelScene)',
                    desc = 'Use projector-based fitting for better framing in ModelScene backend. Disable if you see jitter or prefer the classic fit.',
                    get = function(info)
                        return CLN.db.profile.advancedCameraFitting
                    end,
                    set = function(info, value)
                        CLN.db.profile.advancedCameraFitting = value
                        -- Rebuild host to switch fit delegates and reapply default fit if visible
                        if CLN.ReplayFrame and CLN.ReplayFrame.RebuildModelHost then
                            CLN.ReplayFrame:RebuildModelHost()
                        end
                        if CLN.ReplayFrame and CLN.ReplayFrame.ApplyDefaultFit then
                            local cur = CLN.VoiceoverPlayer and CLN.VoiceoverPlayer.currentlyPlaying
                            if cur and (CLN.ReplayFrame.NpcModelFrame and CLN.ReplayFrame.NpcModelFrame.IsShown and CLN.ReplayFrame.NpcModelFrame:IsShown()) then
                                CLN.ReplayFrame:ApplyDefaultFit(cur.displayID)
                            end
                        end
                    end,
                },
                disableCameraAnimations = {
                    type = 'toggle',
                    name = 'Disable Camera Animations',
                    desc = 'Stop camera zoom/pan easing during playback; model/emote animations still run.',
                    get = function(info)
                        return CLN.db.profile.disableCameraAnimations
                    end,
                    set = function(info, value)
                        CLN.db.profile.disableCameraAnimations = value
                        if CLN.ReplayFrame then
                            if CLN.ReplayFrame.AnimStop then
                                CLN.ReplayFrame:AnimStop('zoom')
                                CLN.ReplayFrame:AnimStop('pan')
                            end
                            if CLN.ReplayFrame._UpdateModelOnUpdateHook then
                                CLN.ReplayFrame:_UpdateModelOnUpdateHook()
                            end
                        end
                    end,
                },
                renderBackend = {
                    type = 'select',
                    name = 'Render Backend',
                    desc = 'Choose which model renderer to use for the floating head. Auto prefers ModelScene if available; PlayerModel is the legacy fallback.',
                    values = function()
                        return { auto = 'Auto (prefer ModelScene)', scene = 'ModelScene (Retail)', player = 'PlayerModel (Legacy)' }
                    end,
                    hidden = function()
                        -- Only show when ModelScene is available in client
                        return not (CLN and CLN.ReplayFrame and CLN.ReplayFrame.IsModelSceneAvailable and CLN.ReplayFrame:IsModelSceneAvailable())
                    end,
                    get = function(info)
                        return CLN.db.profile.renderBackend or 'auto'
                    end,
                    set = function(info, value)
                        CLN.db.profile.renderBackend = value
                        -- Rebuild model host with new backend and refresh
                        if CLN.ReplayFrame and CLN.ReplayFrame.RebuildModelHost then
                            CLN.ReplayFrame:RebuildModelHost()
                        end
                        if CLN.ReplayFrame and CLN.ReplayFrame.UpdateDisplayFrameState then
                            CLN.ReplayFrame:UpdateDisplayFrameState()
                        end
                    end,
                },
                -- Edit Mode specific settings removed
                queueTextScale = {
                    type = 'range',
                    name = 'Queue Text Scale',
                    desc = 'Scale the header and queue row text size.',
                    min = 0.75,
                    max = 1.5,
                    step = 0.05,
                    get = function(info)
                        return CLN.db.profile.queueTextScale or 1.0
                    end,
                    set = function(info, value)
                        CLN.db.profile.queueTextScale = value
                        if CLN.ReplayFrame and CLN.ReplayFrame.ApplyQueueTextScale then CLN.ReplayFrame:ApplyQueueTextScale() end
                    end,
                },
                compactMode = {
                    type = 'toggle',
                    name = 'Compact Mode (hide NPC model)',
                    desc = 'Hide the NPC model and shrink the queue frame width.',
                    get = function(info) return CLN.db.profile.compactMode end,
                    set = function(info, value)
                        CLN.db.profile.compactMode = value
                        if CLN.ReplayFrame and CLN.ReplayFrame.UpdateDisplayFrameState then CLN.ReplayFrame:UpdateDisplayFrameState() end
                    end,
                },
                resetFramePos = {
                    type = 'execute',
                    name = 'Reset Replay Frame Position',
                    desc = 'Reset the replay frame position to its default values.',
                    func = function() CLN.ReplayFrame:ResetFramePosition() end,
                },
                openEditMode = {
                    type = 'execute',
                    name = 'Open Edit Mode (show frame)',
                    desc = 'Show the replay frame and enter Edit Mode so you can move/resize it, even if nothing is playing.',
                    func = function()
                        if CLN and CLN.ReplayFrame and CLN.ReplayFrame.ShowForEdit then
                            CLN.ReplayFrame:ShowForEdit()
                        end
                    end,
                },
                showReplayFrame = {
                    type = 'toggle',
                    name = 'Show Floating Head Frame (voiceover queue)',
                    desc = 'Toggle to show the floating head frame (voiceover queue)',
                    get = function(info) return CLN.db.profile.showReplayFrame end,
                    set = function(info, value)
                        CLN.db.profile.showReplayFrame = value
                        if CLN.ReplayFrame and CLN.ReplayFrame.UpdateDisplayFrameState then CLN.ReplayFrame:UpdateDisplayFrameState() end
                    end,
                },
            },
        },
        PlaybackOptions = {
            order = 20,
            type = 'group',
            name = 'Playback Options',
            inline = true,
            args = {
                autoPlayVoiceovers = {
                    type = 'toggle',
                    name = 'Play on dialog window open',
                    desc = 'Toggle to play voiceovers when opening the gossip or quest window.',
                    get = function(info) return CLN.db.profile.autoPlayVoiceovers end,
                    set = function(info, value) CLN.db.profile.autoPlayVoiceovers = value end,
                },
                stopVoiceoverAfterDialogWindowClose = {
                    type = 'toggle',
                    name = 'Stop on dialog window close',
                    desc = 'Only play voiceover while the npc dialog window is open, and auto stop voiceover after the dialog window is closed. (Quest queueing will be disabled)',
                    get = function(info) return CLN.db.profile.stopVoiceoverAfterDialogWindowClose end,
                    set = function(info, value)
                        CLN.db.profile.stopVoiceoverAfterDialogWindowClose = value
                        if (value) then
                            CLN.db.profile.enableQuestPlaybackQueueing = false
                        end
                    end
                },
                enableQuestPlaybackQueueing = {
                    type = 'toggle',
                    name = 'Enable Quest Playback Queueing',
                    desc = 'Toggle to enable or disable quest playback queueing. (Stop on dialog window close will be disabled)',
                    get = function(info) return CLN.db.profile.enableQuestPlaybackQueueing end,
                    set = function(info, value)
                        CLN.db.profile.enableQuestPlaybackQueueing = value
                        if (value) then
                            CLN.db.profile.stopVoiceoverAfterDialogWindowClose = false
                        end
                    end
                },
                playVoiceoverAfterDelay = {
                    type = 'range',
                    name = 'Play Voiceover After A Delay',
                    desc = 'Set the delay (in seconds) before playing voiceovers after talking with questgiver.',
                    min = 0,
                    max = 3,
                    step = 0.1,
                    get = function(info) return CLN.db.profile.playVoiceoverAfterDelay end,
                    set = function(info, value) CLN.db.profile.playVoiceoverAfterDelay = value end,
                },
                audioChannel = {
                    type = 'select',
                    name = 'Audio Channels',
                    desc = 'Select the audio channel for voiceover playback.',
                    values = {
                        MASTER = 'MASTER',
                        DIALOG = 'DIALOG',
                        AMBIENCE = 'AMBIENCE',
                        MUSIC = 'MUSIC',
                        SFX = 'SFX',
                    },
                    get = function(info) return CLN.db.profile.audioChannel end,
                    set = function(info, value) CLN.db.profile.audioChannel = value end,
                },
                showSpeakButton = {
                    type = 'toggle',
                    name = 'Enable Speak/Play button for dialogs',
                    desc = 'Toggle to enable or disable Speak/Play button on next to the dialog frame.',
                    get = function(info) return CLN.db.profile.showSpeakButton end,
                    set = function(info, value) CLN.db.profile.showSpeakButton = value end,
                },
            },
        },
        QuestFrameButtonOptions = {
            order = 30,
            type = 'group',
            name = 'Quest And Gossip Frame Button Options',
            inline = true,
            args = {
                buttonPosX = {
                    type = 'range',
                    name = 'Button X Position',
                    desc = 'Set the X coordinate for the button position relative to the frame.',
                    min = -200,
                    max = 200,
                    step = 1,
                    get = function(info) return CLN.db.profile.buttonPosX or 0 end,
                    set = function(info, value)
                        CLN.db.profile.buttonPosX = value
                        CLN.PlayButton:UpdateButtonPositions()
                    end,
                },
                buttonPosY = {
                    type = 'range',
                    name = 'Button Y Position',
                    desc = 'Set the Y coordinate for the button position relative to the frame.',
                    min = -200,
                    max = 200,
                    step = 1,
                    get = function(info) return CLN.db.profile.buttonPosY or 0 end,
                    set = function(info, value)
                        CLN.db.profile.buttonPosY = value
                        CLN.PlayButton:UpdateButtonPositions()
                    end,
                },
                resetButtonPosition = {
                    type = 'execute',
                    name = 'Reset Button Positions',
                    desc = 'Reset the X and Y positions to their default values.',
                    func = function()
                        CLN.db.profile.buttonPosX = -15  -- Default X position
                        CLN.db.profile.buttonPosY = -30  -- Default Y position
                        CLN.PlayButton:UpdateButtonPositions()
                    end,
                },
            },
        }
    },
}

function Options:SetupOptions()
    if (not self.optionsFrame) then
        LibStub("AceConfig-3.0"):RegisterOptionsTable("ChattyLittleNpc", options)
        self.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("ChattyLittleNpc", "Chatty Little Npc")
    end
end

-- Initialize the Options module
Options:SetupOptions()

-- Helper for other modules to open the Settings category
function Options:OpenSettings()
    local dlg = LibStub("AceConfigDialog-3.0", true)
    if dlg and dlg.Open then
        dlg:Open("ChattyLittleNpc")
        return
    end
    if InterfaceOptionsFrame_OpenToCategory and self.optionsFrame then
        InterfaceOptionsFrame_OpenToCategory(self.optionsFrame)
    end
end