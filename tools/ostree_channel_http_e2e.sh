#!/bin/bash
# SPEC-006 P5c: prove the buckos-update agent pulls + deploys a signed release
# from a channel served over plain static HTTP — the P5 success criterion — and
# fails closed on an unsigned channel served the same way.
#
# Unlike tools/ostree_update_e2e.sh (file:// channels), this exercises the HTTP
# path: a client resolves the ref from the (signed) summary the channel rule
# emits, then fetches objects over HTTP. The repos are served by a stock
# `python3 -m http.server` — the "static HTTP, reuse mirror infra" model.
#
# Requires: unprivileged user namespaces + python3. Self-skips (exit 0) without
# them. $BUCK2 overrides the buck2 binary (CI sets BUCK2=buck2).
set -eu

if [ "${1:-}" != "--inner" ]; then
  cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /home/hodgesd/buckos-build)"
  BB=$PWD
  BUCK2=${BUCK2:-./buck2}
  if ! unshare -r true 2>/dev/null; then echo "SKIP: no unprivileged user namespaces"; exit 0; fi
  command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }

  echo "### build the ostree+agent slice"
  "$BUCK2" build //packages/linux/system/ostree-image:ostree-update-rootfs >/dev/null 2>&1
  ROOT=$BB/$("$BUCK2" build //packages/linux/system/ostree-image:ostree-update-rootfs \
             --show-output 2>/dev/null | awk 'NF>=2{print $NF}')
  if [ ! -x "$ROOT/usr/bin/ostree" ] || [ ! -x "$ROOT/usr/bin/buckos-update" ]; then
    echo "SKIP: could not build the ostree-update slice"; exit 0
  fi
  export E2E_BB=$BB E2E_ROOT=$ROOT
  exec unshare -r "$0" --inner
fi

# ---- inner: root-in-userns ---------------------------------------------------
BB=$E2E_BB; ROOT=$E2E_ROOT
W=${W:-/tmp/ostree_channel_http_e2e}; rm -rf "$W"; mkdir -p "$W"

LD="$ROOT/lib64/ld-linux-x86-64.so.2"; LIBS="$ROOT/usr/lib:$ROOT/lib64"
wrap(){ printf '#!/bin/sh\nexec "%s" --library-path "%s" "%s" "$@"\n' \
  "$LD" "$LIBS" "$ROOT/usr/bin/$1" > "$W/$1"; chmod +x "$W/$1"; }
wrap ostree; OSTREE="$W/ostree"; export BUCKOS_OSTREE="$OSTREE"
wrap buckos-update; UPDATE="$W/buckos-update"
KEY="$BB/defs/keys/ostree-test.ed25519.key"            # ed25519 secret (base64)
SECRET="$(head -1 "$KEY")"
PUB="$(cat "$BB/defs/keys/ostree-test.ed25519.pub")"   # ed25519 public (base64)
REF=buckos/x86_64/stable

mktree(){  # $1=dir $2=marker — a minimal but deployable OS tree
  mkdir -p "$1/usr/bin" "$1/usr/lib/modules/6.0.0" "$1/usr/etc"
  echo "$2" > "$1/usr/bin/marker"
  printf 'ID=buckos\n' > "$1/usr/lib/os-release"
  echo kernel > "$1/usr/lib/modules/6.0.0/vmlinuz"
}

mkchannel(){  # $1=repo $2=tree $3=sign? — build a channel repo (commit + summary)
  "$OSTREE" --repo="$1" init --mode=archive-z2 >/dev/null
  "$OSTREE" --repo="$1" config set core.min-free-space-percent 0
  "$OSTREE" --repo="$1" commit --branch="$REF" --tree=dir="$2" \
    --timestamp=@1700000000 --owner-uid=0 --owner-gid=0 --no-bindings --no-xattrs >/dev/null
  if [ "${3:-}" = sign ]; then
    "$OSTREE" --repo="$1" sign --sign-type=ed25519 --keys-file="$KEY" \
      "$("$OSTREE" --repo="$1" rev-parse "$REF")"
    "$OSTREE" --repo="$1" summary --update --sign="$SECRET" --sign-type=ed25519
  else
    "$OSTREE" --repo="$1" summary --update
  fi
}

SRV_PIDS=""
serve(){  # $1=dir $2=port — static HTTP server; waits until it accepts
  ( cd "$1" && exec python3 -m http.server "$2" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  SRV_PIDS="$SRV_PIDS $!"
  for _ in $(seq 1 50); do
    if python3 -c "import socket,sys; sys.exit(0 if socket.socket().connect_ex(('127.0.0.1',$2))==0 else 1)" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}
trap 'for p in $SRV_PIDS; do kill "$p" 2>/dev/null || true; done' EXIT

init_sysroot(){  # $1=sysroot
  mkdir -p "$1"; "$OSTREE" admin init-fs --modern "$1" >/dev/null
  "$OSTREE" --repo="$1/ostree/repo" config set core.min-free-space-percent 0
  "$OSTREE" admin stateroot-init --sysroot="$1" buckos >/dev/null
}
add_remote(){  # $1=sysroot $2=url
  "$OSTREE" remote add --repo="$1/ostree/repo" buckos "$2" "$REF" \
    --set=sign-verify=true --set=verification-ed25519-key="$PUB"
}
agent(){ "$UPDATE" --sysroot="$1" --os=buckos --remote=buckos --branch="$REF" "${@:2}"; }

rc=0; pass(){ echo "  PASS: $1"; }; fail(){ echo "  FAIL: $1"; rc=1; }

echo "### publish a SIGNED channel + an UNSIGNED channel over static HTTP"
mktree "$W/treeA" A; mkchannel "$W/good" "$W/treeA" sign
mktree "$W/treeU" U; mkchannel "$W/bad"  "$W/treeU"
serve "$W/good" 18080 || { echo "SKIP: http.server could not bind 18080"; exit 0; }
serve "$W/bad"  18081 || { echo "SKIP: http.server could not bind 18081"; exit 0; }
GOOD=http://127.0.0.1:18080/ ; BAD=http://127.0.0.1:18081/

echo "### 1. agent pull over HTTP (must be signature-verified)"
SYS="$W/sysroot"; init_sysroot "$SYS"; add_remote "$SYS" "$GOOD"
agent "$SYS" pull >/dev/null 2>&1 && pass "pulled a signed release over static HTTP" || fail "HTTP pull failed"

echo "### 2. agent deploy the HTTP release"
agent "$SYS" deploy >/dev/null 2>&1 && pass "deployed the release pulled over HTTP" || fail "deploy failed"
[ -e "$SYS"/ostree/deploy/buckos/deploy/*.0/usr/bin/marker ] && pass "deployment checked out" || fail "no deployment"

echo "### 3. fail-closed: an UNSIGNED channel over HTTP is rejected"
SYS2="$W/sys2"; init_sysroot "$SYS2"; add_remote "$SYS2" "$BAD"
if agent "$SYS2" pull >/dev/null 2>&1; then fail "pulled an unsigned commit over HTTP"
else pass "rejected an unsigned commit over HTTP (sign-verify)"; fi

echo "### result"
[ "$rc" = 0 ] && echo "OSTREE_CHANNEL_HTTP_E2E_OK: agent pulls+deploys a signed release over static HTTP and fails closed on unsigned" \
              || echo "OSTREE_CHANNEL_HTTP_E2E FAILED (see $W)"
exit $rc
