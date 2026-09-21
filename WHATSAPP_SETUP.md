# WhatsApp setup

The included provider is deliberately a mock and stores messages in memory for tests. A production adapter must use an approved WhatsApp Business/API provider, store tokens in Keychain or a secret manager, validate recipient IDs, rate-limit retries, and redact paths where appropriate. Set `WHATSAPP_PROVIDER=mock` in `.env` for development. This project does not pretend to deliver messages without credentials.
