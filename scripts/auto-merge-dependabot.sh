#!/usr/bin/env bash
#
# Approve and merge green bot-authored pull requests across several repositories.
#
# Every candidate returned by the GitHub search query is re-validated against the
# API before anything is written, so a wrong or over-broad query cannot cause a
# merge on its own. A PR is only touched when all of these hold:
#
#   1. its author is one of EXPECTED_AUTHORS, and carries the bot flag when that
#      entry names a GitHub App,
#   2. it is not a fork PR (head and base are the same repository),
#   3. its repository owner is in OWNERS (when that list is non-empty),
#   4. it is open and not a draft,
#   5. every status check / check run has finished successfully,
#   6. its semver bump is in ALLOWED_UPDATE_TYPES (when that list is non-empty).
#
# Configuration comes from the environment. Each knob X reads, in order: X_INPUT,
# X_VAR (the repository variable the workflow passes), then the default defined
# below, with empty values falling through. The workflow sets only X_VAR; X_INPUT
# exists for overriding a single setting on a local run.

set -euo pipefail

# Neither owner nor author scoping belongs in the query: GitHub's REST search
# API rejects the `(a OR b)` form that the web UI accepts, so the script runs one
# search per owner x author pair and unions the results. Both lists also serve as
# allowlists, enforced on every candidate before it is touched.
DEFAULT_SEARCH_QUERY='is:open archived:false'
# Empty resolves to the account behind the token; `none` drops owner scoping
# altogether. Anything else is a comma-separated list of owners to sweep.
DEFAULT_OWNERS=''
# Comma-separated. `dependabot[bot]`/`app/dependabot` name a GitHub App; a bare
# login names an ordinary account driving a bot. See the derivation below.
DEFAULT_EXPECTED_AUTHORS='dependabot[bot]'
# Appended to the query as `review-requested:`. `@me` resolves to the account
# behind the token; `none` drops the filter; anything else is used verbatim.
DEFAULT_REVIEW_REQUESTED='@me'
# Bots often request review from a team rather than a person, which
# `review-requested:` does not match. `@my-teams` looks up the teams the token
# belongs to; `none` disables it; anything else is a comma-separated org/team
# list. Requires the read:org scope on a classic PAT.
DEFAULT_TEAM_REVIEW_REQUESTED='@my-teams'
DEFAULT_ALLOWED_UPDATE_TYPES=''
DEFAULT_MERGE_METHOD='squash'
DEFAULT_MAX_PRS='50'
DEFAULT_DRY_RUN='false'
DEFAULT_ALLOW_NO_CHECKS='false'
DEFAULT_DELETE_BRANCH='true'
DEFAULT_FAIL_ON_ERROR='false'
DEFAULT_SUMMARY_ISSUE_REPO=''
DEFAULT_SUMMARY_ISSUE_LABEL='auto-merge-summary'
DEFAULT_SUMMARY_ISSUE_TITLE='Bot Auto-merge Summary'

# cfg NAME DEFAULT -> first non-empty of $NAME_INPUT, $NAME_VAR, DEFAULT
cfg() {
  local input="${1}_INPUT" var="${1}_VAR" value
  value="${!input:-}"
  [[ -n "${value}" ]] || value="${!var:-}"
  [[ -n "${value}" ]] || value="${2}"
  printf '%s' "${value}"
}

