#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_gate() {
  local expected="$1"
  local name="$2"
  local paths_file="${tmp_dir}/${name}.paths"
  local output_file="${tmp_dir}/${name}.output"
  shift 2

  printf '%s\n' "$@" > "$paths_file"
  GITHUB_OUTPUT="$output_file" "${ROOT_DIR}/Scripts/ci_macos_test_gate.sh" "$paths_file" >/dev/null
  local actual
  actual="$(sed -n 's/^macos-tests=//p' "$output_file")"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s: expected macos-tests=%s, got %s\n' "$name" "$expected" "${actual:-<empty>}" >&2
    exit 1
  fi

  local linux_required
  linux_required="$(sed -n 's/^linux-cli-build=//p' "$output_file")"
  if [[ "$linux_required" != "$expected" ]]; then
    printf '%s: expected linux-cli-build=%s, got %s\n' "$name" "$expected" "${linux_required:-<empty>}" >&2
    exit 1
  fi

  local reason
  reason="$(sed -n 's/^macos-tests-reason=//p' "$output_file")"
  if [[ -z "$reason" ]]; then
    printf '%s: expected macos-tests-reason output\n' "$name" >&2
    exit 1
  fi

  if [[ "$(sed -n 's/^linux-cli-build-reason=//p' "$output_file")" != "$reason" ]]; then
    printf '%s: expected Linux glibc gate reason to match the non-draft macOS reason\n' "$name" >&2
    exit 1
  fi

  local deferred
  deferred="$(sed -n 's/^macos-tests-deferred=//p' "$output_file")"
  if [[ "$deferred" != false ]]; then
    printf '%s: expected macos-tests-deferred=false, got %s\n' "$name" "${deferred:-<empty>}" >&2
    exit 1
  fi

  local path_count
  path_count="$(sed -n 's/^changed-path-count=//p' "$output_file")"
  if ! [[ "$path_count" =~ ^[0-9]+$ ]]; then
    printf '%s: expected numeric changed-path-count output, got %s\n' \
      "$name" "${path_count:-<empty>}" >&2
    exit 1
  fi

  if [[ "$expected" == false && "$reason" != "docs/site-only changes covered by portable checks" ]]; then
    printf '%s: expected docs/site skip reason, got %s\n' "$name" "$reason" >&2
    exit 1
  fi
}

assert_gate false docs-only $'M\tdocs/providers.md' $'M\tREADME.md'
assert_gate true configuration-doc $'M\tdocs/configuration.md'
assert_gate true rename-to-configuration-doc $'R100\tdocs/old.md\tdocs/configuration.md'
assert_gate true rename-from-configuration-doc $'R100\tdocs/configuration.md\tdocs/new.md'
assert_gate true agents-contract $'M\tAGENTS.md'
assert_gate true rename-to-agents-contract $'R100\tdocs/old.md\tAGENTS.md'
assert_gate true rename-from-agents-contract $'R100\tAGENTS.md\tdocs/new.md'
assert_gate true claude-contract $'M\tCLAUDE.md'
assert_gate true rename-to-claude-contract $'R100\tdocs/old.md\tCLAUDE.md'
assert_gate true rename-from-claude-contract $'R100\tCLAUDE.md\tdocs/new.md'
assert_gate true source $'M\tSources/CodexBar/App.swift'
assert_gate false docs-site $'M\tdocs/index.html' $'M\tdocs/site.css' $'M\tdocs/site.js' \
  $'M\tdocs/site-locales.mjs' $'M\tdocs/social.html' $'M\tdocs/social.png' \
  $'M\tdocs/CNAME' $'M\tdocs/.nojekyll' $'M\tdocs/llms.txt'
