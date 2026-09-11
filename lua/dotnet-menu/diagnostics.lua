-- Errors that outlive their cause until the buffer is re-opened with :e.
--
-- Add a file to a project — create it, rename or move one, `dotnet new` — and
-- every open buffer that uses its type keeps CS0246 "type not found" (measured:
-- still there 40s later). The server is NOT stale: in that same buffer,
-- go-to-definition and hover already resolve the new type.
--
-- The gap is on the client side. After reloading the project roslyn_ls sends
-- workspace/diagnostic/refresh, and because it supports workspace diagnostics,
-- Neovim answers with a `workspace/diagnostic` pull ONLY (seen in lsp.log: three
-- identifiers — HotReloadDiagnostics, enc, WorkspaceDocumentsAndProject). The
-- per-document categories are never re-pulled, and DocumentCompilerSemantic, the
-- one carrying CS0246, is among them. Pulling each open document again clears
-- it (errors 2 -> 0, measured); :e works for the same reason.
--
-- So the refresh keeps whatever handler the client already has — Neovim's, or
-- one from the user's own config — and adds that per-document pull, the same
-- request the nvim-lspconfig spec makes once the solution has loaded. While
-- typing roslyn_ls sends no refresh (measured over 40 edits), so this adds no
-- traffic there.

local M = {}

local METHOD = "workspace/diagnostic/refresh"

local wrappers = setmetatable({}, { __mode = "k" })

local function pull_open_documents(client)
    local identifiers = vim.iter(client.dynamic_capabilities.capabilities.diagnosticProvider or {})
        :map(function(registration)
            return registration.registerOptions.identifier
        end)
        :totable()

    for bufnr in pairs(client.attached_buffers) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            for _, identifier in ipairs(identifiers) do
                client:request("textDocument/diagnostic", {
                    identifier = identifier,
                    textDocument = vim.lsp.util.make_text_document_params(bufnr),
                }, nil, bufnr)
            end
        end
    end
end

-- A second gap, in Neovim 0.12's workspace diagnostics: every file a
-- workspace report mentions gets a buffer (vim.uri_to_bufnr) and an entry in a
-- private `bufstates` table, and nothing removes that entry when the buffer is
-- wiped. oil wipes the buffer of a file it moves; from then on every
-- workspace/diagnostic/refresh fails in previous_result_ids() with
-- "Invalid buffer id", for the rest of the session (seen after a move, with or
-- without this plugin's own buffers involved).
--
-- The table is not exposed, so it is reached through the upvalue of a function
-- that uses it, and only the entries for buffers that no longer exist are
-- dropped. If a later Neovim renames or restructures it, this finds nothing and
-- does nothing — the error is then only kept from masking the pull below.
local function drop_wiped_bufstates()
    local refresh = vim.lsp.diagnostic._refresh
    if type(refresh) ~= "function" then
        return
    end
    for i = 1, 64 do
        local name, value = debug.getupvalue(refresh, i)
        if not name then
            return
        end
        if name == "bufstates" and type(value) == "table" then
            for bufnr in pairs(value) do
                if type(bufnr) == "number" and not vim.api.nvim_buf_is_valid(bufnr) then
                    value[bufnr] = nil
                end
            end
            return
        end
    end
end

--- Wrapped per client rather than set through vim.lsp.config: that would
--- replace a handler the user defined, and miss a client that was already
--- running when this plugin was set up.
local function wrap(client)
    if client.name ~= "roslyn_ls" then
        return
    end

    local original = client.handlers[METHOD]
    if wrappers[original] then
        return
    end

    -- The original runs first and its outcome is passed on — except the
    -- "Invalid buffer id" failure described above, which would otherwise be
    -- reported on every refresh. Anything else is re-raised, AFTER the
    -- per-document pull, so it does not also cost the open buffers their fresh
    -- diagnostics.
    local function wrapper(err, result, ctx, config)
        pcall(drop_wiped_bufstates)
        local ok, response = pcall(original or vim.lsp.handlers[METHOD], err, result, ctx, config)
        local c = vim.lsp.get_client_by_id(ctx.client_id)
        if c and not err then
            pull_open_documents(c)
        end
        if not ok then
            if tostring(response):find("Invalid buffer id", 1, true) then
                return vim.NIL
            end
            error(response, 0)
        end
        return response
    end
    wrappers[wrapper] = true
    client.handlers[METHOD] = wrapper
end

function M.setup()
    for _, client in ipairs(vim.lsp.get_clients({ name = "roslyn_ls" })) do
        wrap(client)
    end

    vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("dotnet-menu.diagnostics", { clear = true }),
        desc = "dotnet-menu: re-pull open documents' diagnostics on roslyn_ls refresh",
        callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if client then
                wrap(client)
            end
        end,
    })
end

return M
