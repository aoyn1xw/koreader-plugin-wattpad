local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local socket_url = require("socket.url")

local WattpadAPI = {
    BASE_URL = "https://www.wattpad.com",
    USER_AGENT = "Wattpad/com.wattpad.Wattpad (10.9.0; iOS 16.0; iPhone14,2; en_US)",
    PAGE_LIMIT = 500,
}

local function decodeJson(raw)
    if not raw or raw == "" then
        return nil, "empty response body"
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok then
        return nil, "invalid JSON response"
    end

    return decoded, nil
end

local function buildAuthHeaders(token)
    local headers = {
        ["user-agent"] = WattpadAPI.USER_AGENT,
        ["accept"] = "application/json",
    }

    if token and token ~= "" then
        headers["authorization"] = "Bearer " .. token
    end

    return headers
end

local function request(method, url, headers, body)
    local response_chunks = {}
    local req = {
        method = method,
        url = url,
        headers = headers or {},
        sink = ltn12.sink.table(response_chunks),
    }

    if body then
        req.source = ltn12.source.string(body)
        req.headers["content-length"] = tostring(#body)
    end

    local ok, res, status_code, response_headers, status_line = pcall(http.request, req)
    if not ok then
        return nil, "request failed"
    end

    local code = tonumber(status_code)
    local raw = table.concat(response_chunks)
    return {
        code = code,
        headers = response_headers,
        status = status_line,
        raw = raw,
    }, nil
end

function WattpadAPI.extractStoryId(url)
    if type(url) ~= "string" or url == "" then
        return nil, "story URL is required"
    end

    -- Trim whitespace
    url = url:gsub("^%s+", ""):gsub("%s+$", "")

    local story_id = url:match("/story/(%d+)")
    if not story_id then
        return nil, "invalid Wattpad story URL"
    end

    return story_id, nil
end

function WattpadAPI.authenticate(username, password)
    if not username or username == "" or not password or password == "" then
        return nil, "username and password are required"
    end

    local url = WattpadAPI.BASE_URL .. "/api/v3/users/login"
    local payload = json.encode({
        username = username,
        password = password,
    })

    local headers = {
        ["content-type"] = "application/json",
        ["accept"] = "application/json",
        ["user-agent"] = WattpadAPI.USER_AGENT,
    }

    local response, req_err = request("POST", url, headers, payload)
    if req_err then
        return nil, req_err
    end

    if not response or response.code ~= 200 then
        local code = response and response.code or "unknown"
        local data = select(1, decodeJson(response and response.raw or ""))
        local msg = type(data) == "table" and (data.error_description or data.message) or nil
        return nil, msg or ("authentication failed (HTTP " .. tostring(code) .. ")")
    end

    local data, json_err = decodeJson(response.raw)
    if json_err then
        return nil, json_err
    end

    if type(data) ~= "table" then
        return nil, "unexpected authentication response"
    end

    local token = data and (data.token or data.access_token or data.auth_token)
    if not token or token == "" then
        return nil, "authentication succeeded but token was missing"
    end

    return {
        token = token,
        raw = data,
    }, nil
end

function WattpadAPI.fetchStoryMetadata(story_id, token)
    if not story_id or story_id == "" then
        return nil, "story_id is required"
    end

    local path = "/api/v3/stories/" .. tostring(story_id)
    local query = "?fields=id,title,description,cover,parts(id,title)"
    local url = WattpadAPI.BASE_URL .. path .. query

    local response, req_err = request("GET", url, buildAuthHeaders(token), nil)
    if req_err then
        return nil, req_err
    end

    if not response or response.code ~= 200 then
        local code = response and response.code or "unknown"
        local data = select(1, decodeJson(response and response.raw or ""))
        local msg = type(data) == "table" and (data.error_description or data.message) or nil
        return nil, msg or ("failed to fetch metadata (HTTP " .. tostring(code) .. ")")
    end

    local data, json_err = decodeJson(response.raw)
    if json_err then
        return nil, json_err
    end

    if type(data) ~= "table" then
        return nil, "unexpected metadata response"
    end

    local parts = {}
    for _, part in ipairs(data.parts or {}) do
        parts[#parts + 1] = {
            id = tostring(part.id),
            title = part.title or ("Chapter " .. tostring(#parts + 1)),
        }
    end

    local cover_url = nil
    if type(data.cover) == "string" then
        cover_url = data.cover
    elseif type(data.cover) == "table" then
        cover_url = data.cover.original or data.cover.url or data.cover.medium or data.cover.small
    end

    return {
        id = tostring(data.id or story_id),
        title = data.title or ("Story " .. tostring(story_id)),
        description = data.description or "",
        cover = cover_url,
        parts = parts,
        raw = data,
    }, nil
end

function WattpadAPI.fetchChapterHtml(part_id, token)
    if not part_id or part_id == "" then
        return nil, "part_id is required"
    end

    local zlib = nil
    pcall(function() zlib = require("ffi/zlib") end)

    local pages = {}

    for page = 1, WattpadAPI.PAGE_LIMIT do
        local url = string.format("%s/apiv2/storytext?id=%s&page=%d", WattpadAPI.BASE_URL, socket_url.escape(tostring(part_id)), page)
        local response, req_err = request("GET", url, buildAuthHeaders(token), nil)
        if req_err then
            return nil, req_err
        end

        if not response or response.code ~= 200 then
            local code = response and response.code or "unknown"
            return nil, "failed to fetch chapter text (HTTP " .. tostring(code) .. ")"
        end

        local content = response.raw
        if zlib and response.headers and response.headers["content-encoding"] == "gzip" then
            local ok, decompressed = pcall(zlib.inflateGzip, content)
            if ok then
                content = decompressed
            end
        end

        if not content or content == "" then
            break
        end

        -- Wattpad apiv2/storytext returns raw HTML or text, not JSON
        pages[#pages + 1] = content
    end

    if #pages == WattpadAPI.PAGE_LIMIT then
        return nil, "chapter pagination limit reached"
    end

    return table.concat(pages, "\n"), nil
end

function WattpadAPI.buildStoryPayload(story_id, token)
    local metadata, meta_err = WattpadAPI.fetchStoryMetadata(story_id, token)
    if meta_err then
        return nil, meta_err
    end
    if type(metadata) ~= "table" then
        return nil, "metadata missing"
    end

    local chapters = {}
    local parts = metadata.parts or {}
    for idx, part in ipairs(parts) do
        local chapter_html, chapter_err = WattpadAPI.fetchChapterHtml(part.id, token)
        if chapter_err then
            return nil, string.format("failed on chapter %d (%s): %s", idx, part.title, chapter_err)
        end

        chapters[#chapters + 1] = {
            id = part.id,
            title = part.title,
            html = chapter_html,
            index = idx,
        }
    end

    return {
        id = metadata.id,
        title = metadata.title,
        description = metadata.description,
        cover = metadata.cover,
        chapters = chapters,
        source_url = WattpadAPI.BASE_URL .. "/story/" .. tostring(metadata.id),
    }, nil
end

return WattpadAPI
