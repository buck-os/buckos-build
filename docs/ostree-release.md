# Releasing a signed ostree channel (SPEC-006 P5 / SPEC-007)

How BuckOS publishes a signed, over-the-air-updatable ostree channel, and how
the production signing key is kept out of the build.

## Model

Buck builds the channel **content** (`ostree_channel` → a commit on
`buckos/<arch>/<channel>` + a summary) hermetically, with **no production
secret** — so the build stays cacheable and reproducible. A separate, tag-gated
release job is the **only** place the production key appears: it re-signs the
commit + summary with the prod key and publishes the repo over static HTTP.

```
buck2 build buckos-channel-stable     # content only (dev/test-signed)
        │
        ▼
tools/ostree_publish_channel.sh       # trusted release context, has the secret
   strip dev sig → sign(prod) → re-sign summary(prod) → verify → publish
        │
        ▼
static HTTP root  ←  buckos-update agent pulls + verifies (baked prod pubkey)
```

The key never enters buck, `buck-out`, or the action cache. The script loads it
into a tmpfs file and shreds it on exit, and never echoes it.

## One-time setup

### 1. Generate the production keypair (offline, on a trusted machine)

Do **not** do this in CI or any shared session.

```bash
openssl genpkey -algorithm ed25519 -out buckos-release.pem
seed=$(openssl pkey -in buckos-release.pem -outform DER | tail -c 32)
pub=$( openssl pkey -in buckos-release.pem -pubout -outform DER | tail -c 32)
printf '%s%s' "$seed" "$pub" | base64 -w0    # SECRET  (64B) -> CI secret
printf '%s'   "$pub"         | base64 -w0    # PUBLIC  (32B) -> commit + bake
```

Keep an **offline backup** of the secret (password manager / hardware token).
Losing it forces a key rotation (SPEC-007 §10); leaking it does too.

### 2. Store the secret (CI)

A protected GitHub **Environment** named `release` (Settings → Environments):
required reviewers + restrict to tags. Then:

```bash
printf '%s' "$SECRET_B64" | gh secret set BUCKOS_OSTREE_SIGN_KEY \
  --env release --repo buck-os/buckos-build
```

(`printf`, not `echo`, so no trailing newline.) Also set the publish destination
(the static-HTTP root for the channel) as a variable:

```bash
gh variable set CHANNEL_PUBLISH_DEST --env release \
  --body 'user@host:/srv/www/ostree/stable'   # rsync target or local path
```

### 3. Provision an isolated runner

Add a dedicated, trusted self-hosted runner labelled `release` (or switch
`release.yml` to a GitHub-hosted runner). Do **not** reuse the
`[self-hosted, large]` pool — a job there could read the secret.

### 4. Bake the production public key into the image

So deployed systems verify prod releases. Commit the public half and swap the
trusted key (today it's the committed TEST key):

```bash
printf '%s\n' "$PUBLIC_B64" > defs/keys/ostree-release.ed25519.pub
```
```python
# defs/keys/BUCK
export_file(name = "ostree-release-pub", src = "ostree-release.ed25519.pub", visibility = ["PUBLIC"])
```
```python
# packages/linux/system/ostree-image/BUCK — on buckos-ostree-updatable-rootfs
# (and buckos-ostree-rootfs if you ship it):
trusted_key = "//defs/keys:ostree-release-pub",   # was //defs/keys:ostree-test-pub
```

The public key is safe to commit. The TEST key stays for fixtures + CI gates.

## Cutting a release

Push a version tag (or run the workflow manually):

```bash
git tag v0.1.0 && git push origin v0.1.0   # triggers .github/workflows/release.yml
```

The `publish-channel` job (after `release`-environment approval) builds the
channel, signs it with `$BUCKOS_OSTREE_SIGN_KEY`, and publishes it to
`$CHANNEL_PUBLISH_DEST`. `lts`/`mainline` are additional `ostree_channel`
targets published the same way.

### Manual / local (with the secret in your env)

```bash
CHANNEL_REPO=$(./buck2 build //packages/linux/system/ostree-image:buckos-channel-stable --show-output | awk 'NF>=2{print $NF}')
BUCKOS_OSTREE_SIGN_KEY="$SECRET_B64" \
  CHANNEL_REPO="$PWD/$CHANNEL_REPO" \
  CHANNEL_PUBLISH_DEST=/srv/www/ostree/stable \
  ./tools/ostree_publish_channel.sh
```

## Verifying

A deployed system trusts the channel via the baked pubkey + a `sign-verify=true`
remote (set by `ostree_rootfs`'s `remote_url`). End-to-end, the agent pulling a
signed release over HTTP and failing closed on an unsigned one is covered by
`tools/ostree_channel_http_e2e.sh` (nightly `ostree-channel-http`).

## Rotation

See SPEC-007 §10. Summary: generate the new key, ship the new pubkey **alongside**
the old in the image (trust overlap), re-sign current commits/summaries with the
new key (re-run the publish step — no rebuild), let clients update, then retire
the old key.
