# exe.dev-vm-image

A custom [exe.dev](https://exe.dev) VM image: the upstream
[`exeuntu`](https://github.com/boldsoftware/exeuntu) base plus a handful of
developer CLI tools, so a fresh VM is ready out of the box.

## What's in it

On top of `exeuntu` (Ubuntu 24.04 + systemd, git, jq, ripgrep, neovim, gh, Go,
uv, Docker, Claude Code, codex, pi, fd, …):

| Tool                | Source                |
| ------------------- | --------------------- |
| `zoxide`, `bat`     | apt (Ubuntu universe) |
| `zsh`, `fzf`        | apt (Ubuntu universe) |
| `btm` (bottom)      | GitHub release        |
| `jj` (Jujutsu)      | GitHub release        |
| `mise`              | GitHub release        |
| `chezmoi`           | GitHub release        |
| `zellij`            | GitHub release        |
| `yazi` (+ `ya`)     | GitHub release        |
| `eza` (modern `ls`) | GitHub release        |
| `starship` (prompt) | GitHub release        |
| `nu` (nushell)      | GitHub release        |

GitHub-release tools resolve to their **latest** version at build time. `zsh` is
installed but not set as the default login shell. `rustup` is installed as the
Rust toolchain manager only (no toolchain) — `cargo`/`rustc` fetch the
project-pinned toolchain on first use — plus `cargo-binstall` for installing
prebuilt Rust binaries (run `cargo-binstall <crate>` directly; it needs no
toolchain). `~/workplace` is pre-created (owned by `exedev`) for checking out
projects.

## Using it

```bash
ssh exe.dev new --image=ghcr.io/bhanutejags/exe.dev-vm-image:latest
```

The GHCR package must be **public** for exe.dev to pull it (otherwise pass
`--registry-auth USER:PASSWORD`).

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
