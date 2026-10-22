--[[
CE Process Blacklist Manager v1.4.1 (CE 7.x)
Target: Cheat Engine 7.x (Windows)

v1.4 architecture:
- Keep the executable blacklist in autorun\CEProcessBlacklist.txt.
- Mirror executable names into CE's native commonProcessesList.txt so the
  Processes tab keeps CE's native no-flash filtering.
- Applications / Windows use a ONE-SHOT PID -> EXE filter. The filter runs
  only after the visible list actually changes (tab switch / refresh / show),
  not continuously.
- The lightweight watcher only reads tab/list state. It does NOT enumerate
  processes/windows unless a list change is detected.
- After blacklist edits, refresh the currently open process picker once and
  immediately apply the one-shot filter.

v1.4 CE 7.x change:
The legacy watcher described above has been removed from this file. CE 7.x
uses form-show, tab-change and manual-refresh events only; it never polls
process windows in the background.
]]

-- Stop older test versions when manually reloading in the same CE session.
local function stopOldVersion(globalName)
  local old = rawget(_G, globalName)
  if not old then return end
  pcall(function()
    if old.timer then
      old.timer.Enabled = false
      old.timer.destroy()
      old.timer = nil
    end
  end)
  pcall(function()
    if old.formNotification and type(unregisterFormAddNotification) == 'function' then
      unregisterFormAddNotification(old.formNotification)
      old.formNotification = nil
    end
  end)
  pcall(function()
    if old.attached then
      for _, a in pairs(old.attached) do
        if a and a.button then a.button.destroy() end
      end
    end
  end)
  pcall(function()
    if old.manager and old.manager.form then old.manager.form.destroy() end
  end)
end

for _, n in ipairs({
  'CEProcessBlacklistManager',
  'CEProcessBlacklistManagerV02',
  'CEProcessBlacklistManagerV03',
  'CEProcessBlacklistManagerV04',
  'CEProcessBlacklistManagerV05',
  'CEProcessBlacklistManagerV06',
  'CEProcessBlacklistManagerV07',
  'CEProcessBlacklistManagerV08',
  'CEProcessBlacklistManagerV09',
  'CEProcessBlacklistManagerV10',
  'CEProcessBlacklistManagerV11',
  'CEProcessBlacklistManagerV12',
  'CEProcessBlacklistManagerV13',
  'CEProcessBlacklistManagerV14',
}) do
  stopOldVersion(n)
end

if rawget(_G, 'CEProcessBlacklistManagerV15') then return end

local M = {
  version = '1.4.1',
  timer = nil,
  pendingForms = {},
  manager = nil,
  attached = {},
  lastWindow = nil,
  formNotification = nil,
  hookSeq = 0,
}
CEProcessBlacklistManagerV15 = M

local function trim(s)
  if s == nil then return '' end
  return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function lower(s)
  return string.lower(trim(s))
end

local function ensureSlash(path)
  path = tostring(path or '')
  if path ~= '' and path:sub(-1) ~= '\\' and path:sub(-1) ~= '/' then
    path = path .. '\\'
  end
  return path
end

local ceDir = ensureSlash(getCheatEngineDir())
local autorunDir = ceDir .. 'autorun\\'
if type(getAutorunPath) == 'function' then
  local ok, p = pcall(getAutorunPath)
  if ok and p and p ~= '' then autorunDir = ensureSlash(p) end
end

M.listPath = autorunDir .. 'CEProcessBlacklist.txt'
M.nativePath = ceDir .. 'commonProcessesList.txt'
M.errorLogPath = autorunDir .. 'CEProcessBlacklist_error.log'

local MANAGED_BEGIN = '# >>> CE Process Blacklist Manager BEGIN >>>'
local MANAGED_END   = '# <<< CE Process Blacklist Manager END <<<'
local MANAGED_TAG   = '# CEProcessBlacklistManager'
M.nativeBackupPath = M.nativePath .. '.cepb.bak'

local function backupNativeCommonListOnce()
  local exists = io.open(M.nativeBackupPath, 'rb')
  if exists then exists:close(); return true end
  local src = io.open(M.nativePath, 'rb')
  if not src then return true end
  local data = src:read('*a') or ''
  src:close()
  local dst = io.open(M.nativeBackupPath, 'wb')
  if not dst then return false end
  dst:write(data)
  dst:close()
  return true
end

local function writeErrorLog(text)
  local f = io.open(M.errorLogPath, 'ab')
  if f then
    f:write(os.date('%Y-%m-%d %H:%M:%S'), '  ', tostring(text), '\r\n')
    f:close()
  end
end

local function parseEntry(line)
  local s = trim(line)
  if s == '' or s:sub(1, 1) == '#' then return '' end
  local p = s:find('#', 1, true)
  if p then s = trim(s:sub(1, p - 1)) end
  return trim(s)
end

