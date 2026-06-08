
# ===========================================================================
#  FOOTER — short-circuit if already provisioned, else preconditions + install.
# ===========================================================================

# Fast path: skip the whole install when a previous run already provisioned
# exactly this module set and every tool is still on PATH. COOEE_FORCE=1 opts
# out (forces a re-provision / repair).
cooee_already_provisioned() {
  [[ "${COOEE_FORCE:-0}" == 1 ]] && return 1
  [[ -f "$COOEE_STAMP" ]] || return 1
  [[ "$(cat "$COOEE_STAMP" 2>/dev/null)" == "${MODULES[*]:-}" ]] || return 1
  local m
  for m in "${MODULES[@]}"; do
    if [[ "$m" == base ]]; then
      command -v nix >/dev/null 2>&1 || return 1
    else
      module_present "$m" || return 1
    fi
  done
  return 0
}

# Advisory pass: for every requested module, either note that we'll adopt an
# already-present tool, or — on a provider that ships it built-in — nudge the
# user to prefer the built-in instead of installing a redundant copy via Nix.
cooee_builtin_pass() {
  local m cmd envvar
  for m in "${MODULES[@]}"; do
    [[ "$m" == base ]] && continue
    cmd=${_PROVIDES_CMD["$m"]:-}
    envvar=${_BUILTIN_ENVVAR["$m"]:-}
    if module_present "$m"; then
      ok "module '$m': '$cmd' already on PATH — adopting ${COOEE_PROVIDER_LABEL}'s build, no Nix install."
      continue
    fi
    case "$COOEE_PROVIDER" in
      codex)
        if [[ -n "$envvar" ]]; then
          warn "module '$m': Codex provides this from its base image — prefer it by setting ${envvar} in your Codex environment instead of installing via Nix."
        else
          warn "module '$m': Codex's base image may already ship this — prefer the image's version over a Nix install when available."
        fi ;;
      claude|gemini)
        : ;;   # adoption covers the present case; no version selector to point at
    esac
  done
}

main() {
  cooee_detect_provider
  log "coo.ee/env ${COOEE_VERSION} — modules: ${MODULES[*]:-} — provider: ${COOEE_PROVIDER}"

  if cooee_already_provisioned; then
    ok "Already provisioned (${MODULES[*]:-}); skipping install."
    cooee_forward_persisted_env
    log "Re-exported env from ${COOEE_PROFILE} (source it in a fresh shell)."
    log "Force a re-provision with COOEE_FORCE=1."
    return 0
  fi

  cooee_builtin_pass

  # Nix is only worth installing if at least one requested module will actually
  # install (i.e. is not adopted from the environment). If everything is already
  # provided, base is skipped too.
  local need_nix=0 m
  for m in "${MODULES[@]}"; do
    [[ "$m" == base ]] && continue
    if module_present "$m" && [[ "${COOEE_FORCE:-0}" != 1 ]]; then continue; fi
    need_nix=1
  done

  cooee_init_profile

  # Host preflight only matters when something will actually install — if every
  # requested tool is adopted from the environment, there is nothing to probe.
  if [[ "$need_nix" == 1 ]]; then
    check_preconditions
  else
    ok "Nothing to install — every requested tool is already provided; skipping host preflight."
  fi

  for m in "${MODULES[@]}"; do
    log "---- module: ${m} --------------------------------"
    if [[ "$m" == base ]]; then
      if [[ "$need_nix" == 1 ]]; then
        module_base
      else
        ok "base: every requested tool is already provided — skipping Nix install."
      fi
    else
      "module_${m}"   # each module adopts an existing tool or installs via Nix
    fi
  done

  printf '%s' "${MODULES[*]:-}" > "$COOEE_STAMP"
  echo
  ok "Environment ready: ${MODULES[*]:-}"
  log "Persisted env -> ${COOEE_PROFILE}"
  log "In a fresh shell:  source ${COOEE_PROFILE}"
}
main "$@"
