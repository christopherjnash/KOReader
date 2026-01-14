--[[
    Project: Title user patch
    - Tap: open Readeck download folder (PT-style: FileManager.instance.file_chooser:changeToPath)
    - Hold: sync Readeck articles (Dispatcher action: readeck_download)
--]]

local userpatch  = require("userpatch")
local Dispatcher = require("dispatcher")

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")
local LuaSettings = require("frontend/luasettings")
local FileManager = require("apps/filemanager/filemanager")
local util        = require("util")

-- =========================== CONFIG ===========================
-- Pick the button to replace (do NOT replace the essential ones).
-- local button_to_replace = "right3"      -- Open last book (book w/ arrow)
local button_to_replace = "left2"         -- Favorites (heart)
-- local button_to_replace = "left3"       -- History (clock)

-- Choose a new icon for the button (without extension).
local new_icon = "readeck"
-- =============================================================

local function get_readeck_directory()
    local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/readeck.lua")
    local cfg = s:readSetting("readeck", {})
    return cfg and cfg.directory
end

local function normalize_dir(dir)
    if not dir or dir == "" then return nil end
    dir = dir:gsub("/+$", "") -- strip trailing slashes
    return dir
end

-- TAP: Open Readeck folder using the same navigation mechanism as Project: Title's "home" navigation:
-- FileManager.instance.file_chooser:changeToPath(...)
local new_tap_callback = function()
    local dir = normalize_dir(get_readeck_directory())
    if not dir then
        UIManager:show(InfoMessage:new{
            text = "Readeck download folder not set.\nConfigure it in Readeck plugin settings.",
        })
        return
    end

    if not util.directoryExists(dir) then
        UIManager:show(InfoMessage:new{
            text = "Readeck download folder does not exist:\n" .. dir,
        })
        return
    end

    -- PT-style: navigate within existing FileManager file chooser if possible
    local fm = FileManager.instance
    if fm and fm.file_chooser and fm.file_chooser.changeToPath then
        local ok, err = pcall(function()
            -- 2nd arg is the focused_path; PT passes current_path to preserve focus.
            -- We'll focus the folder itself.
            fm.file_chooser:changeToPath(dir, dir)
        end)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = "Failed to navigate via FileChooser:\n" .. tostring(err),
            })
        end
        return
    end

    -- Fallback (if FileManager isn't up yet): open file browser at dir
    local ok, err = pcall(function()
        FileManager:showFiles(dir)
    end)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = "Failed to open FileManager:\n" .. tostring(err),
        })
    end
end

-- HOLD: Sync Readeck articles
local new_hold_callback = function()
    local ok, err = pcall(function()
        Dispatcher:execute({ "readeck_download" })
    end)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = "Readeck sync failed:\n" .. tostring(err),
        })
    end
end

-- Patch Project: Title toolbar button
local function patchCoverBrowser(plugin)
    local TitleBar = require("titlebar")
    local orig_TitleBar_init = TitleBar.init
    TitleBar.init = function(self)
        self[button_to_replace .. "_icon"] = new_icon or self[button_to_replace .. "_icon"]
        self[button_to_replace .. "_icon_tap_callback"] = new_tap_callback or self[button_to_replace .. "_icon_tap_callback"]
        self[button_to_replace .. "_icon_hold_callback"] = new_hold_callback or self[button_to_replace .. "_icon_hold_callback"]
        orig_TitleBar_init(self)
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
