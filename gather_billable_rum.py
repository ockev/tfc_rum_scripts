# Imports
import argparse
import concurrent.futures
import datetime
import getpass
import json
import logging
import os
import requests
import time
from packaging import version
from urllib.parse import urlparse

##
## tfapi_get: makes a single request and throttles thread in the case of a 429
##
def tfapi_get (url,headers,params=None):
    retry_delay = 0.2 # 200 ms delay
    while True:
        try:
            response = requests.get(url,headers=headers, params=params)
            # logging.info(f"Trying: {response.url}")
            response.raise_for_status()
            return response.json()
        except requests.exceptions.HTTPError as err:
            if response.status_code == 401:
                logging.warning(f"Authorization Error: 401 Unauthorized: {response.url}")
                return None 
            elif response.status_code == 404:
                logging.error(f"Forbidden Error: 404 Not Found: {response.url}")
                break
            elif response.status_code == 429:
                # print("Rate Limit Error: 429 Too Many Requests, throttling requests")
                logging.warning("Rate Limit Error: 429 Too Many Requests, throttling requests")
                time.sleep(retry_delay)
            else:
                logging.error(f"HTTP Error: {response.status_code}")
                logging.error(err)
                break #Fatal
        except requests.exceptions.RequestException as err:
            logging.error("Error occurred during the request.")
            logging.error(err)
            break #Fatal



##
## tfapi_get_data: iterates through all the pages of data before returning
##
def tfapi_get_data (url, headers, params):
    result = tfapi_get(url, headers, params)
    if result is None:
        return None
    data = []
    data += result['data']
    while (result['links']['next']):
        result = tfapi_get(result['links']['next'],headers)
        data += result['data']
    return data


##
## tfapi_get_state: Gets the state file resources
##
def tfapi_get_state (url, headers, params):
    resources = []
    result = tfapi_get(url, headers, params)
    data = result['data']

    ## Return no resources if the TF version too old
    if version.parse(data['attributes']['terraform-version']) < version.parse("0.12.0"):
      return []  

    resources += data['attributes']['resources']
    return resources



##
## get_resources: Helper Function that calls the resource API or state file API to capture resources
##
def get_resources(ws, base_url, api_ver, headers, params):
    rum = 0
    null_rs = 0
    data_rs = 0
    total = 0
    state_url = f"{base_url}{api_ver}/workspaces/{ws['id']}/current-state-version"
    
    resources = tfapi_get_state(state_url, headers, params)
    type_counts = {}
    provider_type_counts = {}
    for rs in resources:
        if rs['type'] not in type_counts:
          type_counts[rs['type']] = 0
        type_counts[rs['type']] += rs['count']

        if rs['provider'] not in provider_type_counts:
          provider_type_counts[rs['provider']] = 0
        provider_type_counts[rs['provider']] += rs['count']

        if rs['provider'] == 'provider[\"registry.terraform.io/hashicorp/null\"]':
            null_rs += rs['count']
        elif rs['type'].startswith("data") or rs['type'] == "terraform_data":
            data_rs += rs['count']
        else:
            rum += rs['count']
    
    return {'billable_resources': rum , 'data_resources': data_rs, 'managed_resources': rum+null_rs, 'total_resources':rum+null_rs+data_rs, 'resource_summary': { 'providers': type_counts, 'provider_types':provider_type_counts}}    



##
## Function Set-up Logging
##
def setup_logging(log_level):
    log_format = "%(levelname)s:%(asctime)s %(message)s"
    logging.basicConfig(format=log_format, level=log_level)


##
## Function Parse command line args
##
def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Script to output basic Workspace Info (workspace ID, name, version, # resources) as well as an accurate RUM count."
    )
    # group = parser.add_mutually_exclusive_group()
    parser.add_argument(
        "-l",
        "--log-level",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        default="WARNING",
        help="Set the logging level (default: ERROR)",
    )
    parser.add_argument(
        "-a",
        "--addr",
        default="https://app.terraform.io",
        help="URL for your TFE Server (default: 'https://app.terraform.io')",
    )
    parser.add_argument(
        '-f',
        '--file',
        help="Output file for results (COMING SOON)"
    )
    return parser.parse_args()


