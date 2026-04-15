#!/usr/bin/env bash
# audit-project.sh — runs the applicable hardening checklists against the
# current project, reports pass/fail per item, exits non-zero if any
# required item is missing.
#
# Usage:
#   cd /root/voice/apps/mobile
#   /root/shared/scripts/audit-project.sh
#
# Looks for .audit.json in CWD. Expected shape:
#   {
#     "project_name": "voice-mobile",
#     "project_type": "mobile",          // any | web | mobile | backend | static
#     "applicable_checklists": ["production_hardening", ...]
#   }
#
# Each checklist is a JSON file at /root/shared/audit-rules/<id>.json with
# checks of types: grep | file_exists | manual.
#
# Exits 0 if all required checks pass; 1 if any required fails.

set -e
RULES_DIR="${RULES_DIR:-/root/shared/audit-rules}"
MANIFEST=".audit.json"

if [ ! -f "$MANIFEST" ]; then
  echo "✗ No $MANIFEST in $(pwd) — can't audit. Create it with project_name, project_type, applicable_checklists." >&2
  exit 2
fi

PROJECT_NAME=$(jq -r '.project_name // "(unnamed)"' "$MANIFEST")
PROJECT_TYPE=$(jq -r '.project_type // "any"' "$MANIFEST")
CHECKLISTS=$(jq -r '.applicable_checklists[]?' "$MANIFEST")

if [ -z "$CHECKLISTS" ]; then
  echo "✗ No applicable_checklists declared in $MANIFEST" >&2
  exit 2
fi

# Color helpers (skip if not a TTY).
if [ -t 1 ]; then
  G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[34m'; D='\033[2m'; N='\033[0m'
else
  G=''; R=''; Y=''; B=''; D=''; N=''
fi

echo -e "${B}▶ Auditing $PROJECT_NAME (type=$PROJECT_TYPE)${N}"
echo -e "${D}  Checklists: $(echo $CHECKLISTS | tr '\n' ' ')${N}"
echo

PASS=0
FAIL=0
WARN=0
MANUAL=0

# Run a single check. Echo result line, update counters.
run_check() {
  local checklist_id="$1" check_json="$2"
  local id name type pattern paths severity applies
  id=$(echo "$check_json" | jq -r '.id')
  name=$(echo "$check_json" | jq -r '.name')
  type=$(echo "$check_json" | jq -r '.type')
  severity=$(echo "$check_json" | jq -r '.severity // "required"')
  applies=$(echo "$check_json" | jq -r '.applies_to_project_types // empty | if type=="array" then join(",") else . end')

  # Filter by project type.
  if [ -n "$applies" ] && ! echo ",$applies," | grep -q ",$PROJECT_TYPE,"; then
    return
  fi

  case "$type" in
    grep)
      pattern=$(echo "$check_json" | jq -r '.pattern')
      mapfile -t path_array < <(echo "$check_json" | jq -r '.paths[]?')
      local found=""
      for p in "${path_array[@]}"; do
        # Support glob patterns with bash globstar; skip if no match.
        shopt -s globstar nullglob
        local matches=( $p )
        shopt -u globstar nullglob
        for f in "${matches[@]}"; do
          if [ -f "$f" ] && grep -qE "$pattern" "$f" 2>/dev/null; then
            found="$f"
            break 2
          fi
        done
      done
      if [ -n "$found" ]; then
        echo -e "  ${G}✅${N} ${id} ${name} ${D}(${found})${N}"
        PASS=$((PASS + 1))
      elif [ "$severity" = "required" ]; then
        echo -e "  ${R}❌${N} ${id} ${name} ${R}[REQUIRED — missing]${N}"
        FAIL=$((FAIL + 1))
      else
        echo -e "  ${Y}⚠️${N}  ${id} ${name} ${Y}[${severity} — missing]${N}"
        WARN=$((WARN + 1))
      fi
      ;;
    grep_any_of)
      # Passes if ANY of the listed alternatives matches.
      # Each alternative: {pattern, paths}. Useful when a feature can be
      # implemented multiple legitimate ways (e.g., email via managed
      # provider deps OR via OAuth2 send pattern in source).
      local found=""
      while IFS= read -r alt; do
        [ -n "$found" ] && break
        local apat
        apat=$(echo "$alt" | jq -r '.pattern')
        mapfile -t apaths < <(echo "$alt" | jq -r '.paths[]?')
        for p in "${apaths[@]}"; do
          shopt -s globstar nullglob
          local matches=( $p )
          shopt -u globstar nullglob
          for f in "${matches[@]}"; do
            if [ -f "$f" ] && grep -qE "$apat" "$f" 2>/dev/null; then
              found="$f"; break 3
            fi
          done
        done
      done < <(echo "$check_json" | jq -c '.alternatives[]?')
      if [ -n "$found" ]; then
        echo -e "  ${G}✅${N} ${id} ${name} ${D}(${found})${N}"
        PASS=$((PASS + 1))
      elif [ "$severity" = "required" ]; then
        echo -e "  ${R}❌${N} ${id} ${name} ${R}[REQUIRED — missing]${N}"
        FAIL=$((FAIL + 1))
      else
        echo -e "  ${Y}⚠️${N}  ${id} ${name} ${Y}[${severity} — missing]${N}"
        WARN=$((WARN + 1))
      fi
      ;;
    grep_all)
      # All listed patterns must match within the same file.
      mapfile -t pattern_array < <(echo "$check_json" | jq -r '.patterns[]?')
      mapfile -t path_array < <(echo "$check_json" | jq -r '.paths[]?')
      local found=""
      for p in "${path_array[@]}"; do
        shopt -s globstar nullglob
        local matches=( $p )
        shopt -u globstar nullglob
        for f in "${matches[@]}"; do
          if [ -f "$f" ]; then
            local all_matched=1
            for pat in "${pattern_array[@]}"; do
              if ! grep -qE "$pat" "$f" 2>/dev/null; then
                all_matched=0; break
              fi
            done
            if [ "$all_matched" = 1 ]; then
              found="$f"; break 2
            fi
          fi
        done
      done
      if [ -n "$found" ]; then
        echo -e "  ${G}✅${N} ${id} ${name} ${D}(${found})${N}"
        PASS=$((PASS + 1))
      elif [ "$severity" = "required" ]; then
        echo -e "  ${R}❌${N} ${id} ${name} ${R}[REQUIRED — missing]${N}"
        FAIL=$((FAIL + 1))
      else
        echo -e "  ${Y}⚠️${N}  ${id} ${name} ${Y}[${severity} — missing]${N}"
        WARN=$((WARN + 1))
      fi
      ;;
    grep_negative)
      pattern=$(echo "$check_json" | jq -r '.pattern')
      mapfile -t path_array < <(echo "$check_json" | jq -r '.paths[]?')
      local hit=""
      for p in "${path_array[@]}"; do
        shopt -s globstar nullglob
        local matches=( $p )
        shopt -u globstar nullglob
        for f in "${matches[@]}"; do
          if [ -f "$f" ] && grep -qE "$pattern" "$f" 2>/dev/null; then
            hit="$f"; break 2
          fi
        done
      done
      if [ -z "$hit" ]; then
        echo -e "  ${G}✅${N} ${id} ${name}"
        PASS=$((PASS + 1))
      elif [ "$severity" = "required" ]; then
        echo -e "  ${R}❌${N} ${id} ${name} ${R}[REQUIRED — pattern found in ${hit}]${N}"
        FAIL=$((FAIL + 1))
      else
        echo -e "  ${Y}⚠️${N}  ${id} ${name} ${Y}[${severity} — pattern found in ${hit}]${N}"
        WARN=$((WARN + 1))
      fi
      ;;
    file_exists)
      mapfile -t path_array < <(echo "$check_json" | jq -r '.paths[]?')
      local found=""
      for p in "${path_array[@]}"; do
        if [ -e "$p" ]; then found="$p"; break; fi
      done
      if [ -n "$found" ]; then
        echo -e "  ${G}✅${N} ${id} ${name} ${D}(${found})${N}"
        PASS=$((PASS + 1))
      elif [ "$severity" = "required" ]; then
        echo -e "  ${R}❌${N} ${id} ${name} ${R}[REQUIRED — file not found]${N}"
        FAIL=$((FAIL + 1))
      else
        echo -e "  ${Y}⚠️${N}  ${id} ${name} ${Y}[${severity} — file not found]${N}"
        WARN=$((WARN + 1))
      fi
      ;;
    manual)
      echo -e "  ${B}⏭️${N}  ${id} ${name} ${D}[manual verification — not auto-checked]${N}"
      MANUAL=$((MANUAL + 1))
      ;;
    *)
      echo -e "  ${R}!!${N} ${id} unknown check type: $type"
      ;;
  esac
}

