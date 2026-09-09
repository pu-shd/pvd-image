#!/usr/bin/env bash
#
# Runs both test suites and fails if either one fails.
#
# Deliberately strict: a suite that produces no results is a failure, not a
# pass. An empty Pester run (bad path, parse error) would otherwise exit 0 and
# look green.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="$ROOT/test-results"
mkdir -p "$RESULTS"

overall=0

echo "======================================================================"
echo " Suite 1/4: Pester - guest installer logic"
echo "======================================================================"

pwsh -NoLogo -NonInteractive -Command "
    \$ErrorActionPreference = 'Stop'
    Import-Module Pester -MinimumVersion 5.0

    \$cfg = New-PesterConfiguration
    \$cfg.Run.Path              = '$ROOT/tests'
    \$cfg.Run.PassThru          = \$true
    \$cfg.Output.Verbosity      = 'Detailed'
    \$cfg.TestResult.Enabled    = \$true
    \$cfg.TestResult.OutputPath = '$RESULTS/pester.xml'

    \$r = Invoke-Pester -Configuration \$cfg

    if (\$r.TotalCount -eq 0) {
        Write-Error 'Pester discovered 0 tests - treating as failure, not success.'
        exit 2
    }
    Write-Host \"Pester: \$(\$r.PassedCount) passed, \$(\$r.FailedCount) failed, \$(\$r.TotalCount) total\"
    exit ([int](\$r.FailedCount -gt 0))
"
pester_rc=$?
[[ $pester_rc -ne 0 ]] && overall=1
echo "Pester suite exit code: $pester_rc"

echo
echo "======================================================================"
echo " Suite 2/4: zsh - deploy.sh driver against a mocked Azure CLI"
echo "======================================================================"

zsh "$ROOT/tests/test_deploy.zsh" | tee "$RESULTS/deploy-tests.txt"
zsh_rc=${PIPESTATUS[0]}
[[ $zsh_rc -ne 0 ]] && overall=1
echo "zsh suite exit code: $zsh_rc"

# A results file that recorded nothing means the suite never ran.
if ! grep -q '^passed: [0-9]' "$RESULTS/deploy-tests.txt" 2>/dev/null; then
  echo "ERROR: deploy.sh suite produced no summary line - treating as failure." >&2
  overall=1
fi

echo
echo "======================================================================"
echo " Suite 3/4: zsh - repair.sh driver against a mocked Azure CLI"
echo "======================================================================"

zsh "$ROOT/tests/test_repair.zsh" | tee "$RESULTS/repair-tests.txt"
repair_rc=${PIPESTATUS[0]}
[[ $repair_rc -ne 0 ]] && overall=1
echo "repair suite exit code: $repair_rc"

if ! grep -q '^passed: [0-9]' "$RESULTS/repair-tests.txt" 2>/dev/null; then
  echo "ERROR: repair.sh suite produced no summary line - treating as failure." >&2
  overall=1
fi

echo
echo "======================================================================"
echo " Suite 4/4: zsh - shortcuts.sh driver against a mocked Azure CLI"
echo "======================================================================"

zsh "$ROOT/tests/test_shortcuts.zsh" | tee "$RESULTS/shortcut-tests.txt"
shortcut_rc=${PIPESTATUS[0]}
[[ $shortcut_rc -ne 0 ]] && overall=1
echo "shortcuts suite exit code: $shortcut_rc"

if ! grep -q '^passed: [0-9]' "$RESULTS/shortcut-tests.txt" 2>/dev/null; then
  echo "ERROR: shortcuts.sh suite produced no summary line - treating as failure." >&2
  overall=1
fi

echo
echo "======================================================================"
if [[ $overall -eq 0 ]]; then
  echo " ALL SUITES PASSED"
else
  echo " FAILURES PRESENT - see output above"
fi
echo "======================================================================"
exit $overall
