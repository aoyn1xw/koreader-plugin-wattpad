local Compression = {}

local function shellQuote(text)
    text = tostring(text or "")
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function commandOk(ret)
    return ret == true or ret == 0
end

function Compression.isGzip(data)
    return data and #data >= 2 and data:byte(1) == 0x1f and data:byte(2) == 0x8b
end

function Compression.gunzip(data)
    if not Compression.isGzip(data) then
        return data, nil
    end

    local tmp_base = os.tmpname()
    local tmp_in = tmp_base .. ".gz"
    local tmp_out = tmp_base .. ".out"

    local writer, werr = io.open(tmp_in, "wb")
    if not writer then
        return nil, "failed to open temp input file: " .. tostring(werr)
    end
    writer:write(data)
    writer:close()

    local cmd = string.format("/bin/gunzip -c %s > %s 2>/dev/null", shellQuote(tmp_in), shellQuote(tmp_out))
    local ok = commandOk(os.execute(cmd))
    if not ok then
        os.remove(tmp_in)
        os.remove(tmp_out)
        return nil, "gunzip command failed"
    end

    local reader, rerr = io.open(tmp_out, "rb")
    if not reader then
        os.remove(tmp_in)
        os.remove(tmp_out)
        return nil, "failed to read temp output file: " .. tostring(rerr)
    end
    local inflated = reader:read("*a")
    reader:close()

    os.remove(tmp_in)
    os.remove(tmp_out)

    return inflated or "", nil
end

return Compression
