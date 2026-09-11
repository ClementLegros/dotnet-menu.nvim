-- Running the `dotnet` CLI on behalf of the menu.
--
-- The three rules below were MEASURED against the SDK on this machine
-- (10.0.111), not assumed, because each one shapes the code:
--
--   * A failure writes to stderr and leaves stdout empty; a success does the
--     reverse. So the stream worth showing is chosen by the exit code, never by
--     "whichever one is non-empty".
--   * The exit code is not a 0/1 flag. `dotnet new` answers 103 for an unknown
--     template and 73 when it would overwrite an existing file. Anything
--     non-zero is a failure — but the message ends with an
--     aka.ms/templating-exit-codes link that is pure noise in a notification,
--     so it is stripped.
--   * Exit 0 does not mean anything changed: adding a project already in the
--     solution succeeds with "already contains project". Callers that care must
--     read the output, not just the code.
--
-- Everything runs through vim.system, i.e. asynchronously: `dotnet new` takes a
-- second or more and blocking the editor on it would be felt.

local M = {}

local TITLE = ".NET"

local function notify(msg, level)
    vim.notify(msg, level, { title = TITLE })
end

-- Drop the templating engine's exit-code trailer and any surrounding blank
-- lines, so a notification shows the actual error and nothing else.
local function clean(text)
    text = (text or ""):gsub("\nFor details on the exit code[^\n]*\n?", "\n")
    return vim.trim(text)
end

--- Run `dotnet <args>` and report the outcome.
---
--- @param args string[]                    arguments after the `dotnet` binary
--- @param opts { cwd: string, label: string, full_output?: boolean, success?: string|fun(stdout: string): string }
---             label names the action in messages; full_output keeps every line
---             of a successful run rather than just the first; success replaces
---             the command's own output with a message of our own
--- @param on_success? fun(stdout: string)  called on the main loop, exit 0 only
function M.run(args, opts, on_success)
    -- vim.system raises on a missing executable, which would surface as a Lua
    -- stack trace rather than something actionable.
    if vim.fn.executable("dotnet") ~= 1 then
        notify("`dotnet` not found on the PATH", vim.log.levels.ERROR)
        return
    end

    local cmd = vim.list_extend({ "dotnet" }, args)

    -- The menu has already closed by the time this runs, so without this the
    -- editor would sit silent for the second or two the SDK takes.
    notify(opts.label .. "…", vim.log.levels.INFO)

    vim.system(cmd, { cwd = opts.cwd, text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                local message = clean(result.stderr)
                if message == "" then
                    -- Some failures are reported on STDOUT, buried in it: a
                    -- rejected `dotnet add package` prints two certificate
                    -- warnings and an HTTP log before the one line that says what
                    -- went wrong. The SDK marks that line "error:" / "error NU1101:",
                    -- so those are lifted out when present.
                    local errors = {}
                    for line in clean(result.stdout):gmatch("[^\n]+") do
                        if line:lower():match("^%s*error") then
                            table.insert(errors, vim.trim(line))
                        end
                    end
                    message = #errors > 0 and table.concat(errors, "\n") or clean(result.stdout)
                end
                if message == "" then
                    message = ("`%s` failed (exit code %d)"):format(table.concat(cmd, " "), result.code)
                end
                notify(message, vim.log.levels.ERROR)
                return
            end

            -- Only the FIRST line on success. `dotnet new classlib` confirms in
            -- one sentence and then dumps its whole post-creation restore log
            -- ("Restoring …", "Restored … in 255 ms.", "Restore succeeded."),
            -- which turns a confirmation into a wall of text. Failures keep
            -- their full output — there the detail is the point.
            -- Truncated for DISPLAY only; on_success still receives all of it.
            -- full_output opts out, for the commands whose every line matters:
            -- `dotnet sln add a b c` confirms one project per line, and showing
            -- only the first would report a third of what happened.
            local stdout = clean(result.stdout)

            -- `success` is for commands whose output cannot be summarised by
            -- taking a line from it. `dotnet add package` opens with two X.509
            -- certificate-bundle warnings and then logs every HTTP request it
            -- makes to nuget.org: the first line is noise, and all of it is a
            -- page. Stating the outcome ourselves is the only readable option.
            local shown
            if type(opts.success) == "function" then
                shown = opts.success(stdout)
            elseif opts.success then
                shown = opts.success
            elseif opts.full_output then
                shown = stdout
            else
                shown = stdout:match("^[^\n]*") or ""
            end

            notify(shown ~= "" and shown or (opts.label .. ": OK"), vim.log.levels.INFO)

            if on_success then
                on_success(stdout)
            end
        end)
    end)
end

--- Run `dotnet <args>` for its OUTPUT rather than its effect.
---
--- Separate from M.run because that one narrates: it announces the command and
--- then reports what came back. Querying the SDK — listing templates, listing a
--- solution's projects — is a step inside an action, not an action, and
--- narrating it would put two notifications around every menu that has to look
--- something up first. Failures are still reported; silence only covers success.
---
--- @param args string[]
--- @param opts { cwd: string, label: string }
--- @param on_output fun(stdout: string)
function M.capture(args, opts, on_output)
    if vim.fn.executable("dotnet") ~= 1 then
        notify("`dotnet` not found on the PATH", vim.log.levels.ERROR)
        return
    end

    vim.system(vim.list_extend({ "dotnet" }, args), { cwd = opts.cwd, text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                local message = clean(result.stderr)
                notify(opts.label .. ": " .. (message ~= "" and message or "failed"), vim.log.levels.ERROR)
                return
            end
            on_output(result.stdout or "")
        end)
    end)
end

return M
