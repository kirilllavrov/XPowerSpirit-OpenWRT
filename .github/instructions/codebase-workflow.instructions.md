---
applyTo: '**'
---

## MANDATORY: Always use Codebase Memory MCP to read the codebase

**This rule applies to EVERY request that involves this codebase.**

### Rules

1. **Call `list_projects` FIRST** to discover the correct project name before using any tool.
2. **Call `mcp_codebase-memo_get_architecture` next** — before writing code, editing files, or answering structural questions about the codebase.
3. Use the returned context to make targeted, accurate changes.
4. For **structural code discovery** (символы, вызовы, архитектура) prefer Codebase Memory graph tools over grep/read_file. Конфиги, документацию (например `xray-config-links.md`), литералы и файлы вне графа или непокрытые им — читай обычным способом (`read_file`/grep): граф best-effort, не заменяет чтение.
5. Re-query only if additional context is needed during implementation.

Always use the project identifier returned by `list_projects` instead of guessing project names.

> Канонический свод правил проекта (включая работу строго по официальной документации Xray) — в `AGENTS.md` (корень репозитория).

### Workflow

```
// Step 0 — discover available projects (ALWAYS do this first)
mcp_codebase-memo_list_projects()

// Step 1 — use the project identifier returned above
mcp_codebase-memo_get_architecture({ "project": "<display_name>" })

// Step 2 — find symbols
mcp_codebase-memo_search_graph({ "project": "<display_name>", "name_pattern": "<symbol>" })

// Step 3 — read code
mcp_codebase-memo_get_code_snippet({ "project": "<display_name>", "qualified_name": "<fn>" })
```

### Why

- Graph-индекс помогает быстро находить структуру кода (символы, вызовы, архитектуру).
- Индекс best-effort: он не заменяет чтение конфигов/документации и непокрытых файлов.
- `list_projects` исключает угадывание имени проекта.
