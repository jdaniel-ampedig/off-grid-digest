#!/bin/zsh
set -eu

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <run-once|watch|dry-run|watch-dry-run|print-config>"
  exit 2
fi

MODE="$1"
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h:h}"
GO_DIR="$ROOT_DIR/offgrid-digest-go"
CONFIG_PATH="$ROOT_DIR/Support Files/config.ini"
HELPER_PATH="$GO_DIR/offgrid-digest"
SCHEME_LOG="$GO_DIR/XcodeSchemeOutput.log"

mkdir -p "$GO_DIR"
: > "$SCHEME_LOG"

log() {
  print -r -- "$*"
  print -r -- "$*" >> "$SCHEME_LOG"
}

run_and_log() {
  "$@" 2>&1 | tee -a "$SCHEME_LOG"
  return ${pipestatus[1]}
}

GO_BIN="$(command -v go || true)"
if [[ -z "$GO_BIN" ]]; then
  for candidate in /usr/local/go/bin/go /opt/homebrew/bin/go /usr/local/bin/go; do
    if [[ -x "$candidate" ]]; then
      GO_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "$GO_BIN" ]]; then
  log "error: Go toolchain not found."
  exit 1
fi

cd "$GO_DIR"
run_and_log "$GO_BIN" build -o "$HELPER_PATH" ./cmd/offgrid-digest

log "Running Go helper from Xcode:"
log "$HELPER_PATH --config \"$CONFIG_PATH\""
log "Project log:"
log "tail -f \"$GO_DIR/OffGridDigest.log\""
log "Xcode scheme output log:"
log "tail -f \"$SCHEME_LOG\""
log ""

case "$MODE" in
  run-once)
    run_and_log "$HELPER_PATH" --config "$CONFIG_PATH"
    ;;
  watch)
    run_and_log "$HELPER_PATH" --config "$CONFIG_PATH" --watch --interval=60s
    ;;
  dry-run)
    run_and_log "$HELPER_PATH" --config "$CONFIG_PATH" --dry-run
    ;;
  watch-dry-run)
    run_and_log "$HELPER_PATH" --config "$CONFIG_PATH" --watch --interval=60s --dry-run
    ;;
  print-config)
    run_and_log "$HELPER_PATH" --config "$CONFIG_PATH" --print-config
    ;;
  *)
    log "error: unknown mode: $MODE"
    exit 2
    ;;
esac
