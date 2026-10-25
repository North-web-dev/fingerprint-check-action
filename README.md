# fingerprint-check-action

[![selftest](https://github.com/North-web-dev/fingerprint-check-action/actions/workflows/selftest.yml/badge.svg)](https://github.com/North-web-dev/fingerprint-check-action/actions/workflows/selftest.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**A GitHub Action that catches TLS-fingerprint regressions in CI.** It asserts that your
HTTP client still looks like a real browser — matching the expected **JA3 / JA4 /
Akamai HTTP/2** fingerprint — and fails the build when it silently stops.

## The problem it solves

If you use a browser-impersonation library — [`curl_cffi`](https://github.com/lexiforest/curl_cffi),
[`utls`](https://github.com/refraction-networking/utls), [`tls-client`](https://github.com/bogdanfinn/tls-client),
or our own [impersonate-http](https://github.com/North-web-dev/impersonate-http) /
[impersonate-rs](https://github.com/North-web-dev/impersonate-rs) — you have a **silent-regression
problem**. A dependency bump, a Go/Rust toolchain change, or a pinned browser-version update can quietly
alter the ClientHello your client emits. Nothing breaks in your tests. You only find out weeks later
when the target site starts blocking you, because your JA4 no longer matches a real browser.

This Action puts that check in CI. On every push it drives your client against a live **fingerprint
reflector**, reads back the fingerprint the server actually observed, and compares it to the browser
profile you expect. If it drifted, the build goes red — the day the regression lands, not the day you
get blocked.

## How it works

1. Your client (or plain `curl`) makes a request to a **reflector** — a server that echoes back the
   JA3/JA4/JA4H/Akamai-h2 it saw on the wire, as JSON. The default is our live reflector
   `https://fp.shshbshsnang.shop/api/all`.
2. The Action reads `ja4` / `ja3_hash` / `akamai_h2` from that JSON.
3. It resolves the **expected** values — either a JA4 you pin directly (`expect-ja4`), or a named
   browser profile (`expect-profile: chrome`) looked up live from
   [fingerprint-db](https://github.com/North-web-dev/fingerprint-db) so nothing is hardcoded and stale.
4. It compares the asserted `fields` and sets `match`. On mismatch it fails the build (unless
   `fail-on-mismatch: false`).

There are two ways to feed the reflector:

- **`run` mode (recommended for real clients).** You give a shell command that makes *your* client hit
  the reflector and prints the JSON response to stdout. The reflector URL is exported as `$FP_REFLECTOR`.
  The Action parses whatever JSON your command printed.
- **Default mode (no `run`).** The Action fetches the reflector itself with plain `curl`. `curl` is
  *not* a browser, so this is mainly useful as a negative/self-test (and as a sanity check that the
  reflector is reachable).

## Quick start

Pin the moving major tag `@v1` (Actions convention).

```yaml
# .github/workflows/fingerprint.yml
name: fingerprint
on: [push, pull_request]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # build / prepare your impersonating client here, e.g.:
      # - run: go build -o fetch ./cmd/fetch

      - name: Assert the client still looks like Chrome
        uses: North-web-dev/fingerprint-check-action@v1
        with:
          # your client fetches the reflector and prints its JSON body:
          run: ./fetch "$FP_REFLECTOR"
          expect-profile: chrome      # JA4 looked up live from fingerprint-db
          fields: ja4                 # assert the stable field (see caveats)
          fail-on-mismatch: true
```

### Pin an exact JA4 instead of a named profile

```yaml
      - uses: North-web-dev/fingerprint-check-action@v1
        with:
          run: ./fetch "$FP_REFLECTOR"
          expect-ja4: t13d1516h2_8daaf6152771_d8a2da3f94cd
          fields: ja4
```

### Using the captured values downstream

```yaml
      - id: fp
        uses: North-web-dev/fingerprint-check-action@v1
        with:
          run: ./fetch "$FP_REFLECTOR"
          expect-profile: chrome
      - run: echo "observed JA4 = ${{ steps.fp.outputs.ja4 }} (match=${{ steps.fp.outputs.match }})"
```

### curl_cffi example

```yaml
      - run: pip install curl_cffi
      - uses: North-web-dev/fingerprint-check-action@v1
        with:
          run: python -c "from curl_cffi import requests as r; print(r.get('$FP_REFLECTOR', impersonate='chrome').text)"
          expect-profile: chrome
          fields: ja4,akamai_h2
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `reflector` | `https://fp.shshbshsnang.shop/api/all` | Reflector URL that echoes the observed fingerprint as JSON. Exported to `run` as `$FP_REFLECTOR`. |
| `run` | *(empty)* | Shell command that makes your client hit the reflector and prints the JSON response to stdout. When empty, the Action fetches the reflector with plain `curl`. |
| `expect-profile` | *(empty)* | Named browser profile (`chrome`, `edge`, `firefox`, `safari`, `ios`) whose expected JA4 / JA3-hash / Akamai-h2 are looked up live from fingerprint-db. |
| `expect-ja4` | *(empty)* | Explicit target JA4 string. Overrides `expect-profile` for the `ja4` field. |
| `expect-ja3-hash` | *(empty)* | Explicit target JA3 hash. Used only when `fields` includes `ja3_hash`. |
| `expect-akamai-h2` | *(empty)* | Explicit target Akamai HTTP/2 fingerprint. Used only when `fields` includes `akamai_h2`. |
| `fields` | `ja4` | Comma-separated fields to assert: any of `ja4`, `ja3_hash`, `akamai_h2`. |
| `fail-on-mismatch` | `true` | Fail the build on mismatch. Set `false` to report `match=false` without failing. |
| `profiles-url` | `…/fingerprint-db/main/fingerprints.json` | Source for `expect-profile` lookups. Override to pin a tag/commit. |

## Outputs

| Output | Description |
|---|---|
| `ja4` | The JA4 the reflector observed. |
| `ja3-hash` | The JA3 hash the reflector observed. |
| `akamai-h2` | The Akamai HTTP/2 fingerprint the reflector observed. |
| `user-agent` | The User-Agent the reflector observed. |
| `match` | `true` when every asserted field matched the expected profile, else `false`. |

## How it's implemented

A **composite action** (`action.yml` + a single POSIX `bash` script, `fingerprint-check.sh`). Its only
runtime dependencies are `bash`, `curl` and `jq` — all preinstalled on GitHub-hosted runners — plus
`python3` (also preinstalled) used only as a lenient JSON extractor when your command prints log lines
around the response. No Docker image to build, no `node_modules`, so it starts in well under a second.

## Honest caveats

These are real limitations — read them before you trust a green check:

- **JA4 drifts with browser versions.** A "real Chrome" JA4 today is not the Chrome JA4 in six months.
  When you use `expect-profile`, you inherit whatever fingerprint-db currently calls "chrome", which is
  re-measured periodically. When you use `expect-ja4`, **re-pin it periodically** or your check becomes
  a check against a browser nobody runs anymore. This Action tells you *your client changed*; it cannot
  tell you *the world's browsers changed* — keep the target fresh.
- **Do not assert JA3 for Chrome/Edge.** Chromium randomizes its ClientHello extension order (GREASE),
  so its **JA3 is non-deterministic** and will flap. JA4 buckets this out and is stable — assert `ja4`.
  `ja3_hash` assertions are only meaningful for clients with a deterministic ClientHello.
- **Akamai HTTP/2 ordering can legitimately vary** between runs/versions of some clients; an
  `akamai_h2` mismatch is a weaker signal than JA4. Treat it as advisory unless you know your client is
  deterministic.
- **The reflector sees the last hop.** If your `run` command routes through a proxy, TLS-terminating
  egress, or a corporate MITM, you measure *that* hop's fingerprint, not your client's. Run it with a
  direct connection.
- **This is a liveness/regression check, not an anti-detection guarantee.** Matching a reflector's
  JA3/JA4/Akamai is necessary but not sufficient to evade a determined anti-bot system (which also looks
  at behaviour, IP reputation, TLS session tickets, etc.). A green check means "still looks like the
  browser we pinned", not "undetectable".
- **Default mode measures `curl`, not your client.** It exists for self-test and reachability. For a
  meaningful assertion of *your* client, use `run`.
- **Availability of the public reflector is best-effort.** For production CI you may want to
  [self-host fpcheck](https://github.com/North-web-dev/fpcheck) and point `reflector` at it.

## Sibling tools

- **[impersonate-http](https://github.com/North-web-dev/impersonate-http)** — Go `http.Client` with a
  byte-exact browser TLS fingerprint (uTLS).
- **[impersonate-rs](https://github.com/North-web-dev/impersonate-rs)** — the Rust counterpart.
- **[fpcheck](https://github.com/North-web-dev/fpcheck)** — self-hostable TLS/HTTP2 fingerprint
  reflector + differ. Run your own reflector and point `reflector` at it.
- **[fingerprint-db](https://github.com/North-web-dev/fingerprint-db)** — measured browser JA3/JA4 +
  Akamai fingerprints as JSON; the source for `expect-profile` lookups.

## Self-test

[`.github/workflows/selftest.yml`](.github/workflows/selftest.yml) runs this Action against the live
reflector on every push and weekly:

- **curl-is-not-a-browser** — asserts the runner's plain `curl` against the `chrome` profile with
  `fail-on-mismatch: false`, then verifies `match == false`. Proves the reflector fetch, the
  fingerprint-db lookup, and the JA4 comparison all work, and that a true mismatch is reported honestly.
- **self-match** — captures the reflector's own view of the runner, then asserts the Action matches that
  exact JA4 with `fail-on-mismatch: true`. Proves the positive path returns `match == true` and exit 0.

## Support

If this saved you from shipping a broken fingerprint, a ⭐ on the repo helps others find it.

| Coin | Address |
|---|---|
| **BTC** | `bc1q0sfghv7yfl594gjurhyhlhdgm0dtwh4dkjha36` |
| **ETH / USDT-ERC20 / BNB-BEP20** | `0xB827b5a8B6c5111946c5D872933b2C23484E87dE` |
| **SOL** | `3ch5aHrPp3CierhiNXmqmtFH2dMHh6Gfv7a97KtLMMCh` |
| **USDT-TRC20 / TRX** | `TUAyz7TjgJdFVD2oFHWUUTNrzzAnBRgySG` |
| **TON** | `UQAJmYVuR3hh02etjaPKJF-h6jcpdSnq9ZIFvI64NEskS6tx` |

## License

[MIT](LICENSE) © 2026 North-web-dev
