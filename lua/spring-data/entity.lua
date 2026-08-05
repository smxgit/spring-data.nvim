-- Résolution de l'entité d'un repository Spring Data et extraction de ses
-- champs. Seul module à dépendre à la fois de treesitter et de jdtls.
local M = {}

--- Requête treesitter isolant le premier argument générique d'une interface
--- qui étend un type dont le nom se termine par « Repository ».
---
--- Le parser java expose `extends_interfaces` sur les versions récentes et
--- `super_interfaces` sur les plus anciennes ; la requête tolère les deux en
--- ne contraignant pas le nœud intermédiaire.
local QUERY = [[
(interface_declaration
  (_
    (type_list
      (generic_type
        (type_identifier) @repo_name
        (type_arguments
          (_) @entity_name)))))
]]

local function iter_matches(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local query_ok, query = pcall(vim.treesitter.query.parse, "java", QUERY)
  if not query_ok then
    return nil
  end

  return query, tree:root()
end

--- Nom de l'entité d'un repository, ou nil si le buffer n'en est pas un.
function M.resolve_entity_name(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local query, root = iter_matches(bufnr)
  if not query then
    return nil
  end

  for _, match in query:iter_matches(root, bufnr, 0, -1) do
    local repo_name, entity_name
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      local capture = query.captures[id]
      local text = vim.treesitter.get_node_text(node, bufnr)
      if capture == "repo_name" then
        repo_name = text
      elseif capture == "entity_name" and not entity_name then
        entity_name = text
      end
    end

    if repo_name and repo_name:match("Repository$") and entity_name then
      return entity_name
    end
  end

  return nil
end

--- Vrai si le buffer contient une interface étendant un *Repository.
function M.is_repository(bufnr)
  return M.resolve_entity_name(bufnr) ~= nil
end

-- Cache des champs, indexé par nom d'entité. Invalidé sur BufWritePost du
-- fichier de l'entité, via setup_autocmds.
--
-- `uri_index` associe un NUMÉRO DE BUFFER (pas un chemin) à l'entité qu'il
-- contient : `args.file` d'un autocmd BufWritePost reflète tel quel la
-- façon dont le buffer a été ouvert — relatif si ouvert via un chercheur
-- flou ou un chemin relatif — alors que l'URI renvoyée par jdtls est
-- toujours absolue. Les deux chaînes ne coïncidaient donc presque jamais,
-- et l'invalidation ne se déclenchait pas. Le numéro de buffer est stable
-- et indépendant de toute représentation textuelle du chemin.
local cache = {}
local uri_index = {}

-- Requêtes `M.fields` en cours par nom d'entité : deux demandes concurrentes
-- pour la même entité partagent une seule requête workspace/symbol au lieu
-- d'en déclencher deux, et sont toutes deux résolues à la réponse unique.
local pending = {}

--- Requête treesitter localisant une classe par son nom simple et son corps.
--- Le nom est filtré après coup (égalité stricte avec l'entité recherchée) :
--- la requête elle-même matche n'importe quelle classe, y compris les
--- classes imbriquées (clé composite @Embeddable, par exemple), mais comme
--- un nom de classe simple est unique dans un fichier Java, filtrer par
--- égalité isole sans ambiguïté le corps de la bonne classe.
local CLASS_QUERY = [[
(class_declaration
  name: (identifier) @name
  body: (class_body) @body)
]]

--- Corps (class_body) de la classe portant le nom `entity_name`, ou nil si
--- introuvable dans l'arbre.
local function find_class_body(root, bufnr, entity_name)
  local query_ok, query = pcall(vim.treesitter.query.parse, "java", CLASS_QUERY)
  if not query_ok then
    return nil
  end

  for _, match in query:iter_matches(root, bufnr, 0, -1) do
    local name_text, body_node
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      local capture = query.captures[id]
      if capture == "name" then
        name_text = vim.treesitter.get_node_text(node, bufnr)
      elseif capture == "body" then
        body_node = node
      end
    end
    if name_text == entity_name and body_node then
      return body_node
    end
  end

  return nil
end

--- Nom simple d'une annotation, avec ses arguments éventuels, sans
--- qualification de paquetage : « @jakarta.persistence.Id » devient « Id »,
--- « @Column(unique = true) » reste « Column(unique = true) ».
---
--- parser.is_unique_field (Task 9) compare par égalité stricte au nom
--- simple (`annotation == "Id"`) et cherche les sous-chaînes « Column » /
--- « unique » pour le second cas : une annotation totalement qualifiée
--- (légale en Java, `@jakarta.persistence.Id`) casserait ces deux
--- vérifications si elle n'était pas normalisée ici.
local function annotation_text(node, bufnr)
  local name_node = node:field("name")[1]
  if not name_node then
    return nil
  end

  local qualified = vim.treesitter.get_node_text(name_node, bufnr)
  local simple = qualified:match("([%w_]+)$") or qualified

  local args_node = node:field("arguments")[1]
  if args_node then
    simple = simple .. vim.treesitter.get_node_text(args_node, bufnr)
  end

  return simple
end

--- Extrait les champs déclarés directement dans un `field_declaration`,
--- annotations et modificateurs compris.
local function fields_of_declaration(node, bufnr)
  local java_type
  local annotations = {}
  local names = {}
  local skip = false

  for child in node:iter_children() do
    local kind = child:type()
    if kind == "modifiers" then
      for modifier in child:iter_children() do
        local mtype = modifier:type()
        if mtype == "annotation" or mtype == "marker_annotation" then
          local text = annotation_text(modifier, bufnr)
          if text then
            annotations[#annotations + 1] = text
          end
        elseif mtype == "static" or mtype == "transient" then
          -- Un champ statique ou transient n'est pas persisté : il ne doit
          -- pas être proposé.
          skip = true
        end
      end
    elseif kind == "variable_declarator" then
      local name_node = child:field("name")[1]
      if name_node then
        names[#names + 1] = vim.treesitter.get_node_text(name_node, bufnr)
      end
    elseif java_type == nil then
      -- Premier enfant qui n'est ni les modificateurs ni un déclarateur :
      -- c'est le nœud de type (type_identifier, generic_type, etc.).
      java_type = vim.treesitter.get_node_text(child, bufnr)
    end
  end

  if skip or not java_type then
    return {}
  end

  -- `private String a, b;` déclare plusieurs champs dans un seul
  -- field_declaration : un par déclarateur, type et annotations partagés.
  local out = {}
  for _, name in ipairs(names) do
    out[#out + 1] = { name = name, java_type = java_type, annotations = annotations }
  end
  return out
end

--- Extrait les champs de la classe `entity_name` dans un buffer Java : nom,
--- type et annotations. Les annotations et modificateurs (static,
--- transient) vivent dans le nœud `modifiers` du `field_declaration` —
--- documentSymbol ne les remonterait pas, d'où le passage par treesitter
--- sur le buffer réel.
---
--- Ne parcourt que les `field_declaration` enfants directs du corps de
--- cette classe précise : une requête non bornée matcherait aussi les
--- champs d'une classe imbriquée (clé composite @Embeddable, par exemple)
--- et les ferait fuir dans les propositions de complétion.
---
--- Retourne nil si la classe `entity_name` est introuvable dans l'arbre —
--- distinct d'une liste vide, qui signifie « classe trouvée, zéro champ
--- persistable » et qui est un résultat légitime à mettre en cache. Le nil
--- ne doit jamais être mis en cache : il permettra une nouvelle tentative
--- au prochain appel.
local function extract_fields(bufnr, entity_name)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local body = find_class_body(tree:root(), bufnr, entity_name)
  if not body then
    return nil
  end

  local fields = {}
  for child in body:iter_children() do
    if child:type() == "field_declaration" then
      for _, field in ipairs(fields_of_declaration(child, bufnr)) do
        fields[#fields + 1] = field
      end
    end
  end

  return fields
end

--- Charge le fichier d'une URI dans un buffer et en extrait les champs de
--- la classe `entity_name`. Retourne `nil` (jamais mis en cache par
--- l'appelant) si le buffer n'a pas pu être chargé — fichier supprimé,
--- document virtuel `jdt://` d'un jar dont le contenu n'est pas
--- accessible tel quel, etc. Retourne aussi le `bufnr` résolu : l'appelant
--- en a besoin pour indexer `uri_index` sans jamais repasser par un chemin.
local function fields_from_uri(uri, entity_name)
  local uri_ok, bufnr = pcall(vim.uri_to_bufnr, uri)
  if not uri_ok or not bufnr then
    return nil
  end

  local load_ok = pcall(vim.fn.bufload, bufnr)
  if not load_ok or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end

  return extract_fields(bufnr, entity_name), bufnr
end

--- Récupère les champs d'une entité, en passant par le cache.
--- jdtls localise le fichier via workspace/symbol, treesitter en extrait le
--- contenu — documentSymbol ne remonterait pas les annotations.
---
--- `callback(fields, ok)`. `ok` est faux quand la liste n'a PAS pu être
--- établie — jdtls pas encore attaché, workspace/symbol muet, fichier
--- illisible — par opposition à une entité réellement dépourvue de champ
--- persistable, qui donne une liste vide avec `ok` vrai. Les deux cas
--- produisent la même liste vide côté parser, qui désactive alors la
--- validation (§6) ; sans ce second retour, l'appelant confondrait
--- « aucune erreur relevée » avec « vérifié », et proposerait des
--- signatures fabriquées sur des propriétés jamais confrontées à l'entité.
function M.fields(entity_name, callback)
  if cache[entity_name] then
    callback(cache[entity_name], true)
    return
  end

  local waiters = pending[entity_name]
  if waiters then
    -- Une requête est déjà en vol pour cette entité : on s'accroche à sa
    -- réponse plutôt que d'en émettre une seconde.
    waiters[#waiters + 1] = callback
    return
  end

  local clients = vim.lsp.get_clients({ name = "jdtls" })
  if #clients == 0 then
    callback({}, false)
    return
  end

  waiters = { callback }
  pending[entity_name] = waiters

  -- `waiters` identifie cette requête précise : si `M.invalidate` a
  -- entre-temps décroché `pending[entity_name]` (parce que jdtls a planté
  -- ou a été redémarré sans jamais répondre — la requête ne rappellera
  -- alors jamais, et sans ce décrochage `pending[entity_name]` resterait
  -- occupé pour toujours, empêchant toute nouvelle tentative), une réponse
  -- tardive et orpheline de cette requête sert quand même ses propres
  -- callbacks en attente, mais ne touche ni au cache ni à `pending`, qui
  -- appartiennent désormais à une éventuelle requête plus récente.
  local resolved = false
  local function resolve(fields, ok)
    -- Idempotent : l'appelant a deux chemins d'échec (envoi refusé et
    -- réponse en erreur) qui pourraient sinon servir les mêmes callbacks
    -- deux fois.
    if resolved then
      return
    end
    resolved = true
    fields = fields or {}
    if pending[entity_name] == waiters then
      pending[entity_name] = nil
      if ok then
        cache[entity_name] = fields
      end
    end
    for _, cb in ipairs(waiters) do
      cb(fields, ok)
    end
  end

  local function on_symbols(err, results)
    if err or not results or #results == 0 then
      resolve(nil, false)
      return
    end

    local uri
    for _, symbol in ipairs(results) do
      if symbol.name == entity_name then
        uri = symbol.location and symbol.location.uri
        break
      end
    end

    if not uri then
      resolve(nil, false)
      return
    end

    local fields, bufnr = fields_from_uri(uri, entity_name)
    if fields == nil then
      -- Extraction échouée (fichier introuvable, URI jdt:// illisible,
      -- classe absente de l'arbre…) : ne jamais mettre ce résultat en
      -- cache, pour qu'un appel ultérieur retente au lieu de rester
      -- bloqué sur un résultat vide indéfiniment — aucun BufWritePost ne
      -- viendrait jamais l'invalider.
      resolve(nil, false)
      return
    end

    uri_index[bufnr] = entity_name
    resolve(fields, true)
  end

  -- `pending` est déjà posé : toute sortie qui ne passerait pas par
  -- `resolve` laisserait cette entité muette pour le reste de la session,
  -- et l'exception remonterait jusqu'à `get_completions`, donc à chaque
  -- frappe. `Client:request` peut lever (handle invalide, client en cours
  -- d'arrêt) et peut aussi répondre `false` sans jamais rappeler le
  -- gestionnaire — les deux referment la porte de la même manière.
  local ok, sent = pcall(clients[1].request, clients[1], "workspace/symbol", { query = entity_name }, on_symbols)
  if not ok or sent == false then
    resolve(nil, false)
  end
end

--- Vide l'entrée de cache d'une entité, ou tout le cache si aucun nom donné.
--- Décroche aussi `pending` : une requête en vol qui ne répondra jamais
--- (jdtls planté ou redémarré) ne doit pas bloquer les appels suivants
--- indéfiniment — `M.invalidate` est le mécanisme de reprise.
function M.invalidate(entity_name)
  if entity_name then
    cache[entity_name] = nil
    pending[entity_name] = nil
  else
    cache = {}
    uri_index = {}
    pending = {}
  end
end

--- Invalide le cache d'une entité dès que son fichier est sauvegardé.
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("SpringDataEntityCache", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.java",
    callback = function(args)
      local entity_name = uri_index[args.buf]
      if entity_name then
        M.invalidate(entity_name)
      end
    end,
  })
end

return M
