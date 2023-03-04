local M = {}

---@param cmd string
---@param args string[]
---@param on_result fun(err: string?, output: string?)
local function exec (cmd, args, on_result)
    local stdout = vim.loop.new_pipe()
    local stdout_chunks = {}
    local function on_stdout_read (_, data)
        if data then
            table.insert(stdout_chunks, data)
        end
    end

    local stderr = vim.loop.new_pipe()
    local stderr_chunks = {}
    local function on_stderr_read (_, data)
        if data then
            table.insert(stderr_chunks, data)
        end
    end

    -- print(cmd, vim.inspect(args))

    local handle

    handle, error = vim.loop.spawn(cmd, {
        args = args,
        stdio = {nil, stdout, stderr},
    }, function (code)
        stdout:close()
        stderr:close()
        handle:close()

        vim.schedule(function ()
            if code ~= 0 then
                -- Lop off the trailing newline character
                on_result(table.concat(stderr_chunks, ""):sub(0, -2))
            else
                on_result(nil, table.concat(stdout_chunks, ""))
            end
        end)
    end)

    if not handle then
        on_result(cmd .. " could not be started: " .. error)
    else
        stdout:read_start(on_stdout_read)
        stderr:read_start(on_stderr_read)
    end
end

---@param ctx string
---@param on_result fun(err: string?, output: unknown?): nil
---@param prompt string
---@param selection string
function M.call (ctx, on_result, prompt, selection)
    local api_key = os.getenv("OPENAI_API_KEY")
    if not api_key then
        on_result("$OPENAI_API_KEY environment variable must be set")
        return
    end

    local body = {
        model = "gpt-3.5-turbo",
        max_tokens = 1024,
        temperature = 0.5,
        stop = {"<|INSERT HERE|>"},
        messages = {}
    }

    if selection then
        table.insert(body.messages, {
            role = "system",
            content = "You modify users text. Only respond with the text that should be in users selection."
        })
        table.insert(body.messages, {
            role = "assistant",
            content = ctx
        })

        table.insert(body.messages, {
            role = "system",
            content = "Selection:\n\n" .. selection
        })

        -- expect: this is always true
        if prompt then
            table.insert(body.messages, {
                role = "user",
                content = prompt
            })
        end
    else
        table.insert(body.messages, {
            role = "system",
            content = "You insert text into documents. Only respond with the text that should be in <|INSERT HERE|>."
        })
        table.insert(body.messages, {
            role = "user",
            content = ctx
        })

        if prompt then
            table.insert(body.messages, {
                role = "system",
                content = "Instructions: " .. prompt
            })
        end

        table.insert(body.messages, {
            role = "assistant",
            content = "Contents of <|INSERT HERE|>:"
        })
    end

    local curl_args = {
        "-X", "POST", "--silent", "--show-error",
        "-L", "https://api.openai.com/v1/chat/completions",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " .. api_key,
        "-d", vim.json.encode(body),
    }

    exec("curl", curl_args, function (err, output)
        if err then
            on_result(err)
        else
            local json = vim.json.decode(output)
            if json.error then
                on_result(json.error.message)
            else
                on_result(nil, json)
            end
        end
    end)
end

return M
