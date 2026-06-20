# syntax=docker/dockerfile:1

# Custom exe.dev VM image: the exeuntu base plus extra developer CLI tools.
# Base is pinned by digest; Dependabot bumps it. Re-pin by hand with:
#   docker buildx imagetools inspect ghcr.io/boldsoftware/exeuntu:latest
FROM ghcr.io/boldsoftware/exeuntu:latest@sha256:a4a4a2b5d0fbbba51aed65825f9f720bdf90325ee764f8bce771824f6fd71252

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
    NVIM_ARCH="x86_64"
    TS_ARCH="x64"
    UNAME_ARCH="x86_64"
    ;;
  arm64)
    MISE_ARCH="arm64"
    CHEZMOI_ARCH="arm64"
    RUST_MUSL="aarch64-unknown-linux-musl"
    GNU_TRIPLE="aarch64-unknown-linux-gnu"
    NVIM_ARCH="arm64"
    TS_ARCH="arm64"
    UNAME_ARCH="aarch64"
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
# starship only ships a musl build for aarch64 (no gnu), so use musl for both
# arches — it's statically linked and runs everywhere.
STARSHIP_VERSION="$(gh_latest starship/starship)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-${RUST_MUSL}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/starship" "${BINDIR}/starship"

# --- nushell (secondary structured-data shell) ---
# Tags have no leading "v"; the tarball extracts into a versioned dir.
NU_VERSION="$(gh_latest nushell/nushell)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/nushell/nushell/releases/download/${NU_VERSION}/nu-${NU_VERSION}-${GNU_TRIPLE}.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/nu-${NU_VERSION}-${GNU_TRIPLE}/nu" "${BINDIR}/nu"

# --- cargo-binstall (install prebuilt Rust binaries, no compiling) ---
CARGO_BINSTALL_VERSION="$(gh_latest cargo-bins/cargo-binstall)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/cargo-bins/cargo-binstall/releases/download/v${CARGO_BINSTALL_VERSION}/cargo-binstall-${RUST_MUSL}.tgz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/cargo-binstall" "${BINDIR}/cargo-binstall"

# --- neovim (editor) ---
# The base ships an older apt neovim; the dotfiles' config targets a current
# release (vanilla 0.12: lsp/ dir + builtin treesitter, no nvim-treesitter
# plugin), so bake the official prebuilt tarball. It unpacks bin/ + lib/ +
# share/ — copy the whole tree into /usr/local so bin/nvim lands on PATH
# (shadowing the base) and share/nvim/runtime is found.
NVIM_VERSION="$(gh_latest neovim/neovim)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-linux-${NVIM_ARCH}.tar.gz" |
  tar xz -C "${tmp}"
cp -a "${tmp}/nvim-linux-${NVIM_ARCH}/." /usr/local/

# --- tree-sitter CLI ---
# Used by the dotfiles' run_onchange parser-build script (nvim-treesitter was
# archived; the CLI replaces its parser management). Asset is a single
# gzipped binary, not a tarball.
TREE_SITTER_VERSION="$(gh_latest tree-sitter/tree-sitter)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/tree-sitter/tree-sitter/releases/download/v${TREE_SITTER_VERSION}/tree-sitter-linux-${TS_ARCH}.gz" |
  gunzip >"${tmp}/tree-sitter"
install -m 0755 "${tmp}/tree-sitter" "${BINDIR}/tree-sitter"

# --- procs (modern ps; dotfiles alias pst/psw/psc/psm) ---
# Release filename embeds the version; asset is a zip containing the binary.
PROCS_VERSION="$(gh_latest dalance/procs)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/dalance/procs/releases/download/v${PROCS_VERSION}/procs-v${PROCS_VERSION}-${UNAME_ARCH}-linux.zip" \
  -o "${tmp}/procs.zip"
unzip -qo "${tmp}/procs.zip" -d "${tmp}"
install -m 0755 "${tmp}/procs" "${BINDIR}/procs"

# --- tldr (tealdeer; dotfiles run `tldr --update`) ---
# Asset is a bare binary (no archive).
TEALDEER_VERSION="$(gh_latest tealdeer-rs/tealdeer)"
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/tealdeer-rs/tealdeer/releases/download/v${TEALDEER_VERSION}/tealdeer-linux-${UNAME_ARCH}-musl" \
  -o "${tmp}/tldr"
