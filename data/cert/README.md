# Firmware TLS trust bundle

`x509_crt_bundle.bin` is embedded in ESP32 firmware builds and used by
`WiFiClientSecure` to validate public TLS endpoints, including Cloudflare edge
certificates. It is never used to disable certificate or hostname validation.

Provenance:

- Mozilla CA data distributed by `certifi` 2026.06.17
- Generated with Espressif ESP-IDF v4.4.7 `gen_crt_bundle.py`
- SHA-256: `05b05d72948fb83e0cde813c990bcdd83b64c9bda1bd9fe58a918f90d284c368`

Regenerate this bundle when the CA source changes, then update the hash above
and run an embedded firmware build before merging.
