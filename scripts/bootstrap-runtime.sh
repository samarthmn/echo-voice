#!/bin/bash
# Invoked only by explicit Setup, never by an inference request.
set -euo pipefail
ECHO_DATA_ROOT="${1:?Application data directory required}"
ECHO_SERVICE_SOURCE="${2:?Service source directory required}"
ECHO_RUNTIME="$ECHO_DATA_ROOT/runtime"
ECHO_ARCHIVES="$ECHO_RUNTIME/cache/bootstrap"
# Never follow a substituted managed-directory link during repair.
for directory in "$ECHO_DATA_ROOT" "$ECHO_RUNTIME" "$ECHO_RUNTIME/setup-tmp" "$ECHO_RUNTIME/bin" "$ECHO_RUNTIME/vendor" "$ECHO_RUNTIME/cache" "$ECHO_ARCHIVES" "$ECHO_RUNTIME/cache/uv" "$ECHO_RUNTIME/python" "$ECHO_RUNTIME/venv" "$ECHO_RUNTIME/service"; do
  if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }; then
    echo 'A managed runtime directory is invalid. Restore its location before setup.' >&2
    exit 1
  fi
done
mkdir -p "$ECHO_RUNTIME/setup-tmp" "$ECHO_RUNTIME/bin" "$ECHO_RUNTIME/vendor" "$ECHO_ARCHIVES"
ECHO_WORK="$(/usr/bin/mktemp -d "$ECHO_RUNTIME/setup-tmp/bootstrap.XXXXXX")"
trap '/bin/rm -rf "$ECHO_WORK"' EXIT
chmod 700 "$ECHO_DATA_ROOT" "$ECHO_RUNTIME" "$ECHO_WORK"
export TMPDIR="$ECHO_WORK"
export UV_CACHE_DIR="$ECHO_RUNTIME/cache/uv"
export UV_PYTHON_INSTALL_DIR="$ECHO_RUNTIME/python"
export UV_PROJECT_ENVIRONMENT="$ECHO_RUNTIME/venv"
export UV_NATIVE_TLS=true
export PYTHONDONTWRITEBYTECODE=1
ECHO_UV="$ECHO_RUNTIME/bin/uv"
ECHO_UV_SHA=1f921d491ba5ffeea774eb04d6681ecee379101341cbb1500394993b541bf3f4
ECHO_VOICE_SHA=7ec803afa7c94ccf96973edcda58debe9b145693
ECHO_ARCHIVE_SHA=aa04877d36838adb96f58577128f2049d8ef0e2ea5e14379936ac75929d1201c
progress() { printf '{"status":"%s"}\n' "$1"; }
verify() {
  local actual
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  actual="$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')"
  [ "$actual" = "$2" ]
}
cached_archive() {
  local archive="$1" expected="$2" url="$3" partial="$ECHO_WORK/$(basename "$1").download"
  if verify "$archive" "$expected"; then return; fi
  # Keep valid archives across setup invocations, so repair works offline. A
  # corrupt cache entry is never extracted or treated as an installed receipt.
  if [ -e "$archive" ] || [ -L "$archive" ]; then
    /bin/mv "$archive" "$ECHO_WORK/$(basename "$archive").invalid"
  fi
  /usr/bin/curl --http1.1 --fail --location --proto '=https' --tlsv1.2 --connect-timeout 30 --retry 3 "$url" -o "$partial"
  verify "$partial" "$expected" || { echo 'Downloaded dependency checksum mismatch.' >&2; exit 1; }
  /bin/mv "$partial" "$archive"
}
progress 'Verifying the local Python manager'
ECHO_UV_ARCHIVE="$ECHO_ARCHIVES/uv-0.11.21-aarch64-apple-darwin.tar.gz"
cached_archive "$ECHO_UV_ARCHIVE" "$ECHO_UV_SHA" 'https://github.com/astral-sh/uv/releases/download/0.11.21/uv-aarch64-apple-darwin.tar.gz'
/usr/bin/tar -xzf "$ECHO_UV_ARCHIVE" -C "$ECHO_WORK"
ECHO_VERIFIED_UV="$ECHO_WORK/uv-aarch64-apple-darwin/uv"
if [ -L "$ECHO_UV" ] || [ ! -f "$ECHO_UV" ] || [ ! -x "$ECHO_UV" ] || ! /usr/bin/cmp -s "$ECHO_VERIFIED_UV" "$ECHO_UV"; then
  progress 'Repairing the local Python manager'
  if [ -e "$ECHO_UV" ] || [ -L "$ECHO_UV" ]; then /bin/mv "$ECHO_UV" "$ECHO_WORK/uv.previous"; fi
  chmod 755 "$ECHO_VERIFIED_UV"
  if ! /bin/mv "$ECHO_VERIFIED_UV" "$ECHO_UV"; then
    if [ -e "$ECHO_WORK/uv.previous" ] || [ -L "$ECHO_WORK/uv.previous" ]; then /bin/mv "$ECHO_WORK/uv.previous" "$ECHO_UV"; fi
    exit 1
  fi
