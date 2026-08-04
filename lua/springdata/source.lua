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

--- Texte complet à proposer pour une suggestion.
---
--- `replace_length` dit combien de caractères de la FIN du texte tapé le
--- libellé remplace : zéro pour ce qui s'ajoute à la suite (le cas courant),
--- la longueur du jeton en cours de frappe sinon. C'est ainsi que
--- « findByNameCont » + Containing donne « findByNameContaining » et non
--- « findByNameContContaining », et que « fin » + find donne « find » et non
--- l'absurde « finfind ». Le parser étant seul à savoir où commence le
--- fragment, aucune chirurgie de chaîne n'est refaite ici.
---
--- Les suggestions de nature "property" utilisent le nom du champ tel que
--- déclaré (minuscule initiale) : il faut le capitaliser pour former un
--- segment de méthode valide.
local function fragment_text(prefix, suggestion)
  local candidate = suggestion.label
  if suggestion.kind == "property" then
    candidate = capitalize(candidate)
  end

  local kept = #prefix - (suggestion.replace_length or 0)
  if kept < 0 then
    kept = 0
  end

  return prefix:sub(1, kept) .. candidate
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

--- Vrai si la signature complète peut être proposée.
---
--- `fields_ok` est la condition décisive : sans liste de champs, le parser
--- désactive la validation des propriétés (§6) et `errors` est donc vide
--- parce que RIEN n'a été vérifié, non parce que la méthode est correcte.
--- Confondre les deux fait proposer « List<UserEntity>
--- findByNameCont(Object nameCont); » quand jdtls n'est pas encore attaché.
--- Les fragments, eux, restent proposés : ils ne prétendent à rien.
local function offers_signature(result, fields_ok)
  return fields_ok == true
    and COMPLETE_STATES[result.state] == true
    and #result.predicates > 0
    and #result.errors == 0
end

--- Options effectives : celles de `require("springdata").setup{}`, écrasées
--- par celles déclarées sur le provider blink.
---
--- `M.new` ne reçoit que les seconds — la clé `opts` de la configuration du
--- provider —, presque toujours absentes. Sans cette fusion, une option
--- passée à `setup{}` n'atteignait jamais `parser.return_type` : elle était
--- écrite dans `springdata.opts` et lue par personne.
---
--- Fusion à la main plutôt que par `vim.tbl_extend` : ce module doit rester
--- chargeable sous un interpréteur nu pour que ses fonctions pures soient
--- testables sans Neovim.
local function options(provider_opts)
  local merged = {}
  for key, value in pairs(require("springdata").opts or {}) do
    merged[key] = value
  end
  for key, value in pairs(provider_opts or {}) do
    merged[key] = value
  end
  return merged
end

function M:get_completions(ctx, callback)
  local cancelled = false
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

  local entity_name = entity.resolve_entity_name(bufnr)
  if not entity_name then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return function() end
  end

  local prefix = current_prefix(ctx)

  entity.fields(entity_name, function(fields, fields_ok)
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
      local label = fragment_text(prefix, suggestion)
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
    if offers_signature(result, fields_ok) then
      local return_type = parser.return_type(result, entity_name, options(self.opts))
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

--- Fonctions pures de ce module, exposées pour tests/source_spec.lua.
--- blink.cmp n'appelle que new/enabled/get_completions : elles n'ont aucune
--- autre raison d'être publiques, mais elles portent deux des trois défauts
--- que la relecture finale a relevés ici et doivent donc être épinglées.
M.internal = {
  current_prefix = current_prefix,
  capitalize = capitalize,
  fragment_text = fragment_text,
  build_snippet = build_snippet,
  offers_signature = offers_signature,
  options = options,
}

return M