assert_gate false docs-site-assets $'M\tdocs/icon.png' $'M\tdocs/logos/provider-logo.svg'
assert_gate true docs-unknown-code $'M\tdocs/custom-tool.js'
assert_gate true docs-site-with-config $'M\tdocs/site.css' $'M\tdocs/configuration.md'
assert_gate true empty
assert_gate true source-to-docs $'R100\tSources/CodexBar/App.swift\tdocs/App.md'
assert_gate true docs-to-source $'R100\tdocs/App.md\tSources/CodexBar/App.swift'
assert_gate false docs-to-site $'R100\tdocs/old.md\tdocs/site.css'
assert_gate true source-markdown $'M\tSources/CodexBarCore/Resources/prompt.md'
assert_gate true test-markdown $'M\tTests/Fixtures/README.md'
assert_gate true widget-markdown $'M\tWidgetExtension/README.md'
assert_gate true workflow-markdown $'M\t.github/workflows/README.md'
assert_gate true mixed-docs-source $'M\tREADME.md' $'M\tSources/CodexBar/App.swift'
assert_gate true tests $'M\tTests/CodexBarTests/ProcessTests.swift'
assert_gate true package-manifest $'M\tPackage.swift'
assert_gate true package-resolved $'M\tPackage.resolved'
assert_gate true workflow $'M\t.github/workflows/ci.yml'
assert_gate true script $'M\tScripts/ci_verify_test_jobs.sh'
assert_gate true unknown-file $'A\tunknown.txt'
assert_gate true deleted-source $'D\tSources/CodexBar/App.swift'
assert_gate false deleted-docs $'D\tdocs/old.md'
assert_gate true copied-source $'C100\tSources/CodexBar/App.swift\tdocs/App.md'
assert_gate false copied-docs $'C100\tdocs/old.md\tdocs/new.md'

assert_linux_musl_gate() {
  local expected="$1"
  local name="$2"
  local paths_file="${tmp_dir}/linux-musl-${name}.paths"
  local output_file="${tmp_dir}/linux-musl-${name}.output"
  shift 2

  printf '%s\n' "$@" > "$paths_file"
  GITHUB_OUTPUT="$output_file" "${ROOT_DIR}/Scripts/ci_linux_musl_build_gate.sh" "$paths_file" >/dev/null
  local actual
  actual="$(sed -n 's/^linux-musl-build=//p' "$output_file")"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s: expected linux-musl-build=%s, got %s\n' "$name" "$expected" "${actual:-<empty>}" >&2
    exit 1
  fi

  local reason
  reason="$(sed -n 's/^linux-musl-build-reason=//p' "$output_file")"
  if [[ -z "$reason" ]]; then
    printf '%s: expected linux-musl-build-reason output\n' "$name" >&2
    exit 1
  fi
}

assert_linux_musl_gate true package-manifest $'M\tPackage.swift'
assert_linux_musl_gate true swift-source $'M\tSources/CodexBarCore/Process.swift'
assert_linux_musl_gate true nested-swift-source $'M\tSources/CodexBarCore/Host/Process/Process.swift'
assert_linux_musl_gate true rename-from-swift $'R100\tSources/CodexBarCore/Old.swift\tdocs/Old.md'
assert_linux_musl_gate true rename-to-swift $'R100\tdocs/New.md\tSources/CodexBarCore/New.swift'
assert_linux_musl_gate true sdk-installer $'M\tScripts/install_swift_static_sdk.sh'
assert_linux_musl_gate true removed-sdk-installer $'D\tScripts/install_swift_static_sdk.sh'
assert_linux_musl_gate false tests-only $'M\tTests/CodexBarTests/ProcessTests.swift'
assert_linux_musl_gate false workflow-only $'M\t.github/workflows/ci.yml'
assert_linux_musl_gate false script-only $'M\tScripts/ci_verify_test_jobs.sh'
assert_linux_musl_gate false package-resolved $'M\tPackage.resolved'
assert_linux_musl_gate true empty-diff

draft_paths="${tmp_dir}/draft-source.paths"
draft_output="${tmp_dir}/draft-source.output"
printf '%s\n' $'M\tSources/CodexBar/App.swift' > "$draft_paths"
CI_PULL_REQUEST_DRAFT=true GITHUB_OUTPUT="$draft_output" \
  "${ROOT_DIR}/Scripts/ci_macos_test_gate.sh" "$draft_paths" >/dev/null