SEARCH_QUERY="$(cfg SEARCH_QUERY "${DEFAULT_SEARCH_QUERY}")"
OWNERS="$(cfg OWNERS "${DEFAULT_OWNERS}")"
REVIEW_REQUESTED="$(cfg REVIEW_REQUESTED "${DEFAULT_REVIEW_REQUESTED}")"
TEAM_REVIEW_REQUESTED="$(cfg TEAM_REVIEW_REQUESTED "${DEFAULT_TEAM_REVIEW_REQUESTED}")"
ALLOWED_UPDATE_TYPES="$(cfg ALLOWED_UPDATE_TYPES "${DEFAULT_ALLOWED_UPDATE_TYPES}")"
EXPECTED_AUTHORS="$(cfg EXPECTED_AUTHORS "${DEFAULT_EXPECTED_AUTHORS}")"
MERGE_METHOD="$(cfg MERGE_METHOD "${DEFAULT_MERGE_METHOD}")"
MAX_PRS="$(cfg MAX_PRS "${DEFAULT_MAX_PRS}")"
DRY_RUN="$(cfg DRY_RUN "${DEFAULT_DRY_RUN}")"
ALLOW_NO_CHECKS="$(cfg ALLOW_NO_CHECKS "${DEFAULT_ALLOW_NO_CHECKS}")"
DELETE_BRANCH="$(cfg DELETE_BRANCH "${DEFAULT_DELETE_BRANCH}")"
FAIL_ON_ERROR="$(cfg FAIL_ON_ERROR "${DEFAULT_FAIL_ON_ERROR}")"
SUMMARY_ISSUE_REPO="$(cfg SUMMARY_ISSUE_REPO "${DEFAULT_SUMMARY_ISSUE_REPO}")"
SUMMARY_ISSUE_LABEL="$(cfg SUMMARY_ISSUE_LABEL "${DEFAULT_SUMMARY_ISSUE_LABEL}")"
SUMMARY_ISSUE_TITLE="$(cfg SUMMARY_ISSUE_TITLE "${DEFAULT_SUMMARY_ISSUE_TITLE}")"

SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"

case "${MERGE_METHOD}" in
  squash | merge | rebase) ;;
  *)
    printf 'MERGE_METHOD must be one of squash, merge, rebase (got %q)\n' "${MERGE_METHOD}" >&2
    exit 2
    ;;
esac

if [[ ! "${MAX_PRS}" =~ ^[0-9]+$ ]] || (( MAX_PRS < 1 )); then
  printf 'MAX_PRS must be a positive integer (got %q)\n' "${MAX_PRS}" >&2
  exit 2
fi

is_true() { [[ "${1,,}" == "true" || "${1,,}" == "1" || "${1,,}" == "yes" ]]; }

log() { printf '%s\n' "$*"; }
group() { printf '::group::%s\n' "$*"; }
endgroup() { printf '::endgroup::\n'; }
# notice/warn go to stderr so that a warning raised inside a function whose
# stdout is captured cannot end up parsed as part of that function's result.
notice() { printf '::notice::%s\n' "$*" >&2; }
warn() { printf '::warning::%s\n' "$*" >&2; }

# The GitHub API drops the occasional connection; a transient network error must
# not be reported as a rejected pull request. Prints the last attempt's output.
retry_capture() {
  local attempt out status=1
  for attempt in 1 2 3; do
    if out="$("$@" 2>&1)"; then
      printf '%s' "${out}"
      return 0
    else
      # Must be read inside the else branch: after the `if` completes, `$?` is
      # the status of the compound statement, which is 0 on a failed condition.
      status=$?
    fi
    (( attempt < 3 )) && sleep $(( attempt * 3 ))
  done
  printf '%s' "${out}"
  return "${status}"
}

# GitHub reports bot logins inconsistently across APIs: the REST API says
# "dependabot[bot]", GraphQL/gh say "app/dependabot" or plain "dependabot".
# Reduce all of those to a single comparable form.
normalize_login() {
  local login="${1,,}"
  login="${login#app/}"
  login="${login%\[bot\]}"
  printf '%s' "${login}"
}