##
## print_summary: Prints the summary report 
##
def print_summary(rum_sum):

    # Initialize variables for subtotal and grand total
    org_subtotal = {'billable_resources': 0, 'managed_resources': 0, 'data_resources': 0, 'total_resources': 0}
    grand_total = {'billable_resources': 0, 'managed_resources': 0, 'data_resources': 0, 'total_resources': 0}

    for org in rum_sum:
        for ws in org['workspaces']:
            # Accumulate subtotal for the organization
            org_subtotal['billable_resources'] += ws['billable_resources']
            org_subtotal['data_resources'] += ws['data_resources']
            org_subtotal['managed_resources'] += ws['managed_resources']
            org_subtotal['total_resources'] += ws['total_resources']

            # Accumulate grand total
            grand_total['billable_resources'] += ws['billable_resources']
            grand_total['managed_resources'] += ws['managed_resources']
            grand_total['data_resources'] += ws['data_resources']
            grand_total['total_resources'] += ws['total_resources']

        org.update({'organization_total_resources': org_subtotal['total_resources'], 
                    'organization_managed_resources': org_subtotal['managed_resources'], 
                    'organization_data_resources': org_subtotal['data_resources'], 
                    'organization_billable_rum': org_subtotal['billable_resources']})
        org_subtotal = {'billable_resources': 0, 'managed_resources': 0, 'data_resources': 0, 'total_resources': 0}

    print(json.dumps(rum_sum))


# 
# process_enterprise: subroutine for TFC/TFE
#
def process_enterprise(args):
    logging.info(f"Processing Enterprise")
    rum_sum = []  # rum_sum a list of organization results

    # set the base url
    base_url = os.environ.get("TF_ADDR") or f"{args.addr}"  #ENV Variable overrides commandline
    logging.info(f"Using Base URL: {base_url}")
    server = urlparse(base_url).netloc  # Need the server to parse the token from helper file
    org_response = None

    # Set API Token
    token = os.environ.get("TF_TOKEN")     #ENV Variable first
    if token is None:
        try: 
            with open(os.path.expanduser("~/.terraform.d/credentials.tfrc.json")) as fp:
                credentials = json.load(fp)['credentials']
                if server in credentials:
                    token = credentials[server]['token']
                else:
                    default_server = "app.terraform.io"  # Default server value
                    token = credentials.get(default_server, {}).get('token')
                logging.info(f"Using Token from ~/.terraform.d/credentials.tfrc.json")
        except FileNotFoundError:
            token = getpass.getpass("Enter a TFC Token: ")
            logging.info(f"Using Token from user prompt")
    else:
        logging.info(f"Using Token from $TF_TOKEN")

    # Set Headers & Params
    headers = {"Authorization": "Bearer " + token}
    params = {'page[size]': '100'}
    api_ver = "/api/v2"

    orgs_url = f"{base_url}{api_ver}/organizations"
    org_response = tfapi_get_data(orgs_url, headers, params)


    # Iterate over each org
    for o in org_response:
        start_time = time.perf_counter()
        org_sum = {}  # Initialize org summary
        org_sum['organization_name'] = o['id'] # Set the id to org_id being processed
        org_sum['workspace_total'] = 0 # Start counting the total workspaces
        org_sum['workspaces'] = [] # Initialize the list of workspaces for the org

        ws_url = f"{base_url}{api_ver}/organizations/{o['id']}/workspaces" # build the url for ws list
        workspaces = tfapi_get_data(ws_url, headers, params) # Get all the workspaces for the org

        if workspaces is None:
            continue

        # # Single Threaded
        # for ws in workspaces:
        #     ws_sum = process_workspace(ws, base_url, api_ver, headers, params)    
        #     org_sum['workspaces'].append(ws_sum)

        # Multi-Threaded
        with concurrent.futures.ThreadPoolExecutor(max_workers=100) as executor:
            args_list = [(ws, base_url, api_ver, headers, params) for ws in workspaces]
            workspace_results = executor.map(lambda args: process_workspace(*args), args_list)

            for ws_sum in workspace_results:
                org_sum["workspace_total"] += 1
                org_sum['workspaces'].append(ws_sum)
        # Multi-Threaded

        # Append the org summary to RUM summary 
        rum_sum.append(org_sum)
        elapsed_time = time.perf_counter() - start_time
        logging.debug(f"Processed Org: {o['id']} in {elapsed_time:.3f} seconds")
    return rum_sum



#
# process_workspace: Helper fxn, allowing multiple workspaces to be processed in parallel
# 
def process_workspace(ws, base_url, api_ver, headers, params):
    logging.info(f"Processing ws: {ws['id']}")
    ws_sum = {}
    ws_sum['id'] = ws['id']
    ws_sum['name'] = ws['attributes']['name']
    ws_sum['terraform_version'] = ws['attributes']['terraform-version']
    rs_sum = {'billable_resources': 0, 'managed_resources': 0, 'data_resources': 0, 'total_resources': 0}
    if ws['attributes']['resource-count'] > 0:
        rs_sum = get_resources(ws, base_url, api_ver, headers, params)   
    ws_sum.update(rs_sum)
    return ws_sum



##########################################
## MAIN
##########################################
start_time = time.perf_counter()

# Parse command line arguments
args = parse_arguments()

setup_logging(args.log_level)

rum_sum = process_enterprise(args)

print_summary(rum_sum)

end_time = time.perf_counter()
elapsed_time = end_time - start_time
