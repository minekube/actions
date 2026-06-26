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

Both workflows use `cnap-tech/actions/.github/workflows/runner-plan.yml@main` to
ask the Akua runner control plane for a self-hosted runner. Caller workflows must
grant `id-token: write` so the runner-plan workflow can authenticate to the
control plane with OIDC.

Required caller configuration:

- `vars.RELEASE_CASCADE_APP_ID`
- `secrets.RELEASE_CASCADE_APP_PRIVATE_KEY`
- `secrets: inherit` on the calling job
- GitHub App installation on every repository that the reusable workflow needs
  to write to or dispatch into

Use the major tag `@v1` from callers. Move the `v1` tag when changing the shared
workflow implementation in a backward-compatible way.
