-- CCIDE: A PixelUI-powered single-file editor for CC:Tweaked
---@diagnostic disable: undefined-field

local pixelui = require("pixelui")

local colors = assert(_G.colors, "colors API unavailable")
local fs = assert(_G.fs, "fs API unavailable")
local shell = _G.shell
local printError = _G.printError or function(message)
	print("[error] " .. tostring(message))
end

local args = { ... }

local function ensure_leading_slash(path)
	if not path or path == "" or path == "." then
		return "/"
	end
	path = path:gsub("\\", "/")
	if path:sub(1, 1) ~= "/" then
		path = "/" .. path
	end
	path = path:gsub("/+", "/")
	if #path > 1 and path:sub(-1) == "/" then
		path = path:sub(1, -2)
	end
	return path
end

local function normalize_path(path)
	if not path or path == "" then
		return nil
	end
	if shell and shell.resolve then
		local ok, resolved = pcall(shell.resolve, path)
		if ok and resolved and resolved ~= "" then
			return ensure_leading_slash(resolved)
		end
	end
	return ensure_leading_slash(path)
end

local function clamp(value, minimum, maximum)
	if minimum ~= nil and value < minimum then
		value = minimum
	end
	if maximum ~= nil and value > maximum then
		value = maximum
	end
	return value
end

local function parent_dir(path)
	path = normalize_path(path)
	if not path or path == "/" then
		return "/"
	end
	local dir = fs.getDir(path)
	if not dir or dir == "" or dir == "." then
		return "/"
	end
	return ensure_leading_slash(dir)
end

local function working_directory()
	if shell and shell.dir then
		local dir = shell.dir()
		if not dir or dir == "" or dir == "." then
			return "/"
		end
		if dir == "/" then
			return "/"
		end
		return ensure_leading_slash(dir)
	end
	return "/"
end

local function trim(text)
	text = text or ""
	local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
	return trimmed
end

