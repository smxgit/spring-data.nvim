-- Source blink.cmp pour les derived query methods Spring Data.
local parser = require("springdata.parser")
local entity = require("springdata.entity")

local M = {}

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

--- Actif uniquement dans un buffer Java dont l'interface étend un *Repository.
function M:enabled()
  if vim.bo.filetype ~= "java" then
    return false
  end
  return entity.is_repository(0)
end

--- Fragment de méthode déjà tapé, à gauche du curseur.
--- On remonte jusqu'au début de l'identifiant, en s'arrêtant sur tout ce qui
--- ne peut pas faire partie d'un nom de méthode.
local function current_prefix(ctx)
  local line = ctx.line or ""
  local col = ctx.cursor and ctx.cursor[2] or #line
  local before = line:sub(1, col)
  return before:match("([%a%d_]+)$") or ""
end

--- Met en majuscule la première lettre : inverse de parser.decapitalize pour
--- le cas courant. Les champs Java sont déclarés en lowerCamelCase
--- (`private String name`), donc `suggestions()` renvoie leur nom tel quel
--- (« name ») — sans cette remise en forme, la suggestion de propriété
--- produirait un identifiant Java invalide (« findByname » au lieu de
--- « findByName »).
local function capitalize(s)
  if s == "" then
    return s
  end
  return s:sub(1, 1):upper() .. s:sub(2)
end

--- Texte complet à proposer pour un fragment de suggestion.
---
--- Tant que le sujet (find/count/exists/delete…) n'est pas encore reconnu
--- (`result.subject == nil`), `parser.suggestions` renvoie des mots entiers
--- qui REMPLACENT ce qui est tapé — pour "fin", le mot-clé candidat est
--- "find", pas un suffixe à concaténer (« fin » .. « find » donnerait
--- l'absurde « finfind »). Une fois le sujet reconnu, tout le reste
--- (modifieurs Distinct/First/Top/By, propriétés, mots-clés de condition,
--- connecteurs, directions de tri) s'ajoute à la suite du texte déjà tapé.
---
--- Les suggestions de nature "property" utilisent le nom du champ tel que
--- déclaré (minuscule initiale) : il faut le capitaliser pour former un
--- segment de méthode valide.
local function fragment_text(prefix, result, suggestion)
  local candidate = suggestion.label
  if suggestion.kind == "property" then
    candidate = capitalize(candidate)
  end

  if not result.subject then
    return candidate
  end

  return prefix .. candidate
end

--- Construit le snippet LuaSnip de la signature complète.
--- Les tabstops portent sur les noms de paramètres, pour permettre de les
--- renommer immédiatement après insertion.
local function build_snippet(method_name, return_type, params)
  local rendered = {}
  for index, param in ipairs(params) do
    rendered[#rendered + 1] = string.format(
      "%s ${%d:%s}",
      param.java_type,
      index,
      param.name
    )
  end
  return string.format(
    "%s %s(%s);$0",
    return_type,
    method_name,
    table.concat(rendered, ", ")
  )
end

--- États dans lesquels la signature complète peut être proposée : jamais
--- avant qu'une propriété soit sélectionnée, pour ne pas reproduire le
--- `findBy` nu de Spring Tools (issue spring-projects/spring-tools#1014).
---
--- Le dernier prédicat peut être un FRAGMENT dans les états d'attente
--- (`findByNameAnd`, `findByNameOrderBy` laissent le jeton final accroché à
--- la propriété, avec une erreur `unknown_property`) : c'est `result.state`
--- qui distingue un prédicat complet d'un fragment en cours de frappe, pas
--- l'inspection du dernier prédicat — ne jamais contourner cette porte en
--- lisant `result.predicates` directement.
local COMPLETE_STATES = {
  after_property = true,
  after_condition = true,
  order_direction = true,
}

function M:get_completions(ctx, callback)
  local cancelled = false
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

  local entity_name = entity.resolve_entity_name(bufnr)
  if not entity_name then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return function() end
  end

  local prefix = current_prefix(ctx)

  entity.fields(entity_name, function(fields)
    -- `entity.fields` répond de manière asynchrone (workspace/symbol vers
    -- jdtls) : si l'utilisateur a continué de taper ou a changé de contexte
    -- entre-temps, blink.cmp a appelé la fonction d'annulation renvoyée
    -- plus bas — `cancelled` empêche alors ce callback tardif d'invoquer
    -- `callback` avec un résultat périmé, calculé sur un `prefix` qui ne
    -- correspond plus à ce qui est affiché.
    if cancelled then
      return
    end

    local result = parser.parse(prefix, fields)
    local items = {}

    -- Fragments : propriétés, mots-clés, connecteurs, directions.
    for _, suggestion in ipairs(parser.suggestions(result, fields)) do
      local label = fragment_text(prefix, result, suggestion)
      items[#items + 1] = {
        label = label,
        filterText = label,
        insertText = label,
        labelDetails = { description = suggestion.detail },
        kind = suggestion.kind == "property" and 5 or 14, -- Field / Keyword
        sortText = string.format("%02d%s", suggestion.kind == "property" and 1 or 2, label),
      }
    end

    -- Signature complète : jamais avant qu'une propriété soit sélectionnée,
    -- pour ne pas reproduire le `findBy` nu de Spring Tools (issue #1014).
    if COMPLETE_STATES[result.state] and #result.predicates > 0 and #result.errors == 0 then
      local return_type = parser.return_type(result, entity_name, self.opts)
      items[#items + 1] = {
        label = prefix,
        filterText = prefix,
        labelDetails = { description = return_type },
        kind = 2, -- Method
        insertTextFormat = 2, -- Snippet
        insertText = build_snippet(prefix, return_type, result.params),
        sortText = "00" .. prefix,
        documentation = {
          kind = "markdown",
          value = string.format(
            "```java\n%s %s(%s);\n```",
            return_type,
            prefix,
            (function()
              local parts = {}
              for _, param in ipairs(result.params) do
                parts[#parts + 1] = param.java_type .. " " .. param.name
              end
              return table.concat(parts, ", ")
            end)()
          ),
        },
      }
    end

    callback({
      items = items,
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
  end)

  return function()
    cancelled = true
  end
end

return M
