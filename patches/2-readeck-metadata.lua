-- 2-readeck-metadata.lua
--
-- Robust: patches BookInfoManager when/when it becomes available by intercepting require().
-- Reads read_time from <article>.sdr/readeck_metadata.lua and appends " • 10 min"
-- to whichever metadata field Project: Title is displaying.

local util = require("util")
local logger = require("logger")

-- ===== Config =====
local ENABLE = true
local DEBUG  = false

local META_FILENAME = "readeck_metadata.lua"
local READTIME_KEY  = "read_time"

local SEP        = " • "
local SUFFIX_FMT = "%d min"
local MIN_MINUTES = 1
local MAX_MINUTES = 999

-- Append to the FIRST non-empty string found in this order
local CANDIDATE_KEYS = {
    "authors", "author",
    "publisher", "publishers",
    "series", "subtitle",
    "description",
    -- "title", -- uncomment if you want last-resort
}

if DEBUG then logger.info("READECK-META: patch file loaded (require-hook mode)") end

-- ===== Helpers =====
local function clamp_minutes(n)
    if type(n) ~= "number" then return nil end
    if n ~= n then return nil end
    if n < MIN_MINUTES then n = MIN_MINUTES end
    if n > MAX_MINUTES then n = MAX_MINUTES end
    return math.floor(n + 0.5)
end

local function safe_load_lua_table(path)
    if not util.fileExists(path) then return nil end
    local ok, chunk = pcall(loadfile, path)
    if not ok or type(chunk) ~= "function" then return nil end
    local ok2, tbl = pcall(chunk)
    if not ok2 or type(tbl) ~= "table" then return nil end
    return tbl
end

local function get_sdr_dir(doc_path)
    if type(doc_path) ~= "string" or doc_path == "" then return nil end
    local base = doc_path:gsub("%.[^./]+$", "") -- strip extension
    return base .. ".sdr"
end

local function get_readtime_minutes(doc_path)
    local sdr_dir = get_sdr_dir(doc_path)
    if not sdr_dir then return nil end

    local meta_path = sdr_dir .. "/" .. META_FILENAME
    if not util.fileExists(meta_path) then
        return nil
    end

    local t = safe_load_lua_table(meta_path)
    if not t then
        if DEBUG then logger.warn("READECK-META: could not load", meta_path) end
        return nil
    end

    local m = clamp_minutes(t[READTIME_KEY])
    if DEBUG then logger.info("READECK-META: read_time", tostring(m), "for", doc_path) end
    return m
end

local function already_has_suffix(s)
    if type(s) ~= "string" then return false end
    return s:match("•%s*%d+%s*min%s*$") ~= nil or s:match("%d+%s*min%s*$") ~= nil
end

local function append_suffix(source, minutes)
    if type(source) ~= "string" or source == "" then return source end
    if not minutes then return source end
    if already_has_suffix(source) then return source end
    return source .. SEP .. string.format(SUFFIX_FMT, minutes)
end

local function append_to_first_candidate(meta, minutes, file, which)
    if type(meta) ~= "table" or not minutes then return meta end
    for _, k in ipairs(CANDIDATE_KEYS) do
        if type(meta[k]) == "string" and meta[k] ~= "" then
            if DEBUG then logger.info("READECK-META:", which, "append to", k, "file:", file) end
            meta[k] = append_suffix(meta[k], minutes)
            return meta
        end
    end
    if DEBUG then logger.info("READECK-META:", which, "no candidate keys matched for", file) end
    return meta
end

-- ===== Patching BookInfoManager (table or metatable-based) =====
local function wrap_func(fn, label)
    return function(self, file, ...)
        local meta = fn(self, file, ...)
        if type(meta) ~= "table" or type(file) ~= "string" or file == "" then
            return meta
        end
        local minutes = get_readtime_minutes(file)
        if not minutes then return meta end
        return append_to_first_candidate(meta, minutes, file, label)
    end
end

local function patch_bim_object(bim, label)
    if not bim or type(bim) ~= "table" and type(bim) ~= "userdata" then return false end

    -- Don't patch twice
    if rawget(bim, "_readeck_rt_patched_any") then return true end

    local did = false

    -- Direct table methods
    if type(bim) == "table" then
        if type(bim.getBookInfo) == "function" then
            bim.getBookInfo = wrap_func(bim.getBookInfo, label .. ".getBookInfo")
            did = true
        end
        if type(bim.getDocProps) == "function" then
            bim.getDocProps = wrap_func(bim.getDocProps, label .. ".getDocProps")
            did = true
        end
    end

    -- Metatable methods
    local mt = getmetatable(bim)
    if mt and type(mt.__index) == "table" then
        local idx = mt.__index
        if type(idx.getBookInfo) == "function" and not idx._readeck_rt_patched_bookinfo then
            idx.getBookInfo = wrap_func(idx.getBookInfo, label .. ".__index.getBookInfo")
            idx._readeck_rt_patched_bookinfo = true
            did = true
        end
        if type(idx.getDocProps) == "function" and not idx._readeck_rt_patched_docprops then
            idx.getDocProps = wrap_func(idx.getDocProps, label .. ".__index.getDocProps")
            idx._readeck_rt_patched_docprops = true
            did = true
        end
    elseif mt and type(mt.__index) == "function" and not mt._readeck_rt_patched_indexfn then
        -- Intercept dynamic lookup of getBookInfo/getDocProps
        local orig_index = mt.__index
        mt.__index = function(t, k)
            local v = orig_index(t, k)
            if (k == "getBookInfo" or k == "getDocProps") and type(v) == "function" then
                return wrap_func(v, label .. ".__indexfn." .. k)
            end
            return v
        end
        mt._readeck_rt_patched_indexfn = true
        did = true
    end

    -- Mark
    if type(bim) == "table" then
        bim._readeck_rt_patched_any = did
    end

    if DEBUG then logger.info("READECK-META: patched bookinfomanager =", did) end
    return did
end

-- ===== Hook require() so we patch when bookinfomanager becomes available =====
local function install_require_hook()
    if _G._readeck_rt_require_hooked then
        if DEBUG then logger.info("READECK-META: require hook already installed") end
        return true
    end

    local orig_require = _G.require

    _G.require = function(name)
        local mod = orig_require(name)

        -- Patch exactly when it's loaded
        if name == "bookinfomanager" then
            pcall(patch_bim_object, mod, "bookinfomanager")
        end

        return mod
    end

    _G._readeck_rt_require_hooked = true
    if DEBUG then logger.info("READECK-META: installed require hook") end
    return true
end

if ENABLE then
    pcall(install_require_hook)

    -- If already loaded by the time this patch runs, patch immediately too.
    if package.loaded and package.loaded["bookinfomanager"] then
        pcall(patch_bim_object, package.loaded["bookinfomanager"], "bookinfomanager(preloaded)")
    end
end

return true
