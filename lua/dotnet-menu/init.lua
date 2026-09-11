-- A small .NET solution/project GUI for Neovim.
--
-- Almost everything here is a thin wrapper over the `dotnet` CLI — no MSBuild
-- parsing, no background daemon. The CLI already knows how to create a
-- solution, add a project to it and scaffold a file; what it lacks is a way to
-- reach those from inside the editor without retyping paths, which is what this
-- plugin is.
--
-- The exception is renaming and moving a file: the CLI has neither, and
-- updating every use of the type takes the solution-wide view only roslyn_ls
-- has.
--
-- Entry points: the :Dotnet command, the keymap (<leader>n by default), and —
-- when oil.nvim is installed — file operations saved in oil.

local actions = require("dotnet-menu.actions")
local menu = require("dotnet-menu.menu")

local M = {}

--- @class dotnet-menu.Options
--- @field keymap? string|false          normal-mode key for the menu; false for none
--- @field oil? boolean                  react to file operations saved in oil.nvim
--- @field roslyn_diagnostics? boolean   re-pull open documents' diagnostics when
---                                      roslyn_ls reloads the project (see
---                                      diagnostics.lua)
local defaults = {
    keymap = "<leader>n",
    oil = true,
    roslyn_diagnostics = true,
}

--- Open the main menu.
function M.open()
    menu.open({
        title = ".NET",
        items = {
            { key = "s", label = "New solution", handler = actions.new_solution },
            { key = "p", label = "New project", handler = actions.new_project },
            { key = "a", label = "Add to solution", handler = actions.add_projects },
            { key = "f", label = "New file", handler = actions.new_file },
            { key = "R", label = "Rename / move file", handler = actions.rename_file },
            { key = "r", label = "Project reference", handler = actions.add_reference },
            { key = "n", label = "NuGet package", handler = actions.add_package },
            { separator = true },
            { key = "q", label = "Close", handler = nil },
        },
    })
end

--- Call once, at startup. Not lazy-loaded: the solution-loaded signal the
--- rename waits for arrives a few seconds after roslyn_ls first attaches, and
--- only a plugin already set up by then can see it (see roslyn.lua).
--- @param opts? dotnet-menu.Options
function M.setup(opts)
    opts = vim.tbl_deep_extend("force", defaults, opts or {})

    require("dotnet-menu.roslyn").setup()

    if opts.roslyn_diagnostics then
        require("dotnet-menu.diagnostics").setup()
    end

    -- The same actions, triggered by file operations saved in oil instead of
    -- picked from the menu. A no-op without oil.nvim.
    if opts.oil then
        require("dotnet-menu.oil").setup()
    end

    vim.api.nvim_create_user_command("Dotnet", M.open, { desc = ".NET: open the solution menu" })
    if opts.keymap then
        vim.keymap.set("n", opts.keymap, M.open, { desc = ".NET menu" })
    end
end

return M
