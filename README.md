# exe.dev-vm-image

A custom [exe.dev](https://exe.dev) VM image built on top of the upstream
[`exeuntu`](https://github.com/boldsoftware/exeuntu) base image, with my usual
developer tooling baked in so a freshly created VM is ready to go without
running a setup script.

## What's in it

Everything from the upstream `exeuntu` image (Ubuntu 24.04 + systemd, git, jq,
ripgrep, neovim, gh, Go, uv, Docker, Claude Code, codex, pi, fd, Chrome,
Tailscale, …) **plus** the tools I otherwise install on every VM via
`scripts/setup-exedev.sh` in my dotfiles repo, plus a few extra shell
quality-of-life tools:

| Tool                      | Source                |
| ------------------------- | --------------------- |
| `zoxide`, `bat`           | apt (Ubuntu universe) |
| `zsh`, `fzf`              | apt (Ubuntu universe) |
| `btm` (bottom)            | GitHub release        |
| `jj` (Jujutsu)            | GitHub release        |
| `mise`                    | GitHub release        |
| `chezmoi`                 | GitHub release        |
| `zellij`                  | GitHub release        |
| `yazi` (+ `ya`)           | GitHub release        |
| `eza` (modern `ls`)       | GitHub release        |
| `starship` (prompt)       | GitHub release        |
| `nu` (nushell, secondary) | GitHub release        |

`zsh` is installed but not forced as the login shell — the chezmoi dotfiles own
that. `nu` is a secondary structured-data shell, not a login shell (it isn't
POSIX). Tools already provided by `exeuntu` are not duplicated. The GitHub-release
tools resolve their **latest** version at build time, so a rebuild always picks
up the newest releases.

It also pre-creates `~/workspace` (owned by `exedev`) — the directory
convention I use for checking out projects.

## Using it

Create a VM from the published image:

```bash
ssh exe.dev new --image=ghcr.io/bhanutejags/exe.dev-vm-image:latest
```

The image preserves the contract exe.dev expects: it keeps the `exedev` login
user (`LABEL exe.dev/login-user=exedev`) and the systemd `init` entrypoint
(`CMD ["/usr/local/bin/init"]`) inherited from `exeuntu`.

> The GHCR package must be **public** (or you must pass `--registry-auth
USERNAME:PASSWORD` to `ssh exe.dev new`) for exe.dev to pull it. Make it
> public under the repo's _Packages_ settings after the first publish.

## How it stays in sync with upstream `exeuntu`

The base image is **pinned by digest** in the [`Dockerfile`](Dockerfile):

```dockerfile
FROM ghcr.io/boldsoftware/exeuntu:latest@sha256:034721bc...
```

1. **Dependabot** ([`.github/dependabot.yml`](.github/dependabot.yml)) watches
   the `:latest` tag. Upstream rebuilds it weekly for security fixes; whenever
   the digest changes, Dependabot opens a PR bumping the pinned `sha256`.
2. Merging that PR pushes to `main`, which triggers the **publish workflow**
   ([`.github/workflows/build-publish.yml`](.github/workflows/build-publish.yml)).
3. The workflow builds each architecture on a **native** GitHub-hosted runner
   (`amd64` on `ubuntu-24.04`, `arm64` on `ubuntu-24.04-arm` — no QEMU
   emulation), then a `merge` job combines the per-arch digests into one
   multi-arch manifest and pushes it to
   `ghcr.io/bhanutejags/exe.dev-vm-image:latest`.

A **weekly scheduled run** of the same workflow also rebuilds the image so the
latest-resolving GitHub-release tools stay fresh even between base-image bumps.
You can also trigger a build manually from the Actions tab (_Run workflow_).

Pull requests run the build as a smoke test (no push).

### Re-pinning the base digest by hand

```bash
docker buildx imagetools inspect ghcr.io/boldsoftware/exeuntu:latest
# copy the index Digest into the FROM line in the Dockerfile
```

### Prefer Renovate over Dependabot?

Dependabot is wired up by default (zero infra). If you'd rather use Renovate,
delete `.github/dependabot.yml` and add a `renovate.json` enabling
`pinDigests` for the `docker` and `github-actions` managers — it pins/updates
the base digest the same way.

## Local build

```bash
docker buildx build \
  --secret id=github_token,env=GITHUB_TOKEN \
  -t exe.dev-vm-image:dev .
```

`GITHUB_TOKEN` is optional but recommended — it lifts the unauthenticated
GitHub API rate limit used when resolving the latest tool versions.

## Repository layout

```
Dockerfile                          # the custom image
.github/workflows/build-publish.yml # multi-arch build + push to GHCR
.github/dependabot.yml              # base-image digest + actions updates
```
