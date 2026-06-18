#!/bin/bash
# SPEC-006 P5 / SPEC-007: sign a built ostree channel with the PRODUCTION release
# key and publish it over static HTTP.
#
# Design (option "b"): buck builds the channel content (commit + summary) with no
# production secret — hermetic, cacheable, reproducible. This release step, run
# only in a trusted context (a tag-gated CI job on a protected `release`
# environment), is the *only* place the secret appears. The secret never enters
# buck, buck-out, or the action cache.
#
# The secret is loaded into a tmpfs file and shredded on exit; it is never echoed
# (base64-of-binary can dodge CI log masking).
#
# Env:
#   BUCKOS_OSTREE_SIGN_KEY  (required) base64 ed25519 secret (seed||public, 64B)
#   CHANNEL_REPO            (required) path to the built channel repo (buck output)
#   CHANNEL_PUBLISH_DEST    (optional) rsync/cp destination = the static-HTTP root
#                           for this channel; if unset, sign only (no publish)
#   OSTREE                  (optional) ostree binary; else the buckos slice is used
#   BUCK2                   (optional) buck2 binary (default ./buck2)
set -eu

[ -n "${BUCKOS_OSTREE_SIGN_KEY:-}" ] || { echo "ERROR: BUCKOS_OSTREE_SIGN_KEY not set"; exit 2; }
[ -n "${CHANNEL_REPO:-}" ] || { echo "ERROR: CHANNEL_REPO not set"; exit 2; }
[ -d "$CHANNEL_REPO/objects" ] || { echo "ERROR: $CHANNEL_REPO is not an ostree repo"; exit 2; }

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /home/hodgesd/buckos-build)"
BB=$PWD
BUCK2=${BUCK2:-./buck2}

# ---- locate the buckos ostree (a PIE run via the seed loader + lib closure) ---
if [ -n "${OSTREE:-}" ]; then
  ost(){ "$OSTREE" "$@"; }
else
  SLICE=$BB/$(find buck-out/v2/gen/buckos -path '*__ostree-update-rootfs__/ostree-update-rootfs' 2>/dev/null | head -1)
  if [ ! -x "$SLICE/usr/bin/ostree" ]; then
    "$BUCK2" build //packages/linux/system/ostree-image:ostree-update-rootfs >/dev/null 2>&1 || true
    SLICE=$BB/$(find buck-out/v2/gen/buckos -path '*__ostree-update-rootfs__/ostree-update-rootfs' 2>/dev/null | head -1)
  fi
  [ -x "$SLICE/usr/bin/ostree" ] || { echo "ERROR: could not find a buckos ostree (set \$OSTREE)"; exit 2; }
  LD="$SLICE/lib64/ld-linux-x86-64.so.2"; LIBS="$SLICE/usr/lib:$SLICE/lib64"
  ost(){ "$LD" --library-path "$LIBS" "$SLICE/usr/bin/ostree" "$@"; }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ostree-publish.XXXXXX")
# Secret material lives only in tmpfs and is shredded on exit.
SHM=/dev/shm; [ -d "$SHM" ] && [ -w "$SHM" ] || SHM=$WORK
KEYFILE=$(mktemp "$SHM/buckos-ostree-key.XXXXXX"); chmod 600 "$KEYFILE"
PUBFILE=$(mktemp "$SHM/buckos-ostree-pub.XXXXXX"); chmod 600 "$PUBFILE"
cleanup(){ shred -u "$KEYFILE" "$PUBFILE" 2>/dev/null || rm -f "$KEYFILE" "$PUBFILE"; rm -rf "$WORK"; }
trap cleanup EXIT
printf '%s\n' "$BUCKOS_OSTREE_SIGN_KEY" > "$KEYFILE"

# The public half is the last 32 bytes of the (seed||public) secret — derive it
# so we can self-verify the signature without a second input.
if ! printf '%s' "$BUCKOS_OSTREE_SIGN_KEY" | base64 -d 2>/dev/null | tail -c 32 | base64 -w0 > "$PUBFILE"; then
  echo "ERROR: BUCKOS_OSTREE_SIGN_KEY is not valid base64"; exit 2
fi
printf '\n' >> "$PUBFILE"

# Work on a writable copy (buck outputs are read-only).
REPO="$WORK/repo"; cp -a "$CHANNEL_REPO" "$REPO"; chmod -R u+w "$REPO"
ost --repo="$REPO" config set core.min-free-space-percent 0

REF=$(ost --repo="$REPO" refs | head -1)
[ -n "$REF" ] || { echo "ERROR: channel repo has no ref"; exit 2; }
COMMIT=$(ost --repo="$REPO" rev-parse "$REF")
echo "### channel $REF -> $COMMIT"

# Strip any dev/test signature so the published commit carries ONLY the prod sig,
# then sign the commit + (re)sign the summary with the production key.
rm -f "$REPO/objects/${COMMIT:0:2}/${COMMIT:2}.commitmeta"
ost --repo="$REPO" sign --sign-type=ed25519 --keys-file="$KEYFILE" "$COMMIT"
ost --repo="$REPO" summary --update --sign="$(head -1 "$KEYFILE")" --sign-type=ed25519

# Self-verify: the production public key must verify the freshly signed commit.
if ost --repo="$REPO" sign --verify --sign-type=ed25519 --keys-file="$PUBFILE" "$COMMIT" >/dev/null 2>&1; then
  echo "### signed + verified with the production key"
else
  echo "ERROR: production key did not verify its own signature"; exit 1
fi

# Publish the signed repo to the static-HTTP root (reuse mirror infra).
if [ -n "${CHANNEL_PUBLISH_DEST:-}" ]; then
  echo "### publish -> $CHANNEL_PUBLISH_DEST"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$REPO/" "$CHANNEL_PUBLISH_DEST/"
  else
    case "$CHANNEL_PUBLISH_DEST" in
      *:*) echo "ERROR: remote dest needs rsync"; exit 2 ;;
      *) mkdir -p "$CHANNEL_PUBLISH_DEST"; cp -a "$REPO/." "$CHANNEL_PUBLISH_DEST/" ;;
    esac
  fi
  echo "OSTREE_CHANNEL_PUBLISHED_OK: $REF ($COMMIT) -> $CHANNEL_PUBLISH_DEST"
else
  echo "OSTREE_CHANNEL_SIGNED_OK: $REF ($COMMIT) signed (set CHANNEL_PUBLISH_DEST to publish)"
fi
