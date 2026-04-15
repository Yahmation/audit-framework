# Yahmation audit framework

Production-hardening audit runner for Yahmation projects. Used by every Yahmation repo's CI to verify required hardening items are in place before a PR can merge.

## How it works

1. Each project (or monorepo subproject) has a `.audit.json` declaring its `project_type` (backend / web / mobile / static) and `applicable_checklists` (an array of checklist IDs).
2. `audit-project.sh` reads the manifest and runs every check from each declared checklist's JSON rule file.
3. Checks are one of: `grep` (passes if pattern found in declared paths), `grep_negative` (passes if pattern NOT found), `file_exists`, or `manual` (skipped with a note).
4. Exits non-zero if any required check fails.

## Use in CI

Add to `.github/workflows/ci.yml`:

```yaml
- name: Hardening audit
  uses: Yahmation/audit-framework@main
```

That's it. The action finds `.audit.json` files anywhere in the repo and runs the audit on each.

## Use locally

```bash
cd /path/to/project
/root/shared/scripts/audit-project.sh
```

For the full org rollup:

```bash
/root/shared/scripts/audit-all-projects.sh             # per-project tables
/root/shared/scripts/audit-all-projects.sh --summary   # summary table only
/root/shared/scripts/audit-all-projects.sh --json      # JSON for cron/Discord
```

## Adding a new project

Drop a `.audit.json` at the project root (or each subproject root for monorepos):

```json
{
  "project_name": "my-new-service",
  "project_type": "backend",
  "applicable_checklists": [
    "production_hardening",
    "docs_runbook",
    "code_review",
    "db_design"
  ]
}
```

Project types: `any` | `web` | `mobile` | `backend` | `static`. `validate-project.sh` will fail if any project lacks a manifest.

## Adding a new checklist

1. Write the prose checklist in `/root/.claude/projects/-root/memory/checklist_<id>.md`.
2. Encode the auto-checkable items as `audit-rules/<id>.json` here.
3. Add the checklist ID to the appropriate projects' `.audit.json`.
