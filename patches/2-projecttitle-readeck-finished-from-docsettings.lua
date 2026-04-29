-- ProjectTitle / KOReader userpatch
-- Readeck-only finished-status bridge for ProjectTitle.
--
-- Why this exists:
--   Readeck articles may be correctly marked complete in KOReader DocSettings:
--     summary.status = "complete"
--     percent_finished = 1
--   but ProjectTitle's file-browser row renders the trophy from BookList.getBookInfo().status.
--   This patch copies the DocSettings completion fields into BookInfo ONLY for files
--   inside the Readeck plugin's configured download directory.
--
-- Install:
--   Put this file in koreader/patches/ and restart KOReader.
--   Disable/remove any broader earlier version of this patch to avoid double patching.

local logger = require("logger")

local ENABLE = true
local DEBUG = false

local readeck_dir_cache = false -- false = not loaded yet; nil = no valid dir

local function normalize_dir(path)
    if type(path) ~= "string" or path == "" then return nil end
    -- Keep this simple and KOReader-friendly: compare normalized slash prefixes.
    path = path:gsub("\\", "/")
    if path:sub(-1) ~= "/" then
        path = path .. "/"
    end
    return path
end

local function normalize_path(path)
    if type(path) ~= "string" or path == "" then return nil end
    return path:gsub("\\", "/")
end

local function get_readeck_directory()
    if readeck_dir_cache ~= false then
        return readeck_dir_cache
    end

    readeck_dir_cache = nil

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "frontend/luasettings")
    if not ok_ds or not ok_ls or not DataStorage or not LuaSettings then
        return nil
    end

    local ok, rd_settings = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/readeck.lua")
    end)
    if not ok or not rd_settings then
        return nil
    end

    local data
    pcall(function()
        data = rd_settings:readSetting("readeck", {})
    end)

    if type(data) == "table" then
        readeck_dir_cache = normalize_dir(data.directory)
    end

    if DEBUG then
        logger.info("PT Readeck finished patch: readeck_dir=", tostring(readeck_dir_cache))
    end

    return readeck_dir_cache
end

local function is_readeck_file(filepath)
    filepath = normalize_path(filepath)
    local dir = get_readeck_directory()
    if not filepath or not dir then return false end
    return filepath:sub(1, #dir) == dir
end

local function read_doc_status(filepath)
    if not is_readeck_file(filepath) then return nil, nil end

    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then return nil, nil end

    local ds_ok, ds = pcall(function()
        return DocSettings:open(filepath)
    end)
    if not ds_ok or not ds then return nil, nil end

    local summary, percent_finished
    pcall(function()
        summary = ds:readSetting("summary")
        percent_finished = ds:readSetting("percent_finished")
    end)

    local status = type(summary) == "table" and summary.status or nil
    percent_finished = tonumber(percent_finished)

    -- Trust KOReader/Readeck completion for Readeck articles, even if the final
    -- xpointer is odd, e.g. an image/table node rather than a clean end marker.
    if not status and percent_finished == 1 then
        status = "complete"
    end

    return status, percent_finished
end

local function patch_booklist(BookList, label)
    if type(BookList) ~= "table" then return false end
    if BookList.__pt_readeck_finished_docsettings_patched then return true end
    if type(BookList.getBookInfo) ~= "function" then return false end

    local orig_getBookInfo = BookList.getBookInfo

    BookList.getBookInfo = function(filepath, ...)
        local info = orig_getBookInfo(filepath, ...)
        if type(info) ~= "table" then
            info = {}
        end

        if is_readeck_file(filepath) then
            local status, percent_finished = read_doc_status(filepath)

            -- Only promote completion-ish values. Don't interfere with normal
            -- in-progress Readeck articles or non-Readeck books.
            if status == "complete" or status == "abandoned" or percent_finished == 1 then
                info.status = status or "complete"
                info.percent_finished = percent_finished or info.percent_finished or 1
            elseif info.percent_finished == nil and percent_finished ~= nil then
                -- Harmless: lets ProjectTitle draw regular progress for Readeck articles
                -- if BookList omitted it, without marking them finished.
                info.percent_finished = percent_finished
            end

            if DEBUG then
                logger.info(
                    "PT Readeck finished patch:", tostring(filepath),
                    "status=", tostring(info.status),
                    "pct=", tostring(info.percent_finished),
                    "via", tostring(label)
                )
            end
        end

        return info
    end

    BookList.__pt_readeck_finished_docsettings_patched = true
    logger.info("✅ PT Readeck-only finished-status patch applied to", label)
    return true
end

local function install_require_hook()
    if _G.__pt_readeck_finished_docsettings_require_hooked then return end

    local orig_require = _G.require
    _G.require = function(name)
        local mod = orig_require(name)
        if name == "ui/widget/booklist" then
            pcall(patch_booklist, mod, name)
        end
        return mod
    end

    _G.__pt_readeck_finished_docsettings_require_hooked = true
end

if ENABLE then
    pcall(install_require_hook)
    if package.loaded and package.loaded["ui/widget/booklist"] then
        pcall(patch_booklist, package.loaded["ui/widget/booklist"], "ui/widget/booklist(preloaded)")
    end
end

return true
