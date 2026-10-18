-- ===========================================================
-- Plugin Hexadecimal Viewer and Editor (Multithreaded Rendering)
-- Author: 	Damian V. Cechov
-- damianvcechov@gmail.com ©2026
-- ===========================================================

local M = {}
M.disabled_buffers = {}
-- Per-buffer state of an in-flight chunked load
M.load_state = {}
-- Per-buffer chunk storage. Tables read back from vim.b are detached
-- copies, so the (mutated in place) raw chunk data lives here instead.
M.buf_data = {}
local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("hexview_ns")
local cursor_ns = vim.api.nvim_create_namespace("hexview_cursor_ns")

-- ============================================================
-- CONFIGURATION
-- ============================================================
M.bytes_per_line = 52
M.auto_columns = true
M.ascii_start_col = 0
M.hex_width = 0
-- Raw data is held in chunks of roughly this many bytes, aligned to a
-- multiple of bytes_per_line, so that loading can be split across
-- libuv worker threads. Smaller chunks keep the main-thread insert
-- pauses short (smoother browsing while loading); bigger chunks
-- reduce dispatch overhead.
M.chunk_bytes = 256 * 1024

-- ============================================================
-- AUXILIARY FUNCTIONS
-- ============================================================
local function hex_width_for(cols)
	return cols * 3 + 2 * math.floor((cols - 1) / 4)
end

-- Total rendered line width for a given column count
local function line_width_for(cols)
	return 10 + hex_width_for(cols) + 3 + cols
end

function M.max_columns_for(width)
	local cols = math.floor((width - 13) / 4.5)
	if cols < 1 then
		return 1
	end
	while cols > 1 and line_width_for(cols) > width do
		cols = cols - 1
	end
	while line_width_for(cols + 1) <= width do
		cols = cols + 1
	end
	return cols
end

function M.setup_layout()
	M.hex_width = hex_width_for(M.bytes_per_line)
	M.ascii_start_col = 10 + M.hex_width + 3
end

function M.get_byte(idx)
	local edits = vim.b.hex_edits
	if edits and edits[tostring(idx)] then
		return edits[tostring(idx)]
	end

	local d = M.buf_data[vim.api.nvim_get_current_buf()]
	if d and idx <= (vim.b.hex_size or 0) then
		local cs = d.chunk_size
		if cs > 0 then
			local ci = math.floor((idx - 1) / cs) + 1
			local s = d.chunks[ci]
			if s and idx <= (ci - 1) * cs + #s then
				return string.byte(s, idx - (ci - 1) * cs)
			end
		end
	end
	return nil
end

-- ============================================================
-- 1. FETCH DATA (MULTI-CORE, NON-BLOCKING)
-- ============================================================
-- The file is loaded by libuv worker threads (uv.new_work): each
-- worker reads one chunk from disk and pre-renders its hex lines, the
-- main thread only splices the finished lines into the buffer. The
-- editor stays responsive and browsable while loading; progress is
-- shown in the statusline. The number of worker threads is controlled
-- by the UV_THREADPOOL_SIZE environment variable (libuv default: 4).

-- nvim_buf_set_lines respects 'modifiable', and loading must work on
-- buffers that are locked against user input, so toggle it around the
-- API writes.
local function buf_set_lines(buf, start_i, end_i, lines)
	local bo = vim.bo[buf]
	local was_modifiable = bo.modifiable
	if not was_modifiable then
		bo.modifiable = true
	end
	vim.api.nvim_buf_set_lines(buf, start_i, end_i, false, lines)
	if not was_modifiable then
		bo.modifiable = false
	end
end

