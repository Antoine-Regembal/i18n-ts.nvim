local M = {}

--- Absolute path with symlinks resolved, so buffer names and project paths compare equal.
function M.real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

--- First marker found upwards wins, in the order given (not the nearest of all markers).
---@param path string file or directory
---@param markers string[]
---@return string|nil
function M.find(path, markers)
  if path == "" then
    return nil
  end
  for _, marker in ipairs(markers) do
    local root = vim.fs.root(path, marker)
    if root then
      return M.real(root)
    end
  end
end

return M
