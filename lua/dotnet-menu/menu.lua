-- The floating menu window every dotnet action is reached from.
--
-- Deliberately NOT vim.ui.select: that often hands the list to a fuzzy picker
-- (telescope, fzf-lua…) and turns a short, hand-ordered menu into a search box. Here each entry
-- owns a mnemonic key, the order is meaningful, and the window is small enough
-- to read at a glance — which is the whole point of a menu over a picker.

local M = {}

local ns = vim.api.nvim_create_namespace("dotnet_menu")

-- Layout of one entry line: "  s  Nouvelle solution"
local PAD = "  "
local GAP = "  "

-- Highlights are re-applied on every open rather than once at setup, because
-- `:colorscheme` clears every group — including these. Linked, with
-- default = true, so a theme that ships its own DotnetMenu* groups wins.
--
-- The float is backed by Pmenu, not NormalFloat: catppuccin runs with
-- transparent_background here, which would drop the menu text straight onto the
-- buffer underneath. PmenuSel is then the matching cursorline.
local function set_highlights()
    vim.api.nvim_set_hl(0, "DotnetMenuNormal", { link = "Pmenu", default = true })
    vim.api.nvim_set_hl(0, "DotnetMenuBorder", { link = "FloatBorder", default = true })
    vim.api.nvim_set_hl(0, "DotnetMenuSel", { link = "PmenuSel", default = true })
    vim.api.nvim_set_hl(0, "DotnetMenuKey", { link = "Special", default = true })
end

--- @class dotnet.MenuItem
--- @field key? string       single character that triggers the entry. Optional:
---                          a generated list (every .NET template, say) has no
---                          sensible mnemonic, and inventing one per line would
---                          be noise. Such entries are reached with j/k + <CR>.
--- @field label string      text shown next to the key
--- @field handler fun()     run after the menu closes
--- @field separator boolean render a blank line instead of an entry

--- @param opts { title: string, items: dotnet.MenuItem[] }
function M.open(opts)
    set_highlights()

    -- Build the buffer lines, remembering which line carries which item.
    -- A leading and trailing blank line give the content room inside the border.
    local lines = { "" }
    local by_line = {}
    local selectable = {}

    for _, item in ipairs(opts.items) do
        if item.separator then
            table.insert(lines, "")
        else
            local prefix = item.key and (item.key .. GAP) or ""
            table.insert(lines, PAD .. prefix .. item.label)
            by_line[#lines] = item
            table.insert(selectable, #lines)
        end
    end
    table.insert(lines, "")

    if #selectable == 0 then
        return
    end

    -- strdisplaywidth, not #: the labels carry accented characters, whose byte
    -- length is not their column count.
    local width = vim.fn.strdisplaywidth(opts.title) + 4
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line) + #PAD)
    end
    -- A generated list can be longer than the screen. Capping the window turns
    -- the overflow into scrolling inside it (the cursor drags the view along)
    -- rather than a float taller than the editor.
    local height = math.min(#lines, math.max(vim.o.lines - 6, 3))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- The key is ASCII and always sits at a fixed byte offset, so the extmark
    -- columns need no width juggling.
    for line, item in pairs(by_line) do
        if item.key then
            vim.api.nvim_buf_set_extmark(buf, ns, line - 1, #PAD, {
                end_col = #PAD + #item.key,
                hl_group = "DotnetMenuKey",
            })
        end
    end

    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "dotnet-menu"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2 - 1),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " " .. opts.title .. " ",
        title_pos = "center",
    })

    vim.wo[win].cursorline = true
    vim.wo[win].winhighlight = table.concat({
        "NormalFloat:DotnetMenuNormal",
        "FloatBorder:DotnetMenuBorder",
        "FloatTitle:DotnetMenuBorder",
        "CursorLine:DotnetMenuSel",
    }, ",")

    vim.api.nvim_win_set_cursor(win, { selectable[1], 0 })

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    -- The handler runs AFTER the menu is gone, and scheduled: several of them
    -- open a vim.ui.input prompt, which would otherwise be drawn underneath a
    -- window that is still on screen.
    local function select(item)
        close()
        if item and item.handler then
            vim.schedule(item.handler)
        end
    end

    -- Cursor movement skips the separator lines and wraps at both ends, so
    -- holding j never parks the cursor on a blank row.
    local function move(delta)
        local cur = vim.api.nvim_win_get_cursor(win)[1]
        local index = 1
        for i, line in ipairs(selectable) do
            if line == cur then
                index = i
                break
            end
        end
        index = (index - 1 + delta) % #selectable + 1
        vim.api.nvim_win_set_cursor(win, { selectable[index], 0 })
    end

    local function map(lhs, rhs)
        vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
    end

    -- Mapped before the entries so a menu that defines its own "q" entry wins.
    map("q", close)

    for _, item in ipairs(opts.items) do
        if item.key then
            map(item.key, function()
                select(item)
            end)
        end
    end

    map("<CR>", function()
        select(by_line[vim.api.nvim_win_get_cursor(win)[1]])
    end)
    map("<Esc>", close)
    map("j", function() move(1) end)
    map("k", function() move(-1) end)
    map("<Down>", function() move(1) end)
    map("<Up>", function() move(-1) end)

    -- Clicking into another window abandons the menu rather than leaving an
    -- orphaned float behind.
    vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = close })
end

return M
