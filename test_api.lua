package.path = package.path .. ";/mnt/us/koreader/common/?.lua;/mnt/us/koreader/plugins/wattpad.koplugin/?.lua"
package.cpath = package.cpath .. ";/mnt/us/koreader/common/?.so"
local api = require("api")
local story_id = "320865405"
local metadata, err = api.fetchStoryMetadata(story_id)
if err then
    print("ERROR: " .. tostring(err))
else
    print("SUCCESS: " .. tostring(metadata.title))
    print("Chapters: " .. #metadata.parts)
end
