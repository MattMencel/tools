#!/usr/bin/env bash

echo "=== GROUPS ==="

for G in $(rbac-lookup -k group | grep -v system | grep -v SUBJECT | tr -s ' ' | tr ' ' ','); do
  # echo $G
  GID=$(echo $G | cut -d',' -f1)
  SCOPE=$(echo $G | cut -d',' -f2)
  ROLE=$(echo $G | cut -d',' -f3)
  # echo $GID
  DISPLAYNAME=$(az ad group show -g $GID -o json | jq -r .displayName)
  MEMBERS=$(az ad group member list --group $GID -o json | jq -c '.| map(.mailNickname)')
  # echo $MEMBERS
  jq -n --arg GID $GID --arg SCOPE $SCOPE --arg ROLE $ROLE --arg DISPLAYNAME $DISPLAYNAME --argjson MEMBERS $MEMBERS \
    '{"groupid": "\($GID)", "displayname": "\($DISPLAYNAME)", "scope": "\($SCOPE)", "role": "\($ROLE)", "members": "\($MEMBERS)"}'
done

echo "=== USERS ==="
rbac-lookup -k user | grep -v system
# for U in $(rbac-lookup -k user | grep -v system | grep -v SUBJECT | tr -s ' ' | tr ' ' ','); do
#   echo $U
# done
