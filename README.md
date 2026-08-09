# bot-pr-sweeper

A scheduled GitHub Actions workflow that sweeps for bot-authored pull requests,
approves the ones whose checks are all green, and merges them. Out of the box it
covers the repositories of whoever owns the token; `OWNERS` widens it to any
list of users and orgs.

It ships configured for Dependabot. Nothing in the sweep is Dependabot-specific
except two defaults — add another bot to `EXPECTED_AUTHORS` (`renovate[bot]`,
say) and leave `ALLOWED_UPDATE_TYPES` empty, since its semver filter reads
Dependabot's commit trailers and will not match another bot's.

Everything the sweep does is driven by [`scripts/auto-merge-dependabot.sh`](scripts/auto-merge-dependabot.sh);
the workflow only passes configuration into it.

## Setup

1. **Create a classic personal access token** with the `repo`, `workflow` and
   `read:org` scopes.

   `workflow` is not optional: Dependabot's `github-actions` updates edit files
   under `.github/workflows/`, and GitHub refuses to merge such a pull request
   with a token that lacks it.

   `read:org` is what lets the sweep look up which teams you belong to, so it
   can find pull requests that request a *team* rather than you personally. It
   is not covered by `repo`. Without it the run still works, but logs a warning
   and skips team-requested pull requests entirely.

   A fine-grained token is scoped to a single owner, so it only suits the
   default scope (your own account). Sweeping additional orgs via `OWNERS`
   would mean one token per owner — use a classic one for that.

2. **Store it** as a repository secret named `AUTO_MERGE_PAT`
   (`Settings → Secrets and variables → Actions → Secrets`).

3. **Optionally override defaults** as repository *variables* (same screen,
   `Variables` tab). See the table below.

Approvals are recorded as the token's user. By default the sweep covers exactly
that user's own repositories; widen it with `OWNERS` only to owners where the
token has write access. The token's user must not be the author of the pull
requests — which holds here, since a bot is the author.

## Configuration

Every setting is a repository variable, under `Settings → Secrets and variables
→ Actions → Variables`. Anything left unset falls back to the default below,
which is defined at the top of the script.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SEARCH_QUERY` | `is:open archived:false` | Qualifiers common to every owner. Do **not** put `user:`, `org:` or `sort:` here — nor `author:`, which is derived from `EXPECTED_AUTHORS`. |
| `REVIEW_REQUESTED` | `@me` | Appended to the query as `review-requested:`. `@me` resolves to the account behind the PAT; `none` drops the filter entirely; any other value is used verbatim. |
| `TEAM_REVIEW_REQUESTED` | `@my-teams` | Appended as `team-review-requested:`. `@my-teams` looks up the teams the PAT belongs to (needs `read:org`); `none` disables it; any other value is a comma-separated `org/team` list. |
| `OWNERS` | *(empty — the PAT's own account)* | Comma-separated owners to sweep, searched one at a time. Also the allowlist of repositories that may be merged. Unset resolves to the account behind the token; `none` removes owner scoping entirely. |
| `ALLOWED_UPDATE_TYPES` | *(empty — all)* | Comma-separated semver bumps to accept, e.g. `semver-patch,semver-minor`. Empty accepts every bump. |
| `EXPECTED_AUTHORS` | `dependabot[bot]` | Comma-separated list of the only authors whose pull requests may be merged. Names each bot **once**: the `author:` search qualifiers are derived from it (see below). |
| `MERGE_METHOD` | `squash` | `squash`, `merge` or `rebase`. |
| `MAX_PRS` | `50` | Maximum pull requests fetched per search, and there is one search **per owner × author × reviewer** combination. |
| `ALLOW_NO_CHECKS` | `false` | Whether to merge a pull request that reports no checks at all. |
| `DELETE_BRANCH` | `true` | Delete the Dependabot branch after merging. |
| `DRY_RUN` | `false` | Report what would happen without approving or merging. |
| `FAIL_ON_ERROR` | `false` | Exit non-zero when any pull request errored. |

There is no separate dry-run for manual dispatches: a `workflow_dispatch` run
behaves exactly like a scheduled one. To rehearse a change, set the `DRY_RUN`
variable to `true`, dispatch the workflow, read the job summary, then set it
back to `false`.

## What has to be true before a PR is merged

Search results are treated as candidates only. Each one is re-fetched and
re-validated against the API before anything is written, so a mistyped or
over-broad query cannot cause a merge by itself:

1. the author is one of `EXPECTED_AUTHORS`, and is flagged as a bot account
   when that entry names a GitHub App,
2. the pull request is not from a fork — head and base are the same repository,
3. the repository owner is listed in `OWNERS`,
4. the pull request is open and not a draft,
5. every check run and status context has finished successfully
   (`SKIPPED` and `NEUTRAL` count as success; anything still running defers the
   pull request to a later run),
6. the semver bump is allowed by `ALLOWED_UPDATE_TYPES`, read from Dependabot's
   `update-type:` commit trailers,
7. the branch is neither conflicting nor behind its base.

Branch protection still applies on top of all this. If a repository requires
more approvals than the token can give, the merge fails and is reported as an
error rather than being forced through — the script never uses `--admin`.

## Running it locally

The script only needs `gh` and `jq`:

```sh
DRY_RUN_INPUT=true ./scripts/auto-merge-dependabot.sh

