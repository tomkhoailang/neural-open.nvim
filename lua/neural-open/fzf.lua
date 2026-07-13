local M = {}

local path_mod = require("neural-open.path")
local scorer = require("neural-open.scorer")
local source_mod = require("neural-open.source")
local recent = require("neural-open.recent")
local transitions = require("neural-open.transitions")

local function is_in_cwd(path, cwd)
  if path == cwd then
    return true
  end
  return path:sub(1, #cwd + 1) == cwd .. "/"
end

-- ---------------------------------------------------------------------------
-- Untracked file cache
-- Lives at module level so it persists across M.files() calls for the whole
-- nvim session. The binary reads FZF_UNTRACKED_FILES and pushes items
-- synchronously (instant), falling back to its own goroutine when empty.
-- ---------------------------------------------------------------------------
local _untracked = {
  cwd   = nil,   -- cwd the cache was built for
  files = nil,   -- array of relative paths, nil = not yet cached
  busy  = false, -- async rebuild currently running
  ready = false, -- autocmds registered
}

local function _rebuild_untracked(cwd)
  if _untracked.busy then return end
  _untracked.busy = true
  vim.system(
    { "git", "ls-files", "--others", "--exclude-standard" },
    { text = true, cwd = cwd },
    vim.schedule_wrap(function(obj)
      _untracked.busy = false
      if obj.code == 0 and obj.stdout then
        local files = {}
        for line in obj.stdout:gmatch("[^\n]+") do
          if line ~= "" then
            table.insert(files, line)
          end
        end
        _untracked.cwd   = cwd
        _untracked.files = files
      end
    end)
  )
end

-- Invalidate cache and proactively rebuild when the user switches back to nvim
-- or changes directory — so the cache is warm before the picker is opened.
local function _setup_untracked_watchers()
  if _untracked.ready then return end
  _untracked.ready = true
  vim.api.nvim_create_autocmd({ "FocusGained", "DirChanged" }, {
    callback = function()
      _untracked.files = nil
      _rebuild_untracked(vim.fn.getcwd())
    end,
  })
end

function M.files(opts)
  opts = opts or {}
  local fzf = require("fzf-lua")

  -- 1. Resolve context
  local current_file = ""
  local current_buf = vim.api.nvim_get_current_buf()
  if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
    local buf_name = vim.api.nvim_buf_get_name(current_buf)
    if buf_name and buf_name ~= "" then
      current_file = path_mod.normalize(buf_name)
    end
  end

  local cwd = vim.fn.getcwd()
  local alternate_buf = vim.fn.bufname("#")
  if alternate_buf ~= "" then
    alternate_buf = path_mod.normalize(alternate_buf)
    if not is_in_cwd(alternate_buf, cwd) then
      alternate_buf = ""
    end
  end

  -- Open buffers
  local open_bufs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name and name ~= "" then
        local norm = path_mod.normalize(name)
        if is_in_cwd(norm, cwd) then
          table.insert(open_bufs, norm)
        end
      end
    end
  end

  -- Recency list
  local recent_map = recent.get_recency_map()
  local mru_list = {}
  local sorted_mru = {}
  for path, data in pairs(recent_map) do
    table.insert(sorted_mru, { path = path, rank = data.recent_rank })
  end
  table.sort(sorted_mru, function(a, b) return a.rank < b.rank end)
  for _, item in ipairs(sorted_mru) do
    if is_in_cwd(item.path, cwd) then
      table.insert(mru_list, item.path)
    end
  end

  -- Transitions
  local transition_scores = {}
  if current_file ~= "" then
    transition_scores = transitions.compute_scores_from(current_file)
  end
  local trans_list = {}
  for path, score in pairs(transition_scores) do
    if is_in_cwd(path, cwd) then
      table.insert(trans_list, path .. ":" .. tostring(score))
    end
  end

  -- Frecency (from Snacks)
  local frec_list = {}
  local frecency_ok, snacks_frecency = pcall(require, "snacks.picker.core.frecency")
  if frecency_ok then
    local inst_ok, frecency_inst = pcall(snacks_frecency.new)
    if inst_ok and frecency_inst and frecency_inst.cache then
      local frecency_mod = require("neural-open.frecency")
      for path, deadline in pairs(frecency_inst.cache) do
        if is_in_cwd(path, cwd) then
          local norm_path = path_mod.normalize(path)
          local raw = frecency_inst:to_score(deadline)
          local norm = frecency_mod.normalize_transition(raw, 8)
          table.insert(frec_list, norm_path .. ":" .. tostring(norm))
        end
      end
    end
  end

  -- Weights file
  local config = require("neural-open").config
  local weights_dir = config.weights_dir or (vim.fn.stdpath("data") .. "/neural-open")
  local weights_file = weights_dir .. "/files.json"

  -- 2. Setup env variables
  vim.env.FZF_CURRENT_FILE = current_file
  vim.env.FZF_OPEN_BUFFERS = table.concat(open_bufs, ";")
  vim.env.FZF_ALT_BUFFER = alternate_buf
  vim.env.FZF_MRU_LIST = table.concat(mru_list, ";")
  vim.env.FZF_TRANSITIONS = table.concat(trans_list, ";")
  vim.env.FZF_FRECENCY = table.concat(frec_list, ";")
  vim.env.FZF_NEURAL_WEIGHTS_FILE = weights_file
  vim.env.FZF_PROJECT_CWD = cwd

  -- Untracked cache: set up watchers on first call, rebuild if stale,
  -- and pass cached files to the binary via env var (instant).
  -- Empty string → binary falls back to its own goroutine (cold-cache path).
  _setup_untracked_watchers()
  if _untracked.cwd ~= cwd or _untracked.files == nil then
    _rebuild_untracked(cwd) -- async; result ready for the NEXT open
    vim.env.FZF_UNTRACKED_FILES = ""
  else
    vim.env.FZF_UNTRACKED_FILES = table.concat(_untracked.files, ";")
  end

  -- 3. File command
  -- Phase 1: plain git ls-files (22ms). Deleted files are filtered by stat()
  -- in the binary. Untracked files come from FZF_UNTRACKED_FILES (cached,
  -- instant) or fall back to a background goroutine in the binary on cold cache.
  local is_git = #vim.fs.find(".git", { upward = true, stop = vim.loop.os_homedir() }) > 0
  local cmd
  if is_git then
    cmd = "git ls-files"
  elseif vim.fn.executable("fd") == 1 then
    cmd = "fd --type f --hidden --follow --exclude .git"
  else
    cmd = "find . -type f -not -path '*/.git/*'"
  end

  local fzf_bin = vim.fn.stdpath("data") .. "/lazy/fzf/bin/fzf"

  vim.fn.mkdir(weights_dir, "p")

  -- 4. Launch FZF
  local function handle_file_action(selected, fzf_opts, open_cmd)
    if not selected or #selected == 0 then return end
    
    -- Parse selection
    local clean_sel = selected[1]:gsub("\x1b%[[%d;]*m", "")
    local filename, dir = clean_sel:match("^[^ ]+  (.+)  (.-)$")
    local selected_file
    if filename then
      dir = dir:gsub("%s+$", "")
      selected_file = dir ~= "" and (dir .. "/" .. filename) or filename
    else
      selected_file = clean_sel
    end

    local abs_selected_file = vim.fn.fnamemodify(selected_file, ":p")
    abs_selected_file = path_mod.normalize(abs_selected_file)

    -- Edit the file
    vim.cmd(open_cmd .. " " .. vim.fn.fnameescape(abs_selected_file))

    -- 5. Record selection & Train neural network
    vim.schedule(function()
      if current_file ~= "" then
        transitions.record_transition(current_file, abs_selected_file)
      end

      local item_tracking = require("neural-open.item_tracking")
      item_tracking.record_selection("files", abs_selected_file, cwd)

      local registry = require("neural-open.algorithms.registry")
      local algorithm = registry.get_algorithm()
      algorithm.load_weights()

      -- Build mock positive item
      local selected_item = {
        file = abs_selected_file,
        nos = {
          normalized_path = abs_selected_file,
          virtual_name = scorer.get_virtual_name(abs_selected_file, config.special_files),
          ctx = {
            recent_files = recent_map,
            alternate_buf = alternate_buf,
            cwd = cwd,
            current_file = current_file,
            current_file_dir = filepath_dir(current_file),
            current_file_depth = count_slashes(current_file),
            algorithm = algorithm,
            transition_scores = transition_scores,
          }
        }
      }

      -- Run scorer to populate input_buf features
      local mock_matcher
      mock_matcher = {
        pattern = fzf_opts.last_query or "",
        match = function(_, it)
          local text = it.text or ""
          if mock_matcher.pattern == "" then
            return 1000
          end
          if text:lower():find(mock_matcher.pattern:lower(), 1, true) then
            return 3000
          end
          return 0
        end
      }
      scorer.on_match_handler(mock_matcher, selected_item)

      -- Collect negative samples to train
      local ranked_items = { selected_item }
      local count = 1
      for _, recent_path in ipairs(mru_list) do
        if recent_path ~= abs_selected_file and count < 11 then
          local neg_item = {
            file = recent_path,
            nos = {
              normalized_path = recent_path,
              virtual_name = scorer.get_virtual_name(recent_path, config.special_files),
              ctx = selected_item.nos.ctx
            }
          }
          scorer.on_match_handler(mock_matcher, neg_item)
          table.insert(ranked_items, neg_item)
          count = count + 1
        end
      end

      pcall(algorithm.update_weights, selected_item, ranked_items)
    end)
  end

  local function copy_path_action(selected, relative)
    if not selected or #selected == 0 then return end
    local clean_sel = selected[1]:gsub("\x1b%[[%d;]*m", "")
    local filename, dir = clean_sel:match("^[^ ]+  (.+)  (.-)$")
    local selected_file
    if filename then
      dir = dir:gsub("%s+$", "")
      selected_file = dir ~= "" and (dir .. "/" .. filename) or filename
    else
      selected_file = clean_sel
    end
    local abs_selected_file = vim.fn.fnamemodify(selected_file, ":p")
    abs_selected_file = path_mod.normalize(abs_selected_file)
    local target = abs_selected_file
    if relative then
      target = vim.fn.fnamemodify(abs_selected_file, ":.")
    end
    vim.fn.setreg("+", target)
    vim.notify("Copied path: " .. target)
    return require("fzf-lua").actions.resume
  end

  -- 4. Launch FZF
  fzf.fzf_exec(cmd, {
    prompt = "Neural Open> ",
    fzf_bin = fzf_bin,
    fzf_opts = {
      ["--scheme"] = "filename-first",
      ["--tiebreak"] = "index",
      ["--ansi"] = "",
      ["--algo"] = "frizbee",
      ["--bind"] = "alt-n:next-history,alt-p:prev-history",
      ["--history"] = vim.fn.stdpath("data") .. "/fzf-lua-hybrid-files-history",
    },
    actions = {
      ["default"] = function(selected, fzf_opts)
        handle_file_action(selected, fzf_opts, "edit")
      end,
      ["ctrl-s"] = function(selected, fzf_opts)
        handle_file_action(selected, fzf_opts, "split")
      end,
      ["ctrl-v"] = function(selected, fzf_opts)
        handle_file_action(selected, fzf_opts, "vsplit")
      end,
      ["ctrl-t"] = function(selected, fzf_opts)
        handle_file_action(selected, fzf_opts, "tabedit")
      end,
      ["alt-i"] = function(selected, fzf_opts)
        handle_file_action(selected, fzf_opts, "split")
      end,
      ["alt-o"] = function(selected, fzf_opts)
        handle_file_action(selected, fzf_opts, "vsplit")
      end,
      ["ctrl-alt-x"] = function(selected)
        return copy_path_action(selected, false)
      end,
      ["ctrl-alt-c"] = function(selected)
        return copy_path_action(selected, true)
      end,
    }
  })
end

function filepath_dir(path)
  if not path or path == "" then return nil end
  local dir = path:match("(.*/)")
  return dir
end

function count_slashes(path)
  if not path or path == "" then return 0 end
  local count = 0
  for i = 1, #path do
    if path:byte(i) == 0x2F then
      count = count + 1
    end
  end
  return count
end

return M
