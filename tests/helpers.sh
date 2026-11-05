#!/usr/bin/env bash

# Recompute the identity fields after a test mutates the lock. The production renderer
# validates both digests, so a fixture that changes `.abi` or `.distribution.recipe`
# without refreshing them is testing a lock the pipeline would reject.
refresh_abi_id() {
  local lock=${1:?lock file is required}
  local value tmp
  value="abi-$(jq -S -c '.abi' "${lock}" | tr -d '\r' | sha256sum | awk '{print $1}')"
  tmp=$(mktemp "${lock}.XXXXXX")
  jq --arg value "${value}" '.abi_id = $value' "${lock}" >"${tmp}"
  mv -- "${tmp}" "${lock}"
}

refresh_recipe_id() {
  local lock=${1:?lock file is required}
  local value tmp
  value="recipe-$(jq -S -c '.distribution.recipe' "${lock}" | tr -d '\r' | sha256sum | awk '{print $1}')"
  tmp=$(mktemp "${lock}.XXXXXX")
  jq --arg value "${value}" '.recipe_id = $value' "${lock}" >"${tmp}"
  mv -- "${tmp}" "${lock}"
}

refresh_identity() {
  local lock=${1:?lock file is required}
  refresh_abi_id "${lock}"
  refresh_recipe_id "${lock}"
}

# A copy of the lock that release-mode rendering accepts. The checked-in lock stays in
# measurement until CI records the ceilings, but tests of the writing side need the same
# shape a ready lock has: a ready state and positive integer ceilings everywhere.
ready_lock() {
  local source=${1:?source lock is required}
  local target=${2:?target lock is required}
  jq '.distribution.release.state = "ready"
      | .distribution.release.size_limits |= walk(
          if type == "number" or type == "null" then 1 else . end)' \
    "${source}" >"${target}"
}