local function split_lines(text)
	if not text or text == "" then
		return { "" }
	end
	local result = {}
	local start_index = 1
	local length = #text
	while start_index <= length do
		local newline = text:find("\n", start_index, true)
		if not newline then
			result[#result + 1] = text:sub(start_index)
			break
		end
		result[#result + 1] = text:sub(start_index, newline - 1)
		start_index = newline + 1
		if start_index > length then
			result[#result + 1] = ""
			break
		end
	end
	if #result == 0 then
		result[1] = ""
	end
	return result
end

local function wrap_text(text, width)
	if not width or width <= 0 then
		return { "" }
	end
	local result = {}
	local raw_lines = split_lines(text or "")
	for index = 1, #raw_lines do
		local line = raw_lines[index]
		local remaining = line
		local added = false
		while #remaining > width do
			local segment = remaining:sub(1, width)
			local break_pos = segment:match(".*()%s")
			if break_pos and break_pos > 1 then
				result[#result + 1] = segment:sub(1, break_pos - 1)
				remaining = trim(remaining:sub(break_pos + 1))
			else
				result[#result + 1] = segment
				remaining = remaining:sub(width + 1)
			end
			added = true
		end
		if #remaining > 0 then
			result[#result + 1] = remaining
			added = true
		end
		if not added then
			result[#result + 1] = ""
		end
	end
	if #result == 0 then
		result[1] = ""
	end
	return result
end

local function truncate(text, width)
	if width <= 0 then
		return ""
	end
	if #text > width then
		if width <= 3 then
			return text:sub(1, width)
		end
		return text:sub(1, width - 3) .. "..."
	end
	if #text < width then
		return text .. string.rep(" ", width - #text)
	end
	return text
end

local LUA_SUGGESTIONS = {
	"and", "break", "do", "else", "elseif", "end", "false", "for", "function",
	"if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
	"true", "until", "while", "pcall", "xpcall", "select", "type", "pairs",
	"ipairs", "next", "tostring", "tonumber", "math", "string", "table", "os",
	"coroutine", "require", "term", "peripheral", "redstone", "vector", "colors",
	"keys", "fs", "shell"
}

local state = {
	path = nil,
	pendingPath = nil,
	displayName = "Untitled-1",
	savedText = "",
	dirty = false,
	isUntitled = true,
	message = nil,
	cursorLine = 1,
	cursorCol = 1,
	selectionLength = 0,
	showStatusBar = true,
	autocompleteEnabled = true,
	syntaxHighlight = true,
	tabSize = 4,
	recentFiles = {},
	nextUntitled = 2,
	helpBox = nil,
	helpPagination = nil,
	diagnostics = {},
	diagnosticsExpanded = false,
	showEditorBorder = true,
	showHomeScreen = true,
	maxRecentFiles = 12,
	buffers = {},
	activeBufferIndex = 0,
	activeBuffer = nil,
	nextBufferId = 1,
	splitActive = false,
	splitDirection = "horizontal",
	activePaneIndex = 1
}

local app = pixelui.create({ background = colors.black })
local root = app:getRoot()
root:setBorder({ color = colors.gray })

local TAB_CONTROL_HEIGHT = 1
local TAB_CONTROL_Y = 2

local function getEditorTopY()
	return TAB_CONTROL_Y + TAB_CONTROL_HEIGHT
end

local tabControl

-- Forward declarations
local updateMainVisibility
local updateDiagnosticsView
local hasUnsavedChanges
local confirmUnsaved

-- Forward declarations
local updateMainVisibility

local rootWidth, rootHeight = root.width, root.height
local statusBarY = rootHeight
local editorHeight = math.max(1, rootHeight - getEditorTopY() - 1)

local menuBar = app:createFrame({
	x = 1,
	y = 1,
	width = rootWidth,
	height = 1,
	bg = colors.blue,
	fg = colors.white
})
root:addChild(menuBar)

tabControl = app:createTabControl({
	x = 1,
	y = TAB_CONTROL_Y,
	width = rootWidth,
	height = TAB_CONTROL_HEIGHT,
	tabHeight = TAB_CONTROL_HEIGHT,
	tabPadding = 2,
	tabSpacing = 1,
	tabIndicator = { char = ">", spacing = 1 },
	tabCloseButton = { enabled = true, char = "x", spacing = 1, fg = colors.white, bg = colors.red },
	bodyBg = colors.black,
	bodyFg = colors.white,
	focusable = true
})
tabControl.visible = false
root:addChild(tabControl)

local statusLabel = app:createLabel({
	x = 1,
	y = statusBarY,
	width = math.max(1, rootWidth - 1),
	height = 1,
	text = "",
	align = "left",
	bg = colors.gray,
	fg = colors.white
})

local diagnosticsToggleButton = app:createButton({
	x = statusLabel.x + statusLabel.width,
	y = statusBarY,
	width = 1,
	height = 1,
	label = "\30",
	bg = colors.gray,
	fg = colors.white,
	border = { color = colors.gray },
	clickEffect = false
})
diagnosticsToggleButton.focusable = false

local editor = app:createTextBox({
	x = 1,
	y = getEditorTopY(),
	width = rootWidth,
	height = editorHeight,
	bg = colors.black,
	fg = colors.white,
	scrollbar = { enabled = true, trackColor = colors.black, thumbColor = colors.gray },
	tabWidth = state.tabSize,
	syntax = "lua",
	autocomplete = LUA_SUGGESTIONS,
	autocompleteAuto = state.autocompleteEnabled,
	autocompleteMaxItems = 8,
	autocompleteBorder = { color = colors.gray }
})

root:addChild(editor)

local splitEditor = app:createTextBox({
	x = 1,
	y = getEditorTopY(),
	width = rootWidth,
	height = editorHeight,
	bg = colors.black,
	fg = colors.white,
	scrollbar = { enabled = true, trackColor = colors.black, thumbColor = colors.gray },
	tabWidth = state.tabSize,
	syntax = "lua",
	autocomplete = LUA_SUGGESTIONS,
	autocompleteAuto = state.autocompleteEnabled,
	autocompleteMaxItems = 8,
	autocompleteBorder = { color = colors.gray }
})
splitEditor.visible = false
root:addChild(splitEditor)

local splitDivider = app:createFrame({
	x = 1,
	y = getEditorTopY(),
	width = rootWidth,
	height = 1,
	bg = colors.gray,
	fg = colors.gray
})
splitDivider.visible = false
root:addChild(splitDivider)

local function getActiveEditor()
	if state.splitActive and splitEditor and app:getFocus() == splitEditor then
		return splitEditor, 2
	end
	return editor, 1
end

local function focusActiveEditor()
	if state.splitActive and state.activePaneIndex == 2 and splitEditor then
		app:setFocus(splitEditor)
	else
		app:setFocus(editor)
	end
end

root:addChild(statusLabel)
root:addChild(diagnosticsToggleButton)

local maxDiagHeight = math.max(0, rootHeight - getEditorTopY() - 1)
local diagnosticsPanelHeight = math.min(5, maxDiagHeight)
local diagnosticsPanel
local diagnosticsList
if diagnosticsPanelHeight > 0 then
	diagnosticsPanel = app:createFrame({
		x = 1,
		y = statusBarY - diagnosticsPanelHeight,
		width = rootWidth,
		height = diagnosticsPanelHeight,
		bg = colors.black,
		fg = colors.white
	})
	diagnosticsPanel.visible = false
	root:addChild(diagnosticsPanel)
	diagnosticsList = app:createList({
		x = 1,
		y = 1,
		width = rootWidth,
		height = diagnosticsPanelHeight,
		bg = colors.black,
		fg = colors.white,
		highlightBg = colors.lightBlue,
		highlightFg = colors.black,
		placeholder = "(no diagnostics)",
		scrollbar = { enabled = true, trackColor = colors.black, thumbColor = colors.gray }
	})
	diagnosticsList.focusable = true
	diagnosticsPanel:addChild(diagnosticsList)
end

local updateStatus
-- Diagnostics panel helpers manage layout, button state, and live syntax checks.
local diagnosticsUpdateThread

local function updateDiagnosticsToggle()
	if not diagnosticsToggleButton then
		return
	end
	local available = diagnosticsPanelHeight > 0 and diagnosticsPanel ~= nil
	diagnosticsToggleButton.visible = available and state.showStatusBar
	local glyph = state.diagnosticsExpanded and "\31" or "\30"
	diagnosticsToggleButton:setLabel(glyph)
	if state.diagnostics and #state.diagnostics > 0 then
		diagnosticsToggleButton.fg = colors.red
	else
		diagnosticsToggleButton.fg = colors.white
	end
	if diagnosticsToggleButton.invalidate then
		diagnosticsToggleButton:invalidate()
	end
end

local function updateDiagnosticsView()
	local diagnostics = state.diagnostics or {}
	if diagnosticsList then
		local items = {}
		for i = 1, #diagnostics do
			local entry = diagnostics[i]
			local severity = entry and entry.severity or "error"
			local prefix = severity == "warning" and "W" or "E"
			local line = entry and entry.line and tostring(entry.line) or "?"
			local message = entry and entry.message or ""
			items[#items + 1] = string.format("%s %s: %s", prefix, line, message)
		end
		diagnosticsList:setItems(items)
		if #items == 0 then
			diagnosticsList:setSelectedIndex(0)
		end
	end
	updateDiagnosticsToggle()
end

local function layoutEditorAndDiagnostics()
	if not editor then
		return
	end
	local diagHeight = 0
	if state.diagnosticsExpanded and diagnosticsPanel and diagnosticsPanelHeight > 0 then
		diagHeight = math.min(diagnosticsPanelHeight, math.max(0, rootHeight - getEditorTopY() - 1))
	else
		state.diagnosticsExpanded = false
	end
	local editorTop = getEditorTopY()
	local totalEditorHeight = math.max(1, statusBarY - diagHeight - editorTop)

	if state.splitActive and splitEditor then
		if state.splitDirection == "horizontal" then
			-- Top/bottom split
			local dividerHeight = 1
			local availableHeight = totalEditorHeight - dividerHeight
			local primaryHeight = math.max(1, math.floor(availableHeight / 2))
			local splitHeight = math.max(1, availableHeight - primaryHeight)

			editor:setPosition(1, editorTop)
			editor:setSize(rootWidth, primaryHeight)

			splitDivider:setPosition(1, editorTop + primaryHeight)
			splitDivider:setSize(rootWidth, dividerHeight)
			splitDivider.visible = true

			splitEditor:setPosition(1, editorTop + primaryHeight + dividerHeight)
			splitEditor:setSize(rootWidth, splitHeight)
			splitEditor.visible = true
		else
			-- Left/right split
			local dividerWidth = 1
			local availableWidth = rootWidth - dividerWidth
			local primaryWidth = math.max(1, math.floor(availableWidth / 2))
			local splitWidth = math.max(1, availableWidth - primaryWidth)

			editor:setPosition(1, editorTop)
			editor:setSize(primaryWidth, totalEditorHeight)

			splitDivider:setPosition(1 + primaryWidth, editorTop)
			splitDivider:setSize(dividerWidth, totalEditorHeight)
			splitDivider.visible = true

			splitEditor:setPosition(1 + primaryWidth + dividerWidth, editorTop)
			splitEditor:setSize(splitWidth, totalEditorHeight)
			splitEditor.visible = true
		end
	else
		editor:setPosition(1, editorTop)
		editor:setSize(rootWidth, totalEditorHeight)
		if splitEditor then splitEditor.visible = false end
		if splitDivider then splitDivider.visible = false end
	end

	if diagnosticsPanel then
		if diagHeight > 0 then
			diagnosticsPanel.visible = true
			diagnosticsPanel:setPosition(1, statusBarY - diagHeight)
			diagnosticsPanel:setSize(rootWidth, diagHeight)
			if diagnosticsList then
				diagnosticsList:setSize(rootWidth, diagHeight)
				diagnosticsList:setPosition(1, 1)
			end
		else
			diagnosticsPanel.visible = false
		end
	end
	updateDiagnosticsToggle()
end

local function applyEditorBorder()
	if not editor or not editor.setBorder then
		return
	end
	if state.showEditorBorder then
		editor:setBorder({ color = colors.gray })
		if splitEditor and splitEditor.setBorder then
			splitEditor:setBorder({ color = colors.gray })
		end
	else
		editor:setBorder(false)
		if splitEditor and splitEditor.setBorder then
			splitEditor:setBorder(false)
		end
	end
end

local function formatFileDate(path)
	if not fs.exists(path) then
		return "(missing)"
	end
	local attrs = fs.attributes and fs.attributes(path)
	if attrs and attrs.modified then
		local date = os.date("%m/%d %H:%M", attrs.modified)
		return date or "(unknown)"
	end
	return "(no date)"
end

local function getFileSize(path)
	if not fs.exists(path) then
		return 0
	end
	local size = fs.getSize and fs.getSize(path)
	return size or 0
end

local function hideHomeScreen()
	state.showHomeScreen = false
	if updateMainVisibility then updateMainVisibility() end
end

local function showHomeScreen()
	state.showHomeScreen = true
	if updateMainVisibility then updateMainVisibility() end
end

local function createBuffer(params)
	params = params or {}
	local id = state.nextBufferId or 1
	state.nextBufferId = id + 1
	return {
		id = id,
		path = params.path,
		pendingPath = params.pendingPath,
		displayName = params.displayName or string.format("Untitled-%d", id),
		savedText = params.savedText or "",
		text = params.text or params.savedText or "",
		dirty = params.dirty or false,
		isUntitled = params.isUntitled ~= false,
		cursorLine = params.cursorLine or 1,
		cursorCol = params.cursorCol or 1,
		selectionLength = params.selectionLength or 0,
		diagnostics = params.diagnostics or {},
		diagnosticsExpanded = params.diagnosticsExpanded or false,
		splitCursorLine = params.splitCursorLine or 1,
		splitCursorCol = params.splitCursorCol or 1,
		splitSelectionLength = params.splitSelectionLength or 0
	}
end

local function findBufferByPath(path)
	if not path then
		return nil, nil
	end
	for index, buffer in ipairs(state.buffers) do
		if buffer.path == path then
			return index, buffer
		end
	end
	return nil, nil
end

local function formatTabLabel(buffer)
	if not buffer then
		return "Untitled"
	end
	local label = buffer.displayName or "Untitled"
	if buffer.dirty then
		label = "* " .. label
	end
	return label
end

local function refreshTabLabel(index)
	if not tabControl then
		return
	end
	local buffer = state.buffers[index]
	if not buffer then
		return
	end
	tabControl:setTabLabel(index, formatTabLabel(buffer))
end

local function refreshAllTabLabels()
	if not tabControl then
		return
	end
	for index = 1, #state.buffers do
		refreshTabLabel(index)
	end
end

local function line_col_to_index(lines, line, col)
	lines = lines or { "" }
	line = math.max(1, math.min(line or 1, #lines))
	col = math.max(1, col or 1)
	local index = 1
	for i = 1, line - 1 do
		index = index + #lines[i] + 1
	end
	return index + math.min(col - 1, #lines[line])
end

local function syncStateToBuffer(buffer)
	if not buffer then
		return
	end
	buffer.path = state.path
	buffer.pendingPath = state.pendingPath
	buffer.displayName = state.displayName
	buffer.savedText = state.savedText
	buffer.dirty = state.dirty
	buffer.isUntitled = state.isUntitled
	buffer.cursorLine = state.cursorLine or buffer.cursorLine
	buffer.cursorCol = state.cursorCol or buffer.cursorCol
	buffer.selectionLength = state.selectionLength or buffer.selectionLength
	buffer.diagnostics = state.diagnostics or buffer.diagnostics
	buffer.diagnosticsExpanded = state.diagnosticsExpanded or buffer.diagnosticsExpanded
	if editor then
		buffer.text = editor:getText()
	end
	if splitEditor and state.splitActive then
		local sLine, sCol = splitEditor:getCursorPosition()
		buffer.splitCursorLine = sLine or 1
		buffer.splitCursorCol = sCol or 1
	end
end

local function syncBufferToState(buffer)
	if not buffer then
		state.path = nil
		state.pendingPath = nil
		state.displayName = nil
		state.savedText = ""
		state.dirty = false
		state.isUntitled = true
		state.cursorLine = 1
		state.cursorCol = 1
		state.selectionLength = 0
		state.diagnostics = {}
		state.diagnosticsExpanded = false
		if editor then
			editor:setText("", true)
			editor:_moveCursorToIndex(1)
		end
		if splitEditor then
			splitEditor:setText("", true)
			splitEditor:_moveCursorToIndex(1)
		end
		updateDiagnosticsView()
		layoutEditorAndDiagnostics()
		updateStatus()
		return
	end
	state.path = buffer.path
	state.pendingPath = buffer.pendingPath
	state.displayName = buffer.displayName
	state.savedText = buffer.savedText or ""
	state.dirty = buffer.dirty or false
	state.isUntitled = buffer.isUntitled ~= false
	state.cursorLine = buffer.cursorLine or 1
	state.cursorCol = buffer.cursorCol or 1
	state.selectionLength = buffer.selectionLength or 0
	state.diagnostics = buffer.diagnostics or {}
	state.diagnosticsExpanded = buffer.diagnosticsExpanded or false
	if editor then
		local text = buffer.text or buffer.savedText or ""
		editor:setText(text, true)
		local lines = split_lines(text)
		local cursorIndex = line_col_to_index(lines, state.cursorLine, state.cursorCol)
		editor:_moveCursorToIndex(cursorIndex)
		if splitEditor and state.splitActive then
			splitEditor:_setTextInternal(text, false, true)
			local sLines = split_lines(text)
			local sCursorIndex = line_col_to_index(sLines, buffer.splitCursorLine or 1, buffer.splitCursorCol or 1)
			splitEditor:_moveCursorToIndex(sCursorIndex)
		end
	end
	updateDiagnosticsView()
	layoutEditorAndDiagnostics()
	updateStatus()
	refreshTabLabel(state.activeBufferIndex)
end

local suppressTabSelect = false

local function activateBufferByIndex(index, options)
	options = options or {}
	if index < 1 or index > #state.buffers then
		return false
	end
	if state.activeBufferIndex ~= index or options.force then
		syncStateToBuffer(state.activeBuffer)
		state.activeBufferIndex = index
		state.activeBuffer = state.buffers[index]
		syncBufferToState(state.activeBuffer)
		if tabControl and not options.skipTabSelect then
			suppressTabSelect = true
			tabControl:setSelectedIndex(index, true)
			suppressTabSelect = false
		end
	end
	state.showHomeScreen = false
	if not options.skipVisibilityUpdate and updateMainVisibility then
		updateMainVisibility()
	end
	if not options.skipFocus then
		app:setFocus(editor)
	end
	return true
end

local function addBuffer(buffer, options)
	options = options or {}
	state.buffers[#state.buffers + 1] = buffer
	if tabControl then
		tabControl:addTab({
			id = buffer.id,
			label = formatTabLabel(buffer),
			value = buffer.id,
			closeable = true
		})
		if options.select ~= false then
			activateBufferByIndex(#state.buffers, { skipTabSelect = true, skipFocus = options.skipFocus })
			suppressTabSelect = true
			tabControl:setSelectedIndex(state.activeBufferIndex, true)
			suppressTabSelect = false
		end
	else
		if options.select ~= false then
			activateBufferByIndex(#state.buffers, { skipVisibilityUpdate = true })
		end
	end
	refreshTabLabel(#state.buffers)
end

local function finalizeBufferRemoval(index)
	suppressTabSelect = true
	if tabControl then
		tabControl:removeTab(index)
	end
	suppressTabSelect = false
	table.remove(state.buffers, index)
	if #state.buffers == 0 then
		state.activeBuffer = nil
		state.activeBufferIndex = 0
		syncBufferToState(nil)
		showHomeScreen()
		if tabControl then
			suppressTabSelect = true
			tabControl:setSelectedIndex(0, true)
			suppressTabSelect = false
		end
		return
	end
	local currentIndex = state.activeBufferIndex or 0
	local newIndex
	if index < currentIndex then
		newIndex = currentIndex - 1
	elseif index == currentIndex then
		newIndex = math.min(index, #state.buffers)
	else
		newIndex = currentIndex
	end
	state.activeBuffer = nil
	state.activeBufferIndex = 0
	activateBufferByIndex(newIndex, { skipTabSelect = true })
	if tabControl then
		suppressTabSelect = true
		tabControl:setSelectedIndex(state.activeBufferIndex, true)
		suppressTabSelect = false
	end
	refreshAllTabLabels()
end

local function requestBufferActivation(index, onActivated)
	if index < 1 or index > #state.buffers then
		return
	end
	if state.activeBufferIndex == index then
		if onActivated then
			onActivated()
		end
		return
	end
	local previousIndex = state.activeBufferIndex
	local function perform()
		activateBufferByIndex(index, { skipTabSelect = true })
		if tabControl then
			suppressTabSelect = true
			tabControl:setSelectedIndex(index, true)
			suppressTabSelect = false
		end
		if onActivated then
			onActivated()
		end
	end
	if hasUnsavedChanges() then
		if tabControl and previousIndex and previousIndex > 0 then
			suppressTabSelect = true
			tabControl:setSelectedIndex(previousIndex, true)
			suppressTabSelect = false
		end
		confirmUnsaved(function()
			perform()
		end)
	else
		perform()
	end
end

local function requestBufferClose(index)
	local buffer = state.buffers[index]
	if not buffer then
		return
	end
	local function proceedClose()
		syncStateToBuffer(state.activeBuffer)
		finalizeBufferRemoval(index)
	end
	if state.activeBufferIndex ~= index then
		local function afterSwitch()
			requestBufferClose(state.activeBufferIndex)
		end
		local function switchFirst()
			activateBufferByIndex(index, { skipTabSelect = true })
			if tabControl then
				suppressTabSelect = true
				tabControl:setSelectedIndex(index, true)
				suppressTabSelect = false
			end
			afterSwitch()
		end
		if hasUnsavedChanges() then
			confirmUnsaved(function()
				switchFirst()
			end)
		else
			switchFirst()
		end
		return
	end
	if hasUnsavedChanges() then
		confirmUnsaved(function()
			proceedClose()
		end)
	else
		proceedClose()
	end
end

local function parseSyntaxError(err)
	if not err or err == "" then
		return nil, "syntax error"
	end
	local line, message = err:match(":(%d+):%s*(.*)")
	if not line then
		line, message = err:match("(%d+)%s*:%s*(.*)")
	end
	return tonumber(line), message or err
end

local function recomputeDiagnosticsNow()
	local diagnostics = {}
	local buffer = state.activeBuffer
	if editor and buffer then
		local text = editor:getText() or ""
		local env = setmetatable({}, { __index = _G })
		local chunk, err = load(text, state.path or "buffer", "t", env)
		if not chunk and err then
			local line, message = parseSyntaxError(err)
			diagnostics[#diagnostics + 1] = {
				severity = "error",
				line = line,
				message = message or err
			}
		end
	end
	if buffer then
		buffer.diagnostics = diagnostics
	end
	state.diagnostics = diagnostics
	updateDiagnosticsView()
	updateStatus()
end

local function scheduleDiagnosticsUpdate()
	if diagnosticsUpdateThread then
		diagnosticsUpdateThread:cancel()
		diagnosticsUpdateThread = nil
	end
	if not app or not app.spawnThread then
		recomputeDiagnosticsNow()
		return
	end
	diagnosticsUpdateThread = app:spawnThread(function(ctx)
		ctx:sleep(0.2)
		diagnosticsUpdateThread = nil
		recomputeDiagnosticsNow()
	end)
end

local function toggleDiagnosticsPanel()
	if not diagnosticsPanel or diagnosticsPanelHeight <= 0 then
		state.diagnosticsExpanded = false
		local buffer = state.activeBuffer
		if buffer then
			buffer.diagnosticsExpanded = false
		end
		updateDiagnosticsToggle()
		return
	end
	state.diagnosticsExpanded = not state.diagnosticsExpanded
	local buffer = state.activeBuffer
	if buffer then
		buffer.diagnosticsExpanded = state.diagnosticsExpanded
	end
	layoutEditorAndDiagnostics()
	if state.diagnosticsExpanded then
		if diagnosticsUpdateThread then
			diagnosticsUpdateThread:cancel()
			diagnosticsUpdateThread = nil
		end
		recomputeDiagnosticsNow()
		if diagnosticsList and state.diagnostics and #state.diagnostics > 0 then
			diagnosticsList:setSelectedIndex(1)
			app:setFocus(diagnosticsList)
		end
	end
	if not state.diagnosticsExpanded then
		focusActiveEditor()
	end
	app:render()
end

if diagnosticsToggleButton then
	diagnosticsToggleButton.onClick = toggleDiagnosticsPanel
end



layoutEditorAndDiagnostics()
applyEditorBorder()

-- Home Screen Components
local homeFrame = app:createFrame({
	x = 1,
	y = 1,
	width = rootWidth,
	height = rootHeight,
	bg = colors.black,
	fg = colors.white
})
homeFrame.visible = false
root:addChild(homeFrame)

local homeTitle = app:createLabel({
	x = 1,
	y = 2,
	width = rootWidth,
	height = 1,
	text = "CCIDE - CC:Tweaked IDE",
	align = "center",
	bg = colors.black,
	fg = colors.white
})
homeFrame:addChild(homeTitle)

local homeSubtitle = app:createLabel({
	x = 1,
	y = 3,
	width = rootWidth,
	height = 1,
	text = "Choose a file to edit or start a new project",
	align = "center",
	bg = colors.black,
	fg = colors.lightGray
})
homeFrame:addChild(homeSubtitle)

local newFileButton = app:createButton({
	x = math.floor(rootWidth / 2) - 8,
	y = 5,
	width = 16,
	height = 3,
	label = "New File",
	bg = colors.blue,
	fg = colors.white,
	border = { color = colors.lightBlue }
})
newFileButton.focusable = true
homeFrame:addChild(newFileButton)

local openFileButton = app:createButton({
	x = math.floor(rootWidth / 2) - 8,
	y = 9,
	width = 16,
	height = 3,
	label = "Open File...",
	bg = colors.green,
	fg = colors.white,
	border = { color = colors.lime }
})
openFileButton.focusable = true
homeFrame:addChild(openFileButton)

local recentLabel = app:createLabel({
	x = 2,
	y = 14,
	width = rootWidth - 2,
	height = 1,
	text = "Recent Files:",
	align = "left",
	bg = colors.black,
	fg = colors.white
})
homeFrame:addChild(recentLabel)

local recentListHeight = math.max(3, rootHeight - 16)
local recentList = app:createList({
	x = 2,
	y = 15,
	width = rootWidth - 2,
	height = recentListHeight,
	bg = colors.black,
	fg = colors.white,
	highlightBg = colors.blue,
	highlightFg = colors.white,
	placeholder = "(no recent files)",
	scrollbar = { enabled = true, trackColor = colors.black, thumbColor = colors.gray },
	border = { color = colors.gray }
})
recentList.focusable = true
homeFrame:addChild(recentList)

-- Function to update home screen layout when app is resized
local function updateHomeScreenLayout()
	local currentWidth, currentHeight = root:getSize()
	if homeFrame then
		homeFrame:setSize(currentWidth, currentHeight)
		homeTitle:setSize(currentWidth, 1)
		homeSubtitle:setSize(currentWidth, 1)
		
		-- Center the buttons
		local buttonX = math.floor(currentWidth / 2) - 8
		newFileButton:setPosition(buttonX, 5)
		openFileButton:setPosition(buttonX, 9)
		
		-- Update recent files section
		recentLabel:setSize(currentWidth - 2, 1)
		local newRecentListHeight = math.max(3, currentHeight - 16)
		recentList:setSize(currentWidth - 2, newRecentListHeight)
	end
end

local function refreshHomeScreen()
	if not state.showHomeScreen or not homeFrame.visible then
		return
	end
	local items = {}
	for i = 1, #state.recentFiles do
		local path = state.recentFiles[i]
		local name = fs.getName(path) or path
		local size = getFileSize(path)
		local date = formatFileDate(path)
		local sizeStr = size > 0 and string.format("(%d bytes)", size) or ""
		local display = string.format("%s %s %s", name, sizeStr, date)
		items[#items + 1] = truncate(display, recentList.width - 4)
	end
	recentList:setItems(items)
end

-- Button callbacks will be set after function declarations

local function showFileDialog(options)
		options = options or {}
		local mode = options.mode or "open"
		local onComplete = options.onComplete
		local startPath = normalize_path(options.startPath) or working_directory()
		local defaultName = options.defaultName or ""
		local selectPath = options.selectPath and normalize_path(options.selectPath) or nil

		local dialogWidth = math.max(28, math.min(rootWidth - 2, 46))
		local dialogHeight = math.max(mode == "save" and 15 or 13, math.min(rootHeight - 2, 20))
		local dx = math.floor((rootWidth - dialogWidth) / 2) + 1
		local dy = math.floor((rootHeight - dialogHeight) / 2) + 1

		local dialog = app:createDialog({
			x = dx,
			y = dy,
			width = dialogWidth,
			height = dialogHeight,
			title = mode == "save" and "Save File" or "Open File",
			bg = colors.black,
			titleBar = {
				bg = colors.white,
				fg = colors.black
			}
		})
		dialog:setBorder({ color = colors.white })
		root:addChild(dialog)

		local leftPad, rightPad, topPad, bottomPad, innerWidth, innerHeight = dialog:_computeInnerOffsets()
		local titleHeight = dialog:_getVisibleTitleBarHeight()
		local contentX = leftPad + 1
		local contentY = topPad + titleHeight + 1
		local contentWidth = innerWidth
		local contentHeight = innerHeight - titleHeight

		local pathLabel = app:createLabel({
			x = contentX,
			y = contentY,
			width = contentWidth,
			height = 1,
			text = truncate(startPath, contentWidth),
			fg = colors.white,
			bg = colors.black,
			align = "left"
		})
		dialog:addChild(pathLabel)

		local reserved = 4 -- buttons + message
		if mode == "save" then
			reserved = reserved + 4
		end
		local listHeight = math.max(3, contentHeight - reserved)

		local listWidget = app:createList({
			x = contentX,
			y = contentY + 1,
			width = contentWidth,
			height = listHeight,
			border = { color = colors.white },
			highlightBg = colors.lightBlue,
			highlightFg = colors.black,
			bg = colors.black,
			fg = colors.white,
			placeholder = "(empty)",
			scrollbar = { enabled = true, trackColor = colors.black, thumbColor = colors.gray }
		})
		dialog:addChild(listWidget)

		local nameLabel
		local filenameBox
		local inputBottom = contentY + 1 + listHeight
		if mode == "save" then
			nameLabel = app:createLabel({
				x = contentX,
				y = inputBottom,
				width = contentWidth,
				height = 1,
				text = "File name:",
				fg = colors.white,
				bg = colors.black,
				align = "left"
			})
			dialog:addChild(nameLabel)
			filenameBox = app:createTextBox({
				x = contentX,
				y = inputBottom + 1,
				width = contentWidth,
				height = 3,
				multiline = false,
				text = defaultName,
				bg = colors.black,
				fg = colors.white,
				border = { color = colors.white },
				scrollbar = { enabled = false }
			})
			dialog:addChild(filenameBox)
			inputBottom = filenameBox.y + filenameBox.height
		end

		local messageLabel = app:createLabel({
			x = contentX,
			y = inputBottom,
			width = contentWidth,
			height = 1,
			text = "",
			fg = colors.lightGray,
			bg = colors.black,
			align = "left"
		})
		dialog:addChild(messageLabel)

		local buttonY = inputBottom + 1
		local confirmLabel = mode == "save" and "Save" or "Open"
		local confirmWidth = math.floor((contentWidth - 1) / 2)
		local confirmButton = app:createButton({
			x = contentX,
			y = buttonY,
			width = confirmWidth,
			height = 1,
			label = confirmLabel,
			bg = colors.gray,
			fg = colors.white,
			border = { color = colors.white }
		})
		dialog:addChild(confirmButton)

		local cancelButton = app:createButton({
			x = contentX + confirmWidth + 1,
			y = buttonY,
			width = contentWidth - confirmWidth - 1,
			height = 1,
			label = "Cancel",
			bg = colors.gray,
			fg = colors.white,
			border = { color = colors.white }
		})
		dialog:addChild(cancelButton)

		local currentPath = startPath
		local entries = {}
		local lastSelectTime = 0

		local function setMessage(text, color)
			messageLabel:setText(truncate(text or "", messageLabel.width))
			messageLabel.fg = color or colors.lightGray
		end

		local function closeDialog(success, path)
			if onComplete then
				local ok, err = pcall(onComplete, success, path)
				if not ok then
					print("Dialog callback error: " .. tostring(err))
				end
			end
			dialog:close()
			if dialog.parent then
				dialog.parent:removeChild(dialog)
			end
			focusActiveEditor()
		end

		local function rebuildEntries()
			entries = {}
			local listItems = {}
			if currentPath ~= "/" then
				local parent = parent_dir(currentPath)
				entries[#entries + 1] = { label = "../", isDir = true, path = parent }
				listItems[#listItems + 1] = "../"
			end
			local ok, listing = pcall(fs.list, currentPath)
			if not ok then
				setMessage("Error reading directory", colors.red)
				return
			end
			table.sort(listing, function(a, b)
				return a:lower() < b:lower()
			end)
			for i = 1, #listing do
				local name = listing[i]
				local full = ensure_leading_slash(fs.combine(currentPath, name))
				local isDir = fs.isDir(full)
				local display = isDir and (name .. "/") or name
				entries[#entries + 1] = { label = display, isDir = isDir, path = full }
				listItems[#listItems + 1] = display
			end
			pathLabel:setText(truncate(currentPath, pathLabel.width))
			listWidget:setItems(listItems)
			if selectPath then
				for index = 1, #entries do
					if entries[index].path == selectPath then
						listWidget:setSelectedIndex(index)
						break
					end
				end
			end
		end

		local function activateEntry(entry)
			if not entry then
				return
			end
			if entry.isDir then
				currentPath = ensure_leading_slash(entry.path)
				selectPath = nil
				rebuildEntries()
				setMessage("", nil)
			else
				if mode == "save" and filenameBox then
					filenameBox:setText(fs.getName(entry.path))
					app:setFocus(filenameBox)
				else
					closeDialog(true, entry.path)
				end
			end
		end

		listWidget:setOnSelect(function(_, _, index)
			local entry = entries[index]
			if not entry then
				return
			end
			if mode == "save" and filenameBox and not entry.isDir then
				filenameBox:setText(fs.getName(entry.path))
			end
			local now = os.clock()
			if entry.isDir then
				if now - lastSelectTime < 0.35 then
					activateEntry(entry)
				end
			else
				if now - lastSelectTime < 0.35 then
					closeDialog(true, entry.path)
				end
			end
			lastSelectTime = now
		end)

		local function confirmSelection()
			if mode == "open" then
				local index = listWidget:getSelectedIndex()
				local entry = entries[index]
				if not entry then
					setMessage("Select a file", colors.orange)
					return
				end
				if entry.isDir then
					activateEntry(entry)
					return
				end
				closeDialog(true, entry.path)
			else
				local filename = filenameBox and trim(filenameBox:getText()) or ""
				if filename == "" then
					setMessage("Enter a file name", colors.orange)
					return
				end
				local full = ensure_leading_slash(fs.combine(currentPath, filename))
				if fs.exists(full) and fs.isDir(full) then
					setMessage("Cannot overwrite directory", colors.red)
					return
				end
				closeDialog(true, full)
			end
		end

		confirmButton.onClick = function()
			confirmSelection()
		end

		cancelButton.onClick = function()
			closeDialog(false, nil)
		end

		if filenameBox then
			filenameBox:setOnChange(function()
				setMessage("", nil)
			end)
		end

		rebuildEntries()
		if filenameBox then
			app:setFocus(filenameBox)
		else
			app:setFocus(listWidget)
		end

		return dialog
	end

	local function showInputDialog(options)
		options = options or {}
		local title = options.title or "Input"
		local prompt = options.prompt or ""
		local initial = options.value or ""
		local allowEmpty = options.allowEmpty == true
		local onSubmit = options.onSubmit

		local dialogWidth = math.max(24, math.min(rootWidth - 2, 44))
		local dialogHeight = 9
		local dx = math.floor((rootWidth - dialogWidth) / 2) + 1
		local dy = math.floor((rootHeight - dialogHeight) / 2) + 1

		local dialog = app:createDialog({
			x = dx,
			y = dy,
			width = dialogWidth,
			height = dialogHeight,
			title = title,
			bg = colors.black,
			titleBar = {
        		bg = colors.white,
        		fg = colors.black,
    		}
		})
		dialog:setBorder({ color = colors.white })
		root:addChild(dialog)

		local leftPad, rightPad, topPad, bottomPad, innerWidth = dialog:_computeInnerOffsets()
		local titleHeight = dialog:_getVisibleTitleBarHeight()
		local contentX = leftPad + 1
		local contentY = topPad + titleHeight + 1
		local contentWidth = innerWidth

		local promptLabel = app:createLabel({
			x = contentX,
			y = contentY,
			width = contentWidth,
			height = 1,
			text = truncate(prompt, contentWidth),
			fg = colors.white,
			bg = colors.black,
			align = "left"
		})
		dialog:addChild(promptLabel)

		local inputBox = app:createTextBox({
			x = contentX,
			y = contentY + 1,
			width = contentWidth,
			height = 3,
			multiline = false,
			text = initial,
			bg = colors.black,
			fg = colors.white,
			border = { color = colors.white },
			scrollbar = { enabled = false }
		})
		dialog:addChild(inputBox)

		local messageLabel = app:createLabel({
			x = contentX,
			y = inputBox.y + inputBox.height,
			width = contentWidth,
			height = 1,
			text = "",
			fg = colors.lightGray,
			bg = colors.black,
			align = "left"
		})
		dialog:addChild(messageLabel)

		local buttonY = messageLabel.y + 1
		local okWidth = math.floor((contentWidth - 1) / 2)
		local okButton = app:createButton({
			x = contentX,
			y = buttonY,
			width = okWidth,
			height = 1,
			label = "OK",
			bg = colors.gray,
			fg = colors.white,
			border = { color = colors.white }
		})
		dialog:addChild(okButton)

		local cancelButton = app:createButton({
			x = contentX + okWidth + 1,
			y = buttonY,
			width = contentWidth - okWidth - 1,
			height = 1,
			label = "Cancel",
			bg = colors.gray,
			fg = colors.white,
			border = { color = colors.white }
		})
		dialog:addChild(cancelButton)

		local function setMessage(text, color)
			messageLabel:setText(truncate(text or "", messageLabel.width))
			messageLabel.fg = color or colors.lightGray
		end

		local function closeDialog()
			dialog:close()
			if dialog.parent then
				dialog.parent:removeChild(dialog)
			end
			focusActiveEditor()
		end

		local function submit()
			local value = trim(inputBox:getText())
			if value == "" and not allowEmpty then
				setMessage("Value required", colors.orange)
				return
			end
			if onSubmit then
				local ok, result = pcall(onSubmit, value)
				if not ok then
					setMessage(tostring(result), colors.red)
					return
				end
				if result == false then
					return
				end
			end
			closeDialog()
		end

		okButton.onClick = submit
		cancelButton.onClick = closeDialog

		inputBox:setOnChange(function()
			setMessage("", nil)
		end)

		app:setFocus(inputBox)
		return dialog
	end

	local messageThread

	local function updateDirtyState(text)
		local buffer = state.activeBuffer
		if buffer then
			buffer.text = text or buffer.text or ""
			buffer.dirty = (buffer.text or "") ~= (buffer.savedText or "")
			state.dirty = buffer.dirty
			refreshTabLabel(state.activeBufferIndex)
		else
			state.dirty = false
		end
	end

	updateStatus = function()
		if not statusLabel then
			return
		end
		statusLabel.visible = state.showStatusBar
		if state.showStatusBar then
			updateDiagnosticsToggle()
		elseif diagnosticsToggleButton then
			diagnosticsToggleButton.visible = false
		end
		if not state.showStatusBar then
			statusLabel:setText(truncate("", statusLabel.width))
			return
		end
		local name = state.path and fs.getName(state.path) or state.displayName or "Untitled"
		local dirtyMark = state.dirty and "*" or ""
		local width = statusLabel.width or rootWidth
		local rightParts = {
			string.format("Ln %d", state.cursorLine or 1),
			string.format("Col %d", state.cursorCol or 1)
		}
		if state.selectionLength and state.selectionLength > 0 then
			rightParts[#rightParts + 1] = "Sel " .. tostring(state.selectionLength)
		end
		if state.diagnostics then
			rightParts[#rightParts + 1] = string.format("Diag %d", #state.diagnostics)
		end
		local rightText = table.concat(rightParts, "  ")
		if #rightText >= width then
			statusLabel:setText(truncate(rightText, width))
			return
		end
		local leftCapacity = width - #rightText - 1
		if leftCapacity < 0 then
			leftCapacity = 0
		end
		local leftParts = { name .. dirtyMark }
		if state.message and state.message ~= "" then
			leftParts[#leftParts + 1] = state.message
		elseif state.path then
			leftParts[#leftParts + 1] = state.path
		end
		local leftText = table.concat(leftParts, "  ")
		if leftCapacity == 0 then
			if #rightText < width then
				rightText = string.rep(" ", width - #rightText) .. rightText
			elseif #rightText > width then
				rightText = truncate(rightText, width)
			end
			statusLabel:setText(rightText)
			return
		end
		if #leftText > leftCapacity then
			if leftCapacity <= 3 then
				leftText = leftText:sub(1, leftCapacity)
			else
				leftText = leftText:sub(1, leftCapacity - 3) .. "..."
			end
		end
		if #leftText < leftCapacity then
			leftText = leftText .. string.rep(" ", leftCapacity - #leftText)
		end
		local final = leftText .. " " .. rightText
		if #final < width then
			final = final .. string.rep(" ", width - #final)
		end
		statusLabel:setText(final)
	end

	local function showStatusMessage(message, duration)
		state.message = message
		updateStatus()
		if messageThread then
			messageThread:cancel()
			messageThread = nil
		end
		if duration and duration > 0 then
			local captured = message
			messageThread = app:spawnThread(function(ctx)
				ctx:sleep(duration)
				if state.message == captured then
					state.message = nil
					updateStatus()
				end
			end)
		end
	end

	local function showHelpDialog()
		if state.helpBox then
			local ok, err = pcall(function()
				state.helpBox:close()
			end)
			if not ok then
				printError(err)
			end
			state.helpBox = nil
			state.helpPagination = nil
		end

		local helpItems = {
			"Home screen: Shows recent files and options to create or open files.",
			"File menu: Access home, create new files, open existing ones, save, and manage recents.",
			"View menu: Toggle the status bar visibility and the editor border.",
			"Edit menu: Trim whitespace, duplicate lines, go to a line, or revert to saved.",
			"Settings menu: Enable or disable autocomplete and change the tab width.",
			"Status bar: Shows cursor info and diagnostics count; the arrow opens diagnostics.",
			"Toolbar buttons: 'Icons' inserts CC:T glyphs, 'Run' executes the saved file, '?' shows help."
		}

		local rootW = root.width or rootWidth or 51
		local rootH = root.height or rootHeight or 19

		local minBoxWidth = 20
		if rootW <= minBoxWidth + 1 then
			minBoxWidth = math.max(16, rootW - 2)
		end
		local maxBoxWidth = math.max(minBoxWidth, rootW - 2)
		local desiredWidth = math.floor(rootW * 0.7)
		local boxWidth = clamp(desiredWidth, minBoxWidth, maxBoxWidth)

		local minBoxHeight = 8
		if rootH <= minBoxHeight + 1 then
			minBoxHeight = math.max(6, rootH - 2)
		end
		local maxBoxHeight = math.max(minBoxHeight, rootH - 1)
		local desiredHeight = math.floor(rootH * 0.5)
		local boxHeight = clamp(desiredHeight, minBoxHeight, maxBoxHeight)

		local maxX = math.max(1, rootW - boxWidth + 1)
		local maxY = math.max(2, rootH - boxHeight + 1)
		local posX = clamp(math.floor((rootW - boxWidth) / 2) + 1, 1, maxX)
		local posY = clamp(math.floor((rootH - boxHeight) / 2) + 1, 2, maxY)

		local box
		local pagination = { pages = {}, index = 1 }

		local function refreshNavButtons()
			if not box or not box._buttons then
				return
			end
			local total = #pagination.pages
			for i = 1, #box._buttons do
				local entry = box._buttons[i]
				if entry and entry.button then
					if entry.id == "prev" then
						local disabled = total <= 1 or pagination.index <= 1
						entry.button.bg = disabled and colors.lightGray or colors.white
						entry.button.fg = disabled and colors.gray or colors.black
					elseif entry.id == "next" then
						local disabled = total <= 1 or pagination.index >= total
						entry.button.bg = disabled and colors.lightGray or colors.white
						entry.button.fg = disabled and colors.gray or colors.black
					end
				end
			end
		end

		local function updateHelpDisplay()
			if not box then
				return
			end
			local total = #pagination.pages
			if total == 0 then
				pagination.pages = { "" }
				total = 1
			end
			if pagination.index < 1 then
				pagination.index = 1
			elseif pagination.index > total then
				pagination.index = total
			end
			box:setMessage(pagination.pages[pagination.index] or "")
			if total > 1 then
				box:setTitle(string.format("CCIDE Help (%d/%d)", pagination.index, total))
			else
				box:setTitle("CCIDE Help")
			end
			refreshNavButtons()
			app:render()
		end

		local function changePage(delta)
			local total = #pagination.pages
			if total <= 1 then
				return
			end
			local target = clamp(pagination.index + delta, 1, total)
			if target ~= pagination.index then
				pagination.index = target
				updateHelpDisplay()
			end
		end

		local function rebuildPagination()
			if not box or not box._messageLabel then
				pagination.pages = { "" }
				pagination.index = 1
				return
			end
			local labelWidth = math.max(1, box._messageLabel.width)
			local labelHeight = math.max(1, box._messageLabel.height)
			local lines = {}
			for i = 1, #helpItems do
				local wrapped = wrap_text("- " .. helpItems[i], labelWidth)
				for j = 1, #wrapped do
					lines[#lines + 1] = wrapped[j]
				end
			end
			if #lines == 0 then
				lines[1] = ""
			end
			local perPage = math.max(1, labelHeight)
			local index = 1
			local pages = {}
			while index <= #lines do
				local chunk = {}
				for offset = 0, perPage - 1 do
					local lineText = lines[index + offset]
					if not lineText then
						break
					end
					chunk[#chunk + 1] = lineText
				end
				pages[#pages + 1] = table.concat(chunk, "\n")
				index = index + perPage
			end
			if #pages == 0 then
				pages[1] = ""
			end
			pagination.pages = pages
			local total = #pages
			if total == 0 then
				pagination.index = 1
			else
				pagination.index = clamp(pagination.index, 1, total)
			end
		end

		box = app:createMsgBox({
			x = posX,
			y = posY,
			width = boxWidth,
			height = boxHeight + 2,
			title = "CCIDE Help",
			bg = colors.gray,
			messageBg = colors.white,
			messageFg = colors.black,
			messagePadding = { x = 1, y = 1 },
			buttonHeight = 1,
			buttons = {
				{ id = "ok", label = "OK" }
			}
		})

		state.helpBox = box
		state.helpPagination = pagination

		local originalClose = box.close
		box.close = function(self, ...)
			local result = originalClose(self, ...)
			if state.helpBox == self then
				state.helpBox = nil
			end
			if state.helpPagination == pagination then
				state.helpPagination = nil
			end
			return result
		end

		box:setOnResult(function()
			focusActiveEditor()
		end)

		root:addChild(box)
		if box.bringToFront then
			box:bringToFront()
		end

		rebuildPagination()
		if #pagination.pages > 1 then
			box:setButtons({
				{
					id = "prev",
					label = "Prev",
					autoClose = false,
					onSelect = function()
						changePage(-1)
					end
				},
				{
					id = "next",
					label = "Next",
					autoClose = false,
					onSelect = function()
						changePage(1)
					end
				},
				{ id = "ok", label = "OK" }
			})
			rebuildPagination()
		end

		updateHelpDisplay()
	end

	local function showIconPicker()
		local cols, rows = 16, 16
		local desiredWidth = cols * 3 + 4
		local desiredHeight = rows + 4
		local dialogWidth = math.max(22, math.min(rootWidth - 1, desiredWidth))
		local dialogHeight = math.max(12, math.min(rootHeight, desiredHeight))
		local dx = math.floor((rootWidth - dialogWidth) / 2) + 1
		local dy = math.floor((rootHeight - dialogHeight) / 2) + 1

		local dialog = app:createDialog({
			x = dx,
			y = dy,
			width = dialogWidth,
			height = dialogHeight,
			title = "Select Icon",
			bg = colors.black,
			closeOnBackdrop = true,
			closeOnEscape = true,
			titleBar = {
        		bg = colors.white,
        		fg = colors.black
    		}
		})
		dialog:setBorder({ color = colors.white })
		root:addChild(dialog)

		local originalClose = dialog.close
		function dialog:close(...)
			local result = originalClose(self, ...)
			if self.parent then
				self.parent:removeChild(self)
			end
			focusActiveEditor()
			return result
		end

		local leftPad, rightPad, topPad, bottomPad, innerWidth, innerHeight = dialog:_computeInnerOffsets()
		local titleHeight = dialog:_getVisibleTitleBarHeight()
		local contentX = leftPad + 1
		local contentY = topPad + titleHeight + 1
		local contentWidth = innerWidth
		local contentHeight = innerHeight - titleHeight

		local cellWidth = math.max(1, math.floor(contentWidth / cols))
		if cellWidth > 3 then
			cellWidth = 3
		end
		local gridWidth = cellWidth * cols
		local offsetX = contentX + math.floor((contentWidth - gridWidth) / 2)
		if offsetX < contentX then
			offsetX = contentX
		end
		if contentHeight < rows then
			rows = contentHeight
		end

		local function closeDialog()
			dialog:close()
		end

		local function displayChar(code)
			local ch = string.char(code)
			if ch == "\n" or ch == "\r" or ch == "\t" then
				return " "
			end
			return ch
		end

		local firstButton
		for row = 0, rows - 1 do
			for col = 0, cols - 1 do
				local code = row * 16 + col
				if code > 255 then
					break
				end
				local button = app:createButton({
					x = offsetX + col * cellWidth,
					y = contentY + row,
					width = cellWidth,
					height = 1,
					label = displayChar(code),
					bg = colors.black,
					fg = colors.white,
					border = { color = colors.gray }
				})
				button.focusable = true
				if not firstButton then
					firstButton = button
				end
				button.onClick = function()
					closeDialog()
					local char = string.char(code)
					local activeEd = getActiveEditor()
					activeEd:_insertTextAtCursor(char)
					scheduleDiagnosticsUpdate()
					showStatusMessage(string.format("Inserted char %d (0x%02X)", code, code), 2)
				end
				dialog:addChild(button)
			end
		end

		if firstButton then
			app:setFocus(firstButton)
		else
			app:setFocus(dialog)
		end
	end

	local function addRecentFile(path)
		path = normalize_path(path)
		if not path or path == state.path then
			return
		end
		for i = #state.recentFiles, 1, -1 do
			if state.recentFiles[i] == path then
				table.remove(state.recentFiles, i)
				break
			end
		end
		table.insert(state.recentFiles, 1, path)
		while #state.recentFiles > 8 do
			state.recentFiles[#state.recentFiles] = nil
		end
	end

	function hasUnsavedChanges()
		local buffer = state.activeBuffer
		if not buffer then
			return false
		end
		if buffer.dirty ~= nil then
			return buffer.dirty
		end
		return (buffer.text or editor:getText() or "") ~= (buffer.savedText or "")
	end

	local function showError(title, message)
		local box = app:createMsgBox({
			title = title or "Error",
			message = message or "",
			buttons = { { id = "ok", label = "OK" } }
		})
		box:setOnResult(function()
			focusActiveEditor()
		end)
		root:addChild(box)
	end

	local saveCurrentFile
	local saveAs

	local function confirmUnsaved(onContinue)
		if not hasUnsavedChanges() then
			onContinue()
			return
		end
		local box = app:createMsgBox({
			title = "Unsaved Changes",
			message = "Save changes before continuing?",
			buttons = {
				{ id = "cancel", label = "Cancel" },
				{ id = "discard", label = "Don't Save", bg = colors.red, fg = colors.white },
				{ id = "save", label = "Save" }
			}
		})
		box:setOnResult(function(_, id)
			if id == "save" then
				saveCurrentFile(function(success)
					if success then
						onContinue()
					end
				end)
			elseif id == "discard" then
				onContinue()
			end
			focusActiveEditor()
		end)
		root:addChild(box)
	end

if tabControl then
	tabControl:setOnSelect(function(_, _, index)
		if suppressTabSelect or not index or index < 1 then
			return
		end
		requestBufferActivation(index)
	end)
	tabControl:setOnCloseTab(function(_, _, index)
		if not index or index < 1 then
			return false
		end
		if suppressTabSelect then
			return false
		end
		requestBufferClose(index)
		return false
	end)
end

	local function prepareEmptyBuffer(name, pendingPath)
		hideHomeScreen()
		local buffer = createBuffer({
			displayName = name or state.displayName or "Untitled",
			pendingPath = pendingPath,
			text = "",
			savedText = "",
			dirty = false,
			isUntitled = true
		})
		addBuffer(buffer)
		state.message = nil
		updateStatus()
		refreshTabLabel(state.activeBufferIndex)
	end

	local function saveToPath(targetPath)
		local normalized = normalize_path(targetPath)
		if not normalized then
			showError("Save Failed", "Invalid path")
			return false
		end
		local dir = parent_dir(normalized)
		if dir and dir ~= "/" and not fs.exists(dir) then
			local ok, err = pcall(fs.makeDir, dir)
			if not ok then
				showError("Save Failed", err or ("Unable to create " .. dir))
				return false
			end
		end
		if fs.exists(normalized) and fs.isDir(normalized) then
			showError("Save Failed", "Cannot overwrite a directory")
			return false
		end
		local text = editor:getText()
		local ok, err = pcall(function()
			local handle = fs.open(normalized, "w")
			if not handle then
				error("Unable to open file for writing", 0)
			end
			handle.write(text)
			handle.close()
		end)
		if not ok then
			showError("Save Failed", err)
			return false
		end
		state.path = normalized
		state.pendingPath = nil
		state.displayName = fs.getName(normalized)
		state.savedText = text
		state.dirty = false
		state.isUntitled = false
		local buffer = state.activeBuffer
		if buffer then
			buffer.path = normalized
			buffer.pendingPath = nil
			buffer.displayName = state.displayName
			buffer.savedText = text
			buffer.dirty = false
			buffer.isUntitled = false
			buffer.text = text
		end
		addRecentFile(normalized)
		showStatusMessage("Saved to " .. normalized, 3)
		updateStatus()
		refreshTabLabel(state.activeBufferIndex)
		return true
	end

	local function loadFile(path)
		local normalized = normalize_path(path)
		if not normalized then
			showError("Open Failed", "Invalid path")
			return false
		end
		if not fs.exists(normalized) then
			showError("Open Failed", normalized .. " not found")
			return false
		end
		if fs.isDir(normalized) then
			showError("Open Failed", "Cannot open a directory")
			return false
		end
		local existingIndex = findBufferByPath(normalized)
		if existingIndex then
			hideHomeScreen()
			activateBufferByIndex(existingIndex)
			showStatusMessage("Switched to " .. normalized, 2)
			return true
		end
		local handle, err = fs.open(normalized, "r")
		if not handle then
			showError("Open Failed", err or "Unable to read file")
			return false
		end
		local contents = handle.readAll() or ""
		handle.close()
		hideHomeScreen()
		local buffer = createBuffer({
			path = normalized,
			pendingPath = nil,
			displayName = fs.getName(normalized),
			text = contents,
			savedText = contents,
			dirty = false,
			isUntitled = false,
			cursorLine = 1,
			cursorCol = 1,
			selectionLength = 0,
			diagnostics = {}
		})
		addBuffer(buffer)
		buffer.text = contents
		buffer.savedText = contents
		buffer.dirty = false
		syncBufferToState(buffer)
		recomputeDiagnosticsNow()
		addRecentFile(normalized)
		showStatusMessage("Opened " .. normalized, 3)
		return true
	end

	local function newUntitled()
		confirmUnsaved(function()
			local id = state.nextUntitled or 2
			state.nextUntitled = (state.nextUntitled or 2) + 1
			prepareEmptyBuffer(string.format("Untitled-%d", id), nil)
		end)
	end

	local function saveAs(onSaved)
		local startPath = state.path and parent_dir(state.path) or (state.pendingPath and parent_dir(state.pendingPath)) or working_directory()
		local defaultName = state.path and fs.getName(state.path) or (state.pendingPath and fs.getName(state.pendingPath)) or state.displayName or "Untitled"
		showFileDialog({
			mode = "save",
			startPath = startPath,
			defaultName = defaultName,
			onComplete = function(success, selected)
				if success and selected then
					local saved = saveToPath(selected)
					if onSaved then
						onSaved(saved)
					end
				elseif onSaved then
					onSaved(false)
				end
			end
		})
		return false
	end

	local function saveCurrentFile(onSaved)
		if state.path then
			local saved = saveToPath(state.path)
			if onSaved then
				onSaved(saved)
			end
			return saved
		end
		return saveAs(onSaved)
	end

	local function openFileWorkflow()
		confirmUnsaved(function()
			showFileDialog({
				mode = "open",
				startPath = state.path and parent_dir(state.path) or working_directory(),
				onComplete = function(success, selected)
					if success and selected then
						loadFile(selected)
					end
				end
			})
		end)
	end

	if diagnosticsList then
		local lastSelectTime = 0
		diagnosticsList:setOnSelect(function(_, _, index)
			local entries = state.diagnostics or {}
			local entry = entries[index]
			if not entry then
				return
			end
			local now = os.clock()
			if entry.line and now - lastSelectTime < 0.35 then
				local activeEd = getActiveEditor()
				local lines = split_lines(activeEd:getText())
				activeEd:_moveCursorToIndex(line_col_to_index(lines, entry.line, entry.column or 1))
				focusActiveEditor()
			end
			lastSelectTime = now
		end)
	end

	local function trimTrailingWhitespace()
		local lines = split_lines(editor:getText())
		local changed = false
		for i = 1, #lines do
			local trimmedLine = lines[i]:gsub("%s+$", "")
			if trimmedLine ~= lines[i] then
				lines[i] = trimmedLine
				changed = true
			end
		end
		if not changed then
			showStatusMessage("No trailing whitespace", 2)
			return
		end
		local currentLine = state.cursorLine or 1
		local currentCol = state.cursorCol or 1
		local newText = table.concat(lines, "\n")
		editor:setText(newText)
		editor:_moveCursorToIndex(line_col_to_index(lines, currentLine, currentCol))
		scheduleDiagnosticsUpdate()
		showStatusMessage("Trimmed trailing whitespace", 2)
	end

	local function duplicateCurrentLine()
		local lines = split_lines(editor:getText())
		local line = math.max(1, math.min(state.cursorLine or 1, #lines))
		local lineText = lines[line] or ""
		table.insert(lines, line + 1, lineText)
		local newText = table.concat(lines, "\n")
		editor:setText(newText)
		editor:_moveCursorToIndex(line_col_to_index(lines, line + 1, 1))
		scheduleDiagnosticsUpdate()
		showStatusMessage("Duplicated line", 2)
	end

	local function promptGoToLine()
		local totalLines = editor.getLineCount and editor:getLineCount()
		if not totalLines then
			totalLines = #split_lines(editor:getText())
		end
		showInputDialog({
			title = "Go To Line",
			prompt = string.format("Line number (1-%d):", totalLines),
			value = tostring(state.cursorLine or 1),
			onSubmit = function(value)
				local number = tonumber(value)
				if not number then
					return false
				end
				number = math.floor(number + 0.5)
				if number < 1 then
					number = 1
				elseif number > totalLines then
					number = totalLines
				end
				local lines = split_lines(editor:getText())
				editor:_moveCursorToIndex(line_col_to_index(lines, number, 1))
				showStatusMessage("Moved to line " .. number, 2)
				return true
			end
		})
	end

	local function applyTabSize()
		showInputDialog({
			title = "Tab Size",
			prompt = "Enter tab width (1-8):",
			value = tostring(state.tabSize or 4),
			onSubmit = function(value)
				local number = tonumber(value)
				if not number then
					return false
				end
				number = math.floor(number)
				if number < 1 or number > 8 then
					return false
				end
				state.tabSize = number
				editor.tabWidth = number
				showStatusMessage("Tab width set to " .. number, 2)
				return true
			end
		})
	end

			local function toggleEditorBorder()
				state.showEditorBorder = not state.showEditorBorder
				applyEditorBorder()
				layoutEditorAndDiagnostics()
				showStatusMessage(state.showEditorBorder and "Editor border shown" or "Editor border hidden", 2)
			end

	local function toggleStatusBar()
		state.showStatusBar = not state.showStatusBar
		if not state.showStatusBar and state.diagnosticsExpanded then
			state.diagnosticsExpanded = false
		end
		layoutEditorAndDiagnostics()
		updateStatus()
		showStatusMessage(state.showStatusBar and "Status bar shown" or "Status bar hidden", 2)
	end

	local function toggleAutocomplete()
		state.autocompleteEnabled = not state.autocompleteEnabled
		editor.autocompleteAuto = state.autocompleteEnabled
		if splitEditor then
			splitEditor.autocompleteAuto = state.autocompleteEnabled
		end
		showStatusMessage(state.autocompleteEnabled and "Autocomplete enabled" or "Autocomplete disabled", 2)
	end

	local function clearRecentFiles()
		state.recentFiles = {}
		showStatusMessage("Recent files cleared", 2)
	end

	local function revertToSaved()
		if state.savedText == nil then
			return
		end
		editor:setText(state.savedText, true)
		editor:_moveCursorToIndex(1)
		if state.splitActive and splitEditor then
			splitEditor:_setTextInternal(state.savedText, false, true)
			splitEditor:_moveCursorToIndex(1)
		end
		state.dirty = false
		state.message = nil
		scheduleDiagnosticsUpdate()
		showStatusMessage("Reverted to saved", 2)
		updateStatus()
	end

	local function runCurrentFile()
		if hasUnsavedChanges() then
			showStatusMessage("Save changes before running", 3)
			saveCurrentFile(function(saved)
				if saved then
					runCurrentFile()
				end
			end)
			return
		end
		if not state.path then
			showStatusMessage("Save file before running", 3)
			saveCurrentFile(function(saved)
				if saved then
					runCurrentFile()
				end
			end)
			return
		end
		if not shell or not shell.run then
			showError("Run Failed", "Shell API unavailable")
			return
		end
		local ok, err = pcall(function()
			shell.run(state.path)
		end)
		if not ok then
			showError("Run Failed", tostring(err))
		else
			showStatusMessage("Program finished", 3)
		end
		app:setFocus(editor)
	end

	local function requestExit()
		local function processNextBuffer()
			syncStateToBuffer(state.activeBuffer)
			local nextIndex
			for i, buffer in ipairs(state.buffers) do
				if buffer.dirty then
					nextIndex = i
					break
				end
			end
			if not nextIndex then
				if not hasUnsavedChanges() then
					app:stop()
				end
				return
			end
			local function handleActiveBuffer()
				local function continueExit()
					state.dirty = false
					local active = state.activeBuffer
					if active then
						active.dirty = false
						refreshTabLabel(state.activeBufferIndex)
					end
					processNextBuffer()
				end
				if hasUnsavedChanges() then
					confirmUnsaved(function()
						continueExit()
					end)
				else
					continueExit()
				end
			end
			if state.activeBufferIndex ~= nextIndex then
				requestBufferActivation(nextIndex, function()
					handleActiveBuffer()
				end)
			else
				handleActiveBuffer()
			end
		end
		processNextBuffer()
	end

	local function buildFileMenuItems()
		local items = {
			{ label = "Home", onSelect = function()
				showHomeScreen()
			end },
			"-",
			{ label = "New", onSelect = function()
				newUntitled()
			end },
			{ label = "Open...", onSelect = function()
				openFileWorkflow()
			end },
			{ label = "Save", onSelect = function()
				saveCurrentFile()
			end },
			{ label = "Save As...", onSelect = function()
				saveAs()
			end },
			"-"
		}
		if state.dirty then
			items[#items + 1] = { label = "Revert to Saved", onSelect = function()
				revertToSaved()
			end }
		end
		if #state.recentFiles > 0 then
			local recent = {}
			for i = 1, #state.recentFiles do
				local path = state.recentFiles[i]
				recent[#recent + 1] = {
					label = truncate(path, 32),
					onSelect = function()
						confirmUnsaved(function()
							loadFile(path)
						end)
					end
				}
			end
			items[#items + 1] = { label = "Recent Files", submenu = recent }
			items[#items + 1] = { label = "Clear Recent", onSelect = function()
				clearRecentFiles()
			end }
		end
		items[#items + 1] = "-"
		items[#items + 1] = { label = "Exit", onSelect = function()
			requestExit()
		end }
		return items
	end

	local function toggleSplitView()
		state.splitActive = not state.splitActive
		if state.splitActive then
			-- Initialize split editor with current buffer text
			if splitEditor then
				local text = editor:getText() or ""
				splitEditor:setText(text, true)
				local buffer = state.activeBuffer
				if buffer then
					local sLines = split_lines(text)
					local sCursorIndex = line_col_to_index(sLines, buffer.splitCursorLine or 1, buffer.splitCursorCol or 1)
					splitEditor:_moveCursorToIndex(sCursorIndex)
				end
				splitEditor.visible = true
				if splitDivider then splitDivider.visible = true end
				applyEditorBorder()
			end
			showStatusMessage("Split view enabled", 2)
		else
			state.activePaneIndex = 1
			if splitEditor then splitEditor.visible = false end
			if splitDivider then splitDivider.visible = false end
			app:setFocus(editor)
			showStatusMessage("Split view disabled", 2)
		end
		layoutEditorAndDiagnostics()
	end

	local function switchSplitDirection()
		if not state.splitActive then return end
		if state.splitDirection == "horizontal" then
			state.splitDirection = "vertical"
			showStatusMessage("Split: left/right", 2)
		else
			state.splitDirection = "horizontal"
			showStatusMessage("Split: top/bottom", 2)
		end
		layoutEditorAndDiagnostics()
	end

	local function focusSplitPane(paneIndex)
		if not state.splitActive then return end
		if paneIndex == 2 and splitEditor then
			state.activePaneIndex = 2
			app:setFocus(splitEditor)
			local sLine, sCol = splitEditor:getCursorPosition()
			state.cursorLine = sLine or 1
			state.cursorCol = sCol or 1
		else
			state.activePaneIndex = 1
			app:setFocus(editor)
			local pLine, pCol = editor:getCursorPosition()
			state.cursorLine = pLine or 1
			state.cursorCol = pCol or 1
		end
		updateStatus()
	end

	local function buildViewMenuItems()
		local items = {
			{ label = state.showStatusBar and "Hide Status Bar" or "Show Status Bar", onSelect = function()
				toggleStatusBar()
			end },
			{ label = state.showEditorBorder and "Hide Editor Border" or "Show Editor Border", onSelect = function()
				toggleEditorBorder()
			end },
			"-",
			{ label = state.splitActive and "Close Split View" or "Split Editor", onSelect = function()
				toggleSplitView()
			end }
		}
		if state.splitActive then
			items[#items + 1] = { label = state.splitDirection == "horizontal" and "Split Left/Right" or "Split Top/Bottom", onSelect = function()
				switchSplitDirection()
			end }
			items[#items + 1] = { label = "Switch Pane", onSelect = function()
				focusSplitPane(state.activePaneIndex == 1 and 2 or 1)
			end }
		end
		return items
	end

	local function buildEditMenuItems()
		return {
			{ label = "Trim Trailing Whitespace", onSelect = function()
				trimTrailingWhitespace()
			end },
			{ label = "Duplicate Line", onSelect = function()
				duplicateCurrentLine()
			end },
			{ label = "Go To Line...", onSelect = function()
				promptGoToLine()
			end },
			{ label = "Revert to Saved", onSelect = function()
				revertToSaved()
			end }
		}
	end

	local function buildSettingsMenuItems()
		return {
			{ label = state.autocompleteEnabled and "Disable Autocomplete" or "Enable Autocomplete", onSelect = function()
				toggleAutocomplete()
			end },
			{ label = "Set Tab Size...", onSelect = function()
				applyTabSize()
			end }
		}
	end

	local activeMenu
	local activeMenuButton

	local function setMenuButtonHighlight(button, highlighted)
		if not button then
			return
		end
		if not button._ccideNormalFg then
			button._ccideNormalFg = button.fg or colors.white
		end
		if highlighted then
			button.fg = colors.yellow
		else
			button.fg = button._ccideNormalFg
		end
		if button.invalidate then
			button:invalidate()
		end
	end

	local function decorateContextMenu(menu)
		if not menu or menu._ccideDecorated then
			return
		end
		menu._ccideDecorated = true
		local originalClose = menu.close
		menu.close = function(self, ...)
			local result = originalClose(self, ...)
			if activeMenu == self then
				setMenuButtonHighlight(activeMenuButton, false)
				activeMenu = nil
				activeMenuButton = nil
			end
			return result
		end
	end

	local function openMenu(menu, anchorWidget, items)
		if not menu or not anchorWidget then
			return
		end
		decorateContextMenu(menu)
		if activeMenu and activeMenu ~= menu and activeMenu:isOpen() then
			activeMenu:close()
		end
		if menu:isOpen() then
			menu:close()
			return
		end
		local ax, ay, aw, ah = anchorWidget:getAbsoluteRect()
		activeMenu = menu
		activeMenuButton = anchorWidget
		setMenuButtonHighlight(anchorWidget, true)
		local success = menu:open(ax, ay + ah + 1, { items = items })
		if not success then
			if activeMenu == menu then
				activeMenu = nil
				activeMenuButton = nil
			end
			setMenuButtonHighlight(anchorWidget, false)
		end
	end

	local fileMenu = app:createContextMenu({})
	local editMenu = app:createContextMenu({})
	local viewMenu = app:createContextMenu({})
	local settingsMenu = app:createContextMenu({})

	root:addChild(fileMenu)
	root:addChild(editMenu)
	root:addChild(viewMenu)
	root:addChild(settingsMenu)

	local topButtons = {}

	local function menuButtonWidth(label, minimum)
		local width = (#label) + 2
		if minimum and width < minimum then
			width = minimum
		end
		if width < 3 then
			width = 3
		end
		return math.min(width, rootWidth)
	end
	local buttonLayout = {
		{ id = "file", label = "File", width = menuButtonWidth("File", 5), action = function(button)
			openMenu(fileMenu, button, buildFileMenuItems())
		end },
		{ id = "edit", label = "Edit", width = menuButtonWidth("Edit", 5), action = function(button)
			openMenu(editMenu, button, buildEditMenuItems())
		end },
		{ id = "view", label = "View", width = menuButtonWidth("View", 5), action = function(button)
			openMenu(viewMenu, button, buildViewMenuItems())
		end },
		{ id = "settings", label = "Settings", width = menuButtonWidth("Settings", 9), action = function(button)
			openMenu(settingsMenu, button, buildSettingsMenuItems())
		end },
		{ id = "icons", label = "\2", width = menuButtonWidth("\2", 3), action = function()
			showIconPicker()
		end },
		{ id = "run", label = "Run", width = menuButtonWidth("Run", 4), action = function()
			runCurrentFile()
		end },
		{ id = "help", label = "? Help", width = menuButtonWidth("? Help", 7), action = function()
			showHelpDialog()
		end },
		{ id = "exit", label = "Exit", width = menuButtonWidth("Exit", 5), action = function()
			requestExit()
		end }
	}
	decorateContextMenu(fileMenu)
	decorateContextMenu(editMenu)
	decorateContextMenu(viewMenu)
	decorateContextMenu(settingsMenu)

	local buttonX = 1
	for _, spec in ipairs(buttonLayout) do
		local button = app:createButton({
			x = buttonX,
			y = 1,
			width = spec.width,
			height = 1,
			label = spec.label,
			bg = colors.blue,
			fg = colors.white
		})
		button.onClick = function()
			spec.action(button)
		end
		root:addChild(button)
		topButtons[spec.id] = button
		buttonX = buttonX + spec.width + 1
		if buttonX > rootWidth then
			break
		end
	end

	updateMainVisibility = function()
		local hasBuffers = #state.buffers > 0
		local showMain = not state.showHomeScreen and hasBuffers
		editor.visible = showMain
		statusLabel.visible = showMain and state.showStatusBar
		if diagnosticsToggleButton then
			diagnosticsToggleButton.visible = showMain and state.showStatusBar and diagnosticsPanelHeight > 0
		end
		if diagnosticsPanel then
			diagnosticsPanel.visible = showMain and state.diagnosticsExpanded
		end
		if splitEditor then
			splitEditor.visible = showMain and state.splitActive
		end
		if splitDivider then
			splitDivider.visible = showMain and state.splitActive
		end
		for _, button in pairs(topButtons or {}) do
			if button and button.visible ~= nil then
				button.visible = showMain
			end
		end
		if menuBar then
			menuBar.visible = showMain
		end
		if tabControl then
			tabControl.visible = showMain
		end
		if homeFrame then
			local showHome = state.showHomeScreen or not hasBuffers
			homeFrame.visible = showHome
			if showHome then
				updateHomeScreenLayout()
				refreshHomeScreen()
				app:setFocus(newFileButton)
			end
		end
	end

	-- Initialize home screen visibility
	updateMainVisibility()	-- Set up home screen button callbacks
	if newFileButton then
		newFileButton.onClick = function()
			hideHomeScreen()
			newUntitled()
		end
	end

	if openFileButton then
		openFileButton.onClick = function()
			hideHomeScreen()
			openFileWorkflow()
		end
	end

	if recentList then
		recentList:setOnSelect(function(_, _, index)
			if not index or index < 1 or index > #state.recentFiles then
				return
			end
			local path = state.recentFiles[index]
			if not path then
				return
			end
			hideHomeScreen()
			confirmUnsaved(function()
				loadFile(path)
			end)
		end)
	end

	editor:setOnChange(function(_, text)
		updateDirtyState(text or "")
		if text and text ~= "" and state.showHomeScreen then
			hideHomeScreen()
		end
		-- Sync text to split editor (preserve split cursor)
		if state.splitActive and splitEditor then
			splitEditor:_setTextInternal(text or "", false, true)
		end
		updateStatus()
		scheduleDiagnosticsUpdate()
	end)

	editor:setOnCursorMove(function(_, line, col, selectionLength)
		local buffer = state.activeBuffer
		if buffer then
			buffer.cursorLine = line or 1
			buffer.cursorCol = col or 1
			buffer.selectionLength = selectionLength or 0
		end
		-- Only update status bar cursor info if this pane has focus
		if not state.splitActive or app:getFocus() == editor then
			state.activePaneIndex = 1
			state.cursorLine = line or state.cursorLine or 1
			state.cursorCol = col or state.cursorCol or 1
			state.selectionLength = selectionLength or 0
			updateStatus()
		end
	end)

	-- Split editor event handlers
	splitEditor:setOnChange(function(_, text)
		-- Sync text back to primary editor (preserve primary cursor)
		if editor then
			editor:_setTextInternal(text or "", false, true)
		end
		updateDirtyState(text or "")
		if text and text ~= "" and state.showHomeScreen then
			hideHomeScreen()
		end
		updateStatus()
		scheduleDiagnosticsUpdate()
	end)

	splitEditor:setOnCursorMove(function(_, line, col, selectionLength)
		local buffer = state.activeBuffer
		if buffer then
			buffer.splitCursorLine = line or 1
			buffer.splitCursorCol = col or 1
			buffer.splitSelectionLength = selectionLength or 0
		end
		if app:getFocus() == splitEditor then
			state.activePaneIndex = 2
			state.cursorLine = line or 1
			state.cursorCol = col or 1
			state.selectionLength = selectionLength or 0
			updateStatus()
		end
	end)

	local function initializeFromArgs()
		if args and #args > 0 and args[1] then
			if not loadFile(args[1]) then
				local pending = normalize_path(args[1])
				local displayName = pending and fs.getName(pending) or (state.displayName or "Untitled-1")
				prepareEmptyBuffer(displayName, pending)
				local buffer = state.activeBuffer
				if buffer then
					buffer.displayName = displayName
					buffer.pendingPath = pending
					syncBufferToState(buffer)
					refreshTabLabel(state.activeBufferIndex)
				end
				if not pending then
					showHomeScreen()
				else
					hideHomeScreen()
				end
			else
				-- File was loaded successfully, don't show home screen
				state.showHomeScreen = false
			end
		else
			prepareEmptyBuffer(state.displayName or "Untitled-1", nil)
			-- Show home screen for empty untitled files with no arguments
			showHomeScreen()
		end
	end

	initializeFromArgs()
	updateStatus()
	updateMainVisibility()
	if state.showHomeScreen then
		app:setFocus(newFileButton)
	else
		app:setFocus(editor)
	end
	
	-- Set up resize handler for responsive layout
	root:setOnSizeChange(function(_, newWidth, newHeight)
		rootWidth = newWidth
		rootHeight = newHeight
		statusBarY = newHeight
		editorHeight = math.max(1, rootHeight - getEditorTopY() - 1)
		if menuBar then
			menuBar:setSize(rootWidth, 1)
		end
		if tabControl then
			tabControl:setPosition(1, TAB_CONTROL_Y)
			tabControl:setSize(rootWidth, TAB_CONTROL_HEIGHT)
		end
		if statusLabel then
			statusLabel:setPosition(1, statusBarY)
			statusLabel:setSize(math.max(1, rootWidth - 1), 1)
		end
		if diagnosticsToggleButton and statusLabel then
			diagnosticsToggleButton:setPosition(statusLabel.x + statusLabel.width, statusBarY)
		end
		maxDiagHeight = math.max(0, rootHeight - getEditorTopY() - 1)
		diagnosticsPanelHeight = math.min(5, maxDiagHeight)
		updateHomeScreenLayout()
		layoutEditorAndDiagnostics()
		refreshHomeScreen()
		updateStatus()
		if app and app.render then
			app:render()
		end
	end)
	
	app:run()

	if app.destroy then
		app:destroy()
	end