if [[ "$(sed -n 's/^macos-tests=//p' "$draft_output")" != true ]]; then
  printf 'draft source: expected macOS tests to remain required while deferred\n' >&2
  exit 1
fi
if [[ "$(sed -n 's/^macos-tests-reason=//p' "$draft_output")" != \
  "draft pull request: macOS Swift tests deferred until ready for review" ]]
then
  printf 'draft source: expected draft deferral reason\n' >&2
  exit 1
fi
if [[ "$(sed -n 's/^macos-tests-deferred=//p' "$draft_output")" != true ]]; then
  printf 'draft source: expected macOS tests to be marked deferred\n' >&2
  exit 1
fi
if [[ "$(sed -n 's/^linux-cli-build=//p' "$draft_output")" != true ]] \
  || [[ "$(sed -n 's/^linux-cli-build-reason=//p' "$draft_output")" != \
    "Sources/CodexBar/App.swift: changes source, tests, or workflows" ]]
then
  printf 'draft source: expected Linux glibc builds to remain required without deferral\n' >&2
  exit 1
fi

draft_docs_output="${tmp_dir}/draft-docs.output"
CI_PULL_REQUEST_DRAFT=true GITHUB_OUTPUT="$draft_docs_output" \
  "${ROOT_DIR}/Scripts/ci_macos_test_gate.sh" "${tmp_dir}/docs-only.paths" >/dev/null
if [[ "$(sed -n 's/^macos-tests=//p' "$draft_docs_output")" != false ]] \
  || [[ "$(sed -n 's/^macos-tests-deferred=//p' "$draft_docs_output")" != false ]]
then
  printf 'draft docs: expected required=false and deferred=false\n' >&2
  exit 1
fi
if [[ "$(sed -n 's/^linux-cli-build=//p' "$draft_docs_output")" != false ]]; then
  printf 'draft docs: expected Linux glibc builds to be skipped\n' >&2
  exit 1
fi

assert_gate_fails() {
  local name="$1"
  local paths_file="${tmp_dir}/${name}.paths"
  local output_file="${tmp_dir}/${name}.output"
  shift

  printf '%s\n' "$@" > "$paths_file"
  if GITHUB_OUTPUT="$output_file" "${ROOT_DIR}/Scripts/ci_macos_test_gate.sh" "$paths_file" >/dev/null 2>&1; then
    printf '%s: malformed gate input unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi
  if [[ -s "$output_file" ]]; then
    printf '%s: malformed gate input emitted an output\n' "$name" >&2
    exit 1
  fi
}

assert_gate_fails missing-rename-target $'R100\tREADME.md'
assert_gate_fails extra-modified-path $'M\tREADME.md\tdocs/configuration.md'
assert_gate_fails missing-rename-score $'R\tREADME.md\tdocs/README.md'
assert_gate_fails invalid-rename-score $'Rfoo\tREADME.md\tdocs/README.md'
assert_gate_fails out-of-range-rename-score $'R101\tREADME.md\tdocs/README.md'
assert_gate_fails missing-copy-target $'C100\tREADME.md'
assert_gate_fails unknown-status $'Z\tREADME.md'

for malformed_case in missing-rename-target extra-modified-path missing-rename-score \
  invalid-rename-score out-of-range-rename-score
do
  paths_file="${tmp_dir}/${malformed_case}.paths"
  output_file="${tmp_dir}/linux-musl-${malformed_case}.output"
  if GITHUB_OUTPUT="$output_file" \
    "${ROOT_DIR}/Scripts/ci_linux_musl_build_gate.sh" "$paths_file" >/dev/null 2>&1
  then
    printf '%s: malformed Linux musl gate input unexpectedly succeeded\n' "$malformed_case" >&2
    exit 1
  fi
  if [[ -s "$output_file" ]]; then
    printf '%s: malformed Linux musl gate input emitted an output\n' "$malformed_case" >&2
    exit 1
  fi
done

if CI_PULL_REQUEST_DRAFT=maybe GITHUB_OUTPUT="${tmp_dir}/invalid-draft.output" \
  "${ROOT_DIR}/Scripts/ci_macos_test_gate.sh" "${tmp_dir}/docs-only.paths" >/dev/null 2>&1
