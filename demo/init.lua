-- Minimal Neovim config used to record demo.gif (see demo.tape). Not needed to
-- use the plugin: it only adds a colorscheme, oil and nvim-notify around it,
-- and loads the plugin from this working copy.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.hlsearch = false
vim.o.swapfile = false
vim.o.laststatus = 3
vim.opt.shortmess:append("I")

vim.pack.add({
    { src = "https://github.com/catppuccin/nvim", name = "catppuccin" },
    "https://github.com/nvim-tree/nvim-web-devicons",
    "https://github.com/stevearc/oil.nvim",
    "https://github.com/neovim/nvim-lspconfig",
    "https://github.com/rcarriga/nvim-notify",
}, { confirm = false })

vim.opt.rtp:prepend(root)

require("catppuccin").setup({ flavour = "mocha" })
vim.cmd.colorscheme("catppuccin")

local notify = require("notify")
notify.setup({ stages = "static", render = "wrapped-compact", timeout = 4000, max_width = 70 })
vim.notify = notify

require("oil").setup({
    columns = { "icon" },
    skip_confirm_for_simple_edits = true,
    view_options = {
        is_always_hidden = function(name)
            return name == "bin" or name == "obj"
        end,
    },
})
vim.keymap.set("n", "-", "<cmd>Oil<cr>")

-- Warnings and errors only: roslyn's style hints ("collection initialization
-- can be simplified") would otherwise sit next to every line of the sample.
local shown = { severity = { min = vim.diagnostic.severity.WARN } }
vim.diagnostic.config({ virtual_text = shown, signs = shown, underline = shown })

-- The file or oil directory relative to the solution, rather than an absolute
-- path; nothing for the menu's scratch buffer.
function _G.demo_statusline()
    local name = vim.api.nvim_buf_get_name(0)
    local dir = name:match("^oil://(.*)$")
    if dir then
        return "  " .. vim.fn.fnamemodify(dir, ":.") .. (vim.bo.modified and " [+]" or "")
    end
    if vim.bo.buftype ~= "" or name == "" then
        return ""
    end
    return "  " .. vim.fn.fnamemodify(name, ":.") .. (vim.bo.modified and " [+]" or "")
end
vim.o.statusline = "%{%v:lua.demo_statusline()%}%=%l:%c  "
vim.lsp.enable("roslyn_ls")

require("dotnet-menu").setup()

-- Captions for the recording: Alt+a..f (sent by demo.tape) show one line at
-- the bottom of the screen, replacing the previous one.
local captions = {
    "Menu  <leader>n → f  —  a new file gets the namespace of its folder",
    "oil  create a .cs file  —  it is filled in (interface for IFoo)",
    "oil  rename Product.cs → Item.cs  —  the type follows, solution-wide",
    "oil  move Item.cs into Models/  —  namespace and usings follow",
    "oil  delete Item.cs  —  warns when the type is still used",
    "dotnet-menu.nvim  —  github.com/ClementLegros/dotnet-menu.nvim",
}

local caption = { buf = vim.api.nvim_create_buf(false, true) }

local function show_caption(text)
    vim.api.nvim_buf_set_lines(caption.buf, 0, -1, false, { " " .. text .. " " })
    local width = vim.fn.strdisplaywidth(text) + 2
    local config = {
        relative = "editor",
        width = width,
        height = 1,
        row = vim.o.lines - 4,
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        focusable = false,
        zindex = 250,
    }
    if caption.win and vim.api.nvim_win_is_valid(caption.win) then
        vim.api.nvim_win_set_config(caption.win, config)
    else
        caption.win = vim.api.nvim_open_win(caption.buf, false, config)
        vim.wo[caption.win].winhighlight = "NormalFloat:PmenuSel,FloatBorder:PmenuSel"
    end
end

for i, text in ipairs(captions) do
    vim.keymap.set({ "n", "i" }, "<M-" .. string.char(96 + i) .. ">", function()
        show_caption(text)
    end)
end
