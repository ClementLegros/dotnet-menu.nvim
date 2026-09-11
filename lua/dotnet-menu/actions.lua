-- The concrete menu actions. Each one follows the same shape: gather input,
-- hand a `dotnet` invocation to cli.run, and reveal the result on success.

local cli = require("dotnet-menu.cli")
local context = require("dotnet-menu.context")
local csharp = require("dotnet-menu.csharp")
local menu = require("dotnet-menu.menu")
local project_graph = require("dotnet-menu.project")
local roslyn = require("dotnet-menu.roslyn")
local solution_api = require("dotnet-menu.solution")
local templates = require("dotnet-menu.templates")

local M = {}

--- Re-list the oil buffers affected by something we just created.
---
--- oil keeps a rendered buffer per directory and load_oil_buffer() early-returns
--- on one that is already loaded, so it never re-reads the disk. Files created
--- behind its back — which is exactly what every action here does — therefore
--- stay invisible: walking up with `-` lands on the buffer as it was rendered
--- BEFORE the project existed, and only restarting Neovim shows it.
---
--- Two constraints shape this:
---   * The stale buffer is usually the PARENT, not the current one, so
---     oil.actions.refresh (a plain `:edit!` on the current buffer) cannot fix
---     it. render_buffer_async takes an explicit bufnr and refetches.
---   * An oil buffer is editable. Re-rendering one with unsaved edits would
---     silently discard a pending rename or delete, so modified buffers are
---     left alone.
---
--- Scoped to ancestors of the created path: those are the listings whose
--- contents actually changed (the project's directory, every directory above it,
--- and the solution file's own directory).
local function refresh_oil(path)
    local ok, view = pcall(require, "oil.view")
    if not ok then
        return
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local dir = vim.api.nvim_buf_get_name(bufnr):match("^oil://(.*)$")
        if
            dir
            and vim.api.nvim_buf_is_loaded(bufnr)
            and not vim.bo[bufnr].modified
            and vim.startswith(path .. "/", dir)
        then
            view.render_buffer_async(bufnr)
        end
    end
end

--- Reload buffers whose file we changed behind Neovim's back.
---
--- A plain `:checktime` is NOT enough, and the difference is the whole reason
--- this exists: measured, the global form leaves a HIDDEN buffer stale, while
--- `:checktime <bufnr>` reloads it. Both files touched by `dotnet add package`
--- — the .csproj and Directory.Packages.props under central package management
--- — are normally hidden at that moment, since the action runs from a source
--- file, so the global form reloaded neither.
---
--- Modified buffers are skipped: reloading one would either lose the edit or
--- raise W12, and neither belongs in the middle of an unrelated action. URL
--- buffers (oil://) are skipped too — refresh_oil is what those need.
local function reload_buffers()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        if
            vim.api.nvim_buf_is_loaded(bufnr)
            and not vim.bo[bufnr].modified
            and name ~= ""
            and not name:match("^%a[%w+.-]*://")
            and vim.fn.filereadable(name) == 1
        then
            vim.cmd("checktime " .. bufnr)
        end
    end
end

--- Show a directory after something was created in it: in oil when it is
--- installed, with a plain :edit otherwise.
local function reveal(dir)
    local ok, oil = pcall(require, "oil")
    if ok then
        oil.open(dir)
        -- After the open, so the buffer the user lands on is refreshed too if it
        -- happened to be a stale one.
        refresh_oil(dir)
    else
        vim.cmd.edit(vim.fn.fnameescape(dir))
    end
end

--- The directory an action operates in: wherever the current buffer sits,
--- guarded because start_dir() can hand back a path that no longer exists
--- (a deleted file still open in a buffer).
local function target_dir()
    local dir = context.start_dir()
    if vim.fn.isdirectory(dir) == 0 then
        return vim.fn.getcwd()
    end
    return dir
end

--- `dotnet new sln -n App.slnx` creates "App.slnx.slnx" — the CLI does not
--- deduplicate the extension, and typing the full filename is the natural
--- reflex when the menu entry says "solution". Strip it back off.
local function strip_extension(name)
    return (name:gsub("%.slnx?$", ""))
end

--- Ask for a name, then a format, then create the solution.
function M.new_solution()
    local dir = target_dir()

    -- The target directory goes in the prompt itself rather than in a second
    -- question: where the file lands is visible BEFORE anything is typed, and
    -- the flow stays at two steps.
    vim.ui.input({ prompt = "Nouvelle solution dans " .. vim.fn.fnamemodify(dir, ":~") .. " : " }, function(input)
        if not input then
            return -- cancelled with <Esc>
        end

        local name = strip_extension(vim.trim(input))
        if name == "" then
            return
        end

        local function create(format)
            cli.run({ "new", "sln", "--name", name, "--format", format }, {
                cwd = dir,
                label = "Création de " .. name .. "." .. format,
            }, function()
                reveal(dir)
            end)
        end

        -- Scheduled: this runs from inside the vim.ui.input callback, with the
        -- cmdline prompt still tearing down, and opening a float in that window
        -- lands it on top of a redraw.
        vim.schedule(function()
            menu.open({
                title = "Format",
                items = {
                    {
                        key = "x",
                        label = name .. ".slnx   (XML, défaut du SDK)",
                        handler = function()
                            create("slnx")
                        end,
                    },
                    {
                        key = "s",
                        label = name .. ".sln    (format classique)",
                        handler = function()
                            create("sln")
                        end,
                    },
                },
            })
        end)
    end)
end

--- Where a new project goes: the solution's own directory when there is one,
--- so the path recorded in the .slnx stays relative to it; otherwise wherever
--- the buffer sits.
local function project_base()
    local solution = context.solution()
    if solution then
        return vim.fs.dirname(solution)
    end
    return target_dir()
end

--- Register a freshly created project with the solution, if there is one.
---
--- The project file is looked up on disk rather than assumed to be
--- "<name>.csproj": the extension follows the template's language, and a
--- wrong guess here would report a confusing `dotnet sln add` failure instead
--- of the successful creation that actually happened.
local function add_to_solution(base, project_dir, done)
    local solution = context.solution(base)
    if not solution then
        return done()
    end

    local project = vim.fs.find(function(name)
        return name:match("%.[cf]sproj$") ~= nil
    end, { path = project_dir, type = "file", limit = 1 })[1]

    if not project then
        return done()
    end

    cli.run({ "sln", vim.fs.basename(solution), "add", project }, {
        cwd = base,
        label = "Ajout à " .. vim.fs.basename(solution),
    }, done)
end

--- Ask where the project goes, create it, then hand it to the solution.
local function create_project(short, base)
    local prompt = ("Nouveau projet (%s) dans %s : "):format(short, vim.fn.fnamemodify(base, ":~"))

    vim.ui.input({ prompt = prompt }, function(input)
        if not input then
            return
        end

        -- A PATH is accepted here, not just a name: "src/Api" creates the
        -- project Api underneath src/, which is exactly what
        -- `dotnet new -n Api -o src/Api` does. That keeps the usual src/ and
        -- tests/ layout reachable without a second "where?" question, and a
        -- bare "Api" still behaves the obvious way.
        local rel = (vim.trim(input):gsub("/+$", ""))
        local name = vim.fs.basename(rel)
        if rel == "" or name == "" then
            return
        end

        cli.run({ "new", short, "--name", name, "--output", rel }, {
            cwd = base,
            label = ("Création de %s (%s)"):format(rel, short),
        }, function()
            local dir = base .. "/" .. rel
            add_to_solution(base, dir, function()
                reveal(dir)
            end)
        end)
    end)
end

--- The full catalogue, fetched live. Keyless entries: 25 templates have no
--- sensible mnemonics, so they are navigated with j/k and <CR>.
local function browse_templates(base)
    templates.list(base, function(list)
        if #list == 0 then
            vim.notify("Aucun template de projet trouvé", vim.log.levels.WARN, { title = ".NET" })
            return
        end

        local width = 0
        for _, template in ipairs(list) do
            width = math.max(width, #template.name)
        end

        local items = {}
        for _, template in ipairs(list) do
            table.insert(items, {
                label = ("%-" .. width .. "s  %s"):format(template.name, template.short),
                handler = function()
                    create_project(template.short, base)
                end,
            })
        end

        menu.open({ title = "Templates", items = items })
    end)
end

--- Pick a template, then create the project.
function M.new_project()
    local base = project_base()
    local items = {}

    for _, template in ipairs(templates.CURATED) do
        table.insert(items, {
            key = template.key,
            -- The short name rides along so the CLI equivalent is learnable
            -- from the menu instead of having to be looked up.
            label = ("%-26s %s"):format(template.label, template.short),
            handler = function()
                create_project(template.short, base)
            end,
        })
    end

    table.insert(items, { separator = true })
    table.insert(items, {
        key = "t",
        label = "Tous les templates…",
        handler = function()
            browse_templates(base)
        end,
    })

    menu.open({ title = "Nouveau projet", items = items })
end

--- Run `cb` with a solution, asking which one when the choice is real.
---
--- context.solutions() returns every solution sharing the nearest directory,
--- because `dotnet new sln -f sln` next to an existing .slnx leaves two side by
--- side. Adding a project to whichever one sorted first would be a silent wrong
--- answer, so the ambiguity is put to the user — but only when it exists.
local function with_solution(cb)
    local solutions = context.solutions()

    if #solutions == 0 then
        vim.notify(
            "Aucune solution trouvée en remontant depuis ce buffer",
            vim.log.levels.WARN,
            { title = ".NET" }
        )
        return
    end

    if #solutions == 1 then
        return cb(solutions[1])
    end

    local items = {}
    for _, path in ipairs(solutions) do
        table.insert(items, {
            label = vim.fs.basename(path),
            handler = function()
                cb(path)
            end,
        })
    end

    menu.open({ title = "Quelle solution ?", items = items })
end

--- Add existing projects to the solution in ONE `dotnet sln add` call, which
--- accepts several paths. full_output because that command confirms one project
--- per line and only the first would otherwise be shown.
local function register(root, solution, projects)
    local args = { "sln", vim.fs.basename(solution), "add" }
    vim.list_extend(args, projects)

    cli.run(args, {
        cwd = root,
        label = ("Ajout de %d projet%s à %s"):format(
            #projects,
            #projects > 1 and "s" or "",
            vim.fs.basename(solution)
        ),
        full_output = true,
    }, function()
        -- No new files appear, but the solution's own size and mtime changed.
        refresh_oil(root)
    end)
end

--- Offer the projects that exist on disk but are missing from the solution.
function M.add_projects()
    with_solution(function(solution)
        local root = vim.fs.dirname(solution)

        solution_api.projects(solution, function(referenced)
            local present = {}
            for _, path in ipairs(referenced) do
                present[path] = true
            end

            local missing = {}
            for _, path in ipairs(context.projects(root)) do
                if not present[path] then
                    table.insert(missing, path)
                end
            end

            -- Distinguished from "no projects at all": both would otherwise show
            -- the same empty menu, and they call for opposite next moves.
            if #missing == 0 then
                local message = #referenced > 0
                        and ("Tous les projets sont déjà dans %s"):format(vim.fs.basename(solution))
                    or ("Aucun projet trouvé sous %s"):format(vim.fn.fnamemodify(root, ":~"))
                vim.notify(message, vim.log.levels.INFO, { title = ".NET" })
                return
            end

            local items = {}

            -- Adding several at once is the common case after cloning a repo or
            -- scaffolding by hand, and the CLI takes them in a single call.
            if #missing > 1 then
                table.insert(items, {
                    key = "a",
                    label = ("Tout ajouter (%d)"):format(#missing),
                    handler = function()
                        register(root, solution, missing)
                    end,
                })
                table.insert(items, { separator = true })
            end

            for _, path in ipairs(missing) do
                table.insert(items, {
                    label = path,
                    handler = function()
                        register(root, solution, { path })
                    end,
                })
            end

            menu.open({ title = "Ajouter à " .. vim.fs.basename(solution), items = items })
        end)
    end)
end

-- The type kinds worth a menu entry. `dotnet new class|interface|record|enum|
-- struct` exist and are NOT used: each one writes "namespace <RootNamespace>;"
-- regardless of the folder it runs in (measured: in src/Core/Services/Billing it
-- emits "namespace Core;"), offers no option to correct that, prepends a UTF-8
-- BOM, and costs a second of process startup to write six lines. Building the
-- file here is faster, and nests the namespace under the folders as .NET
-- conventions (and roslyn's IDE0130) expect.
local KINDS = {
    { key = "c", keyword = "class" },
    { key = "i", keyword = "interface" },
    { key = "r", keyword = "record" },
    { key = "e", keyword = "enum" },
    { key = "s", keyword = "struct" },
}

--- Ask for a name, work out the namespace, write the file, open it.
local function create_file(keyword, base)
    local prompt = ("Nouveau %s dans %s : "):format(keyword, vim.fn.fnamemodify(base, ":~"))

    vim.ui.input({ prompt = prompt }, function(input)
        if not input then
            return
        end

        -- A path again, as in "Nouveau projet": "Services/Billing/Invoice"
        -- creates the folders and puts Invoice.cs at the bottom of them. The
        -- extension is stripped so typing "Invoice.cs" cannot yield Invoice.cs.cs.
        local rel = (vim.trim(input):gsub("%.cs$", ""))
        local name = vim.fs.basename(rel)
        if rel == "" or name == "" then
            return
        end

        local dir = vim.fs.normalize(base .. "/" .. (vim.fs.dirname(rel) or "."))
        local path = dir .. "/" .. name .. ".cs"

        if vim.fn.filereadable(path) == 1 then
            vim.notify(
                ("%s existe déjà"):format(vim.fn.fnamemodify(path, ":~:.")),
                vim.log.levels.ERROR,
                { title = ".NET" }
            )
            return
        end

        if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then
            vim.notify("Impossible de créer " .. dir, vim.log.levels.ERROR, { title = ".NET" })
            return
        end

        -- nil outside a project: the file is still written, because being unable
        -- to name the namespace is no reason to refuse to create the file, but
        -- the omission is stated rather than left to be discovered later.
        local namespace = context.namespace_for(dir)
        if not namespace then
            vim.notify(
                "Aucun projet trouvé : fichier créé sans namespace",
                vim.log.levels.WARN,
                { title = ".NET" }
            )
        end

        local lines, cursor = csharp.scaffold(keyword, name, namespace)
        local ok, err = pcall(vim.fn.writefile, lines, path)
        if not ok then
            vim.notify("Écriture impossible : " .. tostring(err), vim.log.levels.ERROR, { title = ".NET" })
            return
        end

        vim.cmd.edit(vim.fn.fnameescape(path))
        pcall(vim.api.nvim_win_set_cursor, 0, { cursor, 0 })
        refresh_oil(dir)

        vim.notify(
            ("%s créé%s"):format(
                vim.fn.fnamemodify(path, ":~:."),
                namespace and (" dans " .. namespace) or ""
            ),
            vim.log.levels.INFO,
            { title = ".NET" }
        )
    end)
end

--- Pick a type kind, then create the file.
function M.new_file()
    local base = target_dir()
    local items = {}

    for _, kind in ipairs(KINDS) do
        table.insert(items, {
            key = kind.key,
            label = kind.keyword,
            handler = function()
                create_file(kind.keyword, base)
            end,
        })
    end

    menu.open({ title = "Nouveau fichier", items = items })
end

--- "Invoice" for .../Invoice.cs
local function stem(path)
    return (vim.fs.basename(path):gsub("%.cs$", ""))
end

--- Rename the file on disk, keeping its buffer (and the LSP's view of it).
---
--- vim.lsp.util.rename does the delicate part: it moves the file, re-points
--- every buffer showing it via `:saveas!`, and that write is what sends the
--- server didClose on the old URI and didOpen on the new one. It reports its
--- own refusals but returns nothing either way, so success is read off the disk.
---
--- @return boolean
local function move_file(path, new_path)
    local ok, err = pcall(vim.lsp.util.rename, path, new_path)
    if not ok or not vim.uv.fs_stat(new_path) then
        vim.notify(
            ("Impossible de renommer %s : %s"):format(vim.fs.basename(path), tostring(err or "?")),
            vim.log.levels.ERROR,
            { title = ".NET" }
        )
        return false
    end
    refresh_oil(vim.fs.dirname(new_path))
    return true
end

--- Rename the type through roslyn_ls, save what it edited, move the file, and
--- when it changed folder, let the namespace follow.
---
--- The TYPE goes first, while the file still has its old path: the rename
--- request is addressed to the document's URI. The NAMESPACE goes last: roslyn
--- only offers that refactoring once the file sits in its new folder.
local function rename_and_move(client, bufnr, path, new_path)
    local old, new = stem(path), stem(new_path)
    local dir, new_dir = vim.fs.dirname(path), vim.fs.dirname(new_path)

    local result = { renamed = false, written = 0, pending = {} }
    if new ~= old then
        local err
        result, err = csharp.rename_type(client, bufnr, old, new)
        if not result then
            vim.notify(err, vim.log.levels.ERROR, { title = ".NET" })
            return
        end
    end

    -- Worked out before the move, while the old folder is where the file is.
    local previous = context.namespace_for(dir)

    if not move_file(path, new_path) then
        return
    end

    if new ~= old then
        csharp.report_rename(old, new, result)
    end
    if new_dir == dir then
        return
    end

    vim.notify(
        ("%s.cs déplacé dans %s"):format(new, vim.fn.fnamemodify(new_dir, ":~:.")),
        vim.log.levels.INFO,
        { title = ".NET" }
    )

    local namespace = context.namespace_for(new_dir)
    if not namespace then
        vim.notify("Hors de tout projet : namespace inchangé", vim.log.levels.WARN, { title = ".NET" })
        return
    end

    -- vim.lsp.util.rename kept the buffer number (`:saveas`), so `bufnr` is now
    -- the file at its new path.
    csharp.sync_namespace(client, bufnr, previous, namespace, function(ns_result, err)
        if ns_result then
            csharp.report_namespace(vim.fs.basename(new_path), ns_result)
        else
            vim.notify(err, vim.log.levels.ERROR, { title = ".NET" })
        end
    end)
end

--- Rename and/or move a C# file, and the type named after it everywhere it is
--- used — the menu counterpart of doing it in oil (see oil.lua).
function M.rename_file()
    local path = context.current_file()
    if not path or not path:match("%.cs$") then
        vim.notify(
            "Renommer : ouvre un fichier .cs, ou place le curseur dessus dans oil",
            vim.log.levels.WARN,
            { title = ".NET" }
        )
        return
    end

    local old = stem(path)
    local dir = vim.fs.dirname(path)

    vim.ui.input({ prompt = ("Renommer / déplacer %s.cs vers : "):format(old), default = old }, function(input)
        if not input then
            return
        end

        -- A name renames in place; a path moves too, relative to the file's own
        -- folder like the other prompts: "Models/Foo", "../Services/Foo".
        local target = vim.trim(input):gsub("%.cs$", "")
        if target == "" then
            return
        end
        if vim.fn.isabsolutepath(target) == 0 then
            target = vim.fs.joinpath(dir, target)
        end
        local new_path = vim.fs.normalize(target .. ".cs")
        if new_path == path then
            return
        end

        -- Checked before anything is touched: finding the clash after the type
        -- rename would leave the code renamed and the file not.
        if vim.uv.fs_stat(new_path) then
            vim.notify(
                vim.fn.fnamemodify(new_path, ":~:.") .. " existe déjà",
                vim.log.levels.ERROR,
                { title = ".NET" }
            )
            return
        end

        -- Scheduled out of the vim.ui.input callback, like the menus above. From
        -- oil the file is opened first: the server can only be asked about a
        -- buffer it is attached to, and landing in the renamed file is where
        -- the user would go next anyway.
        vim.schedule(function()
            local bufnr = vim.fn.bufadd(path)
            if bufnr ~= vim.api.nvim_get_current_buf() then
                vim.cmd.buffer(bufnr)
            end

            roslyn.when_ready(bufnr, function(client)
                rename_and_move(client, bufnr, path, new_path)
            end)
        end)
    end)
end

--- Run `cb` with the project an action applies to.
---
--- The buffer's own project when there is one — editing src/Api and asking for a
--- reference means adding it TO Api — and otherwise a pick from what is on disk.
--- Every menu built on top of this names the project in its title, so the choice
--- made here is never silent.
local function with_project(cb)
    local current = context.project()
    if current then
        return cb(current)
    end

    local root = context.root()
    local found = context.projects(root)

    if #found == 0 then
        vim.notify("Aucun projet trouvé", vim.log.levels.WARN, { title = ".NET" })
        return
    end

    local items = {}
    for _, relative in ipairs(found) do
        table.insert(items, {
            label = relative,
            handler = function()
                cb(vim.fs.normalize(root .. "/" .. relative))
            end,
        })
    end

    menu.open({ title = "Quel projet ?", items = items })
end

local function project_name(path)
    return (vim.fs.basename(path):gsub("%.[cf]sproj$", ""))
end

--- Add a project-to-project reference.
function M.add_reference()
    with_project(function(source)
        local root = context.root()
        local referenced = project_graph.references(source)

        local candidates, cyclic = {}, 0
        for _, relative in ipairs(context.projects(root)) do
            local candidate = vim.fs.normalize(root .. "/" .. relative)

            if candidate ~= source and not vim.tbl_contains(referenced, candidate) then
                -- Adding source -> candidate closes a loop exactly when the
                -- candidate can already reach the source. The SDK will not catch
                -- this, so an offending candidate is withheld rather than listed.
                if project_graph.reaches(candidate, source) then
                    cyclic = cyclic + 1
                else
                    table.insert(candidates, relative)
                end
            end
        end

        if #candidates == 0 then
            local detail = cyclic > 0
                    and (" (%d écarté%s : cycle de références)"):format(cyclic, cyclic > 1 and "s" or "")
                or ""
            vim.notify(
                ("Aucun projet à référencer depuis %s%s"):format(project_name(source), detail),
                vim.log.levels.INFO,
                { title = ".NET" }
            )
            return
        end

        local items = {}
        for _, relative in ipairs(candidates) do
            table.insert(items, {
                label = relative,
                handler = function()
                    cli.run({ "add", source, "reference", root .. "/" .. relative }, {
                        cwd = root,
                        label = ("%s → %s"):format(project_name(source), project_name(relative)),
                    }, function()
                        -- The referencing .csproj changed on disk; a buffer
                        -- showing it would otherwise keep the old contents.
                        reload_buffers()
                    end)
                end,
            })
        end

        menu.open({ title = "Référence pour " .. project_name(source), items = items })
    end)
end

--- Human-readable download counts: the NuGet figures run to ten digits, which
--- says less at a glance than "3.2G" does.
local function downloads(count)
    count = tonumber(count) or 0
    if count >= 1e9 then
        return ("%.1fG"):format(count / 1e9)
    elseif count >= 1e6 then
        return ("%.0fM"):format(count / 1e6)
    elseif count >= 1e3 then
        return ("%.0fk"):format(count / 1e3)
    end
    return tostring(count)
end

--- Search NuGet, then add the chosen package.
function M.add_package()
    with_project(function(target)
        local prompt = ("Package NuGet pour %s : "):format(project_name(target))

        vim.ui.input({ prompt = prompt }, function(input)
            if not input then
                return
            end

            local term = vim.trim(input)
            if term == "" then
                return
            end

            -- capture() is silent, and this one goes over the network: without a
            -- word here the editor would just sit there for a second or two.
            vim.notify("Recherche de « " .. term .. " » sur NuGet…", vim.log.levels.INFO, { title = ".NET" })

            -- --format json rather than the default table: the SDK gives
            -- structured results, so there is no column layout to guess at.
            cli.capture({ "package", "search", term, "--take", "20", "--format", "json" }, {
                cwd = vim.fs.dirname(target),
                label = "Recherche NuGet",
            }, function(stdout)
                local ok, data = pcall(vim.json.decode, stdout)
                if not ok or type(data) ~= "table" then
                    vim.notify("Réponse NuGet illisible", vim.log.levels.ERROR, { title = ".NET" })
                    return
                end

                local items = {}
                for _, source in ipairs(data.searchResult or {}) do
                    for _, package in ipairs(source.packages or {}) do
                        table.insert(items, {
                            label = ("%-42s %-12s %8s"):format(
                                package.id,
                                package.latestVersion or "",
                                downloads(package.totalDownloads)
                            ),
                            handler = function()
                                cli.run({ "add", target, "package", package.id }, {
                                    cwd = vim.fs.dirname(target),
                                    label = ("Ajout de %s à %s"):format(package.id, project_name(target)),
                                    -- The resolved version is read back from the
                                    -- output rather than taken from the search
                                    -- result: NuGet reports the latest version,
                                    -- but the SDK installs the newest one
                                    -- COMPATIBLE with the target framework, and
                                    -- those differ often enough to matter.
                                    success = function(stdout)
                                        local version = stdout:match("version '([^']+)' added")
                                        return ("%s%s ajouté à %s"):format(
                                            package.id,
                                            version and (" " .. version) or "",
                                            project_name(target)
                                        )
                                    end,
                                }, function()
                                    -- Under central package management this wrote
                                    -- to BOTH the .csproj and
                                    -- Directory.Packages.props (verified), so the
                                    -- reload cannot be scoped to one of them.
                                    reload_buffers()
                                end)
                            end,
                        })
                    end
                end

                if #items == 0 then
                    vim.notify("Aucun package pour « " .. term .. " »", vim.log.levels.WARN, { title = ".NET" })
                    return
                end

                menu.open({ title = "NuGet : " .. term, items = items })
            end)
        end)
    end)
end

return M
