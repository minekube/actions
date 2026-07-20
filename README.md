# Minekube Actions

Shared GitHub Actions and reusable workflows for Minekube repositories.

## Release cascade

`bump-go-module.yml` updates one Go module in the caller repository, runs local
tests, optionally dispatches the caller repository's full CI workflow, opens or
updates a rolling pull request, and requests auto-merge.

```yaml
jobs:
  bump:
    uses: minekube/actions/.github/workflows/bump-go-module.yml@v1
    permissions:
      contents: read
      id-token: write
    with:
      module: go.minekube.com/gate
      version: ${{ inputs.version }}
      base-ref: main
      branch: automation/update-gate
      pr-title: "fix(deps): update Gate to ${{ inputs.version }}"
      commit-message: "fix(deps): update gate to ${{ inputs.version }}"
      ci-workflow: fly.yml
    secrets: inherit
```

`dispatch-workflow.yml` dispatches a workflow in another repository with a
GitHub App installation token.

```yaml
jobs:
  dispatch:
    uses: minekube/actions/.github/workflows/dispatch-workflow.yml@v1
    permissions:
      contents: read
      id-token: write
    with:
      target-repository: gate
      target-workflow: bump-managed-dependency.yml
      target-ref: master
      inputs-json: |
        {
          "dependency": "vialite",
          "version": "${{ needs.release-please.outputs.tag_name }}"
        }
    secrets: inherit
```

Both workflows use `akua-dev/actions/.github/workflows/runner-plan.yml@9d86a1802f2ebc29c7d5770a4ffff7bb84b6cdc0` to
ask the Akua runner control plane for a self-hosted runner. Caller workflows must
grant `id-token: write` so the runner-plan workflow can authenticate to the
control plane with OIDC.

Required caller configuration:

- `vars.RELEASE_CASCADE_APP_ID`
- `secrets.RELEASE_CASCADE_APP_PRIVATE_KEY`
- `secrets: inherit` on the calling job
- GitHub App installation on every repository that the reusable workflow needs
  to write to or dispatch into

## Major channel

Use the major tag `@v1` from callers. The repository advances that lightweight
tag automatically after a reviewed pull request is merged into `main`; it is
not a release or a patch/minor tag.

`.github/workflows/advance-v1.yml` runs the contract tests on pull requests
with read-only permissions. After a `main` push, its write-capable job accepts
only this repository's exact checked-out merge commit when GitHub associates it
with a merged pull request targeting `main`. It reads the remote `v1`, requires
that commit to be an ancestor of the target, and verifies the remote value
after updating only `refs/tags/v1`. The GitHub ref API uses `force: true` for
an existing lightweight tag, but the workflow permits it only after those
event, pull-request, test, and ancestry checks.

The channel fails closed: direct pushes, missing PR association, non-fast-
forward history, API errors, and post-write mismatches leave `v1` unchanged.
Do not move `v1` manually to recover a failed run. Investigate the run and
escalate any exceptional rollback need; normal recovery is a reviewed,
compatible corrective merge to `main`, which the channel can advance forward.
