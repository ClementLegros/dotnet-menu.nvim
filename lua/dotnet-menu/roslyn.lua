-- Knowing when roslyn_ls can be trusted with a question about the WHOLE
-- solution.
--
-- The server answers requests as soon as it has initialized, but it only knows
-- the solution once it has loaded it — and until then it answers anyway, from
-- the open files alone. Measured on a three-project solution: renaming
-- TestClass before the load returned an edit for TestClass.cs only, no error;
-- the same request after the load also covered Class1.cs, which uses it. A rename that trusted
-- the early answer would leave Class1.cs pointing at a type that no longer
-- exists, and nothing would say so until the build broke.
--
-- The end of the load is announced by the `workspace/projectInitializationComplete`
-- notification. The lspconfig spec already handles it (notify + diagnostics
-- refresh); it is wrapped here, per client, rather than replaced, so that
-- behaviour stays.

local M = {}

local METHOD = "workspace/projectInitializationComplete"

--- Client ids whose solution has finished loading.
local ready = {}

--- Wrappers installed by this module, so a client whose handlers table is
--- shared with an earlier one is not wrapped twice.
local wrappers = setmetatable({}, { __mode = "k" })

--- Wrap the client's handler for the "solution loaded" notification, so the
--- moment it arrives is recorded.
local function track(client)
    if client.name ~= "roslyn_ls" then
        return
    end

    local original = client.handlers[METHOD]
    if wrappers[original] then
        return
    end

    local function wrapper(err, result, ctx, config)
        ready[ctx.client_id] = true
        if original then
            return original(err, result, ctx, config)
        end
        return vim.NIL
    end
    wrappers[wrapper] = true
    client.handlers[METHOD] = wrapper
end

function M.setup()
    -- A client already running when the plugin is set up (lazy-loaded late)
    -- sent its notification before anyone listened for it. It is taken as
    -- loaded: the alternative — never ready — would block every rename. Set
    -- the plugin up at startup to keep this guess out of the picture.
    for _, client in ipairs(vim.lsp.get_clients({ name = "roslyn_ls" })) do
        ready[client.id] = true
        track(client)
    end

    vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("dotnet-menu.roslyn", { clear = true }),
        desc = "dotnet-menu: track when roslyn_ls has loaded the solution",
        callback = function(args)
            -- LspAttach fires right after `initialize`, and the nvim-lspconfig
            -- spec only asks for the solution in on_init, so the load is still
            -- running when this is installed: measured, attach at 0.9s and load
            -- complete at 3.6s on a three-project solution.
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if client then
                track(client)
            end
        end,
    })
end

-- How long to wait. The load took a few seconds on a three-project solution;
-- the ceiling is generous for large ones. The attach deadline is short on
-- purpose: no client after a few seconds means no server, not a slow one.
local ATTACH_TIMEOUT_MS = 10000
local LOAD_TIMEOUT_MS = 120000
local POLL_MS = 200
local ANNOUNCE_AFTER_MS = 1000

--- The running roslyn_ls whose solution covers `path`, if any. Nothing is
--- started: the oil hooks only act where C# is already being edited, rather
--- than spinning up a server for a stray .cs file in some other directory.
--- @return vim.lsp.Client|nil
function M.client_for(path)
    for _, client in ipairs(vim.lsp.get_clients({ name = "roslyn_ls" })) do
        if client.root_dir and vim.fs.relpath(client.root_dir, path) then
            return client
        end
    end
    return nil
end

--- @return boolean
function M.is_ready(client)
    return ready[client.id] == true
end

--- Block until `client` has loaded the solution, or `timeout_ms` passes.
--- For the oil hooks, which cannot wait with a callback: oil moves the file as
--- soon as the hook returns. vim.wait keeps the event loop running, so the
--- notification it waits for is still delivered.
--- @return boolean ready
function M.wait_ready(client, timeout_ms)
    if ready[client.id] then
        return true
    end
    vim.notify("Waiting for roslyn_ls to load the solution…", vim.log.levels.INFO, { title = ".NET" })
    return vim.wait(timeout_ms, function()
        return ready[client.id] == true
    end, POLL_MS)
end

--- Run `cb(client)` once roslyn_ls is attached to `bufnr` AND has loaded the
--- solution. Reports and gives up on timeout rather than waiting forever.
---
--- @param bufnr integer
--- @param cb fun(client: vim.lsp.Client)
function M.when_ready(bufnr, cb)
    local start = vim.uv.now()
    local announced = false

    local function poll()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        local client = vim.lsp.get_clients({ bufnr = bufnr, name = "roslyn_ls" })[1]
        local elapsed = vim.uv.now() - start

        if client and ready[client.id] then
            return cb(client)
        end

        if not client and elapsed > ATTACH_TIMEOUT_MS then
            vim.notify("roslyn_ls is not attached to this file", vim.log.levels.ERROR, { title = ".NET" })
            return
        end

        if elapsed > LOAD_TIMEOUT_MS then
            vim.notify("roslyn_ls has not finished loading the solution", vim.log.levels.ERROR, { title = ".NET" })
            return
        end

        -- Said once, and only when the wait is a real one. A file just opened
        -- from oil attaches a moment AFTER the first poll even when the server
        -- loaded long ago (measured: ~0.3s), which is not worth a message.
        if not announced and elapsed > ANNOUNCE_AFTER_MS then
            announced = true
            vim.notify("Waiting for roslyn_ls to load the solution…", vim.log.levels.INFO, { title = ".NET" })
        end

        vim.defer_fn(poll, POLL_MS)
    end

    poll()
end

return M
