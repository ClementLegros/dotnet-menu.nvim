-- The project-to-project reference graph.
--
-- Read straight out of the project files rather than through
-- `dotnet list <p> reference`: that command answers for ONE project, so building
-- the graph would cost one subprocess per project — about five seconds on a
-- five-project solution — where parsing the XML is instant and gives the whole
-- graph at once.

local M = {}

--- The projects a project file references.
---
--- MSBuild writes these paths relative to the referencing project and with
--- BACKSLASHES even on Linux
--- (`Include="..\MyApp.Infrastructure\MyApp.Infrastructure.csproj"`),
--- so each one is converted and then resolved to an absolute path —
--- vim.fs.normalize collapses the `..` itself.
---
--- @return string[] absolute paths
function M.references(project)
    local ok, content = pcall(vim.fn.readfile, project)
    if not ok then
        return {}
    end

    local dir = vim.fs.dirname(project)
    local out = {}

    for include in table.concat(content, "\n"):gmatch("<ProjectReference%s+Include%s*=%s*[\"']([^\"']+)[\"']") do
        table.insert(out, vim.fs.normalize(dir .. "/" .. (include:gsub("\\", "/"))))
    end

    return out
end

--- Does `from` reach `to` by following references, directly or transitively?
---
--- This is what stands between the menu and a broken build. `dotnet add
--- reference` performs NO cycle check — asked to add Core -> Api while
--- Api -> Core already existed it answered "Reference added" with exit 0, and
--- the next build failed with "MSB4006: There is a circular dependency in the
--- target dependency graph". Adding A -> B is safe only when B cannot already
--- reach A, so that is the question asked here.
---
--- Transitive, not just direct: A -> B -> C -> A is equally fatal and equally
--- unreported.
function M.reaches(from, to)
    local seen = {}
    local queue = { from }

    while #queue > 0 do
        local current = table.remove(queue)

        if current == to then
            return true
        end

        if not seen[current] then
            seen[current] = true
            for _, reference in ipairs(M.references(current)) do
                table.insert(queue, reference)
            end
        end
    end

    return false
end

return M
