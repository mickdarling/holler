#!/usr/bin/env bash
# Installs a pre-push hook that runs the same verification CI runs.
set -euo pipefail
cd "$(dirname "$0")/.."
cat > .git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
exec scripts/verify.sh all
HOOK
chmod +x .git/hooks/pre-push
echo "pre-push hook installed"
