local ui = require('spelunk.ui')
local persist = require('spelunk.persistence')
local marks = require('spelunk.mark')
local tele = require('spelunk.telescope')
local util = require('spelunk.util')

local M = {}

---@type VirtualStack[]
local default_stacks = {
	{ name = 'Default', bookmarks = {} }
}
---@type VirtualStack[]
local bookmark_stacks
---@type integer
local current_stack_index = 1
---@type integer
local cursor_index = 1

local window_config

---@type boolean
local enable_persist

---@type string
local statusline_prefix

---@type boolean
local show_status_col

---@return VirtualStack
local function current_stack()
	return bookmark_stacks[current_stack_index]
end

---@return VirtualBookmark
local function current_bookmark()
	return bookmark_stacks[current_stack_index].bookmarks[cursor_index]
end

---@type fun(abspath: string): string
M.filename_formatter = require('spelunk.util').filename_formatter

---@return integer
local function max_stack_size()
	local max = 0
	for _, stack in ipairs(bookmark_stacks) do
		local size = util.tbllen(stack.bookmarks)
		if size > max then
			max = size
		end
	end
	return max
end

---@return UpdateWinOpts
local function get_win_update_opts()
	local lines = {}
	for _, vmark in ipairs(bookmark_stacks[current_stack_index].bookmarks) do
		local bookmark = marks.virt_to_physical(vmark)
		local display = string.format('%s:%d', M.filename_formatter(bookmark.file), bookmark.line)
		table.insert(lines, display)
	end
	return {
		cursor_index = cursor_index,
		title = current_stack().name,
		lines = lines,
		bookmark = current_bookmark(),
		max_stack_size = max_stack_size(),
	}
end

---@param updated_indices boolean
local function update_window(updated_indices)
	if updated_indices and show_status_col then
		marks.update_indices(current_stack())
	end
	ui.update_window(get_win_update_opts())
end

---@param file string
---@param line integer
---@param split string | nil
local function goto_position(file, line, col, split)
	if not split then
		vim.api.nvim_command('edit ' .. file)
		vim.api.nvim_win_set_cursor(0, { line, col })
	elseif split == 'vertical' then
		vim.api.nvim_command('vsplit ' .. file)
		vim.api.nvim_win_set_cursor(0, { line, col })
	elseif split == 'horizontal' then
		vim.api.nvim_command('split ' .. file)
		vim.api.nvim_win_set_cursor(0, { line, col })
	else
		vim.notify('[spelunk.nvim] goto_position passed unsupported split: ' .. split)
	end
end

function M.toggle_window()
	ui.toggle_window(get_win_update_opts())
end

function M.close_windows()
	ui.close_windows()
end

function M.show_help()
	ui.show_help()
end

function M.close_help()
	ui.close_help()
end

