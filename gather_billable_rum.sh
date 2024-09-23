#!/usr/bin/env bash

# Exit if a command runs into an error
set -o errexit

# Exit on pipeline fails too
set -o pipefail

# Error when trying to access unset variables
set -o nounset

# Set a trace if desired
if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

# Check if the API URL and org name are provided as command-line arguments
if [[ $# -ne 2 ]]; then
    echo 'Usage: ./gather_billable_rum.sh <API_URL> <ORG_NAME>

    This script will use the TFE API to gather data about billable RUM for an Organization. 

    A "TOKEN" env variable should be set with a valid API token for the organization that is being accessed. 

    API_URL - the base url of the API to pull data from. ex) app.terraform.io

    ORG_NAME - the name of the organization to pull data from

    example) TOKEN=aaaxxxfffkkk ./gather_billable_rum.sh app.terraform.io example_org

'
    exit
fi

cd "$(dirname "$0")"

api_url="$1"
org_name="$2"

# Function to fetch current state version for a workspace
function fetch_current_state_version() {
  local workspace_id="$1"
  
  local state_version_response=$(curl -s \
      --header "Authorization: Bearer $TOKEN"  \
      --header "Content-Type: application/vnd.api+json" \
      "https://$api_url/api/v2/workspaces/$workspace_id/current-state-version")

  echo "$state_version_response"
}

# Check for errors in an API response
function api_error_check {
  local error_response="$1"
  if echo "$error_response" | jq -e '.errors' &> /dev/null; then
    echo "API Error" >&2
    echo "$error_response" >&2
    exit 1
  fi
}

# Aggregate data from the "resources" block
function aggregrate_data_from_resources {
  local resources="$1"
  local aggregate_type="$2"

  local aggregate_totals=$(jq -rc ".data | .attributes | reduce .resources[] as \$entry ( {}; .[\$entry.$aggregate_type] += \$entry.count )" <<< "$resources")
  
  echo "$aggregate_totals"
}

function vercomp() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

main () {
  workspaces_response=$(curl -s \
      --header "Authorization: Bearer $TOKEN"  \
      --header "Content-Type: application/vnd.api+json" \
      https://$api_url/api/v2/organizations/$org_name/workspaces)


  api_error_check "$workspaces_response"

  total_workspace_count=$(jq '.meta.pagination."total-count"' <<< "$workspaces_response")

  workspace_ids=($(echo $workspaces_response | jq -r '.data[].id'))
  workspace_names=($(echo $workspaces_response | jq -r '.data[].attributes.name'))

  next_page="$(jq '.meta.pagination."next-page"' <<< "$workspaces_response")"
  while [ "$next_page" != 'null' ]; do
    workspaces_response=$(curl -s -H "Authorization: Bearer $TOKEN" \
      https://$api_url/api/v2/organizations/$org_name/workspaces?page%5Bnumber%5D="$next_page"page%5Bsize%5D=100)
    api_error_check "$workspaces_response"
    next_page=$(jq '.meta.pagination."next-page"' <<< "$workspaces_response")

    workspace_ids+=($(echo $workspaces_response | jq -r '.data[].id'))
    workspace_names+=($(echo $workspaces_response | jq -r '.data[].attributes.name'))
  done
  
  declare all_workspaces_json="["

  declare -i organization_billable_rum=0
  declare -i organization_total_resources=0
  declare -i organization_managed_resources=0
  declare -i organization_data_resources=0

  declare -i ITER=0
  # Loop through workspaces
  for id in "${workspace_ids[@]}"; do
    # Fetch and print current state version for each workspace
    state_version_response=$(fetch_current_state_version "$id")

    workspace_name="${workspace_names[ITER]}"

    if echo "$state_version_response" | jq -e '.errors' &> /dev/null; then 
      continue
    fi

    terraform_version=$(jq -rc '.data.attributes."terraform-version"' <<< "$state_version_response")

    # Skip TF versions below 0.12.0
    vercomp $terraform_version "0.11.99" && continue 

    workspace_billable_rum=$(jq '[.data.attributes.resources[] | select((.type|startswith("data."))
      or .type == "terraform_data" or .provider == "provider[\"registry.terraform.io/hashicorp/null\"]" | not)
      | .count] | add // 0' <<< "$state_version_response")


    workspace_total_resources=$(jq '[.data.attributes.resources[] | .count] | add // 0' <<< "$state_version_response")


    workspace_managed_resources=$(jq '[.data.attributes.resources[] | select((.type|startswith("data.")) | not)
      | .count] | add // 0' <<< "$state_version_response")

    workspace_data_resources=$(jq '[.data.attributes.resources[] | select(.type|startswith("data.")) | .count] | add // 0' <<< "$state_version_response")

    type_aggregate=$(aggregrate_data_from_resources "$state_version_response" "type")
    provider_aggregate=$(aggregrate_data_from_resources "$state_version_response" "provider")

    workspace_json=$(jq -n \
                  --argjson wtr "$workspace_total_resources" \
                  --argjson wmr "$workspace_managed_resources" \
                  --argjson wbr "$workspace_billable_rum" \
                  --argjson wdr "$workspace_data_resources" \
                  --arg wn  "$workspace_name" \
                  --arg wid "$id" \
                  --arg tfv "$terraform_version" \
                  --argjson ta  "$type_aggregate" \
                  --argjson pa  "$provider_aggregate" \
                  '{ 
                      "id": $wid,
                      "name": $wn,
                      "total_resources": $wtr, 
                      "total_resources": $wtr, 
                      "managed_resources": $wmr, 
                      "billable_resources": $wbr,
                      "data_resources": $wdr,
                      "terraform_version": $tfv,
                      "resource_summary": {
                        providers: $ta,
                        provider_types: $pa
                      }
                    }
                  ' )

    organization_billable_rum+=$workspace_billable_rum
    organization_total_resources+=$workspace_total_resources
    organization_managed_resources+=$workspace_managed_resources
    organization_data_resources+=$workspace_data_resources

    
    all_workspaces_json+=$workspace_json

    all_workspaces_json+=","

    ((++ITER))
  done

  # Remove the last comma and add a closing bracket if we added at least one workspace
  if (( ITER > 0 )); then
    all_workspaces_json=${all_workspaces_json%?}
  fi
  all_workspaces_json+="]"

  echo "$all_workspaces_json" > workspace_json.json

  echo $(jq -n \
    --slurpfile wrkspcs ./workspace_json.json \
    --arg org_name "$org_name" \
    --argjson otr "$organization_total_resources" \
    --argjson omr "$organization_managed_resources" \
    --argjson odr "$organization_data_resources" \
    --argjson obr "$organization_billable_rum" \
    --argjson wtotal "$total_workspace_count" \
    '{
      "organization_name": $org_name,
      "organization_total_resources": $otr,
      "organization_managed_resources": $omr,
      "organization_data_resources": $odr, 
      "organization_billable_rum": $obr,
      "workspace_total": $wtotal,
      "workspaces": $wrkspcs
    }')

  rm -f ./workspace_json.json
}


main "$@"
