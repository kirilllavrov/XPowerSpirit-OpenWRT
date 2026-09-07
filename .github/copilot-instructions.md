# Работа строго по официальной документации Xray / nftables

Этот проект собирает и правит конфигурацию Xray (`config.json`), правила nftables
TProxy и парсеры подписок. Точность критична: выдуманный или устаревший параметр
ломает работу роутера молча. Поэтому **никакой «отсебятины»** — только официальная документация.

## Источник истины

- **Карта официальной документации — `xray-config-links.md`** (в корне репозитория).
  Это сборник ссылок на официальные разделы Xray (xtls.github.io) и man nftables.
- Допустимы только официальные источники: xtls.github.io (конфигурация Xray) и
  netfilter.org (nftables). Неофициальные статьи, блоги и «советы с форумов» — не источник.

## Обязательные правила

1. **Начинай любую Xray/nftables-задачу с чтения `xray-config-links.md`.** Это карта
   «какая тема — какой раздел документации». Задачи: генерация/правка `config.json`
   (inbounds, outbounds, routing, dns, balancer/observatory), `update-nft.sh` (TProxy),
   парсинг подписок и транспорты, настройка geoip/geosite.
2. **Не знаешь, как правильно — не угадывай.** Если сомневаешься в любом поле, значении,
   синтаксисе, теге, транспорте или поведении — открой нужную официальную страницу из
   `xray-config-links.md` (web-fetch) и следуй ей дословно.
3. **Если официальная документация недоступна или не покрывает случай** — явно скажи,
   что не уверен, и не выдумывай значение; предложи проверить вручную.
4. **При нетривиальных решениях указывай, какой раздел документации применён**
   (например: «по xtls.github.io/config/routing.html …»).

## Codebase Memory MCP

**MANDATORY: use Codebase Memory MCP graph tools FIRST — before reading files or making code changes.**

This rule applies to every request involving this codebase.

Always call `list_projects` first when you do not already know the project name, then use the `display_name` or exact `name` returned by that tool.

```json
// Step 0 — discover project names
mcp_codebase-memo_list_projects()

// Step 1 — use the project identifier returned above
mcp_codebase-memo_get_architecture({ "project": "<display_name>" })
```

### Workflow

1. Call `list_projects` to discover the correct project name.
2. Call `get_architecture(project)` to understand the codebase structure.
3. Use `search_graph` to find relevant symbols, `trace_call_path` for call chains.
4. Use `get_code_snippet` to read specific function implementations.
5. Only use `read_file` when you need exact raw content to edit a specific line.

### Available Tools (14 MCP tools)

**Indexing:**
- `index_repository(repo_path)` — Index a repository into the knowledge graph
- `list_projects` — List all indexed projects with node/edge counts
- `delete_project(project)` — Remove a project and all its graph data
- `index_status(project)` — Check indexing status

**Querying:**
- `search_graph(name_pattern, name_scope, label, file_pattern, exclude_file_pattern)` — Structured search by label, name/qualified_name, include/exclude file globs
- `trace_call_path(function_name, direction, depth)` — BFS call chain traversal
- `detect_changes(project)` — Map git diff to affected symbols + risk
- `query_graph(query)` — Execute Cypher-like graph queries (read-only)
- `get_graph_schema(project)` — Node/edge counts, relationship patterns
- `get_code_snippet(qualified_name)` — Read source code for a function
- `get_architecture(project)` — Codebase overview: languages, packages, routes, hotspots
- `search_code(pattern, project)` — Grep-like text search within indexed files
- `manage_adr(action)` — CRUD for Architecture Decision Records
- `ingest_traces(traces)` — Ingest runtime traces to validate HTTP edges