# Comma-separated list membership, tolerant of spaces around entries.
list_contains() {
  local needle="${1,,}" list="${2,,}" item
  local IFS=','
  for item in ${list}; do
    item="${item## }"
    item="${item%% }"
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

declare -a MERGED=() SKIPPED=() FAILED=()

record_skip() {
  local slug="$1" reason="$2"
  SKIPPED+=("${slug}|${reason}")
  log "  skipped: ${reason}"
}

record_failure() {
  local slug="$1" reason="$2"
  FAILED+=("${slug}|${reason}")
  warn "${slug}: ${reason}"
}

# Finds or creates a pinned GitHub issue whose body is replaced with each run's
# summary, so the results are visible even when the workflow log is buried.
update_summary_issue() {
  local body_file="$1"
  local repo="${SUMMARY_ISSUE_REPO}"
  case "${repo}" in
    '' | none | false) return 0 ;;
    '@self')
      repo="${GITHUB_REPOSITORY:-}"
      if [[ -z "${repo}" ]]; then
        warn "SUMMARY_ISSUE_REPO=@self but GITHUB_REPOSITORY is not set — skipping issue update"
        return 0
      fi
      ;;
  esac

  local issue_body_file
  issue_body_file="$(mktemp)"
  {
    printf '> Last updated: %s' "$(date -u '+%Y-%m-%d %H:%M UTC')"
    if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
      printf ' · [workflow run](%s/%s/actions/runs/%s)' \
        "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}"
    fi
    printf '\n\n'
    cat "${body_file}"
  } >"${issue_body_file}"

  gh label create "${SUMMARY_ISSUE_LABEL}" -R "${repo}" \
    --description "Tracks the bot auto-merge sweep summary" \
    --color "0075ca" --force 2>/dev/null || true

  local issue_number
  issue_number="$(
    gh issue list -R "${repo}" \
      --label "${SUMMARY_ISSUE_LABEL}" \
      --state open \
      --limit 1 \
      --json number \
      --jq '.[0].number // empty' 2>/dev/null
  )" || true

  if [[ -n "${issue_number}" ]]; then
    if gh issue edit "${issue_number}" -R "${repo}" --body-file "${issue_body_file}" >/dev/null 2>&1; then
      log "Updated summary issue: https://github.com/${repo}/issues/${issue_number}"
    else
      warn "could not update summary issue ${repo}#${issue_number}"
    fi
  else
    local issue_url
    if issue_url="$(gh issue create -R "${repo}" \
      --title "${SUMMARY_ISSUE_TITLE}" \
      --label "${SUMMARY_ISSUE_LABEL}" \
      --body-file "${issue_body_file}")"; then
      issue_number="${issue_url##*/}"
      log "Created summary issue: ${issue_url}"
      gh issue pin "${issue_number}" -R "${repo}" >/dev/null 2>&1 ||
        warn "could not pin ${repo}#${issue_number} (pinning requires admin access)"
    else
      warn "could not create summary issue in ${repo}"
    fi
  fi

  rm -f "${issue_body_file}"
}

# Collapses statusCheckRollup into one word: none, pending, failure or success.
# Emits "<verdict>\t<comma separated names of the offending checks>".
# shellcheck disable=SC2016  # $checks is a jq binding, not a shell variable
ROLLUP_JQ='
def name_of:
  .name // .context // "unnamed check";
def classify:
  if .__typename == "CheckRun" then
    if (.status // "") != "COMPLETED" then "pending"
    elif (.conclusion // "") as $c | ["SUCCESS", "SKIPPED", "NEUTRAL"] | index($c) then "success"
    else "failure"
    end
  else
    if (.state // "") as $s | ["PENDING", "EXPECTED"] | index($s) then "pending"
    elif (.state // "") == "SUCCESS" then "success"
    else "failure"
    end
  end;
[.statusCheckRollup // [] | .[] | {name: name_of, verdict: classify}] as $checks
| if ($checks | length) == 0 then "none\t"
  elif ($checks | any(.verdict == "failure"))
    then "failure\t" + ([$checks[] | select(.verdict == "failure") | .name] | join(", "))
  elif ($checks | any(.verdict == "pending"))
    then "pending\t" + ([$checks[] | select(.verdict == "pending") | .name] | join(", "))
  else "success\t"
  end
'

log "Allowed update types: ${ALLOWED_UPDATE_TYPES:-<any>}"
log "Merge method: ${MERGE_METHOD} (dry-run: ${DRY_RUN})"
log ""

# The token's own account drives both the reviewer filter below and the
# already-approved check later, so failing to resolve it is fatal rather than
# something to work around.
if ! viewer="$(retry_capture gh api user --jq '.login')" || [[ -z "${viewer}" ]]; then
  printf 'could not determine the authenticated user from the token: %s\n' \
    "${viewer:-empty login}" >&2
  exit 1
fi
log "Acting as: ${viewer}"

# Left unset, the sweep covers the token's own account and nothing else — the
# narrowest useful scope, and one that needs no hard-coded login. The OWNERS
# variable widens it to a list; `none` removes owner scoping entirely, leaving
# whatever the query alone matches.
case "${OWNERS}" in
  '' | '@me') OWNERS="${viewer}" ;;
  none | false) OWNERS='' ;;
esac
log "Owners: ${OWNERS:-<unscoped>}"

# `gh search` builds its q parameter by joining its positional arguments, and
# quotes any argument containing a space — a whole query passed as one argument
# becomes a literal phrase and matches nothing. Split it into words instead.
read -r -a query_terms <<<"${SEARCH_QUERY}"

# The reviewer filter is derived from the token instead of being hard-coded, so
# the sweep always follows whoever the PAT belongs to. It is kept out of
# query_terms because team filters below make it one alternative among several,
# and the search API has no OR to express them in a single request.
case "${REVIEW_REQUESTED}" in
  '@me') user_review_qualifier="review-requested:${viewer}" ;;
  '' | none | false) user_review_qualifier='' ;;
  *) user_review_qualifier="review-requested:${REVIEW_REQUESTED}" ;;
