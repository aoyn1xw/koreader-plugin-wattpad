local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local api = require("api")
local ui = require("ui")

local function loadEpubBackend()
    -- Try the standard plugin path first
    local ok, backend = pcall(require, "newsdownloader.epubdownloadbackend")
    if ok then return true, backend end

    -- Try absolute path pattern (common for some versions)
    ok, backend = pcall(require, "plugins.newsdownloader.koplugin.epubdownloadbackend")
    if ok then return true, backend end

    -- Manually inject newsdownloader into package path and try again
    package.path = package.path .. ";/mnt/us/koreader/plugins/newsdownloader.koplugin/?.lua"
    ok, backend = pcall(require, "epubdownloadbackend")
    if ok then return true, backend end

    return false, nil
end

local ok_backend, EpubBackend = loadEpubBackend()
local reader_settings = rawget(_G, "G_reader_settings")

local WattpadPlugin = WidgetContainer:extend{
    name = "wattpad",
    is_doc_only = false,
}

function WattpadPlugin:checkDependency()
    if not ok_backend then
        ui.notify(_("Error: News Downloader plugin is required for EPUB creation. Please enable it in Plugin management."))
        return false
    end
    return true
end

local function sanitizeFilename(name)
    local safe = tostring(name or "wattpad_story")
    safe = safe:gsub("[\\/:*?\"<>|]", "_")
    safe = safe:gsub("%s+", " ")
    safe = safe:gsub("^%s+", "")
    safe = safe:gsub("%s+$", "")
    if safe == "" then
        safe = "wattpad_story"
    end
    return safe
end

local function openDocument(path)
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI and ReaderUI.showReader then
        ReaderUI:showReader(path)
        return true
    end

    local ok_event, Event = pcall(require, "ui/event")
    if ok_event and Event then
        UIManager:broadcastEvent(Event:new("OpenFile", path))
        return true
    end

    return false
end

function WattpadPlugin:getToken()
    if reader_settings and reader_settings.readSetting then
        return reader_settings:readSetting("wattpad_token")
    end
    return nil
end

function WattpadPlugin:setToken(token)
    if not (reader_settings and reader_settings.saveSetting) then
        return
    end

    reader_settings:saveSetting("wattpad_token", token)
    if reader_settings.flush then
        reader_settings:flush()
    end
end

function WattpadPlugin:logout()
    self:setToken(nil)
    ui.notify(_("Wattpad token cleared."))
end

local function buildStoryHtml(payload)
    local parts = {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"/><title>",
        payload.title,
        "</title></head><body>",
        "<h1>",
        payload.title,
        "</h1>",
    }

    if payload.cover and payload.cover ~= "" then
        parts[#parts + 1] = string.format("<p><img src=\"%s\" alt=\"cover\"/></p>", payload.cover)
    end

    if payload.description and payload.description ~= "" then
        parts[#parts + 1] = "<p>"
        parts[#parts + 1] = payload.description
        parts[#parts + 1] = "</p>"
    end

    for _, chapter in ipairs(payload.chapters or {}) do
        parts[#parts + 1] = string.format("<h2>%s</h2>", chapter.title)
        parts[#parts + 1] = chapter.html or ""
    end

    parts[#parts + 1] = "</body></html>"
    return table.concat(parts)
end

function WattpadPlugin:loginFlow()
    ui.promptLogin(function(username, password)
        if not username or not password then
            return
        end

        local auth, err = api.authenticate(username, password)
        if err then
            ui.notify(_("Login failed: ") .. err)
            return
        end
        if type(auth) ~= "table" or not auth.token then
            ui.notify(_("Login failed: missing token."))
            return
        end

        self:setToken(auth.token)
        ui.notify(_("Login successful."))
    end)
end

function WattpadPlugin:downloadFromUrlFlow()
    if not self:checkDependency() then
        return
    end
    ui.promptStoryUrl(function(url)
        if not url or url == "" then
            return
        end

        local story_id, parse_err = api.extractStoryId(url)
        if parse_err then
            ui.notify(parse_err)
            return
        end

        local token = self:getToken()
        local payload, payload_err = api.buildStoryPayload(story_id, token)
        if payload_err then
            ui.notify(_("Failed to fetch story: ") .. payload_err)
            return
        end
        if type(payload) ~= "table" then
            ui.notify(_("Failed to fetch story payload."))
            return
        end
        if type(payload.chapters) ~= "table" then
            payload.chapters = {}
        end

        ui.selectChapters(payload.chapters, function(selected_chapters)
            if selected_chapters == nil then
                return
            end

            if #selected_chapters > 0 then
                payload.chapters = selected_chapters
            end

            local html = buildStoryHtml(payload)
            local filename = sanitizeFilename(payload.title) .. "_" .. os.date("%Y%m%d_%H%M%S") .. ".epub"
            local epub_path = "/tmp/" .. filename
            local source_url = payload.source_url or url

            local ok = EpubBackend:createEpub(epub_path, html, source_url, true, payload.title, false, nil, nil)
            if not ok then
                ui.notify(_("EPUB creation failed."))
                return
            end

            ui.notify(_("Saved EPUB: ") .. epub_path)
            if not openDocument(epub_path) then
                UIManager:show(InfoMessage:new({
                    text = _("EPUB created but could not auto-open.\nPath: ") .. epub_path,
                }))
            end
        end)
    end)
end

function WattpadPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function WattpadPlugin:addToMainMenu(menu_items)
    menu_items.wattpad = {
        text = _("Wattpad"),
        sub_item_table = {
            {
                text = _("Download from URL"),
                callback = function()
                    self:downloadFromUrlFlow()
                end,
            },
            {
                text = _("Login"),
                callback = function()
                    self:loginFlow()
                end,
            },
            {
                text = _("Logout"),
                callback = function()
                    self:logout()
                end,
            },
            {
                text = _("About"),
                callback = function()
                    UIManager:show(InfoMessage:new({
                        text = _("Wattpad downloader for KOReader. Uses newsdownloader EPUB backend.\n\nGitHub: https://github.com/aoyn1xw/koreader-plugin-wattpad\nAuthor: aoyn1xw"),
                    }))
                end,
            },
        },
    }
end

return WattpadPlugin
