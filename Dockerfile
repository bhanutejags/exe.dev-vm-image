# syntax=docker/dockerfile:1

# Custom exe.dev VM image: the exeuntu base plus extra developer CLI tools.
# Base is pinned by digest; Dependabot bumps it. Re-pin by hand with:
#   docker buildx imagetools inspect ghcr.io/boldsoftware/exeuntu:latest
FROM ghcr.io/boldsoftware/exeuntu:latest@sha256:d77236e6f434a229cb9d9ae3c1b61dd8795db83dc42b365f679e100af4983b64

# Most of the install steps below run as root (apt + binaries into /usr/local).
# The base image leaves USER=root before its CMD, so we are already root here,
# but make it explicit for clarity.
USER root
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# 1. apt: zsh only.
#    zsh is installed but NOT made the default login shell — the chezmoi
#    dotfiles own that decision (chsh / .zshrc). Everything else we used to
#    apt-install (zoxide, bat, fzf) now comes from mise in step 2, so it stays
#    on the single declarative tool list.
# ---------------------------------------------------------------------------
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y --no-install-recommends zsh && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. GitHub-release CLI tools, installed declaratively via mise.
#
#    The tool list lives in image-tools.toml (the single source of truth).
#    mise resolves each tool's latest release and the correct asset for the
#    HOST arch on its own — the image builds natively per-arch, so there is no
#    TARGETARCH mapping table anymore. We then symlink the resolved binaries
#    onto /usr/local/bin so they are real binaries on the system PATH: no mise
#    activation is needed for root / systemd / non-login shells, matching the
#    old direct-download behaviour.
#
#    mise itself is bootstrapped from its GitHub release first (it can't install
#    itself), and stays on PATH because the dotfiles run `mise activate` at
#    login. The github_token BuildKit secret feeds GITHUB_TOKEN so the github
#    backend and the bootstrap dodge the unauthenticated GitHub rate limit; it
#    never lands in a layer. A BuildKit cache mount on mise's download cache lets
#    incremental rebuilds skip re-fetching unchanged assets (the installs
#    themselves live in the image at MISE_DATA_DIR, not the cache).
# ---------------------------------------------------------------------------
ENV MISE_DATA_DIR=/usr/local/share/mise \
    MISE_CACHE_DIR=/var/cache/mise \
    MISE_CONFIG_FILE=/etc/mise/config.toml
COPY image-tools.toml /etc/mise/config.toml

RUN --mount=type=secret,id=github_token,required=false \
    --mount=type=cache,target=/var/cache/mise <<'EOF'
set -euxo pipefail

# Optional token: export it so both the bootstrap curl and mise's github backend
# authenticate to the GitHub API.
if [ -f /run/secrets/github_token ]; then
  export GITHUB_TOKEN="$(cat /run/secrets/github_token)"
fi
GH_AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && GH_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# --- bootstrap the mise binary (native arch via uname) ---
case "$(uname -m)" in
  x86_64)  MISE_ARCH="x64" ;;
  aarch64) MISE_ARCH="arm64" ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
MISE_VERSION="$(curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  https://api.github.com/repos/jdx/mise/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
curl -fsSL --retry 3 "${GH_AUTH[@]}" \
  "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${MISE_ARCH}-musl.tar.gz" |
  tar xz -C "${tmp}"
install -m 0755 "${tmp}/mise/bin/mise" /usr/local/bin/mise

# --- install every tool on the manifest ---
mise install --yes

# --- expose the resolved binaries on the system PATH ---
# Symlink every executable in each tool's bin dir onto /usr/local/bin (real
# binaries, so root / systemd / non-login shells need no `mise activate`). Plain
# bash glob, not find, so it's independent of the base's find flavour. Covers
# renamed commands (nvim/btm/nu) and multi-binary packages (yazi's `ya`) with no
# per-tool mapping. nvim finds its runtime relative to the resolved binary.
for d in $(mise bin-paths); do
  for f in "$d"/*; do
    [ -f "$f" ] && [ -x "$f" ] && ln -sf "$f" /usr/local/bin/
  done
done
# tealdeer's binary is `tealdeer`; the dotfiles (and everyone) call it `tldr`.
ln -sf "$(command -v tealdeer)" /usr/local/bin/tldr
# nvim must beat the base's apt nvim regardless of /usr/local/bin PATH order.
ln -sf "$(mise which nvim)" /usr/bin/nvim

# --- smoke-test everything ---
mise ls --installed
for c in zsh nvim zellij eza starship nu jj chezmoi btm procs tldr \
         tree-sitter yazi ya cargo-binstall zoxide bat fzf; do
  command -v "$c" >/dev/null || { echo "MISSING on PATH: $c" >&2; exit 1; }
done
nvim --version | head -1
cargo-binstall -V  # cargo-binstall uses --version for the crate; -V prints its own
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
case "$(uname -m)" in
  x86_64)  RUST_HOST="x86_64-unknown-linux-gnu" ;;
  aarch64) RUST_HOST="aarch64-unknown-linux-gnu" ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
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
