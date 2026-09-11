-- C# source operations shared by the menu (actions.lua) and the oil hooks
-- (oil.lua): the body of a new file, the type a file is named after — finding
-- it, renaming it everywhere, finding who still uses it — and the namespace of
-- a file that changed folder.
--
-- The roslyn_ls requests here are SYNCHRONOUS (request_sync), except the
-- namespace sync, which has to poll until roslyn offers it. The oil hooks
-- have no choice: OilActionsPre is the last moment the server still knows the
-- file under its old path, and oil moves it the moment the hook returns. The
-- menu uses the same code for a single, explicit action, where a fraction of a
-- second of blocking is not worth a second, callback-shaped copy.

local M = {}

-- Generous: a rename walks every reference in the solution.
local TIMEOUT_MS = 10000

local TITLE = ".NET"

--- Build a new file's body, and say which line the cursor belongs on.
---
--- @param keyword string   class | interface | record | enum | struct
--- @param namespace string|nil
--- @return string[] lines, integer cursor_line
function M.scaffold(keyword, name, namespace)
    local lines = {}

    -- File-scoped: the default style of the SDK templates since .NET 6.
    if namespace then
        table.insert(lines, "namespace " .. namespace .. ";")
        table.insert(lines, "")
    end

    table.insert(lines, "public " .. keyword .. " " .. name)
    table.insert(lines, "{")
    table.insert(lines, "")
    table.insert(lines, "}")

    -- The blank line between the braces: where you would start typing anyway.
    return lines, #lines - 1
end

-- The symbol kinds a file can be named after. Records come back as Class
-- (record struct as Struct), so they need no entry of their own.
local TYPE_KINDS = {
    [vim.lsp.protocol.SymbolKind.Class] = true,
    [vim.lsp.protocol.SymbolKind.Interface] = true,
    [vim.lsp.protocol.SymbolKind.Enum] = true,
    [vim.lsp.protocol.SymbolKind.Struct] = true,
}

--- Where the type called `name` is declared, from a documentSymbol answer.
---
--- Searched recursively: the types are CHILDREN of the namespace symbol
--- (measured, file-scoped namespace included). A generic type is reported as
--- "Repository<T>" while its file is Repository.cs, hence the stripped suffix.
---
--- @return lsp.Position|nil
local function find_type(symbols, name)
    for _, symbol in ipairs(symbols) do
        if TYPE_KINDS[symbol.kind] and symbol.name:gsub("<.*$", "") == name then
            -- DocumentSymbol carries selectionRange (the identifier itself);
            -- the flat SymbolInformation form only has a location.
            return (symbol.selectionRange or symbol.location.range).start
        end
        local found = find_type(symbol.children or {}, name)
        if found then
            return found
        end
    end
    return nil
end

--- Every buffer a WorkspaceEdit touches, in either of its two shapes.
local function edited_buffers(edit)
    local uris = {}
    for uri in pairs(edit.changes or {}) do
        uris[uri] = true
    end
    for _, change in ipairs(edit.documentChanges or {}) do
        if change.textDocument then
            uris[change.textDocument.uri] = true
        end
    end

    local out = {}
    for uri in pairs(uris) do
        table.insert(out, vim.uri_to_bufnr(uri))
    end
    return out
end

--- One synchronous request, with its three ways of failing folded into a
--- message: timeout, server error, or (for the caller to judge) a null result.
--- @return any result, string|nil err
local function request(client, bufnr, method, params)
    local response, err = client:request_sync(method, params, TIMEOUT_MS, bufnr)
    if not response then
        return nil, ("roslyn_ls: %s (%s)"):format(err or "no response", method)
    end
    if response.err then
        return nil, "roslyn_ls: " .. response.err.message
    end
    return response.result, nil
end

--- Close a buffer this plugin opened, without wiping it.
---
--- Unloaded and unlisted — `:bunload` plus 'nobuflisted' — rather than deleted
--- outright: Neovim's workspace-diagnostics code keeps per-buffer state that a
--- wiped buffer leaves behind, and the next workspace/diagnostic/refresh then
--- fails on it with "Invalid buffer id" (seen after a move). An unloaded buffer
--- keeps its number valid, and unloading still detaches it from the server.
function M.close_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    vim.bo[bufnr].buflisted = false
    pcall(vim.api.nvim_buf_delete, bufnr, { unload = true })
end

