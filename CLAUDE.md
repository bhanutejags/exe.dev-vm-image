# CLAUDE.md

Guidance for Claude Code working in the **exe.dev-vm-image** repo.

## What this repo is

A custom [exe.dev](https://exe.dev) VM image built **on top of** the upstream
[`exeuntu`](https://github.com/boldsoftware/exeuntu) base image. It bakes in the
developer tooling we'd otherwise install per-VM via `scripts/setup-exedev.sh` in
the **dotfiles** repo, then publishes a multi-arch image to GHCR for use with
`ssh exe.dev new --image=...`.

See [exe.dev customization docs](https://exe.dev/docs/customization).

## Repo layout

```
Dockerfile                          # the custom image (FROM exeuntu, pinned by digest)
.github/workflows/build-publish.yml # multi-arch buildx build + push to GHCR
.github/dependabot.yml              # base-image digest + GitHub Actions updates
README.md                           # user-facing docs
```

## The exe.dev image contract — do not break these

When editing the `Dockerfile`, preserve everything exe.dev relies on (all
inherited from `exeuntu`):

- **`LABEL "exe.dev/login-user"="exedev"`** — exe.dev logs you in as `exedev`.
- **`CMD ["/usr/local/bin/init"]`** — the systemd init wrapper.
- **`USER root` at the end** — the container entrypoint (systemd) must run as
  root. The login user is controlled by the label above, **not** the container
  `USER`. Do not end the image as `USER exedev`.
- The `exedev` user is UID 1000 with `~/.local/bin` on `PATH`.

## What tooling to add

The image should contain exactly the tools that `scripts/setup-exedev.sh` in the
dotfiles repo installs, and **only those not already in `exeuntu`**. As of now:

- apt: `zsh` only (installed, not made the login shell — the dotfiles own that).
- GitHub-release CLI tools, installed **declaratively via mise** from the
  [`image-tools.toml`](image-tools.toml) manifest: `nvim` (current Neovim),
  `zellij`, `eza`, `starship`, `nu` (nushell), `jj`, `chezmoi`, `btm` (bottom),
  `procs`, `tldr` (tealdeer), `tree-sitter`, `yazi`+`ya`, `cargo-binstall`,
  `zoxide`, `bat`, `fzf`. `mise` itself is bootstrapped from its GitHub release
  first (it can't install itself) and stays on `PATH` for the dotfiles' `mise
activate`. See [How tools are installed](#how-tools-are-installed) below.
- `fd`: already in the base but only at pi's private `~/.pi/agent/bin/fd` (off
  `PATH`). Symlinked onto `PATH` — the dotfiles assume `fd` is callable
  (`FZF_DEFAULT_COMMAND`, the `vv`/`zjw` helpers, the chezmoi run-scripts).
  **Don't** download a second copy.
- oh-my-zsh + the four zsh plugins the dotfiles' `.zshrc` sources
  (`zsh-autosuggestions`, `zsh-syntax-highlighting`, `forgit`,
  `zsh-you-should-use`): shallow git clones baked into
  `~/.local/share/zsh/plugins` (`.git` stripped) so first login has a working,
  fully-featured zsh with no network round-trip. The dotfiles still own `.zshrc`
  and source the plugins from there as a Homebrew-independent fallback.
- `rustup` via rustup-init with `--default-toolchain none`: the Rust toolchain
  manager + proxy shims only, no `rustc`/`cargo`/`std` (installed on demand).
  Don't bake a full toolchain — it's huge and usually project-pinned.
- `cargo-binstall` installs prebuilt Rust binaries; run it as
  `cargo-binstall <crate>` (toolchain-free) — the `cargo binstall …` subcommand
  form needs a default toolchain set.

No `curl | bash` of external install scripts. Tools go on the
[`image-tools.toml`](image-tools.toml) mise manifest (declarative); the only
direct download left is the mise binary itself (bootstrap).

`zsh` is installed but not set as the login shell (the dotfiles own that via
`chsh`/`.zshrc`). `nu` is a secondary structured-data shell, not a login shell
(not POSIX) — don't `chsh` to it.

Before adding a tool, check the upstream
[`exeuntu` Dockerfile](https://github.com/boldsoftware/exeuntu/blob/main/Dockerfile)
— it already ships git, jq, ripgrep, neovim, gh, Go, uv, Docker, Claude Code,
codex, pi, fd, Chrome, Tailscale, etc. **Don't duplicate** those — with two
deliberate exceptions: we bake a **current** `neovim` (the base's apt one is too
old for the dotfiles' config) that shadows the base on `PATH`, and we symlink
the base's `fd` onto `PATH` (it ships only at pi's private path).

This image owns **tool install**; the dotfiles own **config** (neovim config,
`.zshrc`, etc.) applied by a lightweight startup `chezmoi apply` that no longer
installs these tools. The mise manifest mirrors the CLI subset of the dotfiles'
Brewfile — keep the two aligned when either moves.

The image also pre-creates `~/workplace` (owned by `exedev`) — the personal
directory convention for checking out projects. Keep it.

### How tools are installed

The [`image-tools.toml`](image-tools.toml) manifest is the single source of
truth. It's `COPY`d to `/etc/mise/config.toml`; `mise install` fetches every
tool, then the resolved binaries are symlinked onto `/usr/local/bin` (real
binaries, so root / systemd / non-login shells need no `mise activate`).

- **No arch table.** mise resolves the host arch itself, and the image builds
  natively per-arch, so there's no `TARGETARCH` mapping — the same manifest and
  the same symlink loop run unchanged on amd64 and arm64. (Only the mise and
  rustup-init bootstraps still branch on `uname -m`.)
- **Backends:** `aqua` where available (curated, checksum-verified, prebuilt),
  `ubi` for the few tools aqua lacks (e.g. `eza`). Neither compiles from source.
- **Versions** are `latest`, resolved at build, so the weekly scheduled rebuild
  keeps them fresh. The github backend and the mise bootstrap read the
  `github_token` BuildKit secret via `GITHUB_TOKEN` (never baked into a layer) to
  dodge the unauthenticated rate limit.
- **PATH / shadowing:** the symlink loop links every tool onto `/usr/local/bin`;
  renamed commands (`btm`/`nu`) and multi-binary packages (yazi's `ya`) are picked
  up automatically from `mise bin-paths`. On exe.dev VMs the login `PATH` puts
  `/usr/local/bin` _last_ (after `/usr/bin`), so anything earlier in `/usr/bin`
  wins. Only **`nvim`** is a real in-image shadow — the base ships an old `nvim`
  (0.9.x) in `/usr/bin`, so we symlink ours over it (with a build-time assertion
  that `/usr/bin/nvim` resolves into `MISE_DATA_DIR`; a plain `command -v` check
  can't catch it, since the build shell puts `/usr/local/bin` first). `btm`/`zoxide`
  are **not** overridden: the base ships neither — the older copies seen on a VM
  come from **exe.dev's own provisioning** (layered on top of this image), so
  fighting them here is futile; the dotfiles' brew provides current ones on apply.
- **Adding a tool:** add one line to `image-tools.toml`. Find its backend id
  with `mise registry <name>` and use the `github:<owner>/<repo>` form (uniform,
  arm64-safe, not deprecated like `ubi:`).

## Staying in sync with upstream exeuntu

The base is **pinned by digest**: `FROM ghcr.io/boldsoftware/exeuntu:latest@sha256:...`.

- **Dependabot** opens a PR whenever upstream publishes a new `:latest` digest
  (they rebuild weekly for security fixes). Merging it republishes our image.
- To re-pin by hand:
  ```bash
  docker buildx imagetools inspect ghcr.io/boldsoftware/exeuntu:latest
  # copy the index Digest into the FROM line
  ```

## Workflow / publishing

`.github/workflows/build-publish.yml` builds each arch on a **native** runner
(`amd64` on `ubuntu-24.04`, `arm64` on `ubuntu-24.04-arm` — no QEMU), pushes
each by digest, then a `merge` job assembles the multi-arch manifest and pushes
tags to `ghcr.io/bhanutejags/exe.dev-vm-image`:

- push to `main` touching `Dockerfile`/the workflow → publish `:latest`
- `workflow_dispatch` → manual build
- weekly `schedule` → refresh latest-resolving tools
- `pull_request` → build only (no push), as a smoke test

After the first publish, make the GHCR package **public** (or create VMs with
`--registry-auth USERNAME:PASSWORD`).

## Formatting

Run the mise task before committing (prettier over Markdown / YAML / JSON):

```bash
mise run fmt        # write
mise run fmt:check  # verify only (CI / pre-commit)
```

Tasks and the pinned prettier live in [`.mise.toml`](.mise.toml). The
`Dockerfile` is not prettier-formatted; keep it tidy by hand.

## Conventions

- Keep changes minimal and reviewable; the base image is pinned by digest on
  purpose so updates are explicit.
- Do **not** open a PR unless explicitly asked.
- Validate YAML (`python3 -c "import yaml; yaml.safe_load(open(f))"`) and, when
  possible, do a local `docker buildx build` smoke test before pushing — CI is
  the real test since this environment may not have Docker.
