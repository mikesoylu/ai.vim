local M = {}

---@param name string
---@param default_value unknown
---@return unknown
function M.get_var (name, default_value)
    local value = vim.g[name]
    if value == nil then
        return default_value
    end
    return value
end

return M
