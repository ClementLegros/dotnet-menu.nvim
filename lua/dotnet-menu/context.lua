-- Answering "where am I?" — which solution, which projects, which directory the
-- CLI should run in.
--
-- The rooting rule deliberately matches what roslyn_ls does with the
-- nvim-lspconfig spec: nearest .sln/.slnx walking up, falling back to the
-- nearest project file. A menu that operated on a different solution than the language
-- server would be its own kind of bug.

local M = {}

-- Directories never worth walking into. bin/ and obj/ are the ones that matter:
-- a restored obj/ holds project.assets.json and a pile of generated props, and
-- descending into every one of them on each menu open is pure waste.
local SKIP = {
    bin = true,
    obj = true,
    [".git"] = true,
    [".vs"] = true,
    node_modules = true,
}

local function is_solution(name)
    return name:match("%.slnx?$") ~= nil
end

local function is_project(name)
    return name:match("%.[cf]sproj$") ~= nil
end

--- The directory searches start from: the current buffer's own directory, or
--- the cwd when the buffer is not a file on disk.
---
--- oil is special-cased because its buffers are named `oil:///path/to/dir/` while reporting an EMPTY buftype —
--- so the usual "buftype == '' means a real file" test would hand the rest of
--- this module a path with a URL scheme glued to the front.
function M.start_dir()
    local name = vim.api.nvim_buf_get_name(0)

    if name:match("^oil://") then
        return (name:gsub("^oil://", ""))
    end

    if name ~= "" and vim.bo.buftype == "" then
        return vim.fs.dirname(name)
    end

    return vim.fn.getcwd()
end

--- The file an action on "this file" means: the entry under the cursor in an
--- oil buffer, otherwise the current buffer's own file.
---
--- oil gets the same special case as in start_dir: its buffer is a directory,
--- and the file the user is pointing at is the line the cursor is on.
---
--- @return string|nil absolute path of an existing file
function M.current_file()
    local path

    if vim.api.nvim_buf_get_name(0):match("^oil://") then
        local ok, oil = pcall(require, "oil")
        local entry = ok and oil.get_cursor_entry()
        local dir = ok and oil.get_current_dir()
        if entry and dir and entry.type == "file" then
            path = vim.fs.joinpath(dir, entry.name)
        end
    elseif vim.bo.buftype == "" then
        path = vim.api.nvim_buf_get_name(0)
    end

    if path and path ~= "" and vim.fn.filereadable(path) == 1 then
        return vim.fs.normalize(path)
    end
    return nil
end

--- Every solution file in the NEAREST ancestor directory that holds one.
--- Usually a single entry — but `dotnet new sln -f sln` next to an existing
--- .slnx leaves two side by side, and silently picking one would be wrong.
--- @return string[] absolute paths, may be empty
function M.solutions(from)
    local found = vim.fs.find(is_solution, {
        upward = true,
        type = "file",
        path = from or M.start_dir(),
        limit = math.huge,
    })

    if #found == 0 then
        return {}
    end

    -- find() returns nearest-first; keep only the ones sharing that directory.
    local dir = vim.fs.dirname(found[1])
    return vim.tbl_filter(function(path)
        return vim.fs.dirname(path) == dir
    end, found)
end

--- The nearest solution, or nil. Callers that must disambiguate between two
--- solutions in one directory should use M.solutions() instead.
function M.solution(from)
    return M.solutions(from)[1]
end

--- Directory every `dotnet` invocation should run in: the solution's, else the
--- nearest project's, else the cwd.
function M.root(from)
    from = from or M.start_dir()

    local solution = M.solution(from)
    if solution then
        return vim.fs.dirname(solution)
    end

    local project = vim.fs.find(is_project, {
        upward = true,
        type = "file",
        path = from,
        limit = 1,
    })[1]
    if project then
        return vim.fs.dirname(project)
    end

    return vim.fn.getcwd()
end

--- The project a path belongs to: nearest .csproj/.fsproj walking up.
function M.project(from)
    return vim.fs.find(is_project, {
        upward = true,
        type = "file",
        path = from or M.start_dir(),
        limit = 1,
    })[1]
end

--- A project's root namespace.
---
--- MSBuild defaults RootNamespace to the project file's name and most projects
--- never override it. An explicit
--- value wins, unless it is an MSBuild expression: evaluating $(...) would mean
--- running MSBuild, and the file name is the right answer far more often than a
--- literal "$(MSBuildProjectName)" would be.
function M.root_namespace(project)
    local ok, content = pcall(vim.fn.readfile, project)
    if ok then
        local declared = table.concat(content, "\n"):match("<RootNamespace>%s*(.-)%s*</RootNamespace>")
        if declared and declared ~= "" and not declared:find("%$%(") then
            return declared
        end
    end

    return (vim.fs.basename(project):gsub("%.[cf]sproj$", ""))
end

--- One path segment turned into something legal in a namespace.
---
--- Bytes above 0x7f are left alone: C# identifiers accept them, and mangling
--- them per byte would turn one accented character into two underscores.
--- A dot survives too — a "My.Feature" directory is a nested namespace by
--- convention, not one identifier containing a dot.
local function sanitize(segment)
    segment = segment:gsub("[^%w_.\128-\255]", "_")
    if segment:match("^%d") then
        segment = "_" .. segment
    end
    return segment
end

--- The namespace a file in `dir` should declare.
---
--- Root namespace plus the directory path below the project (MyApp.Api/
--- Extensions/ declares MyApp.Api.Extensions): the .NET convention, and the one
--- roslyn checks with IDE0130.
---
--- Worth doing by hand precisely because the SDK does not: `dotnet new class`
--- in src/Core/Services/Billing writes "namespace Core;", dropping the folders.
---
--- @return string|nil nil when `dir` is not inside a project
function M.namespace_for(dir)
    local project = M.project(dir)
    if not project then
        return nil
    end

    local parts = { M.root_namespace(project) }
    local project_dir = vim.fs.normalize(vim.fs.dirname(project))
    local relative = vim.fs.normalize(dir):sub(#project_dir + 2)

    for segment in relative:gmatch("[^/]+") do
        table.insert(parts, sanitize(segment))
    end

    return table.concat(parts, ".")
end

--- Every project file on disk under `root`.
---
--- A filesystem scan rather than `dotnet sln list` on purpose: the caller that
--- needs this most is "add a project to the solution", whose candidates are
--- exactly the projects NOT yet in the solution. Membership questions use the
--- CLI instead.
---
--- @return string[] paths relative to root, sorted
function M.projects(root)
    local out = {}

    -- skip() is handed the path RELATIVE TO root ("src/Core/obj"), not the
    -- directory's own name, so the basename has to be pulled back out of it.
    for path, type in vim.fs.dir(root, {
        depth = 8,
        skip = function(dir)
            return not SKIP[vim.fs.basename(dir)]
        end,
    }) do
        if type == "file" and is_project(path) then
            table.insert(out, path)
        end
    end

    table.sort(out)
    return out
end

return M
