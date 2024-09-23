# TFE RUM Scripts
This repo contains two scripts that can count RUM and aggregrate data for TFE instances. These scripts use the API and count using each workspaces current state version. 

The repo also contains two SQL queries. One for gathering the total RUM for a TFE organization and one for counting the total number of worksapces. These queries must be run against the TFE database. 

## Usage
**Note**: The Python script is multi-threaded, making it much faster than the bash script. Both scripts work, but if an organization has over 1k workspaces the Python script should be used to avoid long runtimes. The bash script takes roughly 30 minutes to run for 2k workspaces. 
### Python Usage
```
python3 tfc_rum_count.py [-h] [-l {DEBUG,INFO,WARNING,ERROR,CRITICAL}] [-a ADDR] [-v] [-p PATH] [-f FILE] [--csv CSV]

Script to output basic Workspace Info (workspace ID, name, version, # resources) as well as an accurate RUM count.

options:
  -h, --help            show this help message and exit
  -l {DEBUG,INFO,WARNING,ERROR,CRITICAL}, --log-level {DEBUG,INFO,WARNING,ERROR,CRITICAL}
                        Set the logging level (default: ERROR)
  -a ADDR, --addr ADDR  URL for your TFE Server (default: 'https://app.terraform.io')
  -v, --verbose         Verbose will print details for every organization, otherwise only a summary table will appear.
  -p PATH, --path PATH  Path where state files are stored.
  -f FILE, --file FILE  Output file for results   (*** COMING SOON ***)
  --csv CSV             Output in CSV format      (*** COMING SOON ***)
```
#### Install dependencies (Python only)
```$ pip install -r requirements.txt```


#### Optional Environment Variables:
**TF_ADDR**: Address of TFE Server.  If not set, assumes TFC ("https://app.terraform.io"), DO NOT add api/v2 path to the address.


**TF_TOKEN**: valid TFC Token, precendence is:
1. TF_TOKEN
2. ~/.terraform.d/credentials.tfrc.json 
3. User prompt

_TF_ORG_: Organization Name


Example usage) 
```
TF_TOKEN=asdfasdfuxuxuxuxu  TF_ADDR=https://my.domain.io python3 gather_billable_rum.py   
```


### Bash Usage
The bash script requires [jq](https://jqlang.github.io/jq/) and cURL to work correctly. 
``` 
./gather_billable_rum.sh <API_URL> <ORG_NAME>

A "TOKEN" env variable should be set with a valid API token for the organization that is being accessed. 

API_URL - the base url of the API to pull data from. ex) app.terraform.io

ORG_NAME - the name of the organization to pull data from

example) TOKEN=aaaxxxfffkkk ./gather_billable_rum.sh app.terraform.io example_org
```
### Simpler Bash Usage

This script will use the TFE API to gather data about billable RUM for an
Organization. The output is in tabular form, meant for human consumption.

This script will use the appropriate API token in the credentials.tfrc.json
file for the invoking user. A "TOKEN" env variable can optionally be set
with a valid API token for the Organization that is being accessed. 

API_URL - the base url of the API to pull data from. ex) app.terraform.io

ORG_NAME - the name of the TFE/TFC Organization to pull data from

Example usage:
  ```
  ./gather_billable_rum-simple.sh app.terraform.io example_org
  ```

  OR

  ```
  export TOKEN=aaaxxxfffkkk
  ./gather_billable_rum-simple.sh app.terraform.io example_org
  ```


### SQL Script Usage
The SQL script can be ran using any SQL agent that has permission to read from the TFE database. You must ensure the correct database is selected (`tfe`) and the database user running the query has adequate permissions. 

The `gather_billable_rum.sql` file contains two queries. One query to count RUM and one to count the total number of workspaces for an organization. These queries should be pasted into the SQL client separatly (or one of the queries commented out) as they are meant to be run as two distinct queries. 


## Example Output for the Bash and Python Scripts
These script both produce JSON output in the same format. 

```
{
  "organization_name": "test-org",
  "organization_total_resources": 12949,
  "organization_managed_resources": 12726,
  "organization_data_resources": 223,
  "organization_billable_rum": 12724,
  "workspace_total": 2,
  "workspaces": [
    {
      "name": "test2-workspace",
      "total_resources": 12,
      "managed_resources": 12,
      "billable_resources": 10,
      "data_resources": 0,
      "terraform_version": "1.5.6",
      "resource_summary": {
        "providers": {
          "fakewebservices_database": 1,
          "fakewebservices_load_balancer": 1,
          "fakewebservices_server": 7,
          "fakewebservices_vpc": 1,
          "null_resource": 2
        },
        "provider_types": {
          "provider[\"registry.terraform.io/hashicorp/fakewebservices\"]": 10,
          "provider[\"registry.terraform.io/hashicorp/null\"]": 2
        }
      }
    },
    {
      "name": "test",
      "total_resources": 12937,
      "managed_resources": 12714,
      "billable_resources": 12714,
      "data_resources": 223,
      "terraform_version": "1.4.2",
      "resource_summary": {
        "providers": {
          "random_password": 1,
          "snowflake_account_grant": 1,
          "snowflake_database": 8,
          "snowflake_managed_account": 1,
          "snowflake_network_policy": 19,
          "snowflake_network_policy_attachment": 19,
          "snowflake_oauth_integration": 2,
          "snowflake_resource_monitor": 1,
          "snowflake_role": 155,
          "snowflake_role_grants": 9,
          "snowflake_saml_integration": 1,
          "snowflake_scim_integration": 1,
          "snowflake_warehouse": 48,
          "snowflake_user": 7,
          "aws_secretsmanager_secret": 1,
          "aws_secretsmanager_secret_version": 1,
          "data.snowflake_schemas": 3,
          "data.snowflake_tables": 220,
          "snowflake_database_grant": 3,
          "snowflake_schema_grant": 220,
          "snowflake_share": 3,
          "snowflake_table_grant": 12213
        },
        "provider_types": {
          "provider[\"registry.terraform.io/hashicorp/random\"]": 1,
          "provider[\"registry.terraform.io/snowflake-labs/snowflake\"]": 12670,
          "provider[\"registry.terraform.io/snowflake-labs/snowflake\"].snowflake_sysadmin": 56,
          "provider[\"registry.terraform.io/snowflake-labs/snowflake\"].snowflake_securityadmin": 208,
          "provider[\"registry.terraform.io/hashicorp/aws\"]": 2
        }
      }
    }
  ]
}

```
