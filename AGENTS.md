# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- Run `ruby test/runner_plan_contract_test.rb` to validate the reusable runner-plan dependency and its consumer call shape.
- `v1` is advanced only by the reviewed-merge contract in `.github/workflows/advance-v1.yml`; run `ruby test/major_channel_contract_test.rb` when changing that channel or its safety checks.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
