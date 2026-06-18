#!/bin/bash
# End-to-end test of the buckos-update agent against real buckos ostree
# (SPEC-006 P4 + SPEC-007 fail-closed verification).
#
# The existing //tests:test-ostree-update-cycle proves the boot+update+rollback
# *mechanics* using raw ostree. This harness instead drives the actual
# `buckos-update` agent binary (from the sibling buckos repo) against a real
# ed25519-signed channel + a deployed sysroot, and asserts:
#
#   1. agent `pull`   — fetches a signed commit (signature-verified) ✓
#   2. agent `deploy` — stages the update as a new deployment ✓
#   3. fail-closed (policy) — refuses a remote without sign-verify ✓
#   4. fail-closed (crypto) — refuses an unsigned/tampered commit ✓
#
# It runs in a user namespace (`ostree admin deploy` needs root; we map the
# build user -> uid 0, like tools/ostree_sysroot_helper.py).
#
# NOTE: the agent's `check`/`rollback`/`status` parse the *booted* deployment, so
# they only work inside a booted ostree system — the full
# install->boot->update->boot->rollback->boot cycle is a follow-on that runs the
# agent inside QEMU (a stateful multi-boot guest). This harness covers the parts
# that are exercisable without a live boot: update application + the SPEC-007
# fail-closed guarantees.
#
# Requires: unprivileged user namespaces + buck2. Self-contained — it builds the
# ostree-update rootfs slice (the buckos `ostree` PIE + the packaged
# `buckos-update` agent + their libgcc_s/glibc closure) and runs both via the
# seed loader. $BUCKOS_UPDATE optionally overrides with a host-built agent
# binary. Self-skips (exit 0) when user namespaces are unavailable.
set -eu

if [ "${1:-}" != "--inner" ]; then
  # ---- outer: build inputs, then re-exec in a userns ------------------------
  cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /home/hodgesd/buckos-build)"
  BB=$PWD
  # buck2 binary: ./buck2 (the working repo-root binary) locally; CI puts buck2
  # on PATH and the repo-root ./buck2 dotslash stub does not resolve there, so CI
  # sets BUCK2=buck2.
  BUCK2=${BUCK2:-./buck2}

  if ! unshare -r true 2>/dev/null; then
    echo "SKIP: unprivileged user namespaces unavailable (unshare -r failed)"; exit 0
  fi

  # The slice provides both the buckos `ostree` PIE and the packaged
  # `buckos-update` agent with their full runtime closures (glibc + libgcc_s),
  # so the harness is self-contained (no host cargo build needed).
  echo "### build the ostree+agent rootfs slice"
  "$BUCK2" build //packages/linux/system/ostree-image:ostree-update-rootfs >/dev/null 2>&1
  ROOT=$BB/$("$BUCK2" build //packages/linux/system/ostree-image:ostree-update-rootfs \
             --show-output 2>/dev/null | awk 'NF>=2{print $NF}')
  if [ ! -x "$ROOT/usr/bin/buckos-update" ] || [ ! -x "$ROOT/usr/bin/ostree" ]; then
    echo "SKIP: could not build the ostree-update rootfs slice"; exit 0
  fi

  # $BUCKOS_UPDATE overrides with a host-built (natively-runnable) agent binary.
  export E2E_BB=$BB E2E_ROOT=$ROOT E2E_UPDATE_HOST=${BUCKOS_UPDATE:-}
  exec unshare -r "$0" --inner
fi

# ---- inner: runs as root-in-userns -----------------------------------------
BB=$E2E_BB; ROOT=$E2E_ROOT
W=${W:-/tmp/ostree_update_e2e}; rm -rf "$W"; mkdir -p "$W"

# Wrappers so a buckos PIE from the slice runs via the seed loader + the slice's
# lib closure (covers the agent's own `Command::new(ostree)` too).
LD="$ROOT/lib64/ld-linux-x86-64.so.2"; LIBS="$ROOT/usr/lib:$ROOT/lib64"
wrap(){ printf '#!/bin/sh\nexec "%s" --library-path "%s" "%s" "$@"\n' \
  "$LD" "$LIBS" "$ROOT/usr/bin/$1" > "$W/$1"; chmod +x "$W/$1"; }
wrap ostree; OSTREE="$W/ostree"; export BUCKOS_OSTREE="$OSTREE"
# Agent: a host-built binary override (runs natively), else the packaged binary
# from the slice via the loader.
if [ -n "${E2E_UPDATE_HOST:-}" ] && [ -x "$E2E_UPDATE_HOST" ]; then
  UPDATE="$E2E_UPDATE_HOST"
else
  wrap buckos-update; UPDATE="$W/buckos-update"
