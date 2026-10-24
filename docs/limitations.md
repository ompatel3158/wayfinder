# Wayfinder: Known Limitations

While Wayfinder delivers completely offline, privacy-first database analysis and semantic retrieval, the following known limitations apply:

1. **Small-Model SQL Generation**:
   Wayfinder is designed to run efficiently on lightweight consumer hardware using small local open-weight models (e.g. Gemma 4 E2B/E4B quantized). While excellent for single-table queries, aggregations, filters, groupings, and orderings, small models can occasionally produce syntax errors or struggle with complex multi-table joins and recursive CTEs. Wayfinder mitigates this by restricting SQL generation to single tables, verifying syntax, and validating referenced tables against the active registry.

2. **Fixed vs Dynamic Schema Boundaries**:
   While users can dynamically import custom `.csv` and `.json` tables and `.txt` / `.md` documents, all table queries operate on one table at a time (no automatic schema inference for joins across independent user tables). Column types are inferred from data (INTEGER, REAL, TEXT), and table names are sanitized to `[a-z0-9_]`.

3. **English Language Focus**:
   Prompt instructions, system routing templates, policy documentation, and reasoning chains are currently authored and tested exclusively for the English language.

4. **Single-Record Page Size in Embedded Engine**:
   In ULTSQL's default slotted-page architecture, 768-dimensional dense vector embeddings exceed the 4KB single-record page capacity limit. To prevent page overflow, vector similarity search operates with in-memory normalized cosine scoring in Dart while relational tables and chunk metadata persist directly in ULTSQL.

5. **Retrieval Top-K Scope**:
   Vector retrieval defaults to $k = 3$ (or $k = 5$ for hybrid queries). For massive document libraries with tens of thousands of pages, advanced re-ranking or dynamic top-k retrieval would be beneficial.
