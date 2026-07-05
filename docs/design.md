# Design: how this image installs and exposes developer tools

This records the design of the exe.dev VM image's tooling layer and the reasoning
behind it — including several things that were only learned by testing on a real
VM, which aren't obvious from the code.

## The layering

Two systems provision an exe.dev VM, with a deliberate split:

- **This image owns _tool install_** — it bakes the developer CLIs so a fresh VM
  is usable at first login with no network round-trip.
- **The dotfiles own _config_** — `.zshrc`, the Neovim config, etc., applied by
  `chezmoi apply` at boot.

Keeping the boundary clean is why the image doesn't run `chezmoi apply` or
Homebrew at build time (see [Rejected alternatives](#rejected-alternatives)).

## Tool install: a declarative mise manifest

The GitHub-release CLIs are installed **declaratively** from a single manifest,
[`image-tools.toml`](../image-tools.toml), consumed at **build time**:

```
COPY image-tools.toml /etc/mise/config.toml     # single source of truth
mise install --yes                              # resolve + download every tool
```

`mise install` runs at build, not runtime — the whole point of the image is that
tools are present at first login without a network round-trip. Deferring to boot
would defeat that (and the VM already runs a heavy `chezmoi apply` on boot).

This replaced ~150 lines of hand-rolled per-tool `curl`/`tar`/`unzip` blocks plus
a per-tool `TARGETARCH` naming table. The Dockerfile shrank 304 → ~185 lines.

### Backend: `github:`

Every tool uses mise's native **`github:` backend** (`github:owner/repo`), which
downloads release assets directly and auto-detects the host OS/arch/libc.

Why not the alternatives:

- **`aqua:`** — its curated registry is **missing arm64-linux assets** for some
  of our tools (e.g. `procs` reports `unsupported env: linux/arm64`). Caught by
  testing on arm64; would have shipped a broken arm64 image.
- **`ubi:`** — deprecated.

Uniform `github:` gives one mental model, arm64 safety, and no per-tool backend
bikeshedding. Versions are `latest`, resolved at build; the weekly rebuild keeps
them fresh. (`mise.lock` could pin checksums later if reproducibility matters.)

### Exposing tools on `PATH`: symlink to `/usr/local/bin`

mise does **not** install into a system `bin` dir. It installs into a nested,
versioned tree (`$MISE_DATA_DIR/installs/<tool>/<version>/…`) and exposes tools
via **shims** (need mise at runtime + shims dir on `PATH`) or **`mise activate`**
(login shells only). Neither gives plain binaries usable by `root`, `systemd`,
and non-login shells.

So after install we symlink the resolved binaries onto `/usr/local/bin`:

```
for d in $(mise bin-paths); do
  for f in "$d"/*; do
    [ -f "$f" ] && [ -x "$f" ] && ln -sf "$f" /usr/local/bin/
  done
done
```

A plain bash glob (not `find`, whose flags vary across images). It picks up
renamed commands (`btm`, `nu`) and multi-binary packages (yazi's `ya`) with no
per-tool mapping. `tealdeer`'s binary is `tealdeer`, so it gets an explicit
`tldr` alias symlink.

### Multi-arch: no arch table

The image is `linux/amd64` + `linux/arm64`. CI builds **each arch on a native
runner** (`ubuntu-24.04` / `ubuntu-24.04-arm`, no QEMU), so `mise install` runs
on real hardware of the target arch and resolves the right assets itself. There
is **no `TARGETARCH` mapping** anywhere — the same manifest and symlink loop run
unchanged on both arches. The only remaining arch branch is the mise and
rustup-init bootstraps (`uname -m`).

## PATH & shadowing (learned on a real VM)

This is the subtle part, and most of it was discovered by launching a VM, not by
reading code.

**exe.dev's login `PATH` puts `/usr/local/bin` almost last:**

```
1 ~/.local/bin   2 /bin   3 /usr/bin   …   7 /usr/local/bin   8 /snap/bin
```

So anything earlier in `/usr/bin` **shadows** our `/usr/local/bin` copy. Two
distinct sources of `/usr/bin` copies, handled differently:

- **`nvim` — a real in-image shadow.** The pinned base ships `nvim` 0.9.x in
  `/usr/bin`. We bake a current Neovim (the dotfiles' config needs it), so we
  **symlink ours over `/usr/bin/nvim`** and assert at build time that
  `/usr/bin/nvim` resolves into `$MISE_DATA_DIR`. (A plain `command -v` check
  can't catch a regression here: the build shell puts `/usr/local/bin` first,
  unlike the VM.)

- **`btm` / `zoxide` — NOT ours to fight.** Verified: the pinned base ships
  **neither**. The older `btm` 0.9.6 / `zoxide` 0.9.3 seen in `/usr/bin` on a VM
  come from **exe.dev's own VM provisioning**, which layers on top of this image.
  Overriding them from inside the image is futile — exe.dev re-lands them after
  our layers. We install current versions to `/usr/local/bin` (mirroring the
  dotfiles' Brewfile) and let the dotfiles' Homebrew provide current versions on
  apply, which win from an earlier `PATH` entry. An earlier iteration symlinked
  every tool into `/usr/bin` to force precedence; it was dropped once we found
  the shadow wasn't in the base.

`fd` and the rustup/cargo proxies live in `/usr/local/bin` only — nothing shadows
them (the base ships no `fd`/`cargo` on `PATH`).

## Caching

- The `RUN mise install` layer is cache-keyed on its instruction text + the
  `COPY`'d `image-tools.toml` — same semantics as the old curl block. "latest"
  re-resolves only on a cache miss, i.e. the weekly clean CI build.
- A BuildKit `--mount=type=cache` on mise's download dir speeds incremental
  rebuilds (skip re-fetching unchanged assets); the installs themselves live in
  the image at `MISE_DATA_DIR`, not the cache.
- **exe.dev caches images per repo.** A VM created right after a push — even one
  **pinned by digest** — was served stale content (the digest was recorded
  correctly but old bytes ran; the same digest pulled locally had the fix). So
  image updates don't reach new VMs promptly, and digest pins don't reliably bust
  it. This is exe.dev infrastructure, not something this repo controls.

## Rejected alternatives

- **`mise oci` (mise-oci)** — builds a tool-only OCI image _from scratch_ from a
  `mise.toml`. It can't extend our `exeuntu` base (which carries the exe.dev
  contract: the `exe.dev/login-user` label, `/usr/local/bin/init` CMD, systemd,
  the `exedev` user, Chrome/Tailscale/Go/uv/…), it's experimental, and its docs
  warn cross-platform builds fail. Wrong tool for "extend a base with CLIs."
- **`chezmoi apply` + Homebrew at build** — "reuse the dotfiles' install logic"
  means baking Linuxbrew and `brew bundle`-ing ~120 formulae: huge, slow, and it
  collapses the image-vs-dotfiles layering (the VM already runs that apply on
  boot). A `brewless` chezmoi profile would just fork the tool list, reintroducing
  the drift it was meant to kill.
- **mise shims / `mise activate` instead of symlinks** — leaves a runtime
  dependency on mise and only works in activated (login) shells; breaks
  `root`/`systemd`/non-login and the dotfiles' `nvim --headless` run-script.

## Open items

- **Dotfiles → config-only.** To fully realize the split, slim the startup
  `chezmoi apply` so it stops `brew bundle`-ing these CLIs. If that happens, the
  image becomes the _sole_ provider and the exe.dev-injected `btm`/`zoxide` (and
  the exe.dev image cache) become more important to solve.
- **`mise.lock`** — add if checksum-pinned, reproducible installs are wanted
  beyond "latest at build".
- **Report to exe.dev** — a digest-pinned image pull serving cached content is
  arguably a bug worth flagging.
