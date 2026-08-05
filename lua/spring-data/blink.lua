-- blink.cmp-specific adjustments, called from M.setup().
--
-- Unlike source.lua (which only exposes the generic new/enabled/
-- get_completions contract), this module touches blink.cmp's undocumented
-- internals (blink.cmp.completion.list, .trigger, .types) — deliberately
-- isolated here rather than in source.lua, so the latter stays independent
-- of the completion engine. If blink.cmp changes these internals, only
-- this file breaks.
--
-- Never errors if blink.cmp is absent: every adjustment is pcall-guarded
-- and silently disables itself.
local M = {}

local SOURCE_ID = "spring-data"

--- blink.cmp's live preview (`list.selection.auto_insert = true`) really
--- mutates the buffer (`vim.lsp.util.apply_text_edits`, not a simple ghost
--- text) with the top candidate on every keystroke. Its truncation
--- function (blink.cmp.completion.accept.prefix) cuts everything after an
--- unclosed `<`/`(`/`"`, designed to preview a function call. Full method
--- signatures contain Java generics (`List<UserEntity>`, `Optional<T>`):
--- the preview overwrote the typed text with "List" or "Optional" mid-
--- keystroke, corrupting what the user was typing. Normal acceptance
--- (<C-y>) is unaffected: it uses the full textEdit, never the preview.
---
--- Wraps `list.get_selection_mode` (the function, not the config field)
--- rather than overwriting `list.config.selection.auto_insert` — this
--- composes with any user-defined setting and does not depend on load
--- order between this module and `blink.cmp.setup()`, unlike a plain
--- field replacement, which only holds if this module loads after blink's
--- own setup.
local function disable_preview_for_spring_data()
  local ok, list = pcall(require, "blink.cmp.completion.list")
  if not ok then
    return
  end

  local original = list.get_selection_mode
  list.get_selection_mode = function(context)
    local mode = original(context)
    local top = list.items and list.items[1]
    if top and top.source_id == SOURCE_ID then
      mode.auto_insert = false
    end
    return mode
  end
end

--- blink.cmp only reopens the menu automatically after an accept if the
--- next character is a "trigger character" declared by a source (typically
--- `.` for member access) — this source declares none, so without this
--- adjustment the user has to retype a character to keep building a
--- method after accepting a fragment (`findByNa` -> `findByName` -> nothing,
--- then delete/retype).
---
--- Forces an immediate reopen after any item from this source, except the
--- Method item (the full signature): the declaration is then complete,
--- nothing left to propose.
local function reopen_after_fragment_accept()
  local ok_list, list = pcall(require, "blink.cmp.completion.list")
  local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
  local ok_types, types = pcall(require, "blink.cmp.types")
  if not (ok_list and ok_trigger and ok_types) then
    return
  end

  list.accept_emitter:on(function(event)
    if event.item.source_id ~= SOURCE_ID then
      return
    end
    if event.item.kind == types.CompletionItemKind.Method then
      return
    end
    vim.schedule(function()
      trigger.show({ force = true })
    end)
  end)
end

function M.setup()
  disable_preview_for_spring_data()
  reopen_after_fragment_accept()
end

return M
