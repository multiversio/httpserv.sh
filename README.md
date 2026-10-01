# httpserv.sh

[![CI](https://github.com/multiversio/httpserv.sh/actions/workflows/ci.yml/badge.svg)](https://github.com/multiversio/httpserv.sh/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A single-file Java 25 shebang script that serves a directory over HTTP.
Built on the JDK's built-in `com.sun.net.httpserver` with virtual threads.
No build step, no dependencies — just drop `httpserv` on your `$PATH` and run.

## Features

- Single executable file (`httpserv`) — runs via `java --source 25`
- Virtual-thread-per-request executor
- RFC 7233 range requests: single ranges, multi-range `multipart/byteranges`, and
  `If-Range` — useful for COGs, video, resumable downloads
- Directory listing with sorted entries and human-readable sizes
- Read-only: `GET`, `HEAD`, `OPTIONS`, `TRACE`
- Optional `ETag` header (value = file's `lastModified` timestamp in millis)
- Optional authentication: Basic, Bearer, API Key, Custom Header (repeatable, any match)
- Network conditioning: `--latency` and `--bandwidth` to simulate a distant, throttled bucket
- Path-traversal protection
- Access log includes the `Range` header when present

## Requirements

- JDK 25 or newer on `$PATH` (tested with Temurin 25)

## Install

The installed binary is named `httpserv.sh` to avoid colliding with the NSS
test server that Homebrew ships as `/opt/homebrew/bin/httpserv`.

Clone and use the provided Makefile:

```sh
git clone https://github.com/multiversio/httpserv.sh.git
cd httpserv.sh
sudo make install            # installs to /usr/local/bin/httpserv.sh
```

The install target respects the standard `PREFIX` and `DESTDIR` variables, so
you can install without `sudo` into a user-writable location:

```sh
make install PREFIX=$HOME/.local      # -> ~/.local/bin/httpserv.sh
```

To uninstall:

```sh
sudo make uninstall          # or: make uninstall PREFIX=$HOME/.local
```

Alternatively, download the raw script directly:

```sh
curl -fsSL https://raw.githubusercontent.com/multiversio/httpserv.sh/main/httpserv.sh \
  -o ~/.local/bin/httpserv.sh && chmod +x ~/.local/bin/httpserv.sh
```

## Testing

```sh
make test            # runs test/run.sh (curl against a live server)
```

Or drive the scripts directly:

```sh
./test/smoke.sh      # open-server tests
./test/ranges.sh     # RFC 7233 range request compliance
./test/auth.sh       # auth + range-with-auth tests
./test/latency.sh    # --latency
./test/bandwidth.sh  # --bandwidth
./test/admin.sh      # lab endpoints: counters and runtime conditioning
```

They all honor `PORT=...` and `HTTPSERV=...` env overrides. CI runs the exact same
scripts — no duplicated logic.

## Usage

```
httpserv.sh [options] [directory]

  -d, --dir DIR     directory to serve (default: .)
  -p, --port PORT   listen port (default: 8080)
  -s, --silent      suppress access logging
  -e, --etag        send ETag header (value = lastModified millis)
      --latency DUR fixed delay before each file response; a starting
                    value, replaceable at runtime by the lab endpoint
                      (e.g. 150ms, 2s, 1500us; bare number = ms)
      --bandwidth RATE  throttle the whole server's response throughput;
                    a starting value, replaceable by the lab endpoint
                      (e.g. 10MB/s, 500KB/s; /s optional, 1024-based)
  -a, --auth SPEC   require authentication (repeatable; any match passes)
                      basic:USER:PASS
                      bearer:TOKEN
                      api-key:HEADER:VALUE
                      header:H1=V1,H2=V2,...   (all headers required)
  -h, --help        show this help
```

Examples:

```sh
httpserv.sh                          # serve current dir on :8080
httpserv.sh -p 9000 ./public         # serve ./public on :9000
httpserv.sh --etag --silent /data    # ETags on, no access logs
```

## Authentication

Pass `--auth` one or more times. The server accepts a request as authorized if **any** of the configured credentials matches. With no `--auth` flags, the server is open.

```sh
httpserv.sh --auth basic:alice:s3cret                 # HTTP Basic
httpserv.sh --auth bearer:eyJhbGciOi...               # OAuth/JWT Bearer
httpserv.sh --auth api-key:X-API-Key:abc123           # single-header API key
httpserv.sh --auth header:X-Tenant=acme,X-Env=prod    # multi-header (all required)
```

Multiple schemes can be combined — handy for testing clients that try different auth strategies:

```sh
httpserv.sh \
  --auth basic:alice:s3cret \
  --auth bearer:tok123 \
  --auth api-key:X-API-Key:abc
```

A request that fails authorization gets `401 Unauthorized`. `WWW-Authenticate` challenges are emitted for Basic and Bearer when those schemes are configured.

Schemes map to `io.tileverse.rangereader.http.*Authentication` classes: `BasicAuthentication`, `BearerTokenAuthentication`, `ApiKeyAuthentication`, `CustomHeaderAuthentication`. Digest is intentionally unsupported for now.

## Range requests

Range handling follows [RFC 7233](https://datatracker.ietf.org/doc/html/rfc7233).
Every file response advertises `Accept-Ranges: bytes`.

- **Single range** — `206 Partial Content` with a `Content-Range` header and the
  requested bytes as the body.
- **Multiple ranges** — `206` with a `multipart/byteranges` payload. Each part
  repeats the representation's `Content-Type` and states its own `Content-Range`,
  and the parts keep the order the client listed them in. Ranges are never
  coalesced or reordered, and there is no cap on how many a client may ask for.
- **Suffix ranges** — `bytes=-N` returns the last N bytes; an N larger than the
  file returns the whole file.
- **Clamping** — a `last-byte-pos` past the end of the file is clamped to the
  last byte.
- **`If-Range`** — evaluated against the `ETag` (with `--etag`) and against
  `Last-Modified`, using strong comparison. A validator that no longer matches
  makes the server ignore `Range` and answer `200` with the whole file, which is
  what lets a client resume a download without splicing stale bytes.

`416 Range Not Satisfiable`, with `Content-Range: bytes */<length>`, comes back
when no requested range overlaps the file, when a suffix length is zero, or when
any spec is invalid (`last-byte-pos` before `first-byte-pos`). One invalid spec
rejects the whole set.

`Range` is ignored, and the whole file returned, when the range unit is not
`bytes` or when the header value does not parse as a byte-range-set.

`HEAD` is answered from the same evaluation as `GET`: same status, same
`Content-Range`, same `Content-Length`, no body. RFC 7233 section 3.1 asks
servers to ignore `Range` on any method other than `GET`, but Apache, nginx,
Caddy and S3 all answer `206` here, and RFC 7231 section 4.3.2 asks a `HEAD`
response to mirror the header fields of the matching `GET`. Standing in for
those object stores matters more here than the letter of section 3.1, so a
client probing range support with `HEAD` sees what they would send.

## Network conditioning

These flags reproduce the quirks of a remote object store so clients can be
tested against realistic conditions.

### `--latency`

Adds a fixed delay before each file response is sent, simulating the round-trip
time to a distant bucket. Virtual threads make the `sleep` cheap.

```sh
httpserv.sh --latency 150ms        # 150 ms before every file response
httpserv.sh --latency 2s           # a painfully distant region
httpserv.sh --latency 1500us       # sub-millisecond precision
```

Values accept a `us`, `ms`, or `s` suffix; a bare number is milliseconds. The
delay applies only to file responses (`200`/`206`); error responses (`404`,
`403`, `401`), redirects, and directory listings stay instant.

### `--bandwidth`

Throttles response body throughput against one budget for the whole server,
metering bytes as they are written and holding the sender back to the configured
rate. Pairs with `--latency` to model a high-latency, fat-pipe object store.

```sh
httpserv.sh --bandwidth 10MB/s     # cap every response body at 10 MB/s
httpserv.sh --bandwidth 500KB/s    # a slow link
httpserv.sh --latency 150ms --bandwidth 5MB/s   # both at once
```

Values accept `B`, `KB`, `MB`, or `GB` units (1024-based, case-insensitive); a
bare number is bytes. The trailing `/s` is optional. The throttle covers every
response body, including single-range and `multipart/byteranges` reads.

One budget covers the whole server rather than one budget per response. Eight
parallel reads share the configured rate, the way they share a real link; a
per-response throttle would hand each of them the full rate and a client that
merged its ranges would appear to gain nothing.

### Lab endpoints

Three endpoints on the `/_admin` context serve a measurement run. They are always
on, and they stay outside every counter and outside the bandwidth budget: a run's
own polling never lands in its own numbers.

```sh
curl -X POST 'localhost:8080/_admin/conditioning?latency=25ms&bandwidth=125MB/s'
curl localhost:8080/_admin/conditioning
# {"latencyMillis":25,"bandwidthBytesPerSecond":131072000}
```

`POST /_admin/conditioning` replaces the named halves of the conditioning under a
running server; an omitted half is left alone, and a bare `0` turns that half off.
`GET` reads it back.

```sh
curl -X POST localhost:8080/_admin/counters/reset
# ... the run ...
curl localhost:8080/_admin/counters
# {"requests":41,"rangeSpecs":2317,"wholeResponses":0,"singleRangeResponses":3,
#  "multipartResponses":38,"bytesSent":248901123,"status":{"206":41}}
```

`GET /_admin/counters` reports what the server actually served since the last
reset: requests, the range specs summed over every `Range` header, the three
response shapes, the bytes written, and the status histogram. `POST
/_admin/counters/reset` zeroes all of them and answers `204`. A client that
believes it moved N bytes can be checked against `bytesSent`, and the count of
merged fetches against `requests`.

## Log format

```
[2026-04-18T20:05:21.349Z]  "GET /opendata/file.tif" "okhttp/5.3.2" Range: bytes=0-16383
```

## Roadmap

`httpserv` primarily exists to test other components — `imageio-ext`, `tileverse`,
GeoTools, GeoServer — against cloud-native formats like COG, PMTiles, and GeoParquet.
Planned enhancements are geared at reproducing the quirks of real object-storage
backends (S3, GCS, Azure Blob) rather than general-purpose static hosting.

### Network conditioning

- **`--ttfb <duration>`** — separate "time-to-first-byte" from streaming rate so we
  can model high-latency-but-fat-pipe object stores independently of throughput.
- **`--jitter <pct>`** — randomize latency/bandwidth by ±pct to avoid lockstep clients.

Runtime conditioning is delivered: `POST /_admin/conditioning` moves latency and
bandwidth under a running server, hence a sweep over network profiles needs no
restart between points.

### Failure injection

- **`--fail-rate <pct>`** — return `503 Service Unavailable` on a configurable
  fraction of requests. Exercises client retry/backoff logic.
- **`--fail-ranges-rate <pct>`** — only fail requests that carry a `Range` header
  (COG readers are especially sensitive to partial-read failures).
- **`--truncate-rate <pct>`** — close the connection mid-response. Tests how clients
  handle short reads on range requests.

### HTTP behavior

- **Conditional requests** — honor `If-None-Match` / `If-Modified-Since` → `304 Not
  Modified`. Pairs with the existing `--etag` flag to validate cache logic.
- **`--tls`** — serve over HTTPS with an on-the-fly self-signed certificate. Some
  libraries take different code paths on TLS (connection pooling, ALPN, etc.).

### Observability

- **`--log-jsonl <file>`** — structured access log: method, path, range, status,
  bytes sent, duration. Grep-able for perf regressions and request-pattern asserts.
- **Replay / whitelist mode** — load a manifest of allowed URL+range pairs; anything
  outside returns `403`. Lets tests assert the exact request pattern a client made.

The counting half of both items is delivered: `GET /_admin/counters` reports the
requests, range specs, response shapes, statuses and bytes of a window bounded by
a reset, which is what a perf run and a request-pattern assert need. A structured
per-request log remains open.

CORS is intentionally out of scope: consumers like GeoServer proxy requests
server-side, so the browser never talks to `httpserv` directly.

## License

MIT — see [LICENSE](LICENSE).

