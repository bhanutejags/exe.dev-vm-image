# syntax=docker/dockerfile:1

# Custom exe.dev VM image.
#
# Built on top of boldsoftware's "exeuntu" base image (the default exe.dev
# image). We layer on the developer tooling we install on every VM via
# scripts/setup-exedev.sh in the dotfiles repo, so that a freshly created VM
# already has them without running a setup script.
#
# Tools added (mirrors scripts/setup-exedev.sh in the dotfiles repo):
#   - zoxide, bat            (apt, Ubuntu universe)
#   - btm / bottom           (GitHub release — not reliably packaged for apt)
#   - jj (Jujutsu)           (GitHub release)
#   - mise                   (GitHub release)
#   - chezmoi                (GitHub release)
#   - zellij                 (GitHub release)
#   - yazi (+ ya)            (GitHub release)
#
# Everything the base image already ships (git, jq, ripgrep, neovim, gh, go,
# uv, docker, claude, codex, pi, fd, ...) is intentionally NOT duplicated here.
#
# The base image is pinned by digest so updates are explicit and reviewable.
# Dependabot (.github/dependabot.yml) opens a PR whenever upstream publishes a
# new digest, and the publish workflow rebuilds + pushes the result to GHCR.
# Re-pin the digest manually with:
#   docker buildx imagetools inspect ghcr.io/boldsoftware/exeuntu:latest
FROM ghcr.io/boldsoftware/exeuntu:latest@sha256:034721bc6e024074745d29588d7a287a2f8004d3476014bdd2f6b67fe4272aa6

# buildx populates TARGETARCH automatically (amd64 / arm64).
ARG TARGETARCH

# Most of the install steps below run as root (apt + binaries into
# /usr/local/bin). The base image leaves USER=root before its CMD, so we are
# already root here, but make it explicit for clarity.
USER root
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# 1. apt-installed tools: zoxide, bat, zsh, fzf
#    (bat installs the `batcat` binary on Debian/Ubuntu; we also symlink `bat`.)
#    zsh is installed but NOT made the default login shell — the chezmoi
#    dotfiles own that decision (chsh / .zshrc). nushell (added below) is a
#    secondary shell, not a login shell, since it isn't POSIX.
# ---------------------------------------------------------------------------
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y --no-install-recommends zoxide bat zsh fzf && \
    ln -sf /usr/bin/batcat /usr/local/bin/bat && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. GitHub-release binaries.
#    Versions are resolved at build time so a rebuild (weekly schedule or
#    manual dispatch) always picks up the latest upstream release. A
#    GITHUB_TOKEN BuildKit secret is used (when present) to avoid the
#    unauthenticated GitHub API rate limit on shared CI runners. The secret is
#    never written to a layer.
# ---------------------------------------------------------------------------
RUN --mount=type=secret,id=github_token,required=false <<'EOF'
set -euxo pipefail

# Read the optional token and build a curl auth header if we have one.
GH_AUTH=()
if [ -f /run/secrets/github_token ]; then
  TOKEN="$(cat /run/secrets/github_token)"
  [ -n "${TOKEN}" ] && GH_AUTH=(-H "Authorization: Bearer ${TOKEN}")
fi

# Latest release tag (with leading "v" stripped) for owner/repo.
gh_latest() {
  curl -fsSL --retry 3 "${GH_AUTH[@]}" \
    "https://api.github.com/repos/$1/releases/latest" |
    jq -r '.tag_name' | sed 's/^v//'
}

# Per-tool arch naming. buildx gives us amd64 / arm64.
case "${TARGETARCH}" in
  amd64)
    MISE_ARCH="x64"
    CHEZMOI_ARCH="amd64"
    RUST_MUSL="x86_64-unknown-linux-musl"
    GNU_TRIPLE="x86_64-unknown-linux-gnu"
    ;;
  arm64)
    MISE_ARCH="arm64"
    CHEZMOI_ARCH="arm64"
    RUST_MUSL="aarch64-unknown-linux-musl"
    GNU_TRIPLE="aarch64-unknown-linux-gnu"
    ;;
  *)
    echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2
    exit 1
    ;;
