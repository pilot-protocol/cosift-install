# Install the signed Cosift CLI

Cosift CLI v0.2.7 connects to the same account as the agent installer and web app.
Use the official [v0.2.7 release](https://github.com/pilot-protocol/cosift/releases/tag/v0.2.7).
Each binary has a SHA-256 checksum and a minisign signature. The release also
publishes `cosift-minisign.pub`; its signing key ID is `6184E2C01CA477A6`.

## Linux and macOS

Install [minisign](https://jedisct1.github.io/minisign/) if it is not already
available. Then run this block. It downloads to a temporary directory, verifies
both checks, and installs only the verified binary in `~/.local/bin/cosift`.

```sh
(
  set -eu
  command -v minisign >/dev/null || { echo 'Install minisign first.' >&2; exit 1; }
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) asset=cosift-linux-amd64 ;;
    Linux/aarch64|Linux/arm64) asset=cosift-linux-arm64 ;;
    Darwin/x86_64) asset=cosift-darwin-amd64 ;;
    Darwin/arm64) asset=cosift-darwin-arm64 ;;
    *) echo 'Unsupported platform; see the release assets.' >&2; exit 1 ;;
  esac
  release=https://github.com/pilot-protocol/cosift/releases/download/v0.2.7
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  cd "$scratch"
  for file in "$asset" "$asset.sha256" "$asset.minisig" cosift-minisign.pub; do
    curl --proto '=https' --tlsv1.2 -fsSL "$release/$file" -o "$file"
  done
  if command -v sha256sum >/dev/null; then
    sha256sum -c "$asset.sha256"
  else
    shasum -a 256 -c "$asset.sha256"
  fi
  minisign -Vm "$asset" -p cosift-minisign.pub
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$asset" "$HOME/.local/bin/cosift"
)
export PATH="$HOME/.local/bin:$PATH"
cosift version
```

Keep `~/.local/bin` on your shell's `PATH`. A checksum or signature failure stops
the block before installation. Check the release's trusted version comment is
`cosift v0.2.7` followed by the selected asset name.

Download and run the pinned agent installer after installing the CLI:

```sh
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/pilot-protocol/cosift-install/v0.4.0/install.sh \
  -o install.sh
sh install.sh --cli
cosift request -query 'Rust async runtimes'
cosift contribute -credits
```

The installer detects your harnesses, signs in by email or reuses their verified
Cosift token, and saves the CLI session. Existing sessions are preserved. The
web app at [cosift.pilotprotocol.network](https://cosift.pilotprotocol.network)
uses the same account when you sign in with the same email.

## Windows

The release includes `cosift-windows-amd64.exe`, its `.sha256` and `.minisig`
files, and `cosift-minisign.pub`. Download them from the same official release.
Compare `Get-FileHash -Algorithm SHA256 .\cosift-windows-amd64.exe` with the
checksum file, then verify with:

```powershell
minisign -Vm .\cosift-windows-amd64.exe -p .\cosift-minisign.pub
```

Place the verified executable on your `PATH` as `cosift.exe`. The POSIX agent
installer currently supports Linux and macOS; Windows users can use the CLI's
explicit login options (`cosift login -help`) or run the Linux installer in WSL
with the Linux binary.