install -m 0755 "${tmp}/tldr" "${BINDIR}/tldr"

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
cargo-binstall -V  # cargo-binstall uses --version for the crate version; -V prints its own
nvim --version
tree-sitter --version
procs --version
tldr --version
EOF

# ---------------------------------------------------------------------------
# 3. rustup — the Rust toolchain manager only, with NO toolchain installed.
#    Installs the rustup manager + cargo/rustc proxy shims (~15 MB) but no
#    rustc/cargo/std. The real toolchain installs on demand the first time a
#    project needs it (e.g. a rust-toolchain.toml) or via
#    `rustup toolchain install`. Kept in the exedev home so on-demand installs
#    need no sudo; the proxies are symlinked onto the system PATH.
#    We fetch the official rustup-init binary directly (no `curl | sh`).
# ---------------------------------------------------------------------------
ENV RUSTUP_HOME=/home/exedev/.rustup CARGO_HOME=/home/exedev/.cargo
USER exedev
RUN <<'EOF'
set -euxo pipefail
case "${TARGETARCH}" in
  amd64) RUST_HOST="x86_64-unknown-linux-gnu" ;;
  arm64) RUST_HOST="aarch64-unknown-linux-gnu" ;;
  *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL --retry 3 --proto '=https' --tlsv1.2 \
  "https://static.rust-lang.org/rustup/dist/${RUST_HOST}/rustup-init" -o "${tmp}/rustup-init"
chmod +x "${tmp}/rustup-init"
"${tmp}/rustup-init" -y --no-modify-path --default-toolchain none --profile minimal
"${CARGO_HOME}/bin/rustup" --version
EOF
USER root
RUN ln -sf "${CARGO_HOME}"/bin/* /usr/local/bin/

# ---------------------------------------------------------------------------
# 4. fd: the base ships fd but only at pi's private ~/.pi/agent/bin/fd, which
#    is NOT on the global PATH. The dotfiles assume `fd` is callable
#    (FZF_DEFAULT_COMMAND, the vv/zjw helpers, the chezmoi run-scripts), so
#    symlink the existing binary onto PATH rather than downloading a second
#    copy. (Depends on the base keeping that path; a move would surface as a
#    build-time failure of the smoke test below, not a silent breakage.)
# ---------------------------------------------------------------------------
RUN test -x /home/exedev/.pi/agent/bin/fd && \
    ln -sf /home/exedev/.pi/agent/bin/fd /usr/local/bin/fd && \
    fd --version

# ---------------------------------------------------------------------------
# 5. Shell framework: oh-my-zsh + the zsh plugins the dotfiles' .zshrc sources.
#    Baked here (small, stable git clones) so a fresh VM logs into a working,
#    fully-featured zsh with no network round-trip. The dotfiles still own
#    .zshrc; they source these plugins from ~/.local/share/zsh/plugins as a
#    Homebrew-independent fallback. .git dirs are stripped to keep it tiny.
#    Run as exedev so everything is owned by the login user.
# ---------------------------------------------------------------------------
USER exedev
RUN <<'EOF'
set -euxo pipefail
git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /home/exedev/.oh-my-zsh
PLUGIN_DIR=/home/exedev/.local/share/zsh/plugins
mkdir -p "${PLUGIN_DIR}"
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "${PLUGIN_DIR}/zsh-autosuggestions"
git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "${PLUGIN_DIR}/zsh-syntax-highlighting"
git clone --depth=1 https://github.com/wfxr/forgit "${PLUGIN_DIR}/forgit"
git clone --depth=1 https://github.com/MichaelAquilina/zsh-you-should-use "${PLUGIN_DIR}/zsh-you-should-use"
# Drop the git metadata — these are baked snapshots, not working trees.
find /home/exedev/.oh-my-zsh "${PLUGIN_DIR}" -name .git -type d -prune -exec rm -rf {} +
EOF
USER root

# Personal convention: projects live under ~/workplace. Create it up front,
# owned by the exedev login user, so a fresh VM is ready to clone into.
RUN install -d -o exedev -g exedev -m 0755 /home/exedev/workplace

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
