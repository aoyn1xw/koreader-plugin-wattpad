local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local api = require("api")
local ui = require("ui")

local function loadEpubBackend()
    local candidates = {
        "newsdownloader.epubdownloadbackend",
        "plugins.newsdownloader.koplugin.epubdownloadbackend",
        "epubdownloadbackend",
    }
    for _, modname in ipairs(candidates) do
        local ok, backend = pcall(require, modname)
        if ok and backend then
            return true, backend
        end
    end

    local extra_paths = {
        "/mnt/us/koreader/plugins/newsdownloader.koplugin/?.lua",
        "/mnt/us/koreader/plugins/newsdownloader.koplugin/?/init.lua",
    }
    for _, p in ipairs(extra_paths) do
        if not package.path:find(p, 1, true) then
            package.path = package.path .. ";" .. p
        end
    end

    local ok, backend = pcall(require, "epubdownloadbackend")
    if ok and backend then
        return true, backend
    end

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

local MAX_HTML_BYTES_PER_EPUB = 1000 * 1024
local MAX_CHAPTERS_PER_EPUB = 20

local function buildHtmlPrefix(payload)
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

    return parts
end

local function appendChapter(html_parts, chapter)
    html_parts[#html_parts + 1] = string.format("<h2>%s</h2>", chapter.title)
    html_parts[#html_parts + 1] = chapter.html or ""
end

local function finalizeHtml(html_parts)
    html_parts[#html_parts + 1] = "</body></html>"
    return table.concat(html_parts)
end

local function shouldRotateChunk(chapter_count, chunk_bytes, next_chapter_bytes)
    if chapter_count <= 0 then
        return false
    end
    if chapter_count >= MAX_CHAPTERS_PER_EPUB then
        return true
    end
    return (chunk_bytes + next_chapter_bytes) > MAX_HTML_BYTES_PER_EPUB
end

local function buildStoryTitle(base_title, chunk_index)
    if chunk_index <= 1 then
        return base_title
    end
    return string.format("%s (Part %d)", base_title, chunk_index)
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
        local metadata, metadata_err = api.fetchStoryMetadata(story_id, token)
        if metadata_err then
            ui.notify(_("Failed to fetch story: ") .. metadata_err)
            return
        end
        if type(metadata) ~= "table" then
            ui.notify(_("Failed to fetch story metadata."))
            return
        end
        if type(metadata.parts) ~= "table" then
            metadata.parts = {}
        end

        ui.selectChapters(metadata.parts, function(selected_parts)
            if selected_parts == nil then
                return
            end

            local parts_to_download = selected_parts
            if #parts_to_download == 0 then
                parts_to_download = metadata.parts
            end

            if #parts_to_download == 0 then
                ui.notify(_("No chapters found for this story."))
                return
            end

            local base_title = metadata.title or ("Story " .. tostring(story_id))
            local filename_prefix = sanitizeFilename(base_title) .. "_" .. os.date("%Y%m%d_%H%M%S")
            local source_url = api.BASE_URL .. "/story/" .. tostring(metadata.id or story_id)
            local created_paths = {}
            local chunk_index = 1
            local chunk_chapter_count = 0
            local chunk_bytes = 0
            local chunk_payload = {
                title = buildStoryTitle(base_title, chunk_index),
                description = metadata.description,
                cover = metadata.cover,
            }
            local html_parts = buildHtmlPrefix(chunk_payload)

            local function flushChunk()
                if chunk_chapter_count == 0 then
                    return true
                end

                local html = finalizeHtml(html_parts)
                local filename = filename_prefix
                if chunk_index > 1 then
                    filename = filename .. string.format("_part%02d", chunk_index)
                end
                local epub_path = "/tmp/" .. filename .. ".epub"
                local ok = EpubBackend:createEpub(epub_path, html, source_url, true, chunk_payload.title, false, nil, nil)
                if not ok then
                    return false
                end

                created_paths[#created_paths + 1] = epub_path
                chunk_index = chunk_index + 1
                chunk_chapter_count = 0
                chunk_bytes = 0
                chunk_payload = {
                    title = buildStoryTitle(base_title, chunk_index),
                    description = metadata.description,
                    cover = metadata.cover,
                }
                html_parts = buildHtmlPrefix(chunk_payload)
                collectgarbage()
                collectgarbage()
                return true
            end

            for idx, part in ipairs(parts_to_download) do
                local chapter_html, chapter_err = api.fetchChapterHtml(part.id, token)
                if chapter_err then
                    ui.notify(_("Failed to fetch chapter ") .. tostring(idx) .. ": " .. chapter_err)
                    return
                end

                local chapter = {
                    title = part.title or ("Chapter " .. tostring(idx)),
                    html = chapter_html,
                }
                local chapter_block_size = #(chapter.html or "") + #(chapter.title or "") + 64
                if shouldRotateChunk(chunk_chapter_count, chunk_bytes, chapter_block_size) then
                    local ok = flushChunk()
                    if not ok then
                        ui.notify(_("EPUB creation failed."))
                        return
                    end
                end

                appendChapter(html_parts, chapter)
                chunk_chapter_count = chunk_chapter_count + 1
                chunk_bytes = chunk_bytes + chapter_block_size
                chapter.html = nil
                collectgarbage()
            end

            local ok = flushChunk()
            if not ok then
                ui.notify(_("EPUB creation failed."))
                return
            end

            if #created_paths == 0 then
                ui.notify(_("No EPUB was created."))
                return
            end

            if #created_paths == 1 then
                ui.notify(_("Saved EPUB: ") .. created_paths[1])
            else
                ui.notify(_("Saved ") .. tostring(#created_paths) .. _(" EPUB parts. First file: ") .. created_paths[1])
            end

            if not openDocument(created_paths[1]) then
                UIManager:show(InfoMessage:new({
                    text = _("EPUB created but could not auto-open.\nPath: ") .. created_paths[1],
                }))
            end
        end)
    end)
end
function WattpadPlugin:init()
    print("WattpadPlugin: initializing...")
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
