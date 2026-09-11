-- The `dotnet new` template catalogue.
--
-- Two tiers on purpose. Listing the real catalogue costs ~320 ms (measured) and
-- returns 25 project templates for C# — fine to wait for occasionally, too slow
-- and too long to be the thing standing between a keypress and a new class
-- library. So the handful of templates actually used day to day are hardcoded
-- with mnemonic keys and appear instantly, and the full list is one keypress
-- further in, fetched live so it can never drift from the installed SDK or from
-- a template pack added later.

local cli = require("dotnet-menu.cli")

local M = {}

--- The fast path. Short names are SDK built-ins, so they are always present;
--- if one ever is not, `dotnet new` answers 103 with a clear message, which
--- cli.run already surfaces.
M.CURATED = {
    { key = "c", short = "classlib", label = "Class Library" },
    { key = "o", short = "console", label = "Console App" },
    { key = "a", short = "webapi", label = "ASP.NET Core Web API" },
    { key = "m", short = "mvc", label = "ASP.NET Core MVC" },
    { key = "b", short = "blazor", label = "Blazor Web App" },
    { key = "w", short = "worker", label = "Worker Service" },
    { key = "x", short = "xunit", label = "xUnit Test Project" },
}

--- Parse the table `dotnet new list` prints.
---
--- The columns are separated by two-or-more spaces and template names contain
--- single ones ("ASP.NET Core Web App (Model-View-Controller)"), so that is the
--- split — not fixed offsets, which would move the day a longer name appears.
--- The row of dashes marks where the data starts, which also skips the
--- "These templates matched your input:" preamble.
---
--- Verified against the 25 rows this SDK returns: every one yields 4 columns.
---
--- @return { name: string, short: string, tags: string }[]
function M.parse(stdout)
    local out = {}
    local started = false

    for _, line in ipairs(vim.split(stdout, "\n")) do
        if line:match("^%-%-%-") then
            started = true
        elseif started and vim.trim(line) ~= "" then
            local cols = vim.split(vim.trim(line), "%s%s+")
            if #cols >= 2 then
                table.insert(out, {
                    name = cols[1],
                    -- "webapp,razor" — several aliases, the first is canonical.
                    short = vim.split(cols[2], ",")[1],
                    tags = cols[4] or "",
                })
            end
        end
    end

    return out
end

--- Every C# project template the SDK knows about, asynchronously.
---
--- `--type project` is what keeps item templates (gitignore, editorconfig, a
--- lone Razor component…) out: they are not things you create from a menu whose
--- next question is "where should the project go?".
function M.list(cwd, on_list)
    cli.capture({ "new", "list", "--type", "project", "-lang", "C#" }, {
        cwd = cwd,
        label = "Listing templates",
    }, function(stdout)
        on_list(M.parse(stdout))
    end)
end

return M
