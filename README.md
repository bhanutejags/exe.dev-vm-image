# exe.dev-vm-image

A custom [exe.dev](https://exe.dev) VM image: the upstream
[`exeuntu`](https://github.com/boldsoftware/exeuntu) base plus a handful of
developer CLI tools, so a fresh VM is ready out of the box.

## What's in it

On top of `exeuntu` (Ubuntu 24.04 + systemd, git, jq, ripgrep, neovim, gh, Go,
uv, Docker, Claude Code, codex, pi, fd, …):

| Tool                                                                                                                                                         | Source                     |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------- |
| `nvim`, `zellij`, `eza`, `starship`, `nu`, `jj`, `chezmoi`, `btm`, `procs`, `tldr`, `tree-sitter`, `yazi` (+ `ya`), `cargo-binstall`, `zoxide`, `bat`, `fzf` | mise (`github:` backend)   |
| `mise`                                                                                                                                                       | GitHub release (bootstrap) |
| `zsh`                                                                                                                                                        | apt (Ubuntu universe)      |
| oh-my-zsh + 4 zsh plugins                                                                                                                                    | git clone (baked)          |

The CLI tools are installed **declaratively** from a single
[`image-tools.toml`](image-tools.toml) manifest via [mise](https://mise.jdx.dev);
mise auto-detects the host arch (the image builds natively per-arch), so there is
no per-tool arch table. Versions resolve to **latest** at build time. Each tool's
binary is symlinked onto `/usr/local/bin` as a real binary (no `mise activate`
needed).

`zsh` is installed but not set as the default login shell. We bake a **current**
`nvim` (the base's is too old for the dotfiles' config) and symlink it over the
base's `/usr/bin/nvim` — that path sits earlier than `/usr/local/bin` on exe.dev's
`PATH`, so ours has to win explicitly. We also bake the `tree-sitter` CLI the
dotfiles use to build parsers. `fd` (already in the base,
but only at pi's private path) is symlinked onto `PATH` since the dotfiles expect
it there. **oh-my-zsh** and the
four zsh plugins the dotfiles' `.zshrc` sources (`zsh-autosuggestions`,
`zsh-syntax-highlighting`, `forgit`, `zsh-you-should-use`) are baked into
`~/.local/share/zsh/plugins` so first login has a working, fully-featured shell
without a network round-trip — the dotfiles still own `.zshrc` and source them
from there as a Homebrew-independent fallback. `rustup` is installed as the Rust
toolchain manager only (no toolchain) — `cargo`/`rustc` fetch the project-pinned
toolchain on first use — plus `cargo-binstall` for installing prebuilt Rust
binaries (run `cargo-binstall <crate>` directly; it needs no toolchain).
`~/workplace` is pre-created (owned by `exedev`) for checking out projects.

## Using it

```bash
ssh exe.dev new --image=ghcr.io/bhanutejags/exe.dev-vm-image:latest
```

The GHCR package must be **public** for exe.dev to pull it (otherwise pass
`--registry-auth USER:PASSWORD`). The image opts into exe.dev's native Shelley
installation, so new VMs receive the current Shelley automatically.

## Staying in sync with `exeuntu`

The base is **pinned by digest** in the [`Dockerfile`](Dockerfile). Dependabot
opens a PR when upstream publishes a new digest; merging it triggers the
[publish workflow](.github/workflows/build-publish.yml), which builds each arch
on a native runner (no QEMU), assembles a multi-arch manifest, and pushes
`:latest` to GHCR. A weekly schedule and manual dispatch also rebuild to refresh
the latest-resolving tools.

Re-pin the digest by hand with:

```bash
docker buildx imagetools inspect ghcr.io/boldsoftware/exeuntu:latest
```

## Local build

```bash
docker buildx build --secret id=github_token,env=GITHUB_TOKEN -t exe.dev-vm-image:dev .
```

`GITHUB_TOKEN` is optional but avoids GitHub API rate limits when resolving tool
versions.
