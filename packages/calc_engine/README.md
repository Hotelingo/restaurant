# Calculation engine

Pure Python calculation functions.

Non-negotiable properties:
- Decimal-based money arithmetic;
- stable calc IDs;
- no database access;
- no HTTP/network access;
- no browser dependency;
- no clock or randomness;
- all settings supplied explicitly;
- missing is never silently converted to zero.

This package must run its unit tests with no database and no network available.
