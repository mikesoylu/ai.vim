local M = {}

local openai = require("_ai/openai")
local util = require("_ai/util")

---@param content string
local function insert_text_at_cursor_mark (content)
    -- Make sure we are in normal mode
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "n" then
        local normal_mode_key = vim.api.nvim_replace_termcodes('<Esc>l', true, true, true)
        vim.api.nvim_feedkeys(normal_mode_key, 'n', false)
    end

    local buffer = vim.api.nvim_get_current_buf()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local row = cursor_pos[1] - 1
    local col = cursor_pos[2]

    local current_line = vim.api.nvim_buf_get_lines(buffer, row, row + 1, true)[1]
    local new_line = current_line:sub(1, col) .. content .. current_line:sub(col + 1)

    -- Split the content into lines, hack it to make sure we preserve empty lines
    local lines = {}
    for line in new_line:gsub("\n\n", "\n{{SEPERATOR}}\n"):gmatch("[^\n]+") do
        if line == "{{SEPERATOR}}" then
            line = ""
        end
        table.insert(lines, line)
    end

    -- Insert the lines one by one using nvim_buf_set_lines
    vim.api.nvim_buf_set_lines(buffer, row, row + 1, true, lines)

    -- Update the cursor position
    local new_row = row + #lines - 1
    local new_col = lines[#lines]:len() - current_line:sub(col + 1):len()
    vim.api.nvim_win_set_cursor(0, {new_row + 1, new_col})
end

---@param args { args: string, range: integer }
function M.ai (args)
    local prompt = args.args
    local visual_mode = args.range > 0

    local buffer = vim.api.nvim_get_current_buf()

    local start_row, start_col
    local end_row, end_col

    if visual_mode then
        -- Use the visual selection
        local start_pos = vim.api.nvim_buf_get_mark(buffer, "<")
        start_row = start_pos[1] - 1
        start_col = start_pos[2]

        local end_pos = vim.api.nvim_buf_get_mark(buffer, ">")
        end_row = end_pos[1] - 1
        end_col = end_pos[2] + 1

    else
        -- Use the cursor position
        local start_pos = vim.api.nvim_win_get_cursor(0)
        start_row = start_pos[1] - 1
        start_col = start_pos[2] + 1
        end_row = start_row
        end_col = start_col
    end

    local start_line_length = vim.api.nvim_buf_get_lines(buffer, start_row, start_row+1, true)[1]:len()
    start_col = math.min(start_col, start_line_length)

    local end_line_length = vim.api.nvim_buf_get_lines(buffer, end_row, end_row+1, true)[1]:len()
    end_col = math.min(end_col, end_line_length)

    local function on_result (err, result)
        if err then
            vim.api.nvim_err_writeln("ai.vim: " .. err)
        else
            -- delete the character at the end
            local fin_cursor = vim.api.nvim_win_get_cursor(0)
            local fin_row = fin_cursor[1] - 1
            local fin_col = fin_cursor[2]
            vim.api.nvim_buf_set_text(buffer, fin_row, fin_col, fin_row, fin_col + 1, {""})
        end
    end

    local function clear ()
        local lines = {" "}
        vim.api.nvim_buf_set_text(buffer, start_row, start_col, end_row, end_col, lines)
        vim.api.nvim_win_set_cursor(0, {start_row + 1, start_col})
    end

    local context_before = util.get_var("ai_context_before", 20)
    local prefix = table.concat(vim.api.nvim_buf_get_text(buffer,
        math.max(0, start_row-context_before), 0, start_row, start_col, {}), "\n")

    local context_after = util.get_var("ai_context_after", 20)
    local line_count = vim.api.nvim_buf_line_count(buffer)
    local suffix = table.concat(vim.api.nvim_buf_get_text(buffer,
        end_row, end_col, math.min(end_row+context_after, line_count-1), 99999999, {}), "\n")

    -- Define the callback function to call insert_text_at_cursor_mark with the content
    local function on_content_received (content)
        insert_text_at_cursor_mark(content)
    end

    if visual_mode then
        local selected_text = table.concat(vim.api.nvim_buf_get_text(buffer, start_row, start_col, end_row, end_col, {}), "\n")
        if prompt == "" then
            -- Replace the selected text, also using it as a prompt
            openai.call(prefix .. "##complete_here##" .. suffix, on_result, on_content_received, selected_text)
        else
            -- Edit selected text
            openai.call(prefix .. selected_text .. suffix, on_result, on_content_received, prompt, selected_text)
        end
    else
        if prompt == "" then
            -- Insert some text generated using surrounding context
            openai.call(prefix .. "##complete_here##" .. suffix, on_result, on_content_received)
        else
            -- Insert some text generated using the given prompt
            openai.call(prefix .. "##complete_here##" .. suffix, on_result, on_content_received, prompt)
        end
    end

    clear()
end

return M
