# XPowerSpirit-OpenWRT

Правила проекта (общие для всех агентов) — в **`AGENTS.md`** (корень репозитория).
Следуй им при работе с этим кодом:

1. **Xray / nftables — строго по официальной документации**: карта `xray-config-links.md`;
   не выдумывай параметры/транспорты, сверяйся с официальными страницами.
2. **Codebase Memory MCP**: для структурных запросов по коду используй граф —
   `mcp_codebase-memo_list_projects()` → `get_architecture` → `search_graph`/`trace_path`
   → `get_code_snippet`. Конфиги и документацию читай как обычно.
