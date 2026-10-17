#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/regional-dns.sh
source "$REPO_ROOT/scripts/lib/regional-dns.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
mkdir "$work/bin"
printf 'owned.us-west-2.elb.amazonaws.com\n' >"$work/owned"
cat >"$work/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "route53 list-resource-record-sets")
    [[ "${FAIL_READ:-0}" == 0 ]] || exit 3
    jq -nc --arg host "$TARGET" '{ResourceRecordSets:[
      {Name:"app.example.org.",Type:"A",AliasTarget:{DNSName:$host,HostedZoneId:"Z1234567890ABC",EvaluateTargetHealth:true}},
      {Name:"a-_external-dns-app.example.org.",Type:"TXT",TTL:300,ResourceRecords:[{Value:"\"heritage=external-dns,external-dns/owner=tx01v2-lab\""}]},
      {Name:"other.example.org.",Type:"A",TTL:300,ResourceRecords:[{Value:"203.0.113.10"}]}]}' ;;
  "route53 change-resource-record-sets")
    while (($#)) && [[ "$1" != --change-batch ]]; do shift; done
    printf '%s' "$2" >"$MOCK_DIR/change"
    [[ "${FAIL_CHANGE:-0}" == 0 ]] || exit 4
    echo /change/EXAMPLE ;;
  "route53 wait") echo wait >>"$MOCK_DIR/waits" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH" MOCK_DIR="$work" TARGET=dualstack.owned.us-west-2.elb.amazonaws.com.
remove_owned_app_dns Z1234567890ABC app.example.org "$work/owned"
jq -e '.Changes | length == 2 and all(.[]; .Action == "DELETE" and (.ResourceRecordSet.Name | endswith("app.example.org.")))' "$work/change" >/dev/null
rm "$work/change"
export TARGET=other-region.us-east-1.elb.amazonaws.com.
remove_owned_app_dns Z1234567890ABC app.example.org "$work/owned"
[[ ! -f "$work/change" ]]
export TARGET=owned.us-west-2.elb.amazonaws.com
if FAIL_READ=1 remove_owned_app_dns Z1234567890ABC app.example.org "$work/owned"; then die 'failed inventory ignored'; fi
[[ ! -f "$work/change" ]]
if FAIL_CHANGE=1 remove_owned_app_dns Z1234567890ABC app.example.org "$work/owned"; then die 'concurrent record change ignored'; fi
[[ "$(wc -l <"$work/waits")" == 1 ]]
echo 'PASS exact owned A/TXT cleanup, preservation of other-region aliases and refusal on API/concurrent-change failures'
