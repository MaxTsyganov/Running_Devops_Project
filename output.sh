# Shared console-output helpers for setup/teardown/verify scripts - used to
# be copy-pasted into 8 different files. Sourced, not executed directly.
#
# step/info/success/fail: narrate progress, exit immediately on a real
# failure (paired with `set -e` in every caller). ok/bad: for the read-only
# verify scripts, which run every check and report a full summary instead of
# stopping at the first failure - callers must set ISSUES_FOUND=0 first.
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
step()    { echo -e "\n${BOLD}${YELLOW}==> $1${RESET}"; }
info()    { echo "    $1"; }
success() { echo -e "${GREEN}✔ $1${RESET}"; }
fail()    { echo -e "${RED}✘ $1${RESET}"; exit 1; }
ok()      { echo -e "${GREEN}✔ $1${RESET}"; }
bad()     { echo -e "${RED}✘ $1${RESET}"; ISSUES_FOUND=1; }
