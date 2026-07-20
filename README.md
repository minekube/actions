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

`.github/workflows/advance-v1.yml` checks out the exact event SHA with no
persisted credential and runs the contract tests with read-only permissions.
Only the `closed` event for a pull request merged into this repository's `main`
branch can start the no-checkout write job. That job re-fetches the exact pull
request and requires its latest decisive review to approve the final head SHA
from a collaborator with write or admin permission. It then requires the
remote `v1` commit to be an ancestor of the merge SHA, rechecks the remote tag
before writing only `refs/tags/v1`, and verifies the remote value afterward.
The GitHub ref API uses `force: true` for an existing lightweight tag, but only
after those event, pull-request, approval, contract-test, and ancestry checks.

Refusals before the update issue no tag write. If `v1` already matches the
merge SHA, the job reports an already-current no-op and writes nothing. Once
the update request has been issued, an API failure or post-write mismatch is
not proof that `v1` stayed unchanged; investigate the remote state. Do not move
`v1` manually to recover a failed run. Escalate any exceptional rollback need;
normal recovery is a reviewed, compatible corrective merge to `main`, which
the channel can advance forward.
