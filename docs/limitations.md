# Wayfinder: Known Limitations

- **Corpus and Retrieval Top-K**: Retrieval parameter `k` is tuned for a small policy corpus (k=3 for vector-only lookups, k=5 for hybrid "both" queries). For large enterprise corpora, dynamic k or re-ranking would be required.
- **Small-Model SQL Generation**: The agent relies on small local open-weight models (Gemma 4 E4B, 4-bit quantized). Complex joins, subqueries, or intricate arithmetic conditions may require retries or structured prompt constraints.
- **Fixed Schema**: The relational schema is fixed to the `invoices` table and predefined policy document structures.
- **Language Support**: All current prompt templates, routing classifications, and policy text documents are English only.
- **Vector Capacity**: 768-dimension embeddings exceed the 4KB single-record page limit in ULTSQL's current slotted page implementation, necessitating an in-memory cosine fallback for vector similarity search.
