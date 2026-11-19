-- Rex config. Docs: https://www.superlogical.com/rex/docs/customize/config

local terminal = "com.superlogical.terminal"
local helix = "/etc/profiles/per-user/jason/bin/hx"

-- Lines of scrollback to open, matching the old tmux history-limit.
local scrollback_lines = 10000

-- format returns at most 960 KiB per reply; read the rest with blob_read.
local function read_scrollback(block_id)
  local r, err = rex.block.call(terminal, "format", {
    block_id = block_id,
    unwrap = true,
    trim = true,
    max_bytes = 983040,
  })
  if not r then return nil, err end
  local parts = { r.content }
  local offset = #r.content
  while r.id do
    local id = r.id
    r, err = rex.block.call(terminal, "blob_read", {
      block_id = block_id,
      id = id,
      offset = offset,
      max_bytes = 983040,
    })
    if not r then return nil, err end
    parts[#parts + 1] = r.data
    offset = offset + #r.data
    r.id = (not r.eof) and id or nil
  end
  return table.concat(parts)
end

-- Copy mode stand-in: open the focused pane's scrollback in Helix in a
-- floating layer. Select and yank there; quitting Helix closes the layer.
rex.action{
  name = "scrollback_edit",
  title = "Open Scrollback in Helix",
  keywords = "copy mode scrollback editor",
  run = function(ctx)
    local text, err = read_scrollback(ctx.block_id)
    if not text then error("couldn't read scrollback: " .. tostring(err)) end

    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    local first = math.max(1, #lines - scrollback_lines + 1)

    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write(table.concat(lines, "\n", first), "\n")
    f:close()

    -- Open with the cursor on the last line, and delete the file after.
    local last = #lines - first + 1
    local _, layer_err = rex.session.new_layer{
      session_id = ctx.session_id,
      bounds = { 0.03, 0.03, 0.94, 0.94 },
      focus = true,
      layout = rex.layout.block{
        flavor = "com.superlogical.terminal.shell",
        options = {
          shell = "none",
          command = {
            "/bin/sh", "-c", '"$0" "$1:$2"; rm -f "$1"',
            helix, path, tostring(last),
          },
        },
      },
    }
    if layer_err then
      os.remove(path)
      error("couldn't open Helix: " .. tostring(layer_err))
    end
  end,
}

-- Modes. Prefix is backtick, as in tmux: a lowercase letter enters a mode that
-- stays on, the uppercase letter enters it for one action. Backtick twice
-- types a backtick. Movement is Dvorak h t n s
-- (left, down, up, right). Enter leaves every mode; Escape steps back one.

local prefix = "`"
rex.bind(prefix .. ">" .. prefix, "pane.send_key", { key = prefix })

local function mode(name, key)
  rex.mode(name, { exclusive = true })
  rex.bind(prefix .. ">" .. key, "client.mode.enter", { name = name })
  rex.bind(prefix .. ">shift+" .. key, "client.mode.enter", { name = name, once = true })
  rex.bind(name .. "/enter", "client.mode.exit_all")
end

local dirs = { h = "left", t = "down", n = "up", s = "right" }

-- Pane focus without entering a mode. Takes cmd+shift+n from New Session.
for key, dir in pairs(dirs) do
  rex.bind("cmd+shift+" .. key, "pane.focus." .. dir)
end

-- Pane
mode("pane", "s")
for key, dir in pairs(dirs) do
  rex.bind("pane/" .. key, "pane.focus." .. dir)
  rex.bind("pane/shift+" .. key, "pane.move." .. dir)
end
rex.bind("pane/r", "client.mode.enter", { name = "resize" })
rex.bind("pane/z", "pane.zoom")
rex.bind("pane/=", "pane.balance")
rex.bind("pane/a", "pane.split.right")
rex.bind("pane/shift+a", "pane.split.down")
rex.bind("pane/x", "pane.close")
rex.bind("pane/f", "pane.float")
rex.bind("pane/b", "pane.move_to_new_tab")
rex.bind("pane/j", "pane.move_to_tab")

-- Resize, entered from pane mode with r. Escape goes back to pane mode.
rex.mode("resize", { exclusive = true })
for key, dir in pairs(dirs) do
  rex.bind("resize/" .. key, "pane.resize", { direction = dir })
  rex.bind("resize/shift+" .. key, "pane.resize", { direction = dir, amount = 15 })
end
rex.bind("resize/=", "pane.balance")
rex.bind("resize/enter", "client.mode.exit_all")

-- Tab
mode("tab", "t")
rex.bind("tab/t", "client.tab.new")
rex.bind("tab/n", "client.tab.rename")
rex.bind("tab/h", "step", { action = "client.tab.previous" })
rex.bind("tab/s", "step", { action = "client.tab.next" })
rex.bind("tab/shift+h", "client.tab.move.backward")
rex.bind("tab/shift+s", "client.tab.move.forward")

-- Last place, like a quick cmd+tab. Tabs and sessions passed through in a
-- burst of presses (less than settle_seconds apart) don't count; where the
-- burst started does. last_place flips back to it. A tab reached by mouse or
-- the session picker isn't seen until the next step or flip. With no place
-- to go back to, or when that tab was closed, last_place walks right instead.
-- os.clock() reads wall time in Rex, and rex.after is missing in this file.
local settle_seconds = 0.6
local place = { last = nil, before = nil, pressed = nil, walking = false }

-- The app's current tab is the one holding the pane the key was pressed in.
-- The session's active_window_id doesn't follow the app's tab changes.
-- Returns the place, the session's tabs, and the place's index among them.
local function find_place(session_id, block_id, window_id)
  local view = rex.session.view{ session_id = session_id }
  if not view then return nil end
  for i, w in ipairs(view.windows) do
    if w.window_id == window_id then
      return { session_id = session_id, window_id = w.window_id }, view.windows, i
    end
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        if b.block_id == block_id then
          return { session_id = session_id, window_id = w.window_id }, view.windows, i
        end
      end
    end
  end
end

local function current_place(ctx)
  return find_place(ctx.session_id, ctx.block_id)
end

local function same_place(a, b)
  return a ~= nil and b ~= nil
    and a.session_id == b.session_id and a.window_id == b.window_id
end

-- Remember where a burst of moves started.
local function note_press(here)
  local now = os.clock()
  if not place.pressed or now - place.pressed > settle_seconds then
    if here and not same_place(here, place.last) then
      place.before, place.last = place.last, here
    end
  end
  place.pressed = now
end

rex.action{
  name = "step",
  title = "Step Tab or Session",
  description = "Run a tab or session move, remembering where a burst of moves started.",
  args = { action = "string" },
  run = function(ctx, args)
    note_press(current_place(ctx))
    rex.client.queue(args.action)
  end,
}

rex.action{
  name = "last_place",
  title = "Go to Last Tab or Session",
  keywords = "previous recent toggle back",
  run = function(ctx)
    local here, tabs, index = current_place(ctx)
    if not here then return end
    -- A press inside a walk keeps walking.
    local walking = place.walking and place.pressed
      and os.clock() - place.pressed <= settle_seconds
    local target = nil
    if not walking then
      if same_place(here, place.last) then target = place.before else target = place.last end
      -- The tab to go back to was closed: start over with no history.
      if target and not find_place(target.session_id, nil, target.window_id) then
        place.last, place.before, target = nil, nil, nil
      end
    end
    if target then
      place.walking = false
      place.before, place.last, place.pressed = here, target, nil
    else
      -- Nothing to go back to: walk right, wrapping past the last tab, until
      -- a pause settles on a tab.
      place.walking = true
      note_press(here)
      local next_tab = tabs[index % #tabs + 1]
      target = { session_id = here.session_id, window_id = next_tab.window_id }
    end
    rex.client.queue("session.select", target)
    return target.window_id
  end,
}

-- Tabs and sessions on the left-hand home row, mirroring pane focus on the
-- right. cmd+a was Select All.
rex.bind("cmd+a", "step", { action = "client.tab.previous" })
rex.bind("cmd+u", "step", { action = "client.tab.next" })
rex.bind("cmd+o", "step", { action = "session.previous" })
rex.bind("cmd+e", "step", { action = "session.next" })
rex.bind("cmd+i", "last_place")

-- Command palette on prefix Enter. Shift+Cmd+P is one-handed on Dvorak.
rex.bind(prefix .. ">enter", "client.palette.toggle")

-- Reload this file, as prefix r did in tmux.
rex.bind(prefix .. ">r", "client.config.reload")

-- Copy mode on prefix c, as in tmux. Scrollback in Helix on prefix C, for
-- heavier edits.
rex.bind(prefix .. ">c", "pane.copy_mode.enter")
rex.bind(prefix .. ">shift+c", "scrollback_edit")

-- Copy mode keys mirror helix.config.toml: Dvorak home row h/t/n/s moves,
-- j/J jump till a character, l/L repeat the search, - and _ go to line
-- end and start. k keeps its default (up).
for key, dir in pairs(dirs) do
  rex.bind("copy/" .. key, "pane.copy_mode.move", { to = dir })
end
rex.bind("copy/j", "pane.copy_mode.find", { direction = "forward", till = true })
rex.bind("copy/shift+j", "pane.copy_mode.find", { direction = "backward", till = true })
rex.bind("copy/l", "pane.copy_mode.search_again", { direction = "same" })
rex.bind("copy/shift+l", "pane.copy_mode.search_again", { direction = "opposite" })
rex.bind("copy/-", "pane.copy_mode.move", { to = "line_end" })
rex.bind("copy/shift+-", "pane.copy_mode.move", { to = "line_start" })
