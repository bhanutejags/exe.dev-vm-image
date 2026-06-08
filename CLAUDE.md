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

- apt: `zoxide`, `bat` (symlinked from `batcat`), `zsh`, `fzf`
- GitHub releases: `btm` (bottom), `jj`, `mise`, `chezmoi`, `zellij`, `yazi`+`ya`,
  `eza`, `starship`, `nu` (nushell)

`zsh` is installed but not set as the login shell (the dotfiles own that via
`chsh`/`.zshrc`). `nu` is a secondary structured-data shell, not a login shell
(not POSIX) — don't `chsh` to it.

Before adding a tool, check the upstream
[`exeuntu` Dockerfile](https://github.com/boldsoftware/exeuntu/blob/main/Dockerfile)
— it already ships git, jq, ripgrep, neovim, gh, Go, uv, Docker, Claude Code,
codex, pi, fd, Chrome, Tailscale, etc. **Don't duplicate** those.

If `setup-exedev.sh` changes in the dotfiles repo, mirror the change here.

The image also pre-creates `~/workplace` (owned by `exedev`) — the personal
directory convention for checking out projects. Keep it.

Notes:

- The image is **multi-arch** (`linux/amd64`, `linux/arm64`). Use `TARGETARCH`
  (provided by buildx) for arch-specific download URLs; don't hardcode x86_64.
- GitHub-release tool versions resolve to **latest at build time**, so the
  weekly scheduled rebuild keeps them fresh. The in-Dockerfile GitHub API calls
  use the `github_token` BuildKit secret (never baked into a layer) to dodge the
  unauthenticated rate limit.
- `mise`'s tarball is `mise/bin/mise`; the others extract the binary at the top
  level (or under `yazi-<triple>/`).

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
