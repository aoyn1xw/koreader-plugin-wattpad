local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local UI = {}

local function showInfo(text)
    UIManager:show(InfoMessage:new({ text = text or _("Unknown message") }))
end

function UI.notify(text)
    showInfo(text)
end

local function buildProgressBar(current, total, width)
    width = width or 20
    if total <= 0 then
        total = 1
    end
    if current < 0 then
        current = 0
    end
    if current > total then
        current = total
    end
    local ratio = current / total
    local filled = math.floor(ratio * width + 0.5)
    if filled < 0 then
        filled = 0
    end
    if filled > width then
        filled = width
    end
    return string.rep("#", filled) .. string.rep("-", width - filled), math.floor(ratio * 100 + 0.5)
end

function UI.showProgress(label, current, total)
    local bar, percent = buildProgressBar(current, total, 18)
    local text = string.format("%s [%s] %d%% (%d/%d)", label or _("Progress"), bar, percent, current, total)
    UIManager:show(Notification:new({
        text = text,
        timeout = 1,
    }))
end

function UI.promptStoryUrl(on_submit)
    local dialog
    dialog = InputDialog:new({
        title = _("Wattpad Story URL"),
        input = "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        if on_submit then
                            on_submit(nil)
                        end
                    end,
                },
                {
                    text = _("OK"),
                    callback = function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        if on_submit then
                            on_submit(url)
                        end
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function UI.promptLogin(on_submit)
    local username_dialog
    local password_dialog
    local username = nil

    username_dialog = InputDialog:new({
        title = _("Wattpad Username or Email"),
        input = "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(username_dialog)
                        if on_submit then
                            on_submit(nil, nil)
                        end
                    end,
                },
                {
                    text = _("Next"),
                    callback = function()
                        username = username_dialog:getInputText()
                        UIManager:close(username_dialog)

                        password_dialog = InputDialog:new({
                            title = _("Wattpad Password"),
                            input = "",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(password_dialog)
                                            if on_submit then
                                                on_submit(nil, nil)
                                            end
                                        end,
                                    },
                                    {
                                        text = _("Login"),
                                        callback = function()
                                            local password = password_dialog:getInputText()
                                            UIManager:close(password_dialog)
                                            if on_submit then
                                                on_submit(username, password)
                                            end
                                        end,
                                    },
                                },
                            },
                        })

                        UIManager:show(password_dialog)
                        password_dialog:onShowKeyboard()
                    end,
                },
            },
        },
    })

    UIManager:show(username_dialog)
    username_dialog:onShowKeyboard()
end

function UI.selectChapters(chapters, on_submit)
    chapters = chapters or {}
    if #chapters == 0 then
        if on_submit then
            on_submit({})
        end
        return
    end

    local selected = {}
    local menu
    local items = {
        {
            text = _("Download all chapters"),
            callback = function()
                UIManager:close(menu)
                if on_submit then
                    on_submit(chapters)
                end
            end,
        },
    }

    for _, chapter in ipairs(chapters) do
        items[#items + 1] = {
            text = chapter.title,
            callback = function()
                selected[#selected + 1] = chapter
                showInfo(_("Selected: ") .. chapter.title)
            end,
        }
    end

    items[#items + 1] = {
        text = _("Download selected"),
        callback = function()
            UIManager:close(menu)
            if on_submit then
                on_submit(selected)
            end
        end,
    }

    items[#items + 1] = {
        text = _("Cancel"),
        callback = function()
            UIManager:close(menu)
            if on_submit then
                on_submit(nil)
            end
        end,
    }

    menu = Menu:new({
        title = _("Select Chapters"),
        item_table = items,
    })

    UIManager:show(menu)
end

return UI