then
  printf 'invalid draft flag unexpectedly succeeded\n' >&2
  exit 1
fi

unterminated_paths="${tmp_dir}/unterminated.paths"
unterminated_output="${tmp_dir}/unterminated.output"
printf '%s' $'M\tREADME.md\tdocs/configuration.md' > "$unterminated_paths"
if GITHUB_OUTPUT="$unterminated_output" \
  "${ROOT_DIR}/Scripts/ci_macos_test_gate.sh" "$unterminated_paths" >/dev/null 2>&1
then
  printf 'unterminated malformed gate input unexpectedly succeeded\n' >&2
  exit 1
fi
if [[ -s "$unterminated_output" ]]; then
  printf 'unterminated malformed gate input emitted an output\n' >&2
  exit 1
fi

verify="${ROOT_DIR}/Scripts/ci_verify_test_jobs.sh"
"$verify" success success true success false true success success success true >/dev/null
"$verify" success success true success false false skipped success success true >/dev/null
"$verify" success success false skipped false true success success skipped true >/dev/null
"$verify" success success false skipped false false skipped success skipped true >/dev/null
"$verify" success success false skipped false false skipped skipped skipped false >/dev/null

assert_verify_fails() {
  if "$verify" "$@" >/dev/null 2>&1; then
    printf 'unexpected aggregate success: %s\n' "$*" >&2
    exit 1
  fi
}

for compatibility_result in failure cancelled skipped '' unknown; do
  assert_verify_fails success success true success false false skipped success "$compatibility_result" true
done
assert_verify_fails success success true success false false skipped success
assert_verify_fails success success false skipped false false skipped success success true
assert_verify_fails success success false skipped false false skipped success failure true

assert_verify_fails success success true skipped false true success success success true
assert_verify_fails success success true skipped true true success success success true
assert_verify_fails success success false skipped true true success success skipped true
assert_verify_fails success success true success true true success success success true
assert_verify_fails success success false success false true success success skipped true
assert_verify_fails success success "" skipped false true success success success true
assert_verify_fails failure success true success false true success success success true
assert_verify_fails success failure true success false true success success success true
assert_verify_fails success success true success false true skipped success success true
assert_verify_fails success success true success false false success success success true
assert_verify_fails success success true success false "" skipped success success true

# Skipping all build jobs for docs still requires successful lint and path detection.
for failed_result in failure cancelled; do
  assert_verify_fails "$failed_result" success false skipped false false skipped skipped skipped false
  assert_verify_fails success "$failed_result" false skipped false false skipped skipped skipped false
done

assert_linux_verify_fails() {
  local expected_required="$1"
  local expected_result="$2"
  local error_file="${tmp_dir}/linux-verify.error"
  shift 2
  if "$verify" "$@" >/dev/null 2>"$error_file"; then
    printf 'unexpected Linux aggregate success: %s\n' "$*" >&2
    exit 1
  fi
  if ! grep -Fxq "Linux glibc build gate/result mismatch: required=${expected_required} result=${expected_result}" "$error_file"; then
    printf 'expected Linux matrix diagnostic for required=%s result=%s\n' "$expected_required" "$expected_result" >&2
    cat "$error_file" >&2
    exit 1
  fi
}

