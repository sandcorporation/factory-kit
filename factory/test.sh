#!/usr/bin/env bash
# Runs every factory script test (.github/factory/tests/*.sh) and exits 1 if any fails.
# `cargo xtask ci` calls this ("공장 스크립트 시험"). The tests put a fake `gh` first on PATH and
# need jq, as the scripts themselves do.
set -u
here=$(cd "$(dirname "$0")" && pwd)

if ! command -v jq >/dev/null 2>&1; then
  echo "공장 스크립트 시험: jq가 없어 건너뜀"
  exit 0
fi

failed=0

# The fakes only shadow the real tools on PATH when they are executable. A lost executable bit
# (a copy or move that drops file modes) makes the tests call the real gh instead.
for f in "$here"/tests/fake/* "$here"/tests/fake/probe/* "$here"/tests/decompose-fake/*; do
  [ -f "$f" ] || continue
  if [ ! -x "$f" ]; then
    echo "공장 스크립트 시험: 가짜 도구에 실행 권한이 없음: ${f#"$here"/}"
    failed=1
  fi
done
if [ "$failed" -ne 0 ]; then
  echo "공장 스크립트 시험: 실패 (git update-index --chmod=+x 로 고친다)"
  exit 1
fi

for t in "$here"/tests/*.sh; do
  [ -f "$t" ] || continue
  echo "--- $(basename "$t")"
  if ! bash "$t"; then
    echo "FAILED: $(basename "$t")"
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "공장 스크립트 시험: 실패"
  exit 1
fi
echo "공장 스크립트 시험: 모두 통과"
