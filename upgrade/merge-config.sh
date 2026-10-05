#!/bin/sh
# Builds the new plausible-conf.env from the template of this repository and
# the settings of your old install (MIGRATION-GUIDE.md, step 5).
#
#   ./upgrade/merge-config.sh                       # old file: $BACKUP/config/plausible-conf.env
#   ./upgrade/merge-config.sh /path/to/old/plausible-conf.env
#
# Run from the install directory, after switching to the new deployment files
# (so plausible-conf.env is the new template). Every KEY=value of the old file
# replaces the template's value or is added, so BASE_URL, SECRET_KEY_BASE,
# TOTP_VAULT_KEY, SMTP, Google, MaxMind, ... carry over unchanged.
# Then:
#   * ENABLE_PERSISTENT_TRACKING=false, unless the old file sets it
#     (turn it on after the upgrade)
#   * PERSISTENT_SALT_SECRET is kept from the old file, or generated once
# Prints the resulting setting names (not their values) and a few checks.
set -eu

NEW=plausible-conf.env
if [ $# -ge 1 ]; then
  OLD=$1
else
  [ -f upgrade.vars ] || { echo "upgrade.vars not found: pass the old plausible-conf.env as an argument" >&2; exit 1; }
  . ./upgrade.vars
  OLD="${BACKUP:?}/config/plausible-conf.env"
fi
[ -f "$OLD" ] || { echo "old config not found: $OLD" >&2; exit 1; }
[ -f "$NEW" ] || { echo "$NEW not found: run from the install directory" >&2; exit 1; }
[ "$(cd "$(dirname "$OLD")" && pwd)/$(basename "$OLD")" != "$(pwd)/$NEW" ] ||
  { echo "the old and new config are the same file" >&2; exit 1; }

tmp="$NEW.merge.$$"
cp "$NEW" "$tmp"
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$OLD" | while IFS= read -r line; do
  key=${line%%=*}
  grep -v "^$key=" "$tmp" > "$tmp.2" || true
  mv "$tmp.2" "$tmp"
  printf '%s\n' "$line" >> "$tmp"
done

if ! grep -q '^ENABLE_PERSISTENT_TRACKING=' "$OLD"; then
  sed -i 's/^ENABLE_PERSISTENT_TRACKING=.*/ENABLE_PERSISTENT_TRACKING=false/' "$tmp"
fi
secret=$(sed -n 's/^PERSISTENT_SALT_SECRET=//p' "$tmp" | tail -n 1)
case "$secret" in
  "" | replace-me)
    secret=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
    grep -v '^PERSISTENT_SALT_SECRET=' "$tmp" > "$tmp.2" || true
    mv "$tmp.2" "$tmp"
    printf 'PERSISTENT_SALT_SECRET=%s\n' "$secret" >> "$tmp"
    echo "generated PERSISTENT_SALT_SECRET (keep it: changing it later makes every visitor look new)"
    ;;
esac
mv "$tmp" "$NEW"

echo "settings in $NEW:"
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NEW" | cut -d= -f1 | sed 's/^/  /'
echo
grep -E '^(BASE_URL|SMTP_HOST_PORT|ENABLE_PERSISTENT_TRACKING)=' "$NEW" | sed 's/^/  /'
if grep -q '^TOTP_VAULT_KEY=.' "$OLD"; then
  echo "  TOTP_VAULT_KEY: carried over"
fi
if grep -q '^MAILER_ADAPTER=Bamboo.SMTPAdapter' "$NEW"; then
  echo "WARNING: MAILER_ADAPTER=Bamboo.SMTPAdapter no longer exists: change it to Bamboo.Mua" >&2
fi
if grep -q '^BASE_URL=replace-me' "$NEW" || grep -q '^SECRET_KEY_BASE=replace-me' "$NEW"; then
  echo "WARNING: BASE_URL or SECRET_KEY_BASE is still replace-me: copy them from your old config" >&2
fi
echo "CONFIG MERGED"
