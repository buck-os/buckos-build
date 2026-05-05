# NativeLink Action Cache

Local RE API v2 action cache for Buck2. Caches `http_file` downloads and
other cacheable actions so they survive `buck2 clean`.

## Start

```
docker compose -f infra/docker-compose.yml up -d
```

## Stop

```
docker compose -f infra/docker-compose.yml down
```

To also wipe cached data:

```
docker compose -f infra/docker-compose.yml down -v
```

## Configure Buck2

Add to `.buckconfig.local` (already gitignored):

```ini
[buckos]
remote_cache = true

[buck2_re_client]
engine_address = grpc://localhost:50051
action_cache_address = grpc://localhost:50051
cas_address = grpc://localhost:50051
tls = false

[buck2]
default_allow_cache_upload = true
```

## Verify

Check NativeLink is responding:

```
grpcurl -plaintext localhost:50051 build.bazel.remote.execution.v2.Capabilities/GetCapabilities
```

Test cache hit on rebuild:

```
buck2 build //packages/linux/core/coreutils:coreutils-src
buck2 clean
buck2 build //packages/linux/core/coreutils:coreutils-src
```

The second build should show action cache hits in `buck2 log last`.

## Cache Size Tuning

Default limits in `nativelink/config.json`:

| Store | Default   | Field                               |
|-------|-----------|-------------------------------------|
| CAS   | 2 TB      | `stores.CAS_MAIN...max_bytes`       |
| AC    | 200 GB    | `stores.AC_MAIN...max_bytes`        |

Edit `max_bytes` and restart the container. NativeLink evicts LRU entries
when the limit is reached.
