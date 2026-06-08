
# ===========================================================================
#  FOOTER — run preconditions once, then each registered module in order.
# ===========================================================================
main() {
  log "coo.ee/env ${COOEE_VERSION} — modules: ${MODULES[*]}"
  gha_group "coo.ee: preconditions"
  check_preconditions
  gha_endgroup
  local m
  for m in "${MODULES[@]}"; do
    gha_group "coo.ee: module ${m}"
    log "---- module: ${m} --------------------------------"
    "module_${m}"
    gha_endgroup
  done
  echo
  ok "Environment ready: ${MODULES[*]}"
  log "Persisted env -> ${COOEE_PROFILE}"
  log "In a fresh shell:  source ${COOEE_PROFILE}"
}
main "$@"
