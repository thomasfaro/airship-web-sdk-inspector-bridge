#!/usr/bin/env bash
# Make a usable Node.js available to the launcher, in this order:
#   1. a recent enough Node already on PATH (including nvm / fnm / mise / Homebrew)
#   2. the private copy a previous run installed in .node/
#   3. a fresh private copy downloaded from nodejs.org, checksum verified
#
# The private copy stays inside the bridge folder: no administrator password,
# nothing installed system-wide, and deleting .node/ undoes it completely.
#
# Sourced by scripts/start.sh — defines functions, exports PATH, never exits.

# 22, not 20: the bridge talks to the phone over the debugging protocol with the
# global WebSocket client, which Node only enables by default from v22. On v20 a
# scan succeeds and every read then fails with "WebSocket is not defined".
BRIDGE_MIN_NODE_MAJOR="${BRIDGE_MIN_NODE_MAJOR:-22}"
# Bump this to move to a newer Node line; any nodejs.org/dist channel name works.
BRIDGE_NODE_CHANNEL="${BRIDGE_NODE_CHANNEL:-latest-v22.x}"

_bridge_node_is_recent_enough() {
  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi
  local major
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  if [[ -z "$major" ]]; then
    return 1
  fi
  [[ "$major" -ge "$BRIDGE_MIN_NODE_MAJOR" ]]
}

# Version managers keep their Node outside the default PATH, and Finder starts a
# launcher without ever reading a shell profile.
_bridge_load_node_from_managers() {
  local had_u=0
  local had_e=0
  if [[ $- == *u* ]]; then had_u=1; fi
  if [[ $- == *e* ]]; then had_e=1; fi
  set +ue

  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
  fi
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env 2>/dev/null)"
  fi
  if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash 2>/dev/null)"
  fi

  local dir
  for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [[ -x "$dir/node" && ":$PATH:" != *":$dir:"* ]]; then
      PATH="$dir:$PATH"
      export PATH
    fi
  done

  if [[ "$had_u" == "1" ]]; then set -u; fi
  if [[ "$had_e" == "1" ]]; then set -e; fi
  return 0
}

_bridge_node_platform() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    *) return 1 ;;
  esac
}

_bridge_node_arch() {
  case "$(uname -m)" in
    arm64 | aarch64) echo "arm64" ;;
    x86_64 | amd64) echo "x64" ;;
    *) return 1 ;;
  esac
}

_bridge_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

_bridge_install_private_node() {
  local target_dir="$1"
  local platform arch dist_url shasums entry expected filename tmp actual

  if ! platform="$(_bridge_node_platform)"; then
    echo "Unsupported operating system: $(uname -s)." >&2
    return 1
  fi
  if ! arch="$(_bridge_node_arch)"; then
    echo "Unsupported processor: $(uname -m)." >&2
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is needed to download Node.js but is not available." >&2
    return 1
  fi

  dist_url="https://nodejs.org/dist/${BRIDGE_NODE_CHANNEL}"

  echo "Looking up the current Node.js release…"
  if ! shasums="$(curl -fsSL --retry 2 "${dist_url}/SHASUMS256.txt")"; then
    echo "Could not reach nodejs.org. Check the internet connection or your proxy settings." >&2
    return 1
  fi

  # Each line is "<sha256>  node-v22.17.0-darwin-arm64.tar.gz".
  entry="$(printf '%s\n' "$shasums" | grep -E "node-v[0-9.]+-${platform}-${arch}\.tar\.gz$" | head -1)"
  if [[ -z "$entry" ]]; then
    echo "nodejs.org has no ${platform}-${arch} build in the ${BRIDGE_NODE_CHANNEL} channel." >&2
    return 1
  fi
  expected="${entry%% *}"
  filename="${entry##* }"

  tmp="$(mktemp -d)"
  echo "Downloading ${filename} (about 50 MB, once)…"
  if ! curl -fL --retry 2 --progress-bar -o "${tmp}/${filename}" "${dist_url}/${filename}"; then
    rm -rf "$tmp"
    echo "The download failed." >&2
    return 1
  fi

  echo "Verifying the download…"
  if ! actual="$(_bridge_sha256 "${tmp}/${filename}")"; then
    rm -rf "$tmp"
    echo "No checksum tool available to verify the download." >&2
    return 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$tmp"
    echo "Checksum mismatch: the download is corrupted or was tampered with." >&2
    echo "Nothing was installed." >&2
    return 1
  fi

  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  if ! tar -xzf "${tmp}/${filename}" -C "$target_dir" --strip-components=1; then
    rm -rf "$tmp" "$target_dir"
    echo "Could not unpack Node.js." >&2
    return 1
  fi
  rm -rf "$tmp"

  if [[ ! -x "${target_dir}/bin/node" ]]; then
    echo "The unpacked Node.js looks incomplete." >&2
    return 1
  fi
}

# Returns 0 once `node` on PATH is recent enough, 1 if the user has to act.
ensure_node_available() {
  local root="$1"
  local private_dir="${root}/.node"
  local reply=""

  if _bridge_node_is_recent_enough; then
    return 0
  fi

  _bridge_load_node_from_managers
  if _bridge_node_is_recent_enough; then
    return 0
  fi

  if [[ -x "${private_dir}/bin/node" ]]; then
    PATH="${private_dir}/bin:$PATH"
    export PATH
    hash -r 2>/dev/null || true
    if _bridge_node_is_recent_enough; then
      echo "Using the Node.js copy in .node/ ($(node -v))."
      return 0
    fi
  fi

  if command -v node >/dev/null 2>&1; then
    echo "Node.js $(node -v) is installed, but the bridge needs version ${BRIDGE_MIN_NODE_MAJOR} or later."
  else
    echo "Node.js is not installed on this machine."
  fi
  echo ""
  echo "This launcher can install its own private copy of Node.js in:"
  echo "  ${private_dir}"
  echo ""
  echo "It needs no administrator password, changes nothing else on your machine,"
  echo "and deleting that folder removes it completely."
  echo ""

  if [[ "${BRIDGE_AUTO_INSTALL:-0}" == "1" ]]; then
    reply="y"
  elif [[ -t 0 ]]; then
    read -r -p "Install it now? [Y/n] " reply || reply="n"
  else
    echo "Start the launcher from a terminal window to answer this question," >&2
    echo "or install Node.js ${BRIDGE_MIN_NODE_MAJOR}+ yourself from https://nodejs.org." >&2
    return 1
  fi

  case "${reply:-y}" in
    y | Y | yes | YES | Yes) ;;
    *)
      echo ""
      echo "Nothing installed. Get Node.js ${BRIDGE_MIN_NODE_MAJOR}+ from https://nodejs.org,"
      echo "then start this launcher again."
      return 1
      ;;
  esac

  if ! _bridge_install_private_node "$private_dir"; then
    return 1
  fi

  PATH="${private_dir}/bin:$PATH"
  export PATH
  hash -r 2>/dev/null || true

  if ! _bridge_node_is_recent_enough; then
    echo "The private Node.js copy is not usable." >&2
    return 1
  fi

  echo "Node.js $(node -v) is ready."
  return 0
}