fi
progress 'Verifying the pinned speech engine'
ECHO_VOICE_ARCHIVE="$ECHO_ARCHIVES/VoiceStudio-$ECHO_VOICE_SHA.tar.gz"
cached_archive "$ECHO_VOICE_ARCHIVE" "$ECHO_ARCHIVE_SHA" "https://codeload.github.com/debpalash/VoiceStudio/tar.gz/$ECHO_VOICE_SHA"
/usr/bin/tar -xzf "$ECHO_VOICE_ARCHIVE" -C "$ECHO_WORK"
ECHO_VERIFIED_VOICE="$ECHO_WORK/VoiceStudio-$ECHO_VOICE_SHA"
ECHO_INSTALLED_VOICE="$ECHO_RUNTIME/vendor/VoiceStudio"
printf '%s\n' "$ECHO_VOICE_SHA" > "$ECHO_VERIFIED_VOICE/.echo-revision"
source_matches() {
  [ -d "$ECHO_INSTALLED_VOICE" ] && [ ! -L "$ECHO_INSTALLED_VOICE" ] || return 1
  [ -z "$(/usr/bin/find "$ECHO_INSTALLED_VOICE" ! -type d ! -type f -print -quit)" ] || return 1
  /usr/bin/diff -qr "$ECHO_VERIFIED_VOICE" "$ECHO_INSTALLED_VOICE" >/dev/null
}
if ! source_matches; then
  progress 'Repairing the pinned speech engine'
  if [ -e "$ECHO_INSTALLED_VOICE" ] || [ -L "$ECHO_INSTALLED_VOICE" ]; then
    /bin/mv "$ECHO_INSTALLED_VOICE" "$ECHO_WORK/VoiceStudio.previous"
  fi
  if ! /bin/mv "$ECHO_VERIFIED_VOICE" "$ECHO_INSTALLED_VOICE"; then
    if [ -e "$ECHO_WORK/VoiceStudio.previous" ] || [ -L "$ECHO_WORK/VoiceStudio.previous" ]; then
      /bin/mv "$ECHO_WORK/VoiceStudio.previous" "$ECHO_INSTALLED_VOICE"
    fi
    exit 1
  fi
fi
progress 'Preparing Python 3.11 and local speech libraries'
# Stage the bundle's service as a complete tree, avoiding stale files and links
# left by an older install. uv operates only after this managed tree is replaced.
/usr/bin/ditto "$ECHO_SERVICE_SOURCE" "$ECHO_WORK/service"
if [ -d "$ECHO_RUNTIME/service" ]; then /bin/mv "$ECHO_RUNTIME/service" "$ECHO_WORK/service.previous"; fi
if ! /bin/mv "$ECHO_WORK/service" "$ECHO_RUNTIME/service"; then
  if [ -d "$ECHO_WORK/service.previous" ]; then /bin/mv "$ECHO_WORK/service.previous" "$ECHO_RUNTIME/service"; fi
  exit 1
fi
"$ECHO_UV" sync --project "$ECHO_RUNTIME/service" --locked --no-dev --extra speech --python 3.11 --managed-python
progress 'Runtime ready'
# The EXIT trap removes only this invocation's extraction directory. Verified
# archives remain in the managed cache for subsequent verification and repair.