# narrow it down while experimenting
DRY_RUN_INPUT=true OWNERS_INPUT=some-org MAX_PRS_INPUT=5 \
  ALLOWED_UPDATE_TYPES_INPUT=semver-patch \
  ./scripts/auto-merge-dependabot.sh
```

## Notes on the search query

The query in the GitHub web UI and the query this workflow can run are not quite
the same language.

- **`(user:a OR user:b)` does not work.** The web UI accepts boolean groups, but
  the REST search API backing `gh search` rejects them with HTTP 422. That is
  why owners are configured separately in `OWNERS` and searched one per request,
  with the results unioned.
- **`sort:updated-desc` does not belong in the query either.** The API takes
  sorting as its own parameter; left in the query string it would be matched as
  free text. The script always sorts by `updated`, descending.
- **An owner with nothing indexed makes the whole search fail**, so each owner
  is searched separately and a failure is logged and stepped over rather than
  aborting the run. An org with no repositories visible to the token returns
  HTTP 422 every time — harmless, but dropping it from `OWNERS` silences the
  warning. An org whose repositories have all been moved or made private will do
  this.
- **Each bot is named once, in `EXPECTED_AUTHORS`.** GitHub spells the same bot
  three ways — `dependabot[bot]` on a pull request, `app/dependabot` in a search
  query, `dependabot` bare — so the script normalises whatever you set and
  derives the search qualifiers from it. There is no second place to keep in
  sync.

  The `[bot]` suffix and the `app/` prefix are meaningful, not decoration: both
  mark the author as a **GitHub App**, which searches as `author:app/<slug>` and
  whose pull requests carry a bot flag the script requires. A bare login like
  `renovate-bot` is instead read as an ordinary account driving a bot, searched
  as `author:renovate-bot`, with the bot-flag requirement dropped per entry.

  So `dependabot` is valid but means something different from `dependabot[bot]`,
  and matches nothing — Dependabot is an App. Prefer the `[bot]` form. Should
  the rule ever get a bot's form wrong, an explicit `author:` in `SEARCH_QUERY`
  overrides the derivation entirely, while `EXPECTED_AUTHORS` still governs
  which authors may actually be merged.

- **Every list costs extra requests, for the same reason owners do.** With no
  `OR` available, the sweep is the union over every owner × author × reviewer
  combination — two owners, two bots and one applicable team is six searches.
  Well within rate limits, but it is why `MAX_PRS` is a per-search cap rather
  than a per-run one.

## Using it with Renovate

`EXPECTED_AUTHORS=dependabot[bot],renovate[bot]` is enough to sweep both. Every
gate — fork, checks, draft, conflicts, approval, merge — is bot-agnostic.

Renovate is also the common case for team-requested reviews, so check that
`TEAM_REVIEW_REQUESTED` is left at `@my-teams` and that the PAT carries
`read:org`; otherwise its pull requests will not be found at all.

The **one** exception is `ALLOWED_UPDATE_TYPES`. It reads Dependabot's
`update-type: version-update:semver-*` commit trailers, which Renovate does not
write. Set it, and every Renovate pull request is skipped with *"could not
determine the semver bump from commit metadata"* — a fail-closed outcome, so
nothing merges unchecked, but nothing merges at all either. Leave it empty (the
default) when sweeping both, and let the checks be the gate.

Note also that self-hosted Renovate often runs as an ordinary account rather
than the hosted App, in which case the entry is that account's bare login
(`renovate-bot`, say), not `renovate[bot]`.

- **The reviewer filter is doing real filtering.** It is not part of
  `SEARCH_QUERY`; the script resolves the token's own account and appends
  `review-requested:<that account>`, so the sweep follows whoever owns the PAT
  and no login is hard-coded anywhere. If the account cannot be resolved the run
  fails immediately rather than sweeping unfiltered.

- **`review-requested:` does not match reviews requested from a team.** It only
  matches direct requests to a person; team requests need the separate
  `team-review-requested:org/team` qualifier. Bots wired to CODEOWNERS or to a
  per-repo team request the team, so those pull requests are invisible to the
  user filter no matter who you are.

  `TEAM_REVIEW_REQUESTED=@my-teams` closes that gap: the script lists the teams
  the token belongs to and searches each as an alternative to the user filter.
  Teams are matched against the owner being swept — a team in `some-org` is only
  ever paired with `user:some-org`, since the two can never intersect otherwise.
  So belonging to fourteen teams across six orgs costs nothing while sweeping an
  owner that accounts for one of them.

  The failure mode is quiet, which is what makes it worth knowing: an org can
  hold hundreds of open bot pull requests and still report zero candidates,
  simply because every one of them addresses a team. If an owner you expect to
  sweep comes back empty, this is the first thing to check.
