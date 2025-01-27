local M = {}

local util = require("_ai/util")

-- Global request cancelling hooks
local request_cancelled = false

function AI_remove_keymap()
    local success, err = pcall(function()
        vim.api.nvim_del_keymap('n', '<C-c>')
    end)
end

function AI_cancel_request(handle, stdout, stderr)
    vim.api.nvim_err_writeln("ai.vim: Completion cancelled")
    request_cancelled = true
    AI_remove_keymap()
end

---@param cmd string
---@param args string[]
---@param on_data fun(data: string)
---@param on_result fun(err: string?, output: string?)
local function exec_stream (cmd, args, on_data, on_result)
    local stdout = vim.loop.new_pipe()
    local stderr = vim.loop.new_pipe()

    local handle, error

    handle, error = vim.loop.spawn(cmd, {
        args = args,
        stdio = {nil, stdout, stderr},
    }, function (code)
        stdout:close()
        stderr:close()
        handle:close()

        vim.schedule(function ()
            if code ~= 0 then
                on_result("Error occurred during streaming")
            else
                on_result(nil, "DONE")
            end
        end)
    end)

    if not handle then
        on_result(cmd .. " could not be started: " .. error)
    else
        stdout:read_start(function (_, data)
            if request_cancelled then
                stdout:close()
                stderr:close()
                handle:close()
            end

            if data then
                on_data(data)
            end
        end)

        stderr:read_start(function (_, data)
            if data then
                on_result("Error: " .. data)
            end
        end)
    end
end

---@param ctx string
---@param on_result fun(err: string?, output: unknown?): nil
---@param on_content_received fun(content: string): nil
---@param prompt string
---@param selection string
function M.call (ctx, on_result, on_content_received, prompt, selection)
    -- Reset the request_cancelled flag before starting a new request
    request_cancelled = false

    local api_key = os.getenv("OPENAI_API_KEY")
    if not api_key then
        on_result("$OPENAI_API_KEY environment variable must be set")
        return
    end

    local buffer = vim.api.nvim_get_current_buf()
    local buffer_name = vim.api.nvim_buf_get_name(buffer)
    local buffer_prompt = ""

    if buffer_name ~= "" then
        buffer_name = buffer_name:match("^.+/(.+)$") or buffer_name
        buffer_prompt = " User is editing " .. buffer_name .. ", respond in the same file format."
    end

    local body = {
        model = util.get_var("ai_model", "o1-mini"),
        max_completion_tokens = 8192,
        stream = true,
        messages = {}
    }

    if selection then
        table.insert(body.messages, {
            role = "user",
            content = "You modify user's text. Follow the user's requirements carefully & to the letter. "
                .. "Only respond with the text that should be in user's selection. "
                .. "Never wrap your response in markdown code block indicators (ie no ```). "
                .. "Preserve indentation to be consistent with the surrounding content." .. buffer_prompt
        })

        table.insert(body.messages, {
            role = "user",
            content = ctx .. "\n\n---\n\nSelection:\n\n" .. selection
                .. "\n\n---\n\nModify selection accordingly: " .. (prompt or "improve") -- default to improve instructions
        })

        table.insert(body.messages, {
            role = "assistant",
            content = "Modified selection:"
        })
    else
        table.insert(body.messages, {
            role = "user",
            content = "You complete user's text. " .. (prompt and "Follow the user's instructions carefully & to the letter. " or "")
                .. "Only respond with the text that should be in ##complete_here##. "
                .. "Never wrap your response in markdown code block indicators (ie no ```). "
                .. "Preserve indentation to be consistent with the surrounding content." .. buffer_prompt
        })

        local content = ctx

        if prompt then
            content = content .. "\n\n---\n\nCompletion instructions: " .. prompt
        end

        table.insert(body.messages, {
            role = "user",
            content = content
        })

        table.insert(body.messages, {
            role = "assistant",
            content = "Contents of ##complete_here##:"
        })
    end

    local curl_args = {
        "-X", "POST", "--silent", "--show-error", "--no-buffer",
        "-L", "https://api.openai.com/v1/chat/completions",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " .. api_key,
        "-d", vim.json.encode(body),
    }

    local buffered_data = ""
    local write_buffer = ""

    local function handle_stream_data (data)
        buffered_data = buffered_data .. data

        -- Extract complete JSON objects from the buffered_data
        local json_start, json_end = buffered_data:find("}\n")
        while json_start do
            local json_str = buffered_data:sub(1, json_end)
            buffered_data = buffered_data:sub(json_end + 1)

            -- Remove the "data: " prefix
            json_str = json_str:gsub("data: ", "")

            vim.schedule(function ()
                local success, json_data = pcall(vim.fn.json_decode, json_str)
                
                if success then
                    local content = json_data.choices[1].delta.content

                    if content then
                        write_buffer = write_buffer .. content
                    end

                    local line = write_buffer:match("[^\n]*\n")

                    -- Remove unwanted markdown indicators, including ```<lang>
                    if line then
                        -- Remove lines starting with ```
                        line = line:gsub("```%w*\n?", "")
                    end

                    -- Call the on_content_received function with the content if it's not nil and request is not cancelled
                    if line and not request_cancelled then
                        on_content_received(line)
                    end

                    if line then
                      -- Remove the line from the buffer
                      write_buffer = write_buffer:sub(#line + 1)
                    end
                else
                    -- Handle JSON decoding errors (optional)
                    vim.api.nvim_err_writeln("ai.vim: Error decoding JSON: " .. json_data)
                end
            end)

            json_start, json_end = buffered_data:find("}\n")
        end
    end

    vim.api.nvim_set_keymap('n', '<C-c>', '<cmd>lua AI_cancel_request()<CR>', {noremap = true, silent = true})

    exec_stream("curl", curl_args, handle_stream_data, function(err, output)
        AI_remove_keymap()
        if not request_cancelled then
            if write_buffer ~= "" then
                on_content_received(write_buffer:gsub("```%w*\n?", ""))
            end

            on_result(err, output)
        end
    end)
end

return M
