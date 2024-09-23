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
    echo 'Usage: ./gather_billable_rum-simple.sh <API_URL> <ORG_NAME>

    This script will use the TFE API to gather data about billable RUM for an
    Organization. The output tabular meant for human consumption.

    This script will use the appropriate API token in the credentials.tfrc.json file for the invoking user.
    A "TOKEN" env variable can be set with a valid API token for the organization that is being accessed. 
    This script will use the appropriate API token in the credentials.tfrc.json
    file for the invoking user. A "TOKEN" env variable can optionally be set
    with a valid API token for the Organization that is being accessed. 

    API_URL - the base url of the API to pull data from. ex) app.terraform.io

    ORG_NAME - the name of the organization to pull data from

    Example usage:
      `./gather_billable_rum-simple.sh app.terraform.io example_org`

      OR

      `export TOKEN=aaaxxxfffkkk`
      `./gather_billable_rum-simple.sh app.terraform.io example_org`

'
    exit
fi

cd "$(dirname "$0")"

api_url="$1"
org_name="$2"

# Function to get API token from TF credentials file, or from the $TOKEN env var
get_api_token() {
  set +u

  if [ -z "$TOKEN" ]; then
    jq -r '.credentials."'"$api_url"'".token' "$HOME/.terraform.d/credentials.tfrc.json"
  else
    echo "$TOKEN"
  fi

  set -u
}

# Function# to fetch current state version for a workspace
function fetch_current_state_version() {
  local workspace_id="$1"
  
  local state_version_response
  state_version_response=$(curl -s \
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

  local aggregate_totals
  aggregate_totals=$(jq -rc ".data | .attributes | reduce .resources[] as \$entry ( {}; .[\$entry.$aggregate_type] += \$entry.count )" <<< "$resources")
  
  echo "$aggregate_totals"
}

function vercomp() {
  [  "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
}

main () {
  local TOKEN
  TOKEN=$(get_api_token)
  workspaces_response=$(curl -s \
      --header "Authorization: Bearer $TOKEN"  \
      --header "Content-Type: application/vnd.api+json" \
      "https://$api_url/api/v2/organizations/$org_name/workspaces?page%5Bsize%5D=100)")

  api_error_check "$workspaces_response"

  total_page_count=$(jq '.meta.pagination."total-pages"' <<< "$workspaces_response")
  total_workspace_count=$(jq '.meta.pagination."total-count"' <<< "$workspaces_response")

  declare workspace_ids
  declare workspace_names
  declare -i workspace_rum
  declare -i org_rum

  # Gather Workspace name and IDs
  for ((itr = 1; itr <= total_page_count; itr++ )); do
    workspaces_response=$(curl -s \
      --header "Authorization: Bearer $TOKEN"  \
      --header "Content-Type: application/vnd.api+json" \
      "https://$api_url/api/v2/organizations/$org_name/workspaces?page%5Bsize%5D=100'&'page%5Bnumber%5D=$itr")

    api_error_check "$workspaces_response"

    workspace_ids+=( $(jq -r '.data[].id' <<< "$workspaces_response") )
    workspace_ids+=( "$(jq -r '.data[].id' <<< "$workspaces_response")" )
    workspace_names+=( $(jq -r '.data[].attributes.name' <<< "$workspaces_response") )
  done

  echo "Gathered Workspaces"

  for ((itr = 0; itr < total_workspace_count; itr++ )); do

    # If the Workspace has never had a state version or other errors, skip
    state_version_response=$(fetch_current_state_version "${workspace_ids[$itr]}")
    if echo "$state_version_response" | jq -e '.errors' &> /dev/null; then
      workspace_rum+=0
      continue
    fi

    # Skip old TF versions
    terraform_version=$(jq -rc '.data.attributes."terraform-version"' <<< "$state_version_response")
    vercomp "$terraform_version" "0.11.99" && continue

    workspace_billable_rum=$(jq '[.data.attributes.resources[] | select((.type|startswith("data."))
      or .type == "terraform_data" or .provider == "provider[\"registry.terraform.io/hashicorp/null\"]" | not)
      | .count] | add // 0' <<< "$state_version_response")

    workspace_rum+=$workspace_billable_rum
    org_rum+=$workspace_billable_rum
    echo "${workspace_ids[$itr]} ${workspace_names[$itr]} $workspace_billable_rum"
  done

  echo "--------------------------------"
  echo "Organization RUM total: $org_rum"
}

main "$@"
