# Shared console-output helpers for this project's setup/teardown/verify
# scripts - the same handful of lines used to be copy-pasted verbatim into
# 8 different files. Sourced, not executed directly.
#
# step/info/success/fail: the common case - narrate progress, exit
# immediately on a real failure (paired with `set -e` in every caller).
#
# ok/bad: for the two read-only verify scripts, which deliberately run
# every check and report a full pass/fail summary instead of stopping at
# the first failure - same visual style, different control flow. Callers
# must set ISSUES_FOUND=0 before their first check; bad() only sets it,
# never exits.
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
step()    { echo -e "\n${BOLD}${YELLOW}==> $1${RESET}"; }
info()    { echo "    $1"; }
success() { echo -e "${GREEN}✔ $1${RESET}"; }
fail()    { echo -e "${RED}✘ $1${RESET}"; exit 1; }
ok()      { echo -e "${GREEN}✔ $1${RESET}"; }
bad()     { echo -e "${RED}✘ $1${RESET}"; ISSUES_FOUND=1; }
