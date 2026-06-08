
# ===========================================================================
#  FOOTER — run preconditions once, then each registered module in order.
# ===========================================================================
main() {
  log "coo.ee/env ${COOEE_VERSION} — modules: ${MODULES[*]}"
  check_preconditions
  local m
  for m in "${MODULES[@]}"; do
    log "---- module: ${m} --------------------------------"
    # Pass any request params (set_params, injected by the renderer) as args.
    if [[ -n "${_MODULE_PARAMS[$m]:-}" ]]; then
      local -a _args
      IFS=',' read -r -a _args <<< "${_MODULE_PARAMS[$m]}"
      "module_${m}" "${_args[@]}"
    else
      "module_${m}"
    fi
  done
  echo
  ok "Environment ready: ${MODULES[*]}"
  log "Persisted env -> ${COOEE_PROFILE}"
  log "In a fresh shell:  source ${COOEE_PROFILE}"
}
main "$@"