for cl in $CHECKLISTS; do
  rules="$RULES_DIR/$cl.json"
  if [ ! -f "$rules" ]; then
    echo -e "${R}✗ checklist $cl: rules file $rules not found${N}"
    FAIL=$((FAIL + 1))
    continue
  fi
  cl_name=$(jq -r '.name // .id' "$rules")
  echo -e "${B}▶ $cl${N} — ${D}$cl_name${N}"
  jq -c '.checks[]' "$rules" | while read -r check; do
    run_check "$cl" "$check"
  done
  # Re-read counters (the while-pipe is a subshell). Simplest: tally after each.
  echo
done

# The while-pipe runs in a subshell, so PASS/FAIL/WARN/MANUAL won't have
# accumulated. Re-tally by re-running the checks in a non-pipe form OR
# parse the output. Simplest workaround: use process substitution.
PASS=0; FAIL=0; WARN=0; MANUAL=0
for cl in $CHECKLISTS; do
  rules="$RULES_DIR/$cl.json"
  [ -f "$rules" ] || continue
  while IFS= read -r check; do
    out=$(run_check "$cl" "$check" 2>&1 || true)
    case "$out" in
      *✅*) PASS=$((PASS + 1)) ;;
      *❌*) FAIL=$((FAIL + 1)) ;;
      *⚠*)  WARN=$((WARN + 1)) ;;
      *⏭*)  MANUAL=$((MANUAL + 1)) ;;
    esac
  done < <(jq -c '.checks[]' "$rules")
done

echo "════════════════════════════════════════"
echo -e "${G}Passed: $PASS${N}    ${R}Failed (required): $FAIL${N}    ${Y}Missing (recommended): $WARN${N}    ${B}Manual: $MANUAL${N}"

if [ "$FAIL" -gt 0 ]; then
  echo -e "${R}✗ AUDIT FAILED — $FAIL required item(s) missing${N}"
  exit 1
fi
echo -e "${G}✓ AUDIT PASSED${N}"
exit 0
