local M = {}

local _has_fs_normalize = (function()
  local ok, result = pcall(function()
    return vim.fs ~= nil and vim.fs.normalize ~= nil
  end)
  return ok and result
end)()
local _normalize_opts = { expand_env = false }

local cache = {}
local cwd_cache = {}
local last_cwd = nil

local function is_normalized(p)
  if p:find("\\") or p:find("//") or p:find("/%.%/") or p:find("/%.%.$") or p:find("/%.$") or p:find("/%.%.%/") then
    return false
  end
  local len = #p
  if len > 1 and p:sub(len, len) == "/" then
    return false
  end
  return true
end

---@param path string
---@return string
function M.normalize(path)
  if _has_fs_normalize then
    local cached = cache[path]
    if cached then
      return cached
    end
    local res
    if is_normalized(path) then
      res = path
    else
      res = vim.fs.normalize(path, _normalize_opts)
    end
    cache[path] = res
    return res
  else
    local cwd = vim.fn.getcwd()
    if cwd ~= last_cwd then
      cwd_cache = {}
      last_cwd = cwd
    end
    local cached = cwd_cache[path]
    if cached then
      return cached
    end
    local res = vim.fn.fnamemodify(path, ":p")
    cwd_cache[path] = res
    return res
  end
end

return M
