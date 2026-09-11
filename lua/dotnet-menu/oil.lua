-- Doing the .NET part of a file operation made in oil, so the menu is not the
-- only way in. Editing an oil buffer and saving it creates, renames, moves and
-- deletes files; each of those has a C# consequence:
--
--   create  Invoice.cs   an empty file is filled in, as the menu's "New
--                        file" would: namespace from the folders, then
--                        `public class Invoice` (interface for IInvoice).
--   rename  Foo -> Bar   the type Foo is renamed to Bar across the solution,
--                        as the menu's "Rename" does. oil alone would only
--                        move the file: roslyn_ls declares willRenameFiles for
--                        **/*.razor only (measured on 5.12.0).
--   move    Foo.cs into  the namespace follows the folder, through roslyn's
--           Models/      own "change namespace" refactoring, which also adds the
--                        `using` its callers need. Combined with a rename, both
--                        happen.
--   delete  Foo.cs       a warning when Foo is still used elsewhere — the next
--                        build would fail there — and the deleted file's buffer
--                        is closed, since while it stays open the server keeps
--                        the type alive from the buffer's text.
--
-- Only files inside a project, and only with a roslyn_ls ALREADY running for
-- that solution (see roslyn.client_for): a .cs file in a scratch directory is
-- left alone.

local context = require("dotnet-menu.context")
local csharp = require("dotnet-menu.csharp")
local roslyn = require("dotnet-menu.roslyn")

local M = {}

local TITLE = ".NET"

-- A rename is worth waiting for (it cannot be redone once oil has moved the
-- file), a warning is not: a delete never waits on the server.
local RENAME_WAIT_MS = 30000

local function notify(msg, level)
    vim.notify(msg, level, { title = TITLE })
end

--- oil URL -> path on disk, or nil when the URL is not a local file (ssh, s3,
--- trash). The conversion goes through oil itself: on Windows its URLs read
--- oil:///C/Users/..., not a path Neovim can open.
local function path_of(url)
    local util = require("oil.util")
    local scheme, path = util.parse_url(url)
    local adapter = scheme and require("oil.config").get_adapter_by_scheme(scheme)
    if not path or not adapter or adapter.name ~= "files" then
        return nil
    end
    return vim.fs.normalize(require("oil.fs").posix_to_os_path(path))
end

local function is_cs(path)
    return path ~= nil and path:match("%.cs$") ~= nil
end

--- "Invoice" for .../Invoice.cs
local function stem(path)
    return (vim.fs.basename(path):gsub("%.cs$", ""))
end

--- A buffer on `path` attached to `client`, and whether it was loaded just for
--- this — in which case the caller closes it again. bufadd leaves it unlisted,
--- so it never shows up in the bufferline in between.
local function attached_buffer(client, path)
    local bufnr = vim.fn.bufadd(path)
    local temporary = not vim.api.nvim_buf_is_loaded(bufnr)
    if temporary then
        vim.fn.bufload(bufnr)
    end
    -- Explicit rather than left to the FileType autocmd, which a buffer loaded
    -- from inside another autocmd is not guaranteed to reach.
    if vim.bo[bufnr].filetype == "" then
        vim.bo[bufnr].filetype = "cs"
    end
    vim.lsp.buf_attach_client(bufnr, client.id)
    return bufnr, temporary
end

--- Reports queued by the Pre hook, said by the Post hook once oil has actually
--- done the operation — or turned into an explanation when it failed.
local queued = {}

--- Files that changed folder, for the Post hook to fix their namespace. Their
--- previous namespace is worked out HERE, while the old folder's project can
--- still be found from it.
local moved = {}

--- Before a move: rename the type while the server still knows the old path.
local function before_move(action)
    local src, dest = path_of(action.src_url), path_of(action.dest_url)
    if not (is_cs(src) and is_cs(dest)) then
        return
    end

    local src_dir = vim.fs.dirname(src)
    if not context.project(src_dir) then
        return
    end

    -- Another folder: the namespace follows, but only after the move — roslyn
    -- offers that refactoring for the file where it IS, not where it will be.
    if vim.fs.dirname(dest) ~= src_dir then
        table.insert(moved, { path = dest, previous = context.namespace_for(src_dir) })
    end

    local old, new = stem(src), stem(dest)
    if old == new then
        return
    end

    local client = roslyn.client_for(src)
    if not client then
        notify(("roslyn_ls is not running: %s.cs renamed without its type"):format(old), vim.log.levels.WARN)
        return
    end
    if not roslyn.wait_ready(client, RENAME_WAIT_MS) then
        notify(("roslyn_ls has not finished loading the solution: type %s not renamed"):format(old), vim.log.levels.ERROR)
        return
    end

    local bufnr, temporary = attached_buffer(client, src)
    local result, err = csharp.rename_type(client, bufnr, old, new)
    -- After the save inside rename_type: closing sends didClose, and the server
    -- falls back to the file on disk — which by now holds the new name.
    if temporary then
        csharp.close_buffer(bufnr)
    end

    if not result then
        notify(err, vim.log.levels.ERROR)
        return
    end

    table.insert(queued, {
        ok = function()
            csharp.report_rename(old, new, result)
        end,
        failed = result.renamed and function()
            notify(("Type %s was renamed to %s, but oil did not rename the file"):format(old, new), vim.log.levels.ERROR)
        end or nil,
    })
end

--- Before a delete: find out who still uses the type, while it still exists.
local function before_delete(action)
    local path = path_of(action.url)
    if not is_cs(path) or not context.project(vim.fs.dirname(path)) then
        return
    end

    local client = roslyn.client_for(path)
    if not client or not roslyn.is_ready(client) then
        return
    end

    local name = stem(path)
    local bufnr, temporary = attached_buffer(client, path)
    local users = csharp.users_of_type(client, bufnr, name)
    if temporary then
        csharp.close_buffer(bufnr)
    end

    if users and #users > 0 then
        local names = vim.tbl_map(function(p)
            return vim.fn.fnamemodify(p, ":t")
        end, users)
        table.insert(queued, {
            ok = function()
                notify(
                    ("%s.cs deleted, but %s is still used in: %s"):format(name, name, table.concat(names, ", ")),
                    vim.log.levels.WARN
                )
            end,
        })
    end
end

--- After a delete: close the deleted file's buffer. Left open, it keeps the
--- server treating the type as alive, so the callers would show no error.
local function after_delete(action)
    local path = path_of(action.url)
    if not is_cs(path) then
        return
    end
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and not vim.bo[bufnr].modified then
        csharp.close_buffer(bufnr)
    end
end

--- After a create: fill in an EMPTY .cs file that oil just made in a project.
--- @return string|nil what was written, for the report
local function after_create(action)
    local path = path_of(action.url)
    if not is_cs(path) then
        return nil
    end

    local stat = vim.uv.fs_stat(path)
    local name = stem(path)
    -- Not a plain identifier ("Invoice.Validation.cs", "my-file.cs"): the name
    -- says nothing reliable about the type inside, so the file stays empty.
    if not stat or stat.size > 0 or not name:match("^[%a_][%w_]*$") then
        return nil
    end

    local namespace = context.namespace_for(vim.fs.dirname(path))
    if not namespace then
        return nil
    end

    -- The C# convention for interfaces: I followed by a capitalised word.
    -- IService yes; IOHelper and Invoice no.
    local keyword = name:match("^I%u%l") and "interface" or "class"
    local ok = pcall(vim.fn.writefile, (csharp.scaffold(keyword, name, namespace)), path)
    if not ok then
        return nil
    end

    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.cmd("checktime " .. bufnr)
    end
    return ("%s.cs: %s %s in %s"):format(name, keyword, name, namespace)
end

--- Fix the namespace of each moved file, one after the other: each waits for
--- roslyn to offer the refactoring, and they would otherwise all poll at once.
local function sync_moved(list)
    local item = table.remove(list, 1)
    if not item then
        return
    end

    local file = vim.fs.basename(item.path)
    local namespace = context.namespace_for(vim.fs.dirname(item.path))
    local client = roslyn.client_for(item.path)

    if not namespace then
        notify(("%s is outside any project: namespace unchanged"):format(file), vim.log.levels.WARN)
        return sync_moved(list)
    end
    if not client then
        notify(("roslyn_ls is not running: namespace of %s not updated"):format(file), vim.log.levels.WARN)
        return sync_moved(list)
    end

    local bufnr, temporary = attached_buffer(client, item.path)
    csharp.sync_namespace(client, bufnr, item.previous, namespace, function(result, err)
        if temporary then
            csharp.close_buffer(bufnr)
        end
        if result then
            csharp.report_namespace(file, result)
        else
            notify(err, vim.log.levels.ERROR)
        end
        sync_moved(list)
    end)
end

local function on_pre(actions)
    queued = {}
    moved = {}
    for _, action in ipairs(actions) do
        if action.entry_type == "file" then
            if action.type == "move" then
                before_move(action)
            elseif action.type == "delete" then
                before_delete(action)
            end
        end
    end
end

local function on_post(err, actions)
    if err then
        for _, report in ipairs(queued) do
            if report.failed then
                report.failed()
            end
        end
        queued = {}
        return
    end

    local created = {}
    for _, action in ipairs(actions) do
        if action.entry_type == "file" then
            if action.type == "create" then
                local line = after_create(action)
                if line then
                    table.insert(created, line)
                end
            elseif action.type == "delete" then
                after_delete(action)
            end
        end
    end

    for _, report in ipairs(queued) do
        report.ok()
    end
    queued = {}

    if #created > 0 then
        notify(table.concat(created, "\n"), vim.log.levels.INFO)
    end

    local list = moved
    moved = {}
    sync_moved(list)
end

--- A failure in a hook must not become a failure of the oil save itself: the
--- autocmd error would propagate into oil's own action processing.
local function guarded(fn)
    return function(args)
        local ok, err = pcall(fn, args.data)
        if not ok then
            notify("oil hook: " .. tostring(err), vim.log.levels.ERROR)
        end
    end
end

function M.setup()
    if not pcall(require, "oil") then
        return
    end

    local group = vim.api.nvim_create_augroup("dotnet-menu.oil", { clear = true })

    -- nested: the hooks load and write buffers, and without it the autocmds
    -- those would normally fire (FileType, BufWritePost -> didSave) are skipped.
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "OilActionsPre",
        nested = true,
        desc = "dotnet-menu: rename types / check users before oil moves or deletes .cs files",
        callback = guarded(function(data)
            on_pre(data.actions)
        end),
    })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "OilActionsPost",
        nested = true,
        desc = "dotnet-menu: fill new .cs files, report, close deleted buffers",
        callback = guarded(function(data)
            on_post(data.err, data.actions)
        end),
    })
end

return M