esac

# A review requested from a team is invisible to `review-requested:`, which only
# matches direct requests to a person — `team-review-requested:` is a separate
# qualifier. Bots configured with CODEOWNERS or per-repo teams routinely request
# the team, so those pull requests would otherwise never be swept.
declare -a my_teams=()
case "${TEAM_REVIEW_REQUESTED}" in
  '' | none | false) ;;
  '@my-teams')
    if teams_raw="$(retry_capture gh api user/teams --paginate \
      --jq '.[] | "\(.organization.login)/\(.slug)"')"; then
      while IFS= read -r team_entry; do
        [[ -n "${team_entry}" ]] && my_teams+=("${team_entry}")
      done <<<"${teams_raw}"
    else
      warn "could not list the token's teams, continuing without team review filters (a classic PAT needs the read:org scope): ${teams_raw}"
    fi
    ;;
  *)
    IFS=',' read -r -a team_entries <<<"${TEAM_REVIEW_REQUESTED}"
    for team_entry in "${team_entries[@]}"; do
      team_entry="${team_entry//[[:space:]]/}"
      [[ -n "${team_entry}" ]] && my_teams+=("${team_entry}")
    done
    ;;
esac

# EXPECTED_AUTHORS names the bots once; their search qualifiers are derived from
# it so the two can never drift apart. `dependabot[bot]` and `app/dependabot`
# denote a GitHub App, which search matches as `author:app/<slug>` and whose
# pull requests carry a bot flag; a bare login denotes an ordinary account
# driving a bot, which search matches directly and carries no such flag.
declare -A AUTHOR_IS_APP=()
declare -a author_qualifiers=()

