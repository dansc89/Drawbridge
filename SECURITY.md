# Security and private data

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/dansc89/Drawbridge/security/advisories/new) for security issues. Do not publish credentials, exploit details, or confidential PDFs in public issues. Include the affected release and reproduction steps using a synthetic document.

## Contributing safely

- Keep credentials in Keychain or GitHub Actions secrets. Never commit signing keys, notarization passwords, `.env` files, databases, or client PDFs.
- Keep local fixtures in `private-fixtures/` or outside the checkout. Optional corpus tests use locally supplied fixture paths; no client documents are required for the default test suite.
- Use synthetic or explicitly publishable drawings for screenshots and examples. Check PDF metadata, annotation authors, filenames, and logs before uploading.
- Run `python3 Scripts/check-history-privacy.py` to check historical personal paths and private hostnames. Scan all Git history with `gitleaks git . --log-opts="--all" --redact` before publishing. GitHub secret scanning and push protection are additional safeguards, not a substitute for review.
- Removing a file in a new commit does not erase old commits, tags, forks, or copies. Rotate exposed credentials immediately; coordinate any history cleanup with maintainers.

## Scope

The released macOS application and the optional `Backend/` prototype are separate. The backend is not a production collaboration service and must not be publicly deployed without a separate security review. Developer ID signatures intentionally identify the publisher; public signing certificates are not private signing keys.