--- Which buffers exist and which hold unsaved work, taken BEFORE an edit: both
--- decide what happens to a buffer once the edit is applied.
local function snapshot()
    local loaded, modified = {}, {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        loaded[b] = vim.api.nvim_buf_is_loaded(b)
        modified[b] = vim.bo[b].modified
    end
    return { loaded = loaded, modified = modified }
end

--- Apply a WorkspaceEdit from roslyn_ls and save what it touched.
---
--- Saved, because a refactoring is only real once it is on disk: `dotnet build`
--- reads files, not buffers. The exception is a buffer that ALREADY had unsaved
--- changes — writing it would commit work in progress along with the edit, so it
--- is left to the user and named in the report. `bufnr`, the file the operation
--- is about, is always saved: it is being moved, and what moves is the disk.
---
--- @return integer written, string[] pending
local function apply_and_save(client, edit, bufnr, before)
    vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)

    local written, pending = 0, {}
    for _, b in ipairs(edited_buffers(edit)) do
        if b ~= bufnr and before.modified[b] then
            table.insert(pending, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t"))
        else
            vim.api.nvim_buf_call(b, function()
                vim.cmd("silent write")
            end)
            written = written + 1

            -- apply_workspace_edit loads every file it edits into a LISTED
            -- buffer: a widely used type would fill the bufferline with files
            -- nobody opened. Those go away again; the edit is on disk.
            if b ~= bufnr and not before.loaded[b] then
                M.close_buffer(b)
            end
        end
    end
    return written, pending
end

--- Where the type named after the file is declared, if there is one.
--- @return lsp.Position|nil position, string|nil err
local function locate(client, bufnr, name)
    local symbols, err = request(client, bufnr, "textDocument/documentSymbol", {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
    })
    if err then
        return nil, err
    end
    return find_type(symbols or {}, name), nil
end

--- @class dotnet.RenameResult
--- @field renamed boolean   false: no type called `old` in the file (Program.cs)
--- @field written integer   files saved with the rename
--- @field pending string[]  files renamed in their buffer but left unsaved

--- Rename the type `old` declared in `bufnr` to `new`, across the solution,
--- and save what changed. The file itself is NOT renamed — that is the caller's
--- job (vim.lsp.util.rename for the menu, oil for the hook).
---
--- The buffer at `bufnr` is always saved when it was edited, unsaved changes
--- included: its file is about to move, and what moves is what is on disk.
---
--- @return dotnet.RenameResult|nil result, string|nil err
function M.rename_type(client, bufnr, old, new)
    local position, err = locate(client, bufnr, old)
    if err then
        return nil, err
    end

    -- Program.cs, or a file holding several small types: nothing is named
    -- after it, so there is nothing to rename but the file.
    if not position then
        return { renamed = false, written = 0, pending = {} }
    end

    local before = snapshot()

    local edit
    edit, err = request(client, bufnr, "textDocument/rename", {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        position = position,
        newName = new,
    })
    if err then
        return nil, err
    end

    -- An invalid identifier is refused WITHOUT an error: measured, "2Bad" comes
    -- back as a null result. Nothing has changed at this point.
    if not edit then
        return nil, ("roslyn_ls refused to rename %s to %s (invalid C# type name?)"):format(old, new)
    end

    local written, pending = apply_and_save(client, edit, bufnr, before)
    return { renamed = true, written = written, pending = pending }, nil
end

-- The refactoring roslyn offers on a namespace that does not match the folders,
-- told apart by its provider tag rather than its title: the title is localised
-- (a French Windows may not say "Change namespace to"), the tag is an internal
-- constant. The same provider also offers "Move file to …", which is why the
-- target namespace, quoted in the title in any language, is matched as well.
local SYNC_NAMESPACE_PROVIDER = "Sync Namespace and Folder Name Code Action Provider"

-- How long to wait for roslyn to offer it. It needs the project to know the
-- file's new folder, i.e. a project reload: measured, it appeared ~2s after
-- the move on a three-project solution.
local SYNC_TIMEOUT_MS = 30000
local SYNC_POLL_MS = 500

local function pick_sync_action(actions, namespace)
    for _, action in ipairs(actions) do
        local tags = vim.tbl_get(action, "data", "CustomTags") or {}
        if vim.tbl_contains(tags, SYNC_NAMESPACE_PROVIDER) and action.title:find("'" .. namespace .. "'", 1, true) then
            return action
        end
    end
    return nil
end

--- @class dotnet.NamespaceResult
--- @field changed boolean  false: nothing to do (already right, no namespace,
---                         or a namespace that never followed the folders)
--- @field kept? string     the hand-chosen namespace that was left alone
--- @field from? string
--- @field to? string
--- @field written? integer
--- @field pending? string[]

--- After a file moved to another folder: change its namespace to `namespace`,
--- with roslyn's own refactoring, so every file using its types gets the
--- matching `using` — measured, moving a class into Models/ added
--- `using EncoreUnTest.Models;` to Class1.cs, its only caller.
---
--- Only when the namespace followed the OLD folder (`previous`): a namespace
--- that was chosen by hand is left alone rather than forced onto the folders.
---
--- Asynchronous: the action is only offered once the server has reloaded the
--- project, so this polls for it. `cb` gets the result, or nil and a message.
---
--- @param cb fun(result: dotnet.NamespaceResult|nil, err: string|nil)
function M.sync_namespace(client, bufnr, previous, namespace, cb)
    local symbols, err = request(client, bufnr, "textDocument/documentSymbol", {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
    })
    if err then
        return cb(nil, err)
    end

    local declaration
    for _, symbol in ipairs(symbols or {}) do
        if symbol.kind == vim.lsp.protocol.SymbolKind.Namespace then
            declaration = symbol
            break
        end
    end

    if not declaration or declaration.name == namespace then
        return cb({ changed = false }, nil)
    end
    if declaration.name ~= previous then
        return cb({ changed = false, kept = declaration.name }, nil)
    end

    local params = {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        range = { start = declaration.selectionRange.start, ["end"] = declaration.selectionRange.start },
        context = { diagnostics = {}, triggerKind = 1 },
    }
    local deadline = vim.uv.now() + SYNC_TIMEOUT_MS

    local function attempt()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return cb(nil, "buffer closed before the namespace was updated")
        end

        client:request("textDocument/codeAction", params, function(action_err, actions)
            local action = not action_err and pick_sync_action(actions or {}, namespace)
            if not action then
                if vim.uv.now() < deadline then
                    vim.defer_fn(attempt, SYNC_POLL_MS)
                else
                    cb(nil, ("roslyn_ls did not offer to change %s to %s"):format(declaration.name, namespace))
                end
                return
            end

            local resolved, resolve_err = request(client, bufnr, "codeAction/resolve", action)
            if resolve_err or not (resolved and resolved.edit) then
                return cb(nil, resolve_err or "roslyn_ls: the action carries no edit")
            end

            local written, pending = apply_and_save(client, resolved.edit, bufnr, snapshot())
            cb({ changed = true, from = declaration.name, to = namespace, written = written, pending = pending }, nil)
        end, bufnr)
    end

    attempt()
end

--- @param result dotnet.NamespaceResult
function M.report_namespace(file, result)
    if result.kept then
        vim.notify(
            ("%s: namespace %s kept (it did not follow the folders)"):format(file, result.kept),
            vim.log.levels.INFO,
            { title = TITLE }
        )
    end
    if not result.changed then
        return
    end
    vim.notify(
        ("%s: namespace %s → %s (%d file%s)"):format(
            file,
            result.from,
            result.to,
            result.written,
            result.written > 1 and "s" or ""
        ),
        vim.log.levels.INFO,
        { title = TITLE }
    )
    if #result.pending > 0 then
        vim.notify(
            "Changed but NOT saved (they had unsaved edits): " .. table.concat(result.pending, ", "),
            vim.log.levels.WARN,
            { title = TITLE }
        )
    end
end

--- The files, other than its own, that use the type `name` declared in `bufnr`.
--- @return string[]|nil paths, string|nil err  (empty list: none, or no such type)
function M.users_of_type(client, bufnr, name)
    local position, err = locate(client, bufnr, name)
    if err then
        return nil, err
    end
    if not position then
        return {}, nil
    end

    local locations
    locations, err = request(client, bufnr, "textDocument/references", {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        position = position,
        context = { includeDeclaration = false },
    })
    if err then
        return nil, err
    end

    local own = vim.uri_from_bufnr(bufnr)
    local seen, out = {}, {}
    for _, location in ipairs(locations or {}) do
        if location.uri ~= own and not seen[location.uri] then
            seen[location.uri] = true
            table.insert(out, vim.uri_to_fname(location.uri))
        end
    end
    table.sort(out)
    return out, nil
end

--- Report a rename the way both callers want it said.
--- @param result dotnet.RenameResult
function M.report_rename(old, new, result)
    if not result.renamed then
        vim.notify(
            ("%s.cs → %s.cs (no type %s in the file: only the file was renamed)"):format(old, new, old),
            vim.log.levels.INFO,
            { title = TITLE }
        )
        return
    end

    vim.notify(
        ("%s.cs → %s.cs, type %s renamed in %d file%s"):format(
            old,
            new,
            new,
            result.written,
            result.written > 1 and "s" or ""
        ),
        vim.log.levels.INFO,
        { title = TITLE }
    )
    if #result.pending > 0 then
        vim.notify(
            "Changed but NOT saved (they had unsaved edits): " .. table.concat(result.pending, ", "),
            vim.log.levels.WARN,
            { title = TITLE }
        )
    end
end

return M