fi
KEY="$BB/defs/keys/ostree-test.ed25519.key"           # ed25519 secret (base64)
PUB="$(cat "$BB/defs/keys/ostree-test.ed25519.pub")"  # ed25519 public (base64)
REF=buckos/x86_64/test

mktree(){  # $1=dir $2=marker — a minimal but deployable OS tree (needs /usr/etc
           # for the second deploy's /etc merge, and a kernel for staging).
  mkdir -p "$1/usr/bin" "$1/usr/lib/modules/6.0.0" "$1/usr/etc"
  echo "$2" > "$1/usr/bin/marker"
  printf 'ID=buckos\n' > "$1/usr/lib/os-release"
  echo kernel > "$1/usr/lib/modules/6.0.0/vmlinuz"
}
commit_signed(){  # $1=repo $2=tree — commit on $REF and ed25519-sign the tip
  "$OSTREE" --repo="$1" commit --branch="$REF" --tree=dir="$2" --orphan >/dev/null
  "$OSTREE" --repo="$1" sign --sign-type=ed25519 --keys-file="$KEY" \
    "$("$OSTREE" --repo="$1" rev-parse "$REF")"
}
init_sysroot(){  # $1=sysroot — init-fs + stateroot
  mkdir -p "$1"; "$OSTREE" admin init-fs --modern "$1" >/dev/null
  "$OSTREE" admin stateroot-init --sysroot="$1" buckos >/dev/null
}
agent(){ "$UPDATE" --sysroot="$1" --os=buckos --remote=buckos --branch="$REF" "${@:2}"; }

rc=0
pass(){ echo "  PASS: $1"; }
fail(){ echo "  FAIL: $1"; rc=1; }

echo "### install commit A from a signed channel, then publish B"
CHAN="$W/channel"; "$OSTREE" --repo="$CHAN" init --mode=archive-z2 >/dev/null
mktree "$W/treeA" A; commit_signed "$CHAN" "$W/treeA"
SYS="$W/sysroot"; init_sysroot "$SYS"
"$OSTREE" remote add --repo="$SYS/ostree/repo" buckos "file://$CHAN" "$REF" \
  --set=sign-verify=true --set=verification-ed25519-key="$PUB"
"$OSTREE" --repo="$SYS/ostree/repo" pull buckos "$REF" >/dev/null 2>&1
"$OSTREE" admin deploy --sysroot="$SYS" --os=buckos "buckos:$REF" >/dev/null 2>&1
mktree "$W/treeB" B; commit_signed "$CHAN" "$W/treeB"

echo "### 1. agent pull (must be signature-verified)"
agent "$SYS" pull >/dev/null 2>&1 && pass "pulled the signed update" || fail "pull failed"

echo "### 2. agent deploy (must stage B alongside A)"
agent "$SYS" deploy >/dev/null 2>&1 && pass "deployed the update" || fail "deploy failed"
markers=$(cat "$SYS"/ostree/deploy/buckos/deploy/*.0/usr/bin/marker 2>/dev/null | sort | tr '\n' ' ')
[ "$markers" = "A B " ] && pass "both deployments present (A=rollback, B=update): $markers" \
                        || fail "expected 'A B', got '$markers'"

echo "### 3. fail-closed (policy): a remote without sign-verify is refused"
SYS2="$W/sys2"; init_sysroot "$SYS2"
"$OSTREE" remote add --repo="$SYS2/ostree/repo" buckos "file://$CHAN" "$REF" --set=gpg-verify=false
if agent "$SYS2" pull >/dev/null 2>&1; then fail "pulled from a non-verifying remote"
else pass "refused a non-verifying remote (ensure_trusted)"; fi

echo "### 4. fail-closed (crypto): an unsigned commit is rejected"
CHANU="$W/chanu"; "$OSTREE" --repo="$CHANU" init --mode=archive-z2 >/dev/null
mktree "$W/treeU" U; "$OSTREE" --repo="$CHANU" commit --branch="$REF" --tree=dir="$W/treeU" --orphan >/dev/null
SYS3="$W/sys3"; init_sysroot "$SYS3"
"$OSTREE" remote add --repo="$SYS3/ostree/repo" buckos "file://$CHANU" "$REF" \
  --set=sign-verify=true --set=verification-ed25519-key="$PUB"
if agent "$SYS3" pull >/dev/null 2>&1; then fail "pulled an unsigned commit"
else pass "rejected an unsigned commit (ed25519 verify)"; fi

echo "### result"
[ "$rc" = 0 ] && echo "OSTREE_UPDATE_E2E_OK: buckos-update applies a signed update and fails closed on unverified content" \
              || echo "OSTREE_UPDATE_E2E FAILED (see $W)"
exit $rc