esac

BINDIR=/usr/local/bin
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- jj (Jujutsu VCS) ---
JJ_VERSION="$(gh_latest jj-vcs/jj)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/jj-vcs/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-${RUST_MUSL}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/jj" "${BINDIR}/jj"

# --- mise ---
MISE_VERSION="$(gh_latest jdx/mise)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${MISE_ARCH}-musl.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/mise/bin/mise" "${BINDIR}/mise"

# --- chezmoi ---
CHEZMOI_VERSION="$(gh_latest twpayne/chezmoi)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}/chezmoi_${CHEZMOI_VERSION}_linux_${CHEZMOI_ARCH}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/chezmoi" "${BINDIR}/chezmoi"

# --- zellij ---
ZELLIJ_VERSION="$(gh_latest zellij-org/zellij)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-${RUST_MUSL}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/zellij" "${BINDIR}/zellij"

# --- yazi (+ ya helper) ---
YAZI_VERSION="$(gh_latest sxyazi/yazi)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/sxyazi/yazi/releases/download/v${YAZI_VERSION}/yazi-${GNU_TRIPLE}.zip" \
  -o "${tmp}/yazi.zip"
unzip -qo "${tmp}/yazi.zip" -d "${tmp}"
install -m 0755 "${tmp}/yazi-${GNU_TRIPLE}/yazi" "${BINDIR}/yazi"
install -m 0755 "${tmp}/yazi-${GNU_TRIPLE}/ya" "${BINDIR}/ya"

# --- btm (bottom) ---
# Resolve via the bottom repo; its tags have no leading "v".
BTM_VERSION="$(gh_latest clementtsang/bottom)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/clementtsang/bottom/releases/download/${BTM_VERSION}/bottom_${GNU_TRIPLE}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/btm" "${BINDIR}/btm"

# --- eza (modern ls) ---
EZA_VERSION="$(gh_latest eza-community/eza)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}/eza_${GNU_TRIPLE}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/eza" "${BINDIR}/eza"

# --- starship (prompt) ---
STARSHIP_VERSION="$(gh_latest starship/starship)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-${GNU_TRIPLE}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/starship" "${BINDIR}/starship"

# --- nushell (secondary structured-data shell) ---
# Tags have no leading "v"; the tarball extracts into a versioned dir.
NU_VERSION="$(gh_latest nushell/nushell)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/nushell/nushell/releases/download/${NU_VERSION}/nu-${NU_VERSION}-${GNU_TRIPLE}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/nu-${NU_VERSION}-${GNU_TRIPLE}/nu" "${BINDIR}/nu"

# Smoke-test everything we just installed.
zoxide --version
bat --version
fzf --version
zsh --version
btm --version
jj --version
mise --version
chezmoi --version
zellij --version
yazi --version
eza --version
starship --version
nu --version
EOF

# Personal convention: projects live under ~/workspace. Create it up front,
# owned by the exedev login user, so a fresh VM is ready to clone into.
RUN install -d -o exedev -g exedev -m 0755 /home/exedev/workspace

# Re-assert the contract exe.dev expects from a VM image. These are inherited
# from the base, but we restate them so this image is self-documenting and
# resilient to base changes.
LABEL org.opencontainers.image.source="https://github.com/bhanutejags/exe.dev-vm-image"
LABEL org.opencontainers.image.description="Custom exe.dev VM image (exeuntu + personal dev tooling)"
LABEL "exe.dev/login-user"="exedev"

# The container entrypoint is systemd (via /usr/local/bin/init) and must run as
# root, exactly like the base image. Interactive logins land as `exedev` because
# of the exe.dev/login-user label above, not because of the container USER.
USER root
WORKDIR /home/exedev
CMD ["/usr/local/bin/init"]
