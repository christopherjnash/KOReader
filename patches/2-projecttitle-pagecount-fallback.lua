-- ProjectTitle / CoverBrowser userpatch (Kindle)
-- Get EPUB page counts from KOReader docsettings (where KOReader actually stores per-book metadata),
-- then write into ProjectTitle's cache so progress bars can render.
--
-- Does NOT modify EPUBs.

local userpatch = require("userpatch")
local logger = require("logger")

logger.info("✅ PT pagecount-from-docsettings patch: file loaded")

local function getPagesFromDocSettings(filepath)
    -- DocSettings is KOReader’s abstraction for per-document settings/metadata storage.
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then
        return nil, "require(docsettings) failed"
    end

    -- Try to open docsettings for this document
    local ds_ok, ds = pcall(function()
        return DocSettings:open(filepath)
    end)

    if not ds_ok or not ds then
        return nil, "DocSettings:open failed"
    end

    -- ds.data typically holds the stored table
    local data = ds.data or ds
    if type(data) ~= "table" then
        return nil, "docsettings returned non-table"
    end

    local p = tonumber(data.doc_pages)
    if p and p > 0 then
        return tostring(p), "doc_pages"
    end

    if type(data.stats) == "table" then
        local sp = tonumber(data.stats.pages)
        if sp and sp > 0 then
            return tostring(sp), "stats.pages"
        end
    end

    return nil, "no doc_pages/stats.pages in docsettings"
end

local function patchCoverBrowser()
    logger.info("✅ PT pagecount-from-docsettings patch: applying to coverbrowser")

    local BookInfoManager = require("bookinfomanager")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")

    if BookInfoManager.__pt_pagecount_from_docsettings_patched then
        logger.info("PT pagecount-from-docsettings: already patched (skipping)")
        return
    end
    BookInfoManager.__pt_pagecount_from_docsettings_patched = true

    local orig_get = BookInfoManager.getBookInfo

    BookInfoManager.getBookInfo = function(self, filepath, get_cover)
        local bi = orig_get(self, filepath, get_cover)

        local _, filetype = filemanagerutil.splitFileNameType(filepath)
        if filetype ~= "epub" then
            return bi
        end

        local pages = bi and bi.pages and tonumber(bi.pages) or nil
        if pages and pages > 0 then
            return bi
        end

        local meta_pages, source_or_err = getPagesFromDocSettings(filepath)
        if meta_pages and meta_pages ~= "0" then
            logger.info("✅ PT pagecount-from-docsettings: set pages for", filepath, "=>", meta_pages, "(source:", source_or_err .. ")")
            self:setBookInfoProperties(filepath, { pages = meta_pages })
            if bi then bi.pages = meta_pages end
        else
            logger.info("PT pagecount-from-docsettings: could not get pages for", filepath, "(" .. tostring(source_or_err) .. ")")
        end

        return bi
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