for macos_required in true false; do
  macos_result=success
  [[ "$macos_required" == true ]] || macos_result=skipped
  for musl_required in true false; do
    musl_result=success
    [[ "$musl_required" == true ]] || musl_result=skipped
    valid_args=(success success "$macos_required" "$macos_result" false "$musl_required" "$musl_result")
    for linux_required in true false; do
      for linux_result in success failure cancelled skipped '' unknown; do
        case "${linux_required}:${linux_result}" in
          true:success|false:skipped)
            "$verify" "${valid_args[@]}" "$linux_result" "$macos_result" "$linux_required" >/dev/null
            ;;
          *)
            assert_linux_verify_fails "$linux_required" "${linux_result:-<empty>}" \
              "${valid_args[@]}" "$linux_result" "$macos_result" "$linux_required"
            ;;
        esac
      done
    done
    assert_linux_verify_fails '<missing>' '<missing>' "${valid_args[@]}"
    assert_linux_verify_fails '<missing>' success "${valid_args[@]}" success "$macos_result"
    for invalid_required in '' unknown; do
      assert_linux_verify_fails "${invalid_required:-<empty>}" success \
        "${valid_args[@]}" success "$macos_result" "$invalid_required"
      assert_linux_verify_fails "${invalid_required:-<empty>}" skipped \
        "${valid_args[@]}" skipped "$macos_result" "$invalid_required"
    done

    for failed_result in failure cancelled; do
      assert_verify_fails "$failed_result" success "$macos_required" "$macos_result" \
        false "$musl_required" "$musl_result" success "$macos_result" true
      assert_verify_fails success "$failed_result" "$macos_required" "$macos_result" \
        false "$musl_required" "$musl_result" success "$macos_result" true
      if [[ "$macos_required" == true ]]; then
        assert_verify_fails success success true "$failed_result" false "$musl_required" "$musl_result" success success true
      fi
      if [[ "$musl_required" == true ]]; then
        assert_verify_fails success success "$macos_required" "$macos_result" false true "$failed_result" \
          success "$macos_result" true
      fi
    done
  done
done

# Check the actual aggregate dependency and shell argument, not summary text elsewhere in the workflow.
python3 - "${ROOT_DIR}/.github/workflows/ci.yml" <<'PY'
import pathlib
import re
import shlex
import sys

workflow = pathlib.Path(sys.argv[1]).read_text()
aggregate = re.search(r"(?ms)^  lint-build-test:\n(.*?)(?=^  [\w-]+:|\Z)", workflow)
if aggregate is None:
    sys.exit("missing lint-build-test aggregate")
body = aggregate.group(1)
needs = re.search(r"(?m)^    needs:\n((?:      - [^\n]+\n)+)", body)
if needs is None or "      - build-linux-cli" not in needs.group(1).splitlines():
    sys.exit("lint-build-test must need build-linux-cli")
if "      - swift-build-macos-compatibility" not in needs.group(1).splitlines():
    sys.exit("lint-build-test must need swift-build-macos-compatibility")
command = re.search(r"(?m)^          \./Scripts/ci_verify_test_jobs\.sh(?:[^\n]*\\\n)+[^\n]*", body)
if command is None:
    sys.exit("missing aggregate verifier command")
arguments = shlex.split(command.group(0).replace("\\\n", ""))
if len(arguments) != 11 or arguments[8] != "${{ needs.build-linux-cli.result }}":
    sys.exit("aggregate verifier argument eight must be needs.build-linux-cli.result")
if arguments[9] != "${{ needs.swift-build-macos-compatibility.result }}":
    sys.exit("aggregate verifier argument nine must be needs.swift-build-macos-compatibility.result")
if arguments[10] != "${{ needs.changes.outputs.linux-cli-build }}":
    sys.exit("aggregate verifier argument ten must be needs.changes.outputs.linux-cli-build")

linux_job = re.search(r"(?ms)^  build-linux-cli:\n(.*?)(?=^  [\w-]+:|\Z)", workflow)
if linux_job is None:
    sys.exit("missing build-linux-cli matrix")
linux_body = linux_job.group(1)
if not re.search(r"(?m)^    needs: changes$", linux_body):
    sys.exit("build-linux-cli must need changes")
if "    if: ${{ needs.changes.outputs.linux-cli-build == 'true' }}" not in linux_body.splitlines():
    sys.exit("build-linux-cli must require an explicit true path gate")
changes = re.search(r"(?ms)^  changes:\n(.*?)(?=^  [\w-]+:|\Z)", workflow)
if changes is None or "      linux-cli-build: ${{ steps.macos-tests.outputs.linux-cli-build }}" not in changes.group(1).splitlines():
    sys.exit("changes must expose the Linux glibc path gate output")
PY

printf 'CI path gate tests passed.\n'
