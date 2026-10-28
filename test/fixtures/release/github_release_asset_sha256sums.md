# Public release asset transport fixture

- Repository and release: `chen08209/FlClash`, public release `v0.9.0` (release ID `412264554`).
- Asset: `SHA256SUMS`, asset ID `638887099`.
- Request command: `gh api --include -H 'Accept: application/octet-stream' repos/chen08209/FlClash/releases/assets/638887099`.
- GitHub CLI: `gh version 2.94.0 (2026-06-10)`.
- Response status: `HTTP/2.0 200 OK`.
- Response headers: `Content-Length: 1517`; `Content-Type: application/octet-stream`; `Last-Modified: Wed, 14 Oct 2026 01:56:04 GMT`; `Etag: "0x8DF29964E28CA48"`; `X-Ms-Blob-Content-Md5: MMi12CLmwU4qM1Gzy8VbAw==`.
- Donor metadata expected size: 1517 bytes.
- Saved fixture size: 1517 bytes.
- SHA-256 of downloaded and saved body: `a7c44d49203c71d7ccc6a8ea4efbb774f7495bbd28ae02aab647025114eac682`, matching the donor metadata.
- Fixture: [github_release_asset_sha256sums.txt](github_release_asset_sha256sums.txt).

This confirms that the public release asset endpoint with the octet-stream Accept header returned the exact small text payload for the listed asset ID. It demonstrates the download transport for a text release asset. It is a donor SHA256SUMS file, not a release-manifest.json, and is not evidence of a positive Flashco release bundle. No binary asset or private release data was fetched.
