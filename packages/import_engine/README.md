# Import engine

Pure parsing, fingerprinting, mapping, validation and canonical-DTO logic.

Non-negotiable properties:
- no database access;
- no HTTP/network access;
- deterministic output from explicit input;
- no arbitrary customer executable code;
- closed transform list only.

Persistence belongs in the API/ingestion layer, not here.
