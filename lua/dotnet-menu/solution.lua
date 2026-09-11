-- Reading what a solution currently contains.
--
-- Separate from context.lua, which only ever looks at the filesystem: this asks
-- the SDK. Solution membership is not a question the disk can answer — a
-- project can sit in src/ without being referenced by the .slnx at all, and
-- that gap is exactly what the "add to solution" action exists to close.

local cli = require("dotnet-menu.cli")

local M = {}

--- Parse `dotnet sln list`:
---
---     Project(s)
---     ----------
---     src/Core/Core.csproj
---
--- Same landmark as the template table — the row of dashes marks where data
--- starts, which skips the header without matching on its wording.
---
--- An empty solution prints "No projects found in the solution." with NO dashes
--- row and exit 0, so it falls out of here as an empty list rather than as an
--- error, which is the correct reading: the solution exists and holds nothing.
---
--- @return string[] project paths, relative to the solution
function M.parse(stdout)
    local out = {}
    local started = false

    for _, line in ipairs(vim.split(stdout, "\n")) do
        if line:match("^%-%-%-") then
            started = true
        elseif started then
            local path = vim.trim(line)
            if path ~= "" then
                -- Separators are normalised so the comparison against paths
                -- found on disk cannot fail on a solution authored on Windows.
                table.insert(out, (path:gsub("\\", "/")))
            end
        end
    end

    return out
end

--- The projects a solution references, asynchronously.
function M.projects(solution, on_list)
    cli.capture({ "sln", vim.fs.basename(solution), "list" }, {
        cwd = vim.fs.dirname(solution),
        label = "Lecture de " .. vim.fs.basename(solution),
    }, function(stdout)
        on_list(M.parse(stdout))
    end)
end

return M
