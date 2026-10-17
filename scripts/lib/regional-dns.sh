# shellcheck shell=bash
# Called with a snapshot of this cluster's ALB DNS names. Never delete another region's alias.
remove_owned_app_dns() {
  local zone=$1 domain=$2 owned_file=$3 records batch change
  records="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" --output json)" || return
  batch="$(jq -c --arg app "${domain}." --arg txt "a-_external-dns-${domain}." \
    --rawfile owned "$owned_file" '
    ($owned | split("\n") | map(ascii_downcase | ltrimstr("dualstack.") | rtrimstr("."))) as $names |
    [.ResourceRecordSets[]? | select(.Name == $app and .Type == "A") |
      select(.AliasTarget.DNSName | ascii_downcase | ltrimstr("dualstack.") | rtrimstr(".") | . as $name | $names | index($name))] as $aliases |
    if ($aliases | length) == 1 then
      {Changes: [(.ResourceRecordSets[] | select((.Name == $app and .Type == "A") or (.Name == $txt and .Type == "TXT")) |
        {Action: "DELETE", ResourceRecordSet: .})]}
    else {Changes: []} end' <<<"$records")" || return
  if [[ "$(jq '.Changes | length' <<<"$batch")" == 0 ]]; then
    log 'DNS has no alias owned by this cluster; the other region is preserved.'
    return
  fi
  # Exact record contents make a concurrent change fail rather than delete the new target.
  change="$(aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch "$batch" --query ChangeInfo.Id --output text)" || return
  [[ -n "$change" && "$change" != None ]] || die 'Route53 did not return a change ID'
  aws route53 wait resource-record-sets-changed --id "$change"
}