-- Runs in a worker thread. It is serialized with string.dump, so it
-- must not capture upvalues and may only use the Lua standard library.
-- Line layout must stay in sync with M.generate_line_content().
local read_work = nil
if uv.new_work then
	read_work = uv.new_work(function(path, offset, len, bpl, chunk_id, buf, gen)
		local f = io.open(path, "rb")
		if not f then
			return "", "", chunk_id, buf, gen
		end
		f:seek("set", offset)
		local raw = f:read(len)
		f:close()
		if not raw then
			raw = ""
		end
		local n = #raw

		local hex_lookup = {}
		for i = 0, 255 do
			hex_lookup[i + 1] = string.format("%02X", i)
		end

		-- Chunk offsets are multiples of bytes_per_line, so only the
		-- last chunk of the file can contain a partial (padded) line.
		local lines = {}
		local line_no = 0
		local pos = 1
		while pos <= n do
			local last = math.min(pos + bpl - 1, n)
			local count = last - pos + 1
			local parts = {}

			line_no = line_no + 1
			parts[1] = string.format("%08X: ", offset + pos - 1)

			for i = 0, bpl - 1 do
				if i < count then
					local hx = hex_lookup[string.byte(raw, pos + i) + 1]
					if (i + 1) % 4 == 0 and (i + 1) < bpl then
						parts[#parts + 1] = hx .. " | "
					else
						parts[#parts + 1] = hx .. " "
					end
				else
					if (i + 1) % 4 == 0 and (i + 1) < bpl then
						parts[#parts + 1] = "   | "
					else
						parts[#parts + 1] = "   "
					end
				end
			end

			parts[#parts + 1] = " | "

			for i = 0, bpl - 1 do
				if i < count then
					local c = string.byte(raw, pos + i)
					if c >= 32 and c <= 126 then
						parts[#parts + 1] = string.char(c)
					else
						parts[#parts + 1] = "."
					end
				else
					parts[#parts + 1] = " "
				end
			end

			lines[line_no] = table.concat(parts)
			pos = last + 1
		end

		return raw, table.concat(lines, "\n"), chunk_id, buf, gen
	end, vim.schedule_wrap(function(raw, text, chunk_id, buf, gen)
		-- Runs in the main thread (via vim.schedule: the raw luv
		-- callback is a fast event context that forbids API calls):
		-- store the raw chunk and splice the rendered lines into the
		-- buffer at their fixed rows.
		if not vim.api.nvim_buf_is_valid(buf) then
			M.load_state[buf] = nil
			M.buf_data[buf] = nil
			return
		end
		local state = M.load_state[buf]
		if not state or state.gen ~= gen then
			return
		end

		local d = M.buf_data[buf]
		if not d or d.chunk_size == 0 then
			return
		end

		d.chunks[chunk_id] = raw

		local lines = {}
		if text ~= "" then
			lines = vim.split(text, "\n", { plain = true })
		end
		local chunk_lines = math.floor(d.chunk_size / state.bpl)
		local start_row = (chunk_id - 1) * chunk_lines + 1
		local end_row = start_row + #lines - 1

		local buf_lines = vim.api.nvim_buf_line_count(buf)
		if end_row > buf_lines then
			local empties = {}
			for i = 1, end_row - buf_lines do
				empties[i] = ""
			end
			buf_set_lines(buf, buf_lines, buf_lines, empties)
		end
		if #lines > 0 then
			buf_set_lines(buf, start_row - 1, end_row, lines)
		end

		local expected = math.min(d.chunk_size, state.size - (chunk_id - 1) * d.chunk_size)
		if #raw < expected then
			state.incomplete = true
		end

		state.loaded = state.loaded + #raw
		state.done = state.done + 1
		vim.b[buf].hex_loaded_bytes = state.loaded
		if state.done >= state.nchunks then
			M.finish_load(buf)
		end
	end))
end

-- Load the whole data set of a buffer synchronously (single chunk).
-- Used when there is no readable file behind the buffer, or when
-- uv.new_work is unavailable.
local function set_buffer_data(buf, data, keep_edits)
	local b = vim.b[buf]
	if not keep_edits then
		b.hex_edits = {}
	end
	b.hex_size = #data
	b.hex_loaded_bytes = #data
	b.hex_loading = false
	M.buf_data[buf] = { chunks = { data }, chunk_size = math.max(#data, 1) }
end

-- Kick off an async chunked load of the file behind `buf`. Returns
-- "async" when worker threads were dispatched, or "sync" when the data
-- was loaded into memory synchronously (the caller must then render
-- with M.refresh_view() itself).
function M.start_load(buf, opts)
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(buf)
	local size = 0
	local f = io.open(path, "rb")
	if f then
		size = f:seek("end") or 0
		f:close()
	end

	if not f or not read_work then
		set_buffer_data(buf, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), opts.keep_edits)
		return "sync"
	end

	local prev = M.load_state[buf]
	local gen = (prev and prev.gen or 0) + 1
	local state = {
		gen = gen,
		size = size,
		bpl = M.bytes_per_line,
		loaded = 0,
		done = 0,
		nchunks = 0,
		restore_offset = opts.restore_offset or 0,
		initial = opts.initial or false,
		silent = opts.silent or false,
	}
	M.load_state[buf] = state

	local b = vim.b[buf]
	if not opts.keep_edits then
		b.hex_edits = {}
	end
	b.hex_size = size
	b.hex_loaded_bytes = 0
	b.hex_loading = true
	b.hex_incomplete = false

	-- The buffer is rebuilt from scratch as chunks arrive.
	buf_set_lines(buf, 0, -1, {})

	if size == 0 then
		M.buf_data[buf] = { chunks = {}, chunk_size = 1 }
		local text = M.generate_line_content(1)
		buf_set_lines(buf, 0, -1, { text })
		M.finish_load(buf)
		return "async"
	end

	local chunk_size = math.ceil(M.chunk_bytes / M.bytes_per_line) * M.bytes_per_line
	M.buf_data[buf] = { chunks = {}, chunk_size = chunk_size }
	state.nchunks = math.ceil(size / chunk_size)

	for i = 1, state.nchunks do
		local offset = (i - 1) * chunk_size
		local len = math.min(chunk_size, size - offset)
		read_work:queue(path, offset, len, M.bytes_per_line, i, buf, gen)
	end
	return "async"
end

function M.finish_load(buf)
	local state = M.load_state[buf]
	M.load_state[buf] = nil
	if not state or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local b = vim.b[buf]
	b.hex_loading = false
	b.hex_loaded_bytes = b.hex_size or 0
	if state.incomplete then
		b.hex_incomplete = true
		if not state.silent then
			print("HexView: Warning: file loaded incompletely, saving is disabled.")
		end
	end

	-- Lines whose bytes were edited while chunks were still arriving
	-- need their dirty text/highlights restored.
	local edits = b.hex_edits or {}
	if next(edits) ~= nil then
		local rows = {}
		for k, _ in pairs(edits) do
			local off = tonumber(k)
			if off and off >= 1 and off <= (b.hex_size or 0) then
				rows[#rows + 1] = math.floor((off - 1) / state.bpl) + 1
			end
		end
		if #rows > 0 then
			if buf == vim.api.nvim_get_current_buf() then
				for _, row in ipairs(rows) do
					M.redraw_line(row)
				end
			else
				b.hex_pending_redraw_rows = rows
			end
		end
	end

	local is_current = buf == vim.api.nvim_get_current_buf()
	if state.restore_offset > 0 then
		local row = math.floor((state.restore_offset - 1) / M.bytes_per_line) + 1
		pcall(vim.api.nvim_win_set_cursor, 0, { row, 10 })
	elseif state.initial and is_current then
		local ok_c, cur = pcall(vim.api.nvim_win_get_cursor, 0)
		if ok_c and cur[1] == 1 and cur[2] == 0 then
			pcall(vim.api.nvim_win_set_cursor, 0, { 1, 10 })
		end
	end

	if is_current then
		M.highlight_cursor()
		if not state.silent then
			print(string.format("HexView: Loaded %d bytes.", b.hex_size or 0))
		end
	end
end

-- ============================================================
-- 2. GEN. TEXT
-- ============================================================

function M.generate_line_content(row)
	if not M.buf_data[vim.api.nvim_get_current_buf()] then
		return "", {}, {}
	end

	local base = (row - 1) * M.bytes_per_line

	-- Optimalizace
	local parts = {}

	-- Offset header
	table.insert(parts, string.format("%08X: ", base))

	local dirty_hex_ranges = {}
	local dirty_ascii_indices = {}

	local edits = vim.b.hex_edits or {}
	local current_hex_pos = 10

	-- HEX
	for i = 0, M.bytes_per_line - 1 do
		local idx = base + i + 1
		local b = M.get_byte(idx)

		if b then
			local val = tonumber(b)
			local hex = string.format("%02X", val or 0)

			if edits[tostring(idx)] ~= nil then
				table.insert(dirty_hex_ranges, { current_hex_pos, current_hex_pos + 2 })
				table.insert(dirty_ascii_indices, i)
			end

			if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
				table.insert(parts, hex .. " | ")
				current_hex_pos = current_hex_pos + 5
			else
				table.insert(parts, hex .. " ")
				current_hex_pos = current_hex_pos + 3
			end
		else
			-- Padding
			if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
				table.insert(parts, "   | ")
			else
				table.insert(parts, "   ")
			end
		end
	end

	-- SEPARATOR
	table.insert(parts, " | ")

	-- ASCII
	for i = 0, M.bytes_per_line - 1 do
		local idx = base + i + 1
		local b = M.get_byte(idx)
		if b then
			local val = tonumber(b)
			local c = (val and val >= 32 and val <= 126) and string.char(val) or "."
			table.insert(parts, c)
		else
			table.insert(parts, " ")
		end
	end

	return table.concat(parts), dirty_hex_ranges, dirty_ascii_indices
end

function M.redraw_line(row, buf)
	buf = buf or 0
	local is_current = buf == 0 or buf == vim.api.nvim_get_current_buf()
	local text, dirty_hex, dirty_ascii = M.generate_line_content(row)

	if is_current then
		vim.opt_local.modifiable = true
	end
	vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { text })

	vim.api.nvim_buf_clear_namespace(buf, ns, row - 1, row)

	local len = #text
	for _, range in ipairs(dirty_hex) do
		if range[2] <= len then
			vim.api.nvim_buf_set_extmark(buf, ns, row - 1, range[1], {
				end_col = range[2],
				hl_group = "HexViewChanged",
				priority = 101,
			})
		end
	end

	local hex_end_col = 10 + M.hex_width
	local ascii_start = hex_end_col + 3

	for _, offset_i in ipairs(dirty_ascii) do
		local col = ascii_start + offset_i
		if col < len then
			vim.api.nvim_buf_set_extmark(buf, ns, row - 1, col, {
				end_col = col + 1,
				hl_group = "HexViewChanged",
				priority = 101,
			})
		end
	end

	if is_current then
		vim.opt_local.modifiable = false
	end
end

-- ============================================================
-- 3. CURSOR AND HIGHLIGHTS
-- ============================================================
function M.cursor_byte()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local line = vim.api.nvim_get_current_line()
	local header_end = line:find(": ")
	if not header_end then
		return nil
	end

	local base = tonumber(line:sub(1, header_end - 1), 16)
	if not base then
		return nil
	end

	if col >= M.ascii_start_col then
		local ascii_offset = col - M.ascii_start_col
		if ascii_offset >= 0 and ascii_offset < M.bytes_per_line then
			return base + ascii_offset, 0, true
		end
		return nil
	end

	local char_at_cursor = line:sub(col + 1, col + 1)
	if not char_at_cursor:match("[%x]") then
		return nil
	end

	local start_idx = header_end + 2
	local byte_count = -0.5
	for i = start_idx, col + 1 do
		if line:sub(i, i):match("[%x]") then
			byte_count = byte_count + 0.5
		end
	end

	if byte_count < 0 then
		return nil
	end
	local nibble = (byte_count % 1 ~= 0) and 1 or 0
	return base + math.floor(byte_count), nibble, false
end

function M.highlight_cursor()
	vim.api.nvim_buf_clear_namespace(0, cursor_ns, 0, -1)
	local offset, _, _ = M.cursor_byte()
	if not offset then
		return
	end

	local row = vim.api.nvim_win_get_cursor(0)[1]
	local line_idx = row - 1
	local byte_in_line = offset % M.bytes_per_line

	local hex_col = 10
	for i = 0, byte_in_line - 1 do
		if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
			hex_col = hex_col + 5
		else
			hex_col = hex_col + 3
		end
	end

	local ascii_col = M.ascii_start_col + byte_in_line

	vim.api.nvim_buf_set_extmark(0, cursor_ns, line_idx, hex_col, {
		end_col = hex_col + 2,
		hl_group = "HexViewCursor",
		priority = 200,
	})
	vim.api.nvim_buf_set_extmark(0, cursor_ns, line_idx, ascii_col, {
		end_col = ascii_col + 1,
		hl_group = "HexViewCursor",
		priority = 200,
	})
end

-- ============================================================
-- 4. EDITATION (r, R)
-- ============================================================

local function write_byte(offset, byte_val)
	if not byte_val then
		return false
	end
	local edits = vim.b.hex_edits or {}
	edits[tostring(offset + 1)] = tonumber(byte_val)
	vim.b.hex_edits = edits
	return true
end

local function write_nibble(offset, nibble_idx, char)
	local val = tonumber(char, 16)
	if not val then
		return false
	end

	local raw_val = M.get_byte(offset + 1)
	if not raw_val then
		return false
	end

	local data = tonumber(raw_val)
	if not data then
		return false
	end

	local bit = require("bit")
	local new_data = data

	if nibble_idx == 0 then
		new_data = bit.bor(bit.band(data, 0x0F), bit.lshift(val, 4))
	else
		new_data = bit.bor(bit.band(data, 0xF0), val)
	end

	return write_byte(offset, new_data)
end

function M.replace_one()
	local offset, nibble, is_ascii = M.cursor_byte()
	if not offset then
		return
	end

	local char_code = vim.fn.getchar()
	if char_code == 27 then
		return
	end

	local char = (type(char_code) == "number") and vim.fn.nr2char(char_code) or char_code
	local changed = false

	if is_ascii then
		local byte_val = string.byte(char)
		changed = write_byte(offset, byte_val)
	else
		if char:match("[%x]") then
			changed = write_nibble(offset, nibble, char)
		end
	end

	if changed then
		M.redraw_line(vim.api.nvim_win_get_cursor(0)[1])
		vim.opt_local.modified = true
	end
end

function M.replace_continuous()
	vim.b.hex_replace_active = true
	vim.cmd("redrawstatus")

	while true do
		M.highlight_cursor()
		vim.cmd("redraw")

		local ok, char_code = pcall(vim.fn.getchar)
		if not ok or char_code == 27 then
			break
		end

		local char = (type(char_code) == "number") and vim.fn.nr2char(char_code) or char_code
		local offset, nibble, is_ascii = M.cursor_byte()

		if not offset then
			break
		end
		local changed = false

		if is_ascii then
			local byte_val = string.byte(char)
			if byte_val and byte_val >= 32 and byte_val <= 255 then
				changed = write_byte(offset, byte_val)
			end
		else
			if char:match("[%x]") then
				changed = write_nibble(offset, nibble, char)
			end
		end

		if changed then
			M.redraw_line(vim.api.nvim_win_get_cursor(0)[1])
			vim.opt_local.modified = true
			M.smart_move("l")
		end
	end

	vim.b.hex_replace_active = false
	vim.cmd("redrawstatus")
	print(" ")
end

-- ============================================================
-- 5. MOVEMENT
-- ============================================================
function M.smart_move(key)
	local cmd = (key == "l" or key == "<Right>") and "l" or "h"
	local is_left = (cmd == "h")
	local cur_row = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_get_current_line()
	local hex_start = 10
	local hex_end = 10 + M.hex_width - 1
	local ascii_start = M.ascii_start_col

	vim.cmd("normal! " .. cmd)
	local cur_col = vim.api.nvim_win_get_cursor(0)[2]

	if not is_left and cur_col > hex_end and cur_col < ascii_start then
		vim.api.nvim_win_set_cursor(0, { cur_row, ascii_start })
		return
	end

	if is_left and cur_col < ascii_start and cur_col > hex_end then
		local target = hex_end
		while target > hex_start do
			if line:sub(target + 1, target + 1):match("[%x]") then
				break
			end
			target = target - 1
		end
		vim.api.nvim_win_set_cursor(0, { cur_row, target })
		return
	end

	if cur_col >= hex_start and cur_col <= hex_end then
		local safeguard = 0
		while line:sub(cur_col + 1, cur_col + 1):match("[ |]") and safeguard < 5 do
			vim.cmd("normal! " .. cmd)
			cur_col = vim.api.nvim_win_get_cursor(0)[2]
			safeguard = safeguard + 1
		end
	end

	if cur_col < hex_start then
		vim.api.nvim_win_set_cursor(0, { cur_row, hex_start })
	end
end

-- ============================================================
-- 5.5 FIND
-- ============================================================

function M.goto_byte_offset(offset)
	if offset > (vim.b.hex_size or 0) then
		return
	end

	local row = math.ceil(offset / M.bytes_per_line)

	local byte_in_line = (offset - 1) % M.bytes_per_line -- 0-based index v řádku
	local col = 10

	for i = 0, byte_in_line - 1 do
		col = col + 2
		if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
			col = col + 3 -- " | " separator
		else
			col = col + 1 -- " " space
		end
	end

	vim.api.nvim_win_set_cursor(0, { row, col })
	vim.cmd("normal! zz")
	M.highlight_cursor()
end

-- Raw bytes in [a, b] (1-based, inclusive) from the loaded chunks.
-- Stops at the first chunk that has not arrived yet.
local function raw_range(a, b)
	if b < a then
		return ""
	end
	local d = M.buf_data[vim.api.nvim_get_current_buf()]
	if not d or d.chunk_size <= 0 then
		return ""
	end
	local chunks = d.chunks
	local cs = d.chunk_size
	local out = {}
	local i = a
	while i <= b do
		local ci = math.floor((i - 1) / cs) + 1
		local s = chunks[ci]
		if not s or i > (ci - 1) * cs + #s then
			break
		end
		local take = math.min(b, (ci - 1) * cs + #s)
		out[#out + 1] = string.sub(s, i - (ci - 1) * cs, take - (ci - 1) * cs)
		i = take + 1
	end
	return table.concat(out)
end

-- Bytes in [a, b] with the edit overlay applied. Truncated to the
-- contiguously loaded prefix of the range so partially loaded files
-- never produce corrupted data.
local function binary_range(a, b)
	if b < a then
		return ""
	end
	local d = M.buf_data[vim.api.nvim_get_current_buf()]
	if not d or d.chunk_size <= 0 then
		return ""
	end
	local chunks = d.chunks
	local cs = d.chunk_size

	local ci = math.floor((a - 1) / cs) + 1
	while true do
		local s = chunks[ci]
		if not s then
			-- chunk ci covers [(ci-1)*cs+1, ci*cs]; it is missing, so
			-- truncate to the last byte of the previous chunk
			b = (ci - 1) * cs
			break
		end
		local chunk_end = (ci - 1) * cs + #s
		if chunk_end >= b or #s < cs then
			break
		end
		ci = ci + 1
	end
	if b < a then
		return ""
	end

	local marks = {}
	local edits = vim.b.hex_edits or {}
	for k, v in pairs(edits) do
		local off = tonumber(k)
		if off and off >= a and off <= b then
			marks[#marks + 1] = { off, v }
		end
	end
	if #marks == 0 then
		return raw_range(a, b)
	end

	table.sort(marks, function(x, y)
		return x[1] < y[1]
	end)

	local out = {}
	local pos = a
	for _, m in ipairs(marks) do
		if m[1] > pos then
			out[#out + 1] = raw_range(pos, m[1] - 1)
		end
		out[#out + 1] = string.char(m[2])
		pos = m[1] + 1
	end
	if pos <= b then
		out[#out + 1] = raw_range(pos, b)
	end
	return table.concat(out)
end

function M.get_current_binary_string()
	return binary_range(1, vim.b.hex_size or 0)
end

function M.load_progress_pct()
	local size = vim.b.hex_size or 0
	if size <= 0 then
		return 100
	end
	local loaded = vim.b.hex_loaded_bytes or 0
	return math.floor(loaded / size * 100)
end

function M.find_hex_dialog()
	vim.ui.input({ prompt = "Find HEX (e.g. AA BB 01): " }, function(input)
		if not input or input == "" then
			return
		end

		local clean_hex = input:gsub("[%s|]", "")

		if #clean_hex % 2 ~= 0 then
			print("HexView Error: Enter whole bytes")
			return
		end

		local search_bytes = ""
		for i = 1, #clean_hex, 2 do
			local byte_str = clean_hex:sub(i, i + 1)
			local byte_val = tonumber(byte_str, 16)
			if not byte_val then
				print("HexView Error: Invalid HEX characters.")
				return
			end
			search_bytes = search_bytes .. string.char(byte_val)
		end

		vim.b.last_search_bytes = search_bytes

		M.find_next()
	end)
end

function M.find_next()
	local pattern = vim.b.last_search_bytes
	if not pattern then
		print("HexView: No previous search pattern.")
		return
	end

	local current_offset, _, _ = M.cursor_byte()
	current_offset = current_offset or 1

	local data = M.get_current_binary_string()

	-- string.find(string, pattern, init_pos, plain_search)
	local start_pos, end_pos = string.find(data, pattern, current_offset + 1, true)

	if not start_pos then
		-- Wrap around
		print("HexView: The search has come to an end. Resuming from the beginning...")
		start_pos, end_pos = string.find(data, pattern, 1, true)
	end

	if start_pos then
		M.goto_byte_offset(start_pos)
		local len = end_pos - start_pos + 1
		print(string.format("Found on offset 0x%X (length %d)", start_pos, len))
	elseif vim.b.hex_loading then
		print(string.format("HexView: None found so far (%d%% of file loaded).", M.load_progress_pct()))
	else
		print("HexView: None found.")
	end
end

-- ============================================================
-- 6. UI & STATUSLINE
-- ============================================================
function M.setup_keymaps()
	local moves = { "h", "l", "<Left>", "<Right>" }
	for _, k in ipairs(moves) do
		vim.keymap.set("n", k, function()
			M.smart_move(k)
		end, { buffer = true, silent = true })
	end
	vim.keymap.set("n", "r", function()
		M.replace_one()
	end, { buffer = true, silent = true })
	vim.keymap.set("n", "R", function()
		M.replace_continuous()
	end, { buffer = true, silent = true })

	vim.keymap.set("n", "/", function()
		M.find_hex_dialog()
	end, { buffer = true, silent = false, desc = "Find HEX" })
	vim.keymap.set("n", "n", function()
		M.find_next()
	end, { buffer = true, silent = false, desc = "Find Next HEX" })

	vim.api.nvim_buf_create_user_command(0, "HexSet", function(opts)
		local val = tonumber(opts.args)
		if val and val > 0 then
			require("hexview").set_columns(val)
		else
			print("HexView: Enter a valid number of columns (e.g. :HexSet 16)")
		end
	end, { nargs = 1 })
end

function M.cursor_offset_label()
	local offset, nibble, is_ascii = M.cursor_byte()
	if not offset then
		return ""
	end
	local loc = is_ascii and "[ASCII]" or "[HEX]"
	return string.format("%s 0x%08X", loc, offset)
end

function M.get_statusline_content()
	local mode_info = ""
	if vim.b.hex_replace_active then
		mode_info = "%#HexViewModeEdit# -- REPLACE -- %*"
	elseif vim.b.hex_loading then
		mode_info = "%#HexViewModeEdit# -- LOADING " .. M.load_progress_pct() .. "% -- %*"
	end
	return string.format("  %%f %%m %%= %s Col: %d  %%l,%%c  %%P ", mode_info, M.bytes_per_line)
end

function M.setup_ui()
	vim.api.nvim_set_hl(0, "HexViewOffset", { fg = "#FF9E64", bold = true })
	vim.api.nvim_set_hl(0, "HexViewHeader", { fg = "#FF9E64", bold = true })
	vim.api.nvim_set_hl(0, "HexViewChanged", { fg = "#FF007C", bold = true })
	vim.api.nvim_set_hl(0, "HexViewCursor", { bg = "#330000", fg = "#FFFF00", bold = true })
	vim.api.nvim_set_hl(0, "HexViewModeEdit", { fg = "#00FF00", bg = "#003300", bold = true })

	-- !!! ZRYCHLENÍ: Použití Regex Syntax místo Extmarks pro offsety !!!
	vim.cmd([[syntax match HexViewOffset /^[0-9A-F]\{8\}:/]])

	local O, N = "%#HexViewHeader#", "%*"
	local hex_header_parts = {}
	for i = 0, M.bytes_per_line - 1 do
		local hex = string.format("%02X", i)
		if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
			table.insert(hex_header_parts, hex .. " | ")
		else
			table.insert(hex_header_parts, hex .. " ")
		end
	end
	local hex_header_str = table.concat(hex_header_parts)
	local ascii_header = " | " .. O .. "ASCII" .. N
	local header = " Offset   " .. O .. hex_header_str .. N .. ascii_header

	vim.opt_local.winbar = header .. "%=" .. "%#HexViewHeader# %{v:lua.require'hexview'.cursor_offset_label()} "
	vim.opt_local.statusline = "%!v:lua.require'hexview'.get_statusline_content()"
end

-- ============================================================
-- 7. ENABLE / DISABLE / REFRESH (OPTIMIZED)
-- ============================================================

local function apply_columns(cols)
	if vim.b.hex_loading then
		return
	end
	local current_offset = M.cursor_byte() or 0
	M.bytes_per_line = cols
	M.setup_layout()
	M.setup_ui()
	local buf = vim.api.nvim_get_current_buf()
	local mode = M.start_load(buf, { keep_edits = true, restore_offset = current_offset, silent = true })
	if mode == "sync" then
		M.refresh_view()
		if current_offset > 0 then
			local new_row = math.floor((current_offset - 1) / M.bytes_per_line) + 1
			pcall(vim.api.nvim_win_set_cursor, 0, { new_row, 10 })
		end
	end
end

function M.set_columns(cols)
	if cols < 1 then
		return
	end
	if vim.b.hex_loading then
		print("HexView: Please wait, the file is still loading.")
		return
	end
	M.auto_columns = false
	apply_columns(cols)
	print("HexView: Set on " .. cols .. " columns.")
end

-- Column changes re-render the whole file, so resize-triggered calls
-- are debounced on a timer to avoid a stampede of reloads.
local adapt_timer = nil

function M.adapt_columns()
	if not M.auto_columns or vim.b.hex_loading then
		return
	end
	if not adapt_timer then
		adapt_timer = uv.new_timer()
	end
	adapt_timer:stop()
	adapt_timer:start(250, 0, vim.schedule_wrap(function()
		if vim.bo.filetype ~= "hexview" or vim.b.hex_loading then
			return
		end
		local ok, width = pcall(vim.api.nvim_win_get_width, 0)
		if not ok or width <= 0 then
			return
		end
		local cols = M.max_columns_for(width)
		if cols ~= M.bytes_per_line then
			apply_columns(cols)
		end
	end))
end

function M.refresh_view()
	M.setup_layout()
	M.setup_ui()

	vim.opt_local.modifiable = true
	local size = vim.b.hex_size or 0
	local total_lines = math.ceil(size / M.bytes_per_line)
	if total_lines == 0 then
		total_lines = 1
	end

	local all_lines = {}
	for row = 1, total_lines do
		local text = M.generate_line_content(row)
		table.insert(all_lines, text)
	end

	vim.api.nvim_buf_set_lines(0, 0, -1, false, all_lines)

	local edits = vim.b.hex_edits
	if edits and next(edits) then
	end

	vim.opt_local.modifiable = false
end

function M.enable()
	local buf = vim.api.nvim_get_current_buf()
	M.disabled_buffers[buf] = nil

	vim.b.hex_edits = {}
	vim.b.hex_replace_active = false
	vim.b.hex_loading = false

	vim.opt_local.modifiable = true
	vim.opt_local.readonly = false
	vim.opt_local.number = false
	vim.opt_local.relativenumber = false
	vim.opt_local.wrap = false
	vim.bo.filetype = "hexview"

	if M.auto_columns then
		local ok, width = pcall(vim.api.nvim_win_get_width, 0)
		if ok and width > 0 then
			M.bytes_per_line = M.max_columns_for(width)
		end
	end
	M.setup_layout()
	M.setup_ui()

	-- Start the multithreaded load; the buffer fills in as chunk
	-- workers report back and stays browsable meanwhile.
	local mode = M.start_load(buf, { initial = true })
	if mode == "sync" then
		M.refresh_view()
	else
		vim.opt_local.modifiable = false
	end

	pcall(vim.api.nvim_win_set_cursor, 0, { 1, 10 })
	vim.b.did_ftplugin = 1
	M.setup_keymaps()

	local au_group = vim.api.nvim_create_augroup("HexViewCursor", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = au_group,
		buffer = 0,
		callback = M.highlight_cursor,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = au_group,
		buffer = 0,
		callback = function()
			M.adapt_columns()
		end,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = au_group,
		callback = function()
			if vim.bo.filetype == "hexview" then
				M.adapt_columns()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufEnter", {
		group = au_group,
		buffer = 0,
		callback = function()
			local pending = vim.b.hex_pending_redraw_rows
			if pending then
				vim.b.hex_pending_redraw_rows = nil
				for _, row in ipairs(pending) do
					M.redraw_line(row)
				end
			end
			M.highlight_cursor()
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = au_group,
		buffer = 0,
		callback = function(ev)
			M.load_state[ev.buf] = nil
			M.buf_data[ev.buf] = nil
		end,
	})
	M.highlight_cursor()

	vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = 0, callback = M.save })
end

function M.disable()
	local buf = vim.api.nvim_get_current_buf()
	if vim.b.hex_loading then
		-- Cancel the in-flight load; saving now would write a
		-- truncated file.
		M.load_state[buf] = nil
		vim.b.hex_loading = false
	else
		M.save()
	end
	M.buf_data[buf] = nil
	M.disabled_buffers[buf] = true

	vim.api.nvim_clear_autocmds({ group = "HexViewCursor" })
	vim.api.nvim_buf_clear_namespace(0, cursor_ns, 0, -1)
	vim.api.nvim_clear_autocmds({ event = "BufWriteCmd", buffer = 0 })
	pcall(vim.api.nvim_buf_del_user_command, 0, "HexSet")
	vim.opt_local.winbar = nil
	vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
	vim.cmd("edit!")
	vim.opt_local.binary = true
	vim.opt_local.fixeol = false
	vim.opt_local.eol = false
	vim.opt_local.readonly = true
	vim.opt_local.modifiable = false
	vim.opt_local.statusline = ""
	vim.opt_local.syntax = "off"
	vim.bo.filetype = ""
	vim.b.hex_edits = nil
	vim.b.hex_size = nil
	vim.b.hex_loaded_bytes = nil
	vim.b.hex_pending_redraw_rows = nil
	vim.b.hex_incomplete = nil
	vim.b.hex_replace_active = nil
	print("HexView: RAW mode.")
end

function M.save()
	local name = vim.api.nvim_buf_get_name(0)
	if name == "" then
		print("Error: Buffer has no name.")
		return
	end
	if vim.b.hex_loading then
		print("HexView: Save aborted, file is still loading.")
		return
	end
	if vim.b.hex_incomplete then
		print("HexView: Save aborted, the loaded data is incomplete.")
		return
	end

	local f = assert(io.open(name, "wb"))

	-- Write in large windows so huge files never need a full-size
	-- copy in memory.
	local size = vim.b.hex_size or 0
	local window = 4 * 1024 * 1024
	local pos = 1
	while pos <= size do
		local endp = math.min(pos + window - 1, size)
		f:write(binary_range(pos, endp))
		pos = endp + 1
	end
	f:close()

	-- The file on disk now matches the rendered buffer, so the edit
	-- overlay and its highlights can simply be dropped.
	vim.b.hex_edits = {}
	vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
	vim.opt_local.modified = false
	print("Writed")
end

-- ============================================================
-- 8. SETUP
-- ============================================================
function M.setup(config)
	config = config or {}
	if config.auto_columns ~= nil then
		M.auto_columns = config.auto_columns
	end
	if config.bytes_per_line then
		M.bytes_per_line = config.bytes_per_line
		M.auto_columns = false
	end
	if config.chunk_bytes then
		M.chunk_bytes = config.chunk_bytes
	end
	M.setup_layout()
	local group = vim.api.nvim_create_augroup("HexViewAutoDetect", { clear = true })
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		pattern = "*",
		callback = function(ev)
			if require("hexview").disabled_buffers[ev.buf] then
				return
			end
			local file = ev.file
			if not file or file == "" then
				return
			end
			if vim.bo[ev.buf].binary then
				vim.schedule(function()
					if vim.bo[ev.buf].filetype ~= "hexview" then
						require("hexview").enable()
					end
				end)
				return
			end
			local f = io.open(file, "rb")
			if not f then
				return
			end
			local chunk = f:read(1024)
			f:close()
			if chunk and chunk:find("%z") then
				vim.schedule(function()
					if vim.bo[ev.buf].filetype ~= "hexview" then
						require("hexview").enable()
					end
				end)
			end
		end,
	})
end

return M