function M.add_bookmark()
	local currstack = current_stack()
	table.insert(currstack.bookmarks, marks.set_mark_current_pos(#currstack.bookmarks + 1))
	vim.notify(string.format("[spelunk.nvim] Bookmark added to stack '%s': %s:%d:%d",
		currstack.name, vim.fn.expand('%:p'), vim.fn.line('.'), vim.fn.col('.')))
	update_window(true)
	M.persist()
end

---@param direction 1 | -1
function M.move_cursor(direction)
	local bookmarks = bookmark_stacks[current_stack_index].bookmarks
	cursor_index = cursor_index + direction
	if cursor_index < 1 then
		cursor_index = math.max(#bookmarks, 1)
	elseif cursor_index > #bookmarks then
		cursor_index = 1
	end
	update_window(true)
end

---@param direction 1 | -1
function M.move_bookmark(direction)
	if direction ~= 1 and direction ~= -1 then
		vim.notify('[spelunk.nvim] move_bookmark passed invalid direction')
		return
	end
	local curr_stack = current_stack()
	if util.tbllen(current_stack().bookmarks) < 2 then
		return
	end
	local new_idx = cursor_index + direction
	if new_idx < 1 or new_idx > util.tbllen(curr_stack.bookmarks) then
		return
	end
	local curr_mark = current_bookmark()
	local tmp_new = bookmark_stacks[current_stack_index].bookmarks[new_idx]
	bookmark_stacks[current_stack_index].bookmarks[cursor_index] = tmp_new
	bookmark_stacks[current_stack_index].bookmarks[new_idx] = curr_mark
	M.move_cursor(direction)
	M.persist()
end

---@param close boolean
---@param split string | nil
local function goto_bookmark(close, split)
	local bookmarks = current_stack().bookmarks
	local mark = marks.virt_to_physical(current_bookmark())
	if cursor_index > 0 and cursor_index <= #bookmarks then
		if close then
			M.close_windows()
		end
		vim.schedule(function()
			goto_position(mark.file, mark.line, mark.col, split)
		end)
	end
end

---@param idx integer
function M.goto_bookmark_at_index(idx)
	if idx < 1 or idx > util.tbllen(bookmark_stacks[current_stack_index].bookmarks) then
		vim.notify('[spelunk.nvim] Given invalid index: ' .. idx)
		return
	end
	cursor_index = idx
	goto_bookmark(true)
end

function M.goto_selected_bookmark()
	goto_bookmark(true)
end

function M.goto_selected_bookmark_horizontal_split()
	goto_bookmark(true, 'horizontal')
end

function M.goto_selected_bookmark_vertical_split()
	goto_bookmark(true, 'vertical')
end

function M.delete_selected_bookmark()
	local bookmarks = current_stack().bookmarks
	if not bookmarks[cursor_index] then
		return
	end
	marks.delete_mark(bookmarks[cursor_index])
	table.remove(bookmarks, cursor_index)
	if cursor_index > #bookmarks and #bookmarks ~= 0 then
		cursor_index = #bookmarks
	end
	update_window(true)
	M.persist()
end

---@param direction 1 | -1
function M.select_and_goto_bookmark(direction)
	if ui.is_open() then
		return
	end
	if util.tbllen(current_stack().bookmarks) == 0 then
		vim.notify('[spelunk.nvim] No bookmarks to go to')
		return
	end
	M.move_cursor(direction)
	goto_bookmark(false)
end

function M.delete_current_stack()
	if util.tbllen(bookmark_stacks) < 2 then
		vim.notify('[spelunk.nvim] Cannot delete a stack when you have less than two')
		return
	end
	if not bookmark_stacks[current_stack_index] then
		return
	end
	marks.delete_stack(bookmark_stacks[current_stack_index])
	table.remove(bookmark_stacks, current_stack_index)
	current_stack_index = 1
	update_window(false)
	M.persist()
end

function M.edit_current_stack()
	local stack = bookmark_stacks[current_stack_index]
	if not stack then
		return
	end
	local name = vim.fn.input('[spelunk.nvim] Enter new name for the stack: ', stack.name)
	if name == '' then
		return
	end
	bookmark_stacks[current_stack_index].name = name
	update_window(false)
	M.persist()
end

function M.next_stack()
	current_stack_index = current_stack_index % #bookmark_stacks + 1
	cursor_index = 1
	update_window(false)
end

function M.prev_stack()
	current_stack_index = (current_stack_index - 2) % #bookmark_stacks + 1
	cursor_index = 1
	update_window(false)
end

function M.new_stack()
	local name = vim.fn.input('[spelunk.nvim] Enter name for new stack: ')
	if name and name ~= '' then
		table.insert(bookmark_stacks, { name = name, bookmarks = {} })
		current_stack_index = #bookmark_stacks
		cursor_index = 1
		update_window(false)
	end
	M.persist()
end

function M.persist()
	if enable_persist then
		persist.save(marks.virt_to_physical_stack(bookmark_stacks))
	end
end

---@return FullBookmark[]
function M.all_full_marks()
	local data = {}
	for _, stack in ipairs(bookmark_stacks) do
		for _, vmark in ipairs(stack.bookmarks) do
			local mark = marks.virt_to_physical(vmark)
			table.insert(data, {
				stack = stack.name,
				file = mark.file,
				line = mark.line,
				col = mark.col,
			})
		end
	end
	return data
end

function M.search_marks()
	tele.search_marks('[spelunk.nvim] Bookmarks', M.all_full_marks(), goto_position)
end

---@return FullBookmark[]
function M.current_full_marks()
	local data = {}
	local stack = current_stack()
	for _, vmark in ipairs(stack.bookmarks) do
		local mark = marks.virt_to_physical(vmark)
		table.insert(data, {
			stack = stack.name,
			file = mark.file,
			line = mark.line,
			col = mark.col,
		})
	end
	return data
end

function M.search_current_marks()
	tele.search_marks('[spelunk.nvim] Current Stack', M.current_full_marks(), goto_position)
end

function M.search_stacks()
	---@param stack PhysicalStack
	local cb = function(stack)
		local stack_idx
		for i, s in ipairs(bookmark_stacks) do
			if s.name == stack.name then
				stack_idx = i
			end
		end
		if not stack_idx then
			return
		end
		current_stack_index = stack_idx
		M.toggle_window()
	end
	tele.search_stacks('[spelunk.nvim] Stacks', marks.virt_to_physical_stack(bookmark_stacks), cb)
end

---@return string
function M.statusline()
	local count = 0
	local path = vim.fn.expand('%:p')
	for _, stack in ipairs(bookmark_stacks) do
		for _, vmark in ipairs(stack.bookmarks) do
			local mark = marks.virt_to_physical(vmark)
			if mark.file == path then
				count = count + 1
			end
		end
	end
	return statusline_prefix .. ' ' .. count
end

---@param vmarks VirtualBookmark[]
local open_marks_qf = function(vmarks)
	local qf_items = {}
	for _, vmark in ipairs(vmarks) do
		local mark = marks.virt_to_physical(vmark)
		table.insert(qf_items, {
			bufnr = vmark.bufnr,
			lnum = mark.line,
			col = mark.col,
			text = vim.fn.getline(mark.line),
			type = '',
		})
	end
	vim.fn.setqflist(qf_items, 'r')
	vim.cmd('copen')
end

M.qf_all_marks = function()
	local vmarks = {}
	for _, vstack in ipairs(bookmark_stacks) do
		for _, vmark in ipairs(vstack.bookmarks) do
			table.insert(vmarks, vmark)
		end
	end
	open_marks_qf(vmarks)
end

M.qf_current_marks = function()
	local vmarks = {}
	for _, vmark in ipairs(current_stack().bookmarks) do
		table.insert(vmarks, vmark)
	end
	open_marks_qf(vmarks)
end

function M.setup(c)
	local conf = c or {}
	local cfg = require('spelunk.config')
	local base_config = conf.base_mappings or {}
	cfg.apply_base_defaults(base_config)
	window_config = conf.window_mappings or {}
	cfg.apply_window_defaults(window_config)
	ui.setup(base_config, window_config)

	require('spelunk.layout').setup(conf.orientation or cfg.get_default('orientation'))

	show_status_col = conf.enable_status_col_display or cfg.get_default('enable_status_col_display')

	-- Load saved bookmarks, if enabled and available
	-- Otherwise, set defaults
	---@type PhysicalStack[]
	local physical_stacks
	enable_persist = conf.enable_persist or cfg.get_default('enable_persist')
	if enable_persist then
		local saved = persist.load()
		if saved then
			physical_stacks = saved
		else
			physical_stacks = default_stacks
		end
	end

	bookmark_stacks = marks.setup(physical_stacks, show_status_col)

	-- Configure the prefix to use for the lualine integration
	statusline_prefix = conf.statusline_prefix or cfg.get_default('statusline_prefix')

	local set = cfg.set_keymap
	set(base_config.toggle, M.toggle_window, '[spelunk.nvim] Toggle UI')
	set(base_config.add, M.add_bookmark, '[spelunk.nvim] Add bookmark')
	set(base_config.next_bookmark, ':lua require("spelunk").select_and_goto_bookmark(1)<CR>',
		'[spelunk.nvim] Go to next bookmark')
	set(base_config.prev_bookmark, ':lua require("spelunk").select_and_goto_bookmark(-1)<CR>',
		'[spelunk.nvim] Go to previous bookmark')

	-- Create a callback to persist changes to mark locations on file updates
	local persist_augroup = vim.api.nvim_create_augroup('SpelunkPersistCallback', { clear = true })
	vim.api.nvim_create_autocmd('BufWritePost', {
		group = persist_augroup,
		pattern = '*',
		callback = function(ctx)
			local bufnr = ctx.buf
			if not bufnr then
				return
			end
			for _, stack in pairs(bookmark_stacks) do
				for _, mark in pairs(stack.bookmarks) do
					if bufnr == mark.bufnr then
						M.persist()
						return
					end
				end
			end
		end,
		desc = '[spelunk.nvim] Persist mark updates on file change'
	})

	-- Register telescope extension, only if telescope itself is loaded already
	local telescope_loaded, telescope = pcall(require, 'telescope')
	if not telescope_loaded then
		return
	end
	telescope.load_extension('spelunk')
	set(base_config.search_bookmarks, telescope.extensions.spelunk.marks,
		'[spelunk.nvim] Fuzzy find bookmarks')
	set(base_config.search_current_bookmarks, telescope.extensions.spelunk.current_marks,
		'[spelunk.nvim] Fuzzy find bookmarks in current stack')
	set(base_config.search_stacks, telescope.extensions.spelunk.stacks, '[spelunk.nvim] Fuzzy find stacks')
end

return M
