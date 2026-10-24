# Wayfinder Agent Skills

Wayfinder pairs a local embedded database engine (ULTSQL) with local open-weight language and embedding models (Gemma 4 E2B/E4B & nomic-embed-text) to answer questions without cloud dependencies. The agent employs dynamic semantic routing to execute specialized skills based on question intent.

---

## 1. SQL Skill (`sql`)

### When It Applies
Applies when a user's question requires aggregating, filtering, sorting, summing, averaging, or counting structured relational data (such as invoice records, financial transactions, employee data, or custom tables) where no policy or prose documents are needed.

### Inputs
- **User Question**: The user's analytical query.
- **Dynamic Table Schemas**: In-memory schema definitions (table name, column names, data types, and sample rows) provided by `DataRegistry`.
- **System Constraints**: Read-only `SELECT` enforcement, injection guards, single-table constraint, and registered table validation.

### Outputs
- **SQL Query**: A safe, single-table `SELECT` statement in standard SQL syntax.
- **Result Rows**: Tabular JSON records fetched directly from the local ULTSQL database.
- **Natural Language Answer**: Direct, factual summary generated strictly from the returned rows.

### Example Questions
1. *"What is the total refund amount for Travel?"*
2. *"List the top 5 largest approved invoices ordered by amount descending."*

---

## 2. Vector Skill (`vector`)

### When It Applies
Applies when a user asks about policy definitions, operational rules, compliance guidelines, timeframes, or contextual knowledge stored in unstructured text or markdown documents, without needing relational calculations or database table lookups.

### Inputs
- **User Question / Semantic Query**: Extracted search intent for document retrieval.
- **Embedded Document Chunks**: 768-dimensional normalized vector embeddings generated offline via `nomic-embed-text-v1.5`.
- **Top-K Parameter**: Typically $k = 3$ most relevant chunks ranked by cosine similarity.

### Outputs
- **Relevant Chunks**: Ranked text excerpts alongside source document metadata and cosine similarity scores.
- **Source Citation**: Explicit attribution to the matching file (e.g., `refund_policy.md`, `travel_policy.md`).
- **Natural Language Answer**: Concise, factual answer quoting or explaining the exact policy rules without hallucination.

### Example Questions
1. *"How many days do I have to request a refund?"*
2. *"What receipt requirements exist for business meal reimbursements?"*

---

## 3. Hybrid / Both Skill (`both`)

### When It Applies
Applies when an analytical question bridges both structured data and unstructured guidelines. The agent must first retrieve qualitative rules or thresholds from policy documents and use those criteria to evaluate, filter, or audit database rows.

### Inputs
- **User Question**: The complex evaluation query.
- **Policy Knowledge Base**: Text chunks containing guidelines, thresholds, or eligibility criteria.
- **Database Tables**: Relational records in ULTSQL to be audited or cross-referenced.
- **Multi-Turn Memory**: Conversation context if the question refers to prior answers.

### Outputs
- **Policy Evidence**: Retrieved policy excerpts defining violation or qualification conditions.
- **Evaluated SQL**: Query retrieving candidate rows for inspection.
- **Evidence Table**: The exact rows satisfying or violating the policy rules.
- **Comprehensive Synthesis**: Natural language answer naming the violated policy rule, citing the source document, and listing the affected entity IDs and amounts.

### Example Questions
1. *"Which invoices break the refund policy?"*
2. *"Are there any software subscriptions that exceed the maximum renewal window without approval?"*

---

## Routing Fallback (`none`)
For friendly greetings, small talk, or queries outside the loaded datasets, the agent responds politely offline explaining its capabilities without invoking the SQL or vector pipelines.