IFS=',' read -r -a author_entries <<<"${EXPECTED_AUTHORS}"
for entry in "${author_entries[@]}"; do
  entry="${entry//[[:space:]]/}"
  [[ -n "${entry}" ]] || continue
  entry_slug="$(normalize_login "${entry}")"
  case "${entry}" in
    app/* | *'[bot]')
      AUTHOR_IS_APP["${entry_slug}"]=true
      author_qualifiers+=("author:app/${entry_slug}")
      ;;
    *)
      AUTHOR_IS_APP["${entry_slug}"]=false
      author_qualifiers+=("author:${entry_slug}")
      ;;
  esac
done

if (( ${#AUTHOR_IS_APP[@]} == 0 )); then
  printf 'EXPECTED_AUTHORS is empty — there is no author to sweep for\n' >&2
  exit 2
fi

# An explicit author: in SEARCH_QUERY wins, which is the escape hatch for any
# bot whose search form the rule above gets wrong. EXPECTED_AUTHORS still
# governs which authors may actually be merged.
for term in "${query_terms[@]}"; do
  [[ "${term}" == author:* ]] && author_qualifiers=("")
done

# The REST search API has no OR, so each author needs its own request, just as
# each owner does. The sweep is the union over every owner x author pair.
log "Search query: ${query_terms[*]}"
log "Authors: ${EXPECTED_AUTHORS}"
# Only the teams belonging to an owner being swept are actually queried, so the
# raw count is reported rather than a long list that overstates what runs.
log "Review requested from: ${user_review_qualifier:-<anyone>} (+ ${#my_teams[@]} team(s) the token belongs to, applied per matching owner)"
log ""

# search_owner OWNER AUTHOR_QUALIFIER -> one PR URL per line, empty when that
# pair has nothing indexed. An owner with no searchable repositories makes the
# API return 422, which must not abort the sweep over the remaining pairs.
search_owner() {
  local owner="$1" author_qualifier="$2" reviewer_qualifier="$3"
  local -a args=("${query_terms[@]}")
  [[ -n "${owner}" ]] && args+=("user:${owner}")
  [[ -n "${author_qualifier}" ]] && args+=("${author_qualifier}")
  [[ -n "${reviewer_qualifier}" ]] && args+=("${reviewer_qualifier}")

  local output
  if ! output="$(
    retry_capture gh search prs "${args[@]}" \
      --limit "${MAX_PRS}" \
      --sort updated \
      --order desc \
      --json url \
      --jq '.[].url'
  )"; then
    warn "search failed for '${owner:-<query scope>}'${author_qualifier:+ / ${author_qualifier}}${reviewer_qualifier:+ / ${reviewer_qualifier}}: ${output}"
    return 0
  fi
  printf '%s' "${output}"
}

declare -a urls=()
declare -A seen=()

collect() {
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ -n "${seen[${line}]:-}" ]] && continue
    seen["${line}"]=1
    urls+=("${line}")
  done
}

sweep_owner() {
  local owner="$1" author reviewer team found count total=0
  local -a reviewer_qualifiers=()

  [[ -n "${user_review_qualifier}" ]] && reviewer_qualifiers+=("${user_review_qualifier}")
  # A team qualifier can only match inside its own org, so pairing it with any
  # other owner is a guaranteed-empty request. Skip those.
  for team in "${my_teams[@]+"${my_teams[@]}"}"; do
    if [[ -z "${owner}" || "${team%%/*}" == "${owner}" ]]; then
      reviewer_qualifiers+=("team-review-requested:${team}")
    fi
  done
  # No reviewer filter configured at all: one unfiltered pass.
  (( ${#reviewer_qualifiers[@]} > 0 )) || reviewer_qualifiers=("")

  for reviewer in "${reviewer_qualifiers[@]}"; do
    for author in "${author_qualifiers[@]}"; do
      found="$(search_owner "${owner}" "${author}" "${reviewer}")"
      count=0
      [[ -n "${found}" ]] && count="$(grep -c '' <<<"${found}")"
      total=$(( total + count ))
      collect <<<"${found}"
    done
  done
  log "  ${owner:-<query scope>}: ${total} candidate(s)"
}

if [[ -n "${OWNERS}" ]]; then
  IFS=',' read -r -a owner_list <<<"${OWNERS}"
  for owner in "${owner_list[@]}"; do
    owner="${owner//[[:space:]]/}"
    [[ -n "${owner}" ]] || continue
    sweep_owner "${owner}"
  done
else
  sweep_owner ""
fi

if (( ${#urls[@]} == 0 )); then
  log "No pull requests matched the query."
  report_file="$(mktemp)"
  printf '## Bot auto-merge\n\nNo pull requests matched the query.\n' >"${report_file}"
  cat "${report_file}" >>"${SUMMARY_FILE}"
  update_summary_issue "${report_file}"
  rm -f "${report_file}"
  exit 0
fi

log "Found ${#urls[@]} candidate pull request(s)."
log ""

for url in "${urls[@]}"; do
  [[ -n "${url}" ]] || continue

  if [[ ! "${url}" =~ ^https://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
    record_failure "${url}" "could not parse pull request URL"
    continue
  fi
  owner="${BASH_REMATCH[1]}"
  repo="${BASH_REMATCH[2]}"
  number="${BASH_REMATCH[3]}"
  slug="${owner}/${repo}#${number}"

  group "${slug}"

  if ! pr="$(retry_capture gh pr view "${url}" --json \
    'title,state,isDraft,isCrossRepository,author,headRepository,headRepositoryOwner,headRefName,mergeable,mergeStateStatus,statusCheckRollup,latestReviews,commits' \
    )"; then
    record_failure "${slug}" "could not read pull request: ${pr}"
    endgroup
    continue
  fi

  title="$(jq -r '.title' <<<"${pr}")"
  log "  ${title}"

  # --- Guard 1: repository owner allowlist -----------------------------------
  if [[ -n "${OWNERS}" ]] && ! list_contains "${owner}" "${OWNERS}"; then
    record_skip "${slug}" "owner '${owner}' is not in OWNERS"
    endgroup
    continue
  fi

  # --- Guard 2: author must be Dependabot ------------------------------------
  # jq's `//` treats `false` as absent, so a boolean field must never be read
  # with it — `false // true` yields `true`. Compare explicitly, and let any
  # unexpected value fall on the side that rejects the pull request.
  author_login="$(jq -r '.author.login // ""' <<<"${pr}")"
  author_is_bot="$(jq -r 'if .author.is_bot == true then "true" else "false" end' <<<"${pr}")"
  author_slug="$(normalize_login "${author_login}")"
  if [[ -z "${AUTHOR_IS_APP[${author_slug}]:-}" ]]; then
    record_skip "${slug}" "author is '${author_login}', expected one of: ${EXPECTED_AUTHORS}"
    endgroup
    continue
  fi
  # Only an App-form author carries the bot flag, so the requirement follows the
  # form of the entry this pull request actually matched.
  if [[ "${AUTHOR_IS_APP[${author_slug}]}" == true && "${author_is_bot}" != "true" ]]; then
    record_skip "${slug}" "author '${author_login}' is not a bot account"
    endgroup
    continue
  fi

  # --- Guard 3: no fork PRs --------------------------------------------------
  # The base repository is whatever the PR URL points at, so comparing the head
  # against owner/repo from the URL is enough to rule out fork pull requests.
  is_cross_repo="$(jq -r 'if .isCrossRepository == false then "false" else "true" end' <<<"${pr}")"
  head_repo="$(jq -r '"\(.headRepositoryOwner.login // "?")/\(.headRepository.name // "?")"' <<<"${pr}")"
  if [[ "${is_cross_repo}" != "false" ]]; then
    record_skip "${slug}" "fork pull request (head ${head_repo})"
    endgroup
    continue
  fi
  if [[ "${head_repo}" != "${owner}/${repo}" ]]; then
    record_skip "${slug}" "head repository ${head_repo} does not match ${owner}/${repo}"
    endgroup
    continue
  fi

  # --- Guard 4: open, not a draft -------------------------------------------
  state="$(jq -r '.state' <<<"${pr}")"
  if [[ "${state}" != "OPEN" ]]; then
    record_skip "${slug}" "state is ${state}"
    endgroup
    continue
  fi
  if [[ "$(jq -r 'if .isDraft == false then "false" else "true" end' <<<"${pr}")" == "true" ]]; then
    record_skip "${slug}" "pull request is a draft"
    endgroup
    continue
  fi

  # --- Guard 5: every check green -------------------------------------------
  IFS=$'\t' read -r checks_verdict checks_detail < <(jq -r "${ROLLUP_JQ}" <<<"${pr}")
  case "${checks_verdict}" in
    success)
      log "  checks: all green"
      ;;
    none)
      if is_true "${ALLOW_NO_CHECKS}"; then
        log "  checks: none reported (allowed by ALLOW_NO_CHECKS)"
      else
        record_skip "${slug}" "no checks reported (set ALLOW_NO_CHECKS=true to merge anyway)"
        endgroup
        continue
      fi
      ;;
    pending)
      record_skip "${slug}" "checks still running: ${checks_detail}"
      endgroup
      continue
      ;;
    *)
      record_skip "${slug}" "checks not passing: ${checks_detail}"
      endgroup
      continue
      ;;
  esac

  # --- Guard 6: semver bump allowlist ---------------------------------------
  if [[ -n "${ALLOWED_UPDATE_TYPES}" ]]; then
    # Dependabot records the bump in commit-message trailers, e.g.
    #   update-type: version-update:semver-patch
    commit_messages="$(jq -r '[.commits[]? | .messageHeadline, .messageBody] | join("\n")' <<<"${pr}")"
    mapfile -t update_types < <(
      grep -oE 'update-type:[[:space:]]*version-update:semver-[a-z]+' <<<"${commit_messages}" |
        sed -E 's/.*semver-//' | sort -u
    )
    if (( ${#update_types[@]} == 0 )); then
      record_skip "${slug}" "could not determine the semver bump from commit metadata"
      endgroup
      continue
    fi
    disallowed=""
    for update_type in "${update_types[@]}"; do
      list_contains "${update_type}" "${ALLOWED_UPDATE_TYPES}" ||
        list_contains "semver-${update_type}" "${ALLOWED_UPDATE_TYPES}" ||
        disallowed+="${disallowed:+, }semver-${update_type}"
    done
    if [[ -n "${disallowed}" ]]; then
      record_skip "${slug}" "update type ${disallowed} not in ALLOWED_UPDATE_TYPES"
      endgroup
      continue
    fi
    log "  update type: ${update_types[*]}"
  fi

  # --- Merge state ----------------------------------------------------------
  merge_state="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"${pr}")"
  mergeable="$(jq -r '.mergeable // "UNKNOWN"' <<<"${pr}")"
  if [[ "${mergeable}" == "CONFLICTING" || "${merge_state}" == "DIRTY" ]]; then
    record_skip "${slug}" "merge conflicts — needs a Dependabot rebase"
    endgroup
    continue
  fi
  if [[ "${merge_state}" == "BEHIND" ]]; then
    record_skip "${slug}" "branch is behind the base — needs a Dependabot rebase"
    endgroup
    continue
  fi

  if is_true "${DRY_RUN}"; then
    notice "${slug} would be approved and merged (dry run): ${title}"
    MERGED+=("${slug}|${title}")
    endgroup
    continue
  fi

  # --- Approve --------------------------------------------------------------
  already_approved="$(
    jq -r --arg viewer "${viewer}" \
      '[.latestReviews[]? | select((.author.login // "") == $viewer and .state == "APPROVED")] | length' \
      <<<"${pr}"
  )"
  if (( already_approved > 0 )); then
    log "  already approved by ${viewer}"
  elif output="$(gh pr review "${url}" --approve --body "Dependabot update with all checks passing — approved automatically." 2>&1)"; then
    log "  approved"
  else
    record_failure "${slug}" "approval failed: ${output}"
    endgroup
    continue
  fi

  # --- Merge ----------------------------------------------------------------
  merge_args=("--${MERGE_METHOD}")
  is_true "${DELETE_BRANCH}" && merge_args+=("--delete-branch")

  if output="$(gh pr merge "${url}" "${merge_args[@]}" 2>&1)"; then
    notice "${slug} merged: ${title}"
    MERGED+=("${slug}|${title}")
  else
    record_failure "${slug}" "merge failed: ${output}"
  fi

  endgroup
done

# --- Report -------------------------------------------------------------------
report_file="$(mktemp)"
{
  printf '## Bot auto-merge\n\n'
  # shellcheck disable=SC2016  # backticks here are Markdown, not command substitution
  printf '`%s`\n\n' "${query_terms[*]}"
  printf -- '- merged: **%d**\n- skipped: **%d**\n- errors: **%d**\n\n' \
    "${#MERGED[@]}" "${#SKIPPED[@]}" "${#FAILED[@]}"

  emit_table() {
    local heading="$1" second_column="$2"
    shift 2
    (( $# > 0 )) || return 0
    printf '### %s\n\n| Pull request | %s |\n| --- | --- |\n' "${heading}" "${second_column}"
    local row cell
    for row in "$@"; do
      # A stray pipe in a PR title or an API error would split the table row.
      cell="${row#*|}"
      printf '| %s | %s |\n' "${row%%|*}" "${cell//|/\\|}"
    done
    printf '\n'
  }

  if is_true "${DRY_RUN}"; then
    emit_table 'Would be merged (dry run)' 'Title' "${MERGED[@]+"${MERGED[@]}"}"
  else
    emit_table 'Merged' 'Title' "${MERGED[@]+"${MERGED[@]}"}"
  fi
  emit_table 'Skipped' 'Reason' "${SKIPPED[@]+"${SKIPPED[@]}"}"
  emit_table 'Errors' 'Reason' "${FAILED[@]+"${FAILED[@]}"}"
} >"${report_file}"
cat "${report_file}" >>"${SUMMARY_FILE}"
update_summary_issue "${report_file}"
rm -f "${report_file}"

log ""
log "Done: ${#MERGED[@]} merged, ${#SKIPPED[@]} skipped, ${#FAILED[@]} error(s)."

if (( ${#FAILED[@]} > 0 )) && is_true "${FAIL_ON_ERROR}"; then
  exit 1
fi