local function readRawLines(path)
  local lines = {}
  local f = io.open(path, 'rb')
  if not f then return lines end
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

local function ensureBlacklistFile()
  local f = io.open(M.listPath, 'rb')
  if f then f:close(); return true end
  f = io.open(M.listPath, 'wb')
  if not f then return false end
  f:write('# CE Process Blacklist Manager\r\n')
  f:write('# One executable image name per line.\r\n')
  f:close()
  return true
end

local function readBlacklist()
  local names, set = {}, {}
  local lines = readRawLines(M.listPath)
  for i = 1, #lines do
    local name = parseEntry(lines[i])
    local key = lower(name)
    if key ~= '' and not set[key] then
      set[key] = true
      names[#names + 1] = name
    end
  end
  table.sort(names, function(a, b) return lower(a) < lower(b) end)
  return names, set
end

local function baseName(name)
  name = trim(name)
  local b = name:match('([^\\/]+)$')
  return trim(b or name)
end

local function addBlacklistMany(items)
  if not ensureBlacklistFile() then return false, 0, '无法创建黑名单文件' end
  local _, set = readBlacklist()
  local toAdd = {}
  for i = 1, #items do
    local name = baseName(items[i])
    local key = lower(name)
    if key ~= '' and not set[key] then
      set[key] = true
      toAdd[#toAdd + 1] = name
    end
  end
  if #toAdd == 0 then return true, 0, nil end

  local f, err = io.open(M.listPath, 'ab')
  if not f then return false, 0, err or '无法写入黑名单文件' end
  for i = 1, #toAdd do f:write(toAdd[i], '\r\n') end
  f:close()
  return true, #toAdd, nil
end

local function removeBlacklist(removeSet)
  local lines = readRawLines(M.listPath)
  local out, removed = {}, 0
  for i = 1, #lines do
    local name = parseEntry(lines[i])
    if name ~= '' and removeSet[lower(name)] then
      removed = removed + 1
    else
      out[#out + 1] = lines[i]
    end
  end

  local f, err = io.open(M.listPath, 'wb')
  if not f then return false, err or '无法写入黑名单文件' end
  for i = 1, #out do f:write(out[i], '\r\n') end
  f:close()
  return true, removed
end

-- Build the native filter payload. v1.3 deliberately mirrors EXE names only.
-- CE's built-in blacklist therefore owns the Processes tab; Applications and
-- Windows are handled by one-shot PID -> EXE filtering at refresh time.
local function collectNativeManagedEntries()
  local blackNames = readBlacklist()
  local out, seen = {}, {}
  for i = 1, #blackNames do
    local name = baseName(blackNames[i])
    local key = lower(name)
    if key ~= '' and not seen[key] and not name:find('#', 1, true) then
      seen[key] = true
      out[#out + 1] = name
    end
  end
  table.sort(out, function(a, b) return lower(a) < lower(b) end)
  return out
end

-- Preserve every user/native line outside our managed block and replace only
-- our own block. CE's built-in filter handles the Processes tab; the other
-- two tabs are handled by the one-shot PID -> EXE filter below.
local function syncNativeCommonList()
  backupNativeCommonListOnce()
  local managed = collectNativeManagedEntries()
  local src = readRawLines(M.nativePath)
  local keep = {}
  local inside = false

  for i = 1, #src do
    local line = tostring(src[i] or '')
    if trim(line) == MANAGED_BEGIN then
      inside = true
    elseif trim(line) == MANAGED_END then
      inside = false
    elseif not inside then
      -- Also remove old per-line entries from early plugin test versions.
      if not line:find('# CEProcessBlacklist', 1, true) then
        keep[#keep + 1] = line
      end
    end
  end

  while #keep > 0 and trim(keep[#keep]) == '' do table.remove(keep) end

  local parts = {}
  for i = 1, #keep do parts[#parts + 1] = keep[i] end
  if #keep > 0 then parts[#parts + 1] = '' end
  parts[#parts + 1] = MANAGED_BEGIN
  for i = 1, #managed do
    parts[#parts + 1] = managed[i] .. ' ' .. MANAGED_TAG
  end
  parts[#parts + 1] = MANAGED_END
  local newData = table.concat(parts, '\r\n') .. '\r\n'

  local oldData = ''
  local old = io.open(M.nativePath, 'rb')
  if old then oldData = old:read('*a') or ''; old:close() end
  if oldData == newData then return true end

  local f, err = io.open(M.nativePath, 'wb')
  if not f then return false, err or '无法写入 commonProcessesList.txt' end
  f:write(newData)
  f:close()
  return true
end

local function buildPidNameMap()
  local map = {}

  -- Prefer the StringList overload on CE 6.7. Its documented format is
  -- XXXXXXXX-process.exe, so the PID base is unambiguous (hexadecimal).
  -- This avoids relying on how an older CE build represents table keys.
  local maker = rawget(_G, 'createStringlist')
  if type(maker) == 'function' then
    local okSl, sl = pcall(maker)
    if okSl and sl then
      local okFill = pcall(function() getProcesslist(sl) end)
      if okFill then
        local count = 0
        pcall(function() count = sl.Count end)
        for i = 0, (count or 0) - 1 do
          local row = ''
          pcall(function() row = tostring(sl[i] or '') end)
          local hex, name = row:match('^%s*([0-9A-Fa-f]+)%-(.+)$')
          if hex and name then
            local pid = tonumber(hex, 16)
            if pid then map[pid] = trim(name) end
          end
        end
      end
      pcall(function() sl.destroy() end)
      if next(map) ~= nil then return map end
    end
  end

  -- Fallback for newer builds: getProcesslist() returns a PID -> name table.
  local ok, plist = pcall(function() return getProcesslist() end)
  if ok and type(plist) == 'table' then
    for pid, name in pairs(plist) do
      if name then
        if type(pid) == 'number' then
          map[pid] = trim(name)
        else
          local ps = trim(pid)
          local n10 = tonumber(ps)
          local n16 = tonumber(ps, 16)
          if n10 then map[n10] = trim(name) end
          -- Also map the hexadecimal interpretation for compatibility with
          -- builds/scripts that expose zero-padded hexadecimal string keys.
          if n16 then map[n16] = trim(name) end
        end
      end
    end
  end
  return map
end

local function getRunningExeNames()
  local pidMap = buildPidNameMap()
  local names, seen = {}, {}
  for _, rawName in pairs(pidMap) do
    local name = baseName(rawName)
    local key = lower(name)
    if key ~= '' and not seen[key] then
      seen[key] = true
      names[#names + 1] = name
    end
  end
  table.sort(names, function(a, b) return lower(a) < lower(b) end)
  return names
end

local function isProcessWindow(f)
  if not f then return false end
  local cn = ''
  local ok = pcall(function() cn = f.ClassName or '' end)
  return ok and cn == 'TProcessWindow'
end

local function componentCount(owner)
  local c = 0
  if not owner then return 0 end
  pcall(function() c = owner.ComponentCount end)
  return c or 0
end

local function findOwnedComponent(owner, wantedName)
  if not owner then return nil end
  local count = componentCount(owner)
  for i = 0, count - 1 do
    local c = nil
    pcall(function() c = owner.Component[i] end)
    if c then
      local name = ''
      pcall(function() name = c.Name or '' end)
      if name == wantedName then return c end
      local nested = findOwnedComponent(c, wantedName)
      if nested then return nested end
    end
  end
  return nil
end

local function destroyOldControls(owner)
  if not owner then return end
  local targets = { CEPBM_BottomPanel = true, CEPBM_Quick = true, CEPBM_Manage = true }
  local count = componentCount(owner)
  for i = count - 1, 0, -1 do
    local c = nil
    pcall(function() c = owner.Component[i] end)
    if c then
      local name = ''
      pcall(function() name = c.Name or '' end)
      if targets[name] then
        pcall(function() c.destroy() end)
      else
        destroyOldControls(c)
      end
    end
  end
end

local function getProcessListControl(f)
  return findOwnedComponent(f, 'ProcessList')
end

local WM_SETREDRAW = 0x000B
local function setListRedraw(pl, enabled)
  if not pl then return false end
  local h = 0
  pcall(function() h = pl.Handle or 0 end)
  if h and h ~= 0 and type(sendMessage) == 'function' then
    local ok = pcall(function() sendMessage(h, WM_SETREDRAW, enabled and 1 or 0, 0) end)
    if ok then return true end
  end
  return false
end

local function repaintList(pl)
  if not pl then return end
  pcall(function() pl.repaint() end)
  pcall(function() pl.refresh() end)
end

local function getEventHandler(obj, propertyName)
  if not obj then return nil end
  if type(getMethodProperty) == 'function' then
    local h = nil
    local ok = pcall(function() h = getMethodProperty(obj, propertyName) end)
    if ok and type(h) == 'function' then return h end
  end
  local h = nil
  local ok = pcall(function() h = obj[propertyName] end)
  if ok and type(h) == 'function' then return h end
  return nil
end

local function callHandler(h, sender)
  if type(h) ~= 'function' then return false end
  local ok = pcall(h, sender)
  if ok then return true end
  return pcall(h)
end

-- CE loads commonProcessesList.txt in TProcessWindow.FormShow and then invokes
-- its own RefreshList. Calling the original OnShow method directly lets an
-- already-open picker reload our updated native blacklist without closing it.
local function reloadNativeListInOpenWindow(f)
  if not isProcessWindow(f) then return false end
  local pl = getProcessListControl(f)
  local frozen = setListRedraw(pl, false)
  if not frozen and pl then pcall(function() pl.Items.beginUpdate() end) end

  local h = getEventHandler(f, 'OnShow')
  local ok = callHandler(h, f)

  if frozen then
    setListRedraw(pl, true)
  elseif pl then
    pcall(function() pl.Items.endUpdate() end)
  end
  repaintList(pl)
  return ok
end

-- CE's native commonProcessesList filter only matches the text after the
-- 8-hex-digit PID prefix.  That is the executable name on Processes, but a
-- window/application caption on the other two tabs.  For Applications and
-- Windows we therefore filter by PID -> executable mapping in the same refresh
-- callback, while painting is frozen, so blocked rows are never intentionally
-- shown as a completed frame.
local function getTabIndex(f)
  local tabs = findOwnedComponent(f, 'TabHeader')
  if not tabs then return -1 end

  local idx = nil
  pcall(function() idx = tabs.TabIndex end)
  if type(idx) == 'number' then return idx end

  pcall(function() idx = tabs.ActivePageIndex end)
  if type(idx) == 'number' then return idx end

  return -1
end

local function getTabKey(f)
  local tabs = findOwnedComponent(f, 'TabHeader')
  if not tabs then return '?' end

  local idx = getTabIndex(f)
  local cap = ''
  pcall(function()
    if tabs.ActivePage then cap = tostring(tabs.ActivePage.Caption or '') end
  end)
  return tostring(idx) .. '|' .. cap
end

local function pidFromProcessRow(row)
  local hex = tostring(row or ''):match('^%s*([0-9A-Fa-f]+)%-')
  if not hex then return nil end
  return tonumber(hex, 16)
end

local function exeNameFromRow(row, pidMap)
  row = tostring(row or '')
  local pid = pidFromProcessRow(row)
  if pid and pidMap and pidMap[pid] then
    return baseName(pidMap[pid]), pid
  end

  -- Processes rows already contain PID-image.exe. This fallback also makes
  -- current-tab filtering useful if a very old CE build cannot return a PID map.
  local right = trim(row:match('^[^%-]+%-(.+)$') or '')
  if lower(right):match('%.exe$') then return baseName(right), pid end
  return nil, pid
end

-- Filter whatever is CURRENTLY visible. Do not gate on TabIndex. CE 6.7 can
-- expose PageControl event/state properties differently, and the previous
-- TabIndex gate was the reason Applications/Windows could silently skip the
-- filter even though the list itself had already switched.
local function applyVisibleBlacklistOnce(f)
  if not isProcessWindow(f) then return 0 end
  local _, blockedSet = readBlacklist()
  if next(blockedSet) == nil then return 0 end

  local pl = getProcessListControl(f)
  if not pl then return 0 end

  local count = 0
  if not pcall(function() count = pl.Items.Count end) then return 0 end

  local removed = 0
  local pidMap = nil
  pcall(function() pl.Items.beginUpdate() end)
  for i = (count or 0) - 1, 0, -1 do
    local row = ''
    pcall(function() row = tostring(pl.Items[i] or '') end)
    -- The Processes tab already carries "PID-executable.exe".  Do not call
    -- getProcesslist() for it: that API is comparatively expensive and used
    -- to make opening the picker slower after it had been opened repeatedly.
    local exe = exeNameFromRow(row, nil)
    if not exe then
      if pidMap == nil then pidMap = buildPidNameMap() end
      exe = exeNameFromRow(row, pidMap)
    end
    if exe and blockedSet[lower(baseName(exe))] then
      local ok = pcall(function() pl.Items.delete(i) end)
      if ok then removed = removed + 1 end
    end
  end
  pcall(function() pl.Items.endUpdate() end)
  return removed
end

local function getMethodHandler(obj, propertyName)
  if not obj then return nil end
  if type(getMethodProperty) == 'function' then
    local h = nil
    local ok = pcall(function() h = getMethodProperty(obj, propertyName) end)
    if ok and type(h) == 'function' then return h end
  end
  local h = nil
  local ok = pcall(function() h = obj[propertyName] end)
  if ok and type(h) == 'function' then return h end
  return nil
end

local function setMethodHandler(obj, propertyName, fn)
  if not obj then return false end
  if type(setMethodProperty) == 'function' then
    local ok = pcall(function() setMethodProperty(obj, propertyName, fn) end)
    if ok then return true end
  end
  return pcall(function() obj[propertyName] = fn end)
end

local function callMethodHandler(fn, sender, ...)
  if type(fn) ~= 'function' then return true end
  local ok, err = pcall(fn, sender, ...)
  if ok then return true end
  ok, err = pcall(fn, ...)
  return ok, err
end

local function makeListSignature(f)
  local pl = getProcessListControl(f)
  if not pl then return getTabKey(f) .. '|no-list' end

  local count = 0
  pcall(function() count = pl.Items.Count end)
  count = tonumber(count) or 0

  local first, middle, last = '', '', ''
  if count > 0 then
    pcall(function() first = tostring(pl.Items[0] or '') end)
    pcall(function() last = tostring(pl.Items[count - 1] or '') end)
    pcall(function() middle = tostring(pl.Items[math.floor((count - 1) / 2)] or '') end)
  end

  return getTabKey(f) .. '|' .. tostring(count) .. '|' .. first .. '|' .. middle .. '|' .. last
end

local function runRefreshWithOneShotFilter(f, original, sender, ...)
  local pl = getProcessListControl(f)
  local frozen = setListRedraw(pl, false)
  local outerUpdate = false
  if (not frozen) and pl then outerUpdate = pcall(function() pl.Items.beginUpdate() end) end

  local ok, err = callMethodHandler(original, sender, ...)
  local okFilter, filterErr = pcall(function() applyVisibleBlacklistOnce(f) end)
  if not okFilter then writeErrorLog('One-shot filter: ' .. tostring(filterErr)) end

  if frozen then
    setListRedraw(pl, true)
  elseif outerUpdate and pl then
    pcall(function() pl.Items.endUpdate() end)
  end
  repaintList(pl)
  return ok, err
end

local function hookRefreshEvent(component, propertyName, f, entry, slot)
  if not component or not entry or entry[slot] then return false end
  local original = getMethodHandler(component, propertyName)
  if type(original) ~= 'function' then return false end

  local busy = false
  local wrapper = function(sender, ...)
    if busy then
      local ok, err = callMethodHandler(original, sender, ...)
      if not ok then writeErrorLog(slot .. ' recursive original: ' .. tostring(err)) end
      return
    end

    busy = true
    local ok, err = runRefreshWithOneShotFilter(f, original, sender, ...)
    entry.lastSignature = makeListSignature(f)
    busy = false
    if not ok then writeErrorLog(slot .. ' original: ' .. tostring(err)) end
  end

  if not setMethodHandler(component, propertyName, wrapper) then return false end
  entry[slot] = {component=component, propertyName=propertyName, original=original, wrapper=wrapper}
  return true
end

local function hookProcessWindowRefresh(f, entry)
  if not f or not entry then return end
  -- In CE 7 the form-show handler is the reliable point at which the native
  -- list has finished being populated.  Filtering here replaces the old
  -- perpetual signature-polling timer.
  hookRefreshEvent(f, 'OnShow', f, entry, 'showHook')

  local tabs = findOwnedComponent(f, 'TabHeader')
  if tabs then hookRefreshEvent(tabs, 'OnChange', f, entry, 'tabChangeHook') end

  local mi = findOwnedComponent(f, 'miRefresh')
  if mi then hookRefreshEvent(mi, 'OnClick', f, entry, 'refreshMenuHook') end
end

local function windowKey(f)
  local h = nil
  pcall(function() h = f.Handle end)
  if h and h ~= 0 then return tostring(h) end
  return tostring(f)
end

local function findCurrentProcessWindow()
  local count = getFormCount()
  local found = nil
  for i = 0, count - 1 do
    local f = getForm(i)
    if isProcessWindow(f) then
      found = f
      local visible = false
      pcall(function() visible = f.Visible end)
      if visible then return f end
    end
  end
  return found
end

local function refreshAfterBlacklistChange()
  local okSync, err = syncNativeCommonList()
  if not okSync then
    writeErrorLog('syncNativeCommonList: ' .. tostring(err))
    return false, err
  end

  local pw = findCurrentProcessWindow()
  if pw then
    local ok = reloadNativeListInOpenWindow(pw)
    -- Even when an older CE build does not expose a hookable OnShow method,
    -- apply the cross-tab filter once to the list that is currently visible.
    pcall(function() applyVisibleBlacklistOnce(pw) end)
    if not ok then
      writeErrorLog('Could not call TProcessWindow.OnShow directly; applied current-tab filter once')
    end
  end
  return true
end

local function positionBlacklistButton(f, b)
  if not f or not b then return false end
  local clientH = 0
  local ok = pcall(function() clientH = f.ClientHeight end)
  if (not ok) or (not clientH) or clientH <= 0 then pcall(function() clientH = f.Height end) end
  if not clientH or clientH <= 0 then return false end

  local bh = 24
  pcall(function() if b.Height and b.Height > 0 then bh = b.Height end end)
  pcall(function()
    b.Left = 6
    b.Top = math.max(0, clientH - bh - 6)
    b.Visible = true
    b.Enabled = true
    b.bringToFront()
  end)
  return true
end

local function makeBlacklistButton(f)
  local b = createButton(f)
  b.Caption = '黑名单...'
  b.Width = 74
  local network = findOwnedComponent(f, 'btnNetwork')
  local h = 24
  if network then pcall(function() if network.Height and network.Height > 0 then h = network.Height end end) end
  b.Height = h
  pcall(function()
    b.Hint = '批量添加/移除进程黑名单'
    b.ShowHint = true
  end)
  positionBlacklistButton(f, b)
  return b
end

local function getSelectedItems(lb)
  local out, seen = {}, {}
  if not lb then return out end
  local count = 0
  pcall(function() count = lb.Items.Count end)
  for i = 0, (count or 0) - 1 do
    local selected = false
    pcall(function() selected = lb.Selected[i] end)
    if selected then
      local s = trim(lb.Items[i])
      local k = lower(s)
      if k ~= '' and not seen[k] then
        seen[k] = true
        out[#out + 1] = s
      end
    end
  end
  if #out == 0 then
    local idx = -1
    pcall(function() idx = lb.ItemIndex end)
    if idx and idx >= 0 then
      local s = trim(lb.Items[idx])
      if s ~= '' then out[#out + 1] = s end
    end
  end
  return out
end

local function selectAll(lb)
  if not lb then return end
  local count = 0
  pcall(function() count = lb.Items.Count end)
  for i = 0, (count or 0) - 1 do pcall(function() lb.Selected[i] = true end) end
end

local function fuzzyMatch(text, query)
  query = lower(query)
  if query == '' then return true end
  text = lower(text)
  for token in query:gmatch('%S+') do
    if not text:find(token, 1, true) then return false end
  end
  return true
end

local function applyManagerSearch(manager)
  if not manager then return end
  local q = ''
  pcall(function() q = manager.search.Text or '' end)

  manager.available.Items.clear()
  for i = 1, #(manager.allAvailable or {}) do
    local name = manager.allAvailable[i]
    if fuzzyMatch(name, q) then manager.available.Items.add(name) end
  end

  manager.blocked.Items.clear()
  for i = 1, #(manager.allBlocked or {}) do
    local name = manager.allBlocked[i]
    if fuzzyMatch(name, q) then manager.blocked.Items.add(name) end
  end

  local suffix = ''
  if trim(q) ~= '' then suffix = '    搜索：' .. trim(q) end
  manager.status.Caption = '未拉黑：' .. tostring(#(manager.allAvailable or {})) ..
                           '（显示 ' .. tostring(manager.available.Items.Count) .. '）' ..
                           '    已拉黑：' .. tostring(#(manager.allBlocked or {})) ..
                           '（显示 ' .. tostring(manager.blocked.Items.Count) .. '）' .. suffix
end

local function refreshManager(manager)
  if not manager then return end
  local blackNames, blackSet = readBlacklist()
  local running = getRunningExeNames()

  manager.allAvailable = {}
  for i = 1, #running do
    if not blackSet[lower(running[i])] then
      manager.allAvailable[#manager.allAvailable + 1] = running[i]
    end
  end
  manager.allBlocked = {}
  for i = 1, #blackNames do manager.allBlocked[#manager.allBlocked + 1] = blackNames[i] end
  applyManagerSearch(manager)
end

local function showManager()
  if M.manager then
    local alive = false
    local ok = pcall(function()
      local h = M.manager.form.Handle
      alive = (h ~= nil and h ~= 0)
    end)
    if ok and alive then
      refreshManager(M.manager)
      M.manager.form.show()
      M.manager.form.bringToFront()
      return
    end
    M.manager = nil
  end

  local f = createForm(false)
  f.Caption = '进程黑名单 - 批量管理'
  f.Width = 700
  f.Height = 470
  pcall(function() f.Position = 'poScreenCenter' end)

  local searchLabel = createLabel(f)
  searchLabel.Left = 12
  searchLabel.Top = 13
  searchLabel.Caption = '模糊搜索：'

  local search = createEdit(f)
  search.Left = 82
  search.Top = 8
  search.Width = 593
  search.Height = 25
  search.Text = ''
  pcall(function()
    search.Hint = '大小写不敏感；包含匹配；空格分隔多个关键词时按 AND 匹配'
    search.ShowHint = true
  end)

  local leftLabel = createLabel(f)
  leftLabel.Left = 12
  leftLabel.Top = 43
  leftLabel.Caption = '当前正在运行且未加入黑名单：'

  local rightLabel = createLabel(f)
  rightLabel.Left = 410
  rightLabel.Top = 43
  rightLabel.Caption = '已拉黑：'

  local available = createListBox(f)
  available.Left = 12
  available.Top = 64
  available.Width = 285
  available.Height = 300
  available.MultiSelect = true

  local blocked = createListBox(f)
  blocked.Left = 410
  blocked.Top = 64
  blocked.Width = 265
  blocked.Height = 300
  blocked.MultiSelect = true

  local btnAdd = createButton(f)
  btnAdd.Left = 310
  btnAdd.Top = 140
  btnAdd.Width = 86
  btnAdd.Height = 30
  btnAdd.Caption = '加入 >>'

  local btnRemove = createButton(f)
  btnRemove.Left = 310
  btnRemove.Top = 184
  btnRemove.Width = 86
  btnRemove.Height = 30
  btnRemove.Caption = '<< 移除'

  local btnSelectAllLeft = createButton(f)
  btnSelectAllLeft.Left = 310
  btnSelectAllLeft.Top = 238
  btnSelectAllLeft.Width = 86
  btnSelectAllLeft.Height = 28
  btnSelectAllLeft.Caption = '全选左侧'

  local btnSelectAllRight = createButton(f)
  btnSelectAllRight.Left = 310
  btnSelectAllRight.Top = 272
  btnSelectAllRight.Width = 86
  btnSelectAllRight.Height = 28
  btnSelectAllRight.Caption = '全选右侧'

  local btnManual = createButton(f)
  btnManual.Left = 12
  btnManual.Top = 375
  btnManual.Width = 100
  btnManual.Height = 28
  btnManual.Caption = '手动添加...'

  local btnRefresh = createButton(f)
  btnRefresh.Left = 120
  btnRefresh.Top = 375
  btnRefresh.Width = 88
  btnRefresh.Height = 28
  btnRefresh.Caption = '刷新进程'

  local btnClose = createButton(f)
  btnClose.Left = 575
  btnClose.Top = 375
  btnClose.Width = 100
  btnClose.Height = 28
  btnClose.Caption = '关闭'

  local status = createLabel(f)
  status.Left = 12
  status.Top = 415
  status.Width = 660
  status.Caption = ''

  local manager = {
    form = f,
    search = search,
    available = available,
    blocked = blocked,
    status = status,
    allAvailable = {},
    allBlocked = {},
  }
  M.manager = manager

  f.OnClose = function(sender)
    if M.manager == manager then M.manager = nil end
    return caFree
  end

  search.OnChange = function()
    local ok, err = pcall(function() applyManagerSearch(manager) end)
    if not ok then writeErrorLog('Search: ' .. tostring(err)) end
  end

  btnAdd.OnClick = function()
    local items = getSelectedItems(available)
    if #items == 0 then
      showMessage('请在左侧选择一个或多个进程。\n可使用 Ctrl / Shift 多选，或点“全选左侧”。')
      return
    end
    local ok, added, err = addBlacklistMany(items)
    if not ok then
      showMessage('加入黑名单失败：\n' .. tostring(err))
      return
    end
    refreshAfterBlacklistChange()
    refreshManager(manager)
    manager.status.Caption = '本次加入 ' .. tostring(added) .. ' 项'
  end

  btnRemove.OnClick = function()
    local items = getSelectedItems(blocked)
    if #items == 0 then
      showMessage('请在右侧选择一个或多个要移除的进程。')
      return
    end
    local removeSet = {}
    for i = 1, #items do removeSet[lower(items[i])] = true end
    local ok, removed = removeBlacklist(removeSet)
    if not ok then
      showMessage('移除失败：\n' .. tostring(removed))
      return
    end
    refreshAfterBlacklistChange()
    refreshManager(manager)
    manager.status.Caption = '本次移除 ' .. tostring(removed) .. ' 项'
  end

  btnSelectAllLeft.OnClick = function() selectAll(available) end
  btnSelectAllRight.OnClick = function() selectAll(blocked) end

  btnManual.OnClick = function()
    local name = inputQuery('添加进程黑名单', '输入进程映像名，例如 chrome.exe：', '')
    if not name then return end
    name = baseName(name)
    if name == '' then return end
    local ok, added, err = addBlacklistMany({name})
    if not ok then
      showMessage('添加失败：\n' .. tostring(err))
      return
    end
    refreshAfterBlacklistChange()
    refreshManager(manager)
    manager.status.Caption = (added > 0) and ('已加入：' .. name) or ('已在黑名单：' .. name)
  end

  btnRefresh.OnClick = function()
    refreshAfterBlacklistChange()
    refreshManager(manager)
    manager.status.Caption = '已重新读取当前运行进程'
  end

  btnClose.OnClick = function() f.close() end
  available.OnDblClick = function() btnAdd.doClick() end
  blocked.OnDblClick = function() btnRemove.doClick() end

  refreshManager(manager)
  f.show()
end

local function attachProcessWindow(f)
  if not isProcessWindow(f) then return end
  local key = windowKey(f)
  M.lastWindow = f

  local entry = M.attached[key]
  if entry then
    entry.form = f
    local b = entry.button
    local ok = false
    if b then
      ok = pcall(function()
        positionBlacklistButton(f, b)
        b.bringToFront()
      end)
    end
    if ok then
      hookProcessWindowRefresh(f, entry)
      if entry.lastSignature == nil then entry.lastSignature = makeListSignature(f) end
      return
    end
    M.attached[key] = nil
  end

  destroyOldControls(f)
  local b = makeBlacklistButton(f)
  if b then
    b.OnClick = function()
      local ok, err = pcall(showManager)
      if not ok then
        writeErrorLog('Blacklist button: ' .. tostring(err))
        pcall(function() showMessage('黑名单窗口打开失败。\n错误已写入：\n' .. M.errorLogPath) end)
      end
    end
  end
  entry = { form = f, button = b, lastSignature = nil }
  M.attached[key] = entry

  -- Use the event hook when CE exposes it. The list-signature fallback below is the compatibility path for CE 6.7 builds where method-property replacement is unreliable.
  hookProcessWindowRefresh(f, entry)
end

-- registerFormAddNotification can fire before CE 7.6 has finished loading
-- the controls from the process-picker form resource.  Adding our button at
-- that instant makes CE overwrite it during the remainder of form creation.
-- Queue a short, bounded readiness check instead of keeping a permanent
-- watcher alive for the whole CE session.
local function isProcessWindowReady(f)
  if not isProcessWindow(f) then return false end
  if not getProcessListControl(f) then return false end
  if not findOwnedComponent(f, 'btnNetwork') then return false end
  local h = 0
  pcall(function() h = f.ClientHeight or 0 end)
  return tonumber(h) ~= nil and tonumber(h) > 0
end

local function finishQueuedProcessWindow(f)
  attachProcessWindow(f)
  local visible = false
  pcall(function() visible = f.Visible end)
  if visible then
    -- The form may already have received OnShow before the deferred attach.
    -- Apply the currently visible page once; later changes use event hooks.
    pcall(function() applyVisibleBlacklistOnce(f) end)
  end
end

local function queueProcessWindowAttach(f)
  if not isProcessWindow(f) then return end

  if isProcessWindowReady(f) then
    finishQueuedProcessWindow(f)
    return
  end

  local key = windowKey(f)
  M.pendingForms[key] = {form = f, tries = 0}

  if not M.timer then
    M.timer = createTimer(getMainForm())
    M.timer.Interval = 150
    M.timer.OnTimer = function()
      for pendingKey, pending in pairs(M.pendingForms) do
        local form = pending and pending.form or nil
        pending.tries = (pending.tries or 0) + 1
        if not form or not isProcessWindow(form) then
          M.pendingForms[pendingKey] = nil
        elseif isProcessWindowReady(form) then
          local ok, err = pcall(function() finishQueuedProcessWindow(form) end)
          if not ok then writeErrorLog('Deferred process window attach: ' .. tostring(err)) end
          M.pendingForms[pendingKey] = nil
        elseif pending.tries >= 20 then
          -- At most three seconds per new window; never turn this into a
          -- session-wide polling loop if CE abandons a half-created form.
          writeErrorLog('Process window did not become ready within 3 seconds')
          M.pendingForms[pendingKey] = nil
        end
      end
      if next(M.pendingForms) == nil and M.timer then M.timer.Enabled = false end
    end
  end
  M.timer.Enabled = true
end

local function scanProcessWindows()
  local count = getFormCount()
  for i = 0, count - 1 do
    local f = getForm(i)
    if isProcessWindow(f) then queueProcessWindowAttach(f) end
  end
end

local function singleShotListFallback()
  -- Cheap state watcher only. No getProcesslist()/getWindowlist() call happens
  -- here unless the visible list has actually changed.
  for _, entry in pairs(M.attached) do
    local f = entry and entry.form or nil
    if f and isProcessWindow(f) then
      local visible = false
      pcall(function() visible = f.Visible end)
      if visible then
        local sig = makeListSignature(f)
        if entry.lastSignature == nil then
          entry.lastSignature = sig
        elseif sig ~= entry.lastSignature then
          local ok, err = pcall(function() applyVisibleBlacklistOnce(f) end)
          if not ok then writeErrorLog('Single-shot list fallback: ' .. tostring(err)) end
          -- Store the POST-filter signature so our own deletion does not trigger
          -- another expensive PID enumeration on the next watcher tick.
          entry.lastSignature = makeListSignature(f)
        end
      end
    end
  end
end

local function init()
  ensureBlacklistFile()
  local okSync, err = syncNativeCommonList()
  if not okSync then writeErrorLog('Initial native sync failed: ' .. tostring(err)) end

  if type(registerFormAddNotification) == 'function' then
    local okNotify, obj = pcall(function()
      return registerFormAddNotification(function(form)
        local ok, e = pcall(function()
          if isProcessWindow(form) then queueProcessWindowAttach(form) end
        end)
        if not ok then writeErrorLog('FormAddNotification: ' .. tostring(e)) end
      end)
    end)
    if okNotify then M.formNotification = obj end
  end

  -- Catch a picker that happened to be open while this autorun script loaded.
  -- This scan runs once only. Subsequent pickers are handled by CE's form-add
  -- notification and their own show/tab/refresh events.
  scanProcessWindows()
end

local ok, err = pcall(init)
if not ok then writeErrorLog('Init: ' .. tostring(err)) end
