-----------------------------------------------------------------------------
-- This script will generate a column named RUM_COUNT that holds the total 
-- number of billable resources for an organization. Replace the field that
-- has "%<update org name>%" with the org to count RUM for
-----------------------------------------------------------------------------
SELECT 
  SUM(r.count) RUM_COUNT
FROM (
  SELECT
    sv.workspace_id,
    w.organization_id,
    sv.terraform_version,
    sv.updated_at,
    (r.e->>'type') as resources_type,
    (r.e->>'provider') as resources_provider,
    (r.e->>'count')::integer as count
  FROM rails.state_versions sv
    CROSS JOIN LATERAL JSONB_ARRAY_ELEMENTS(sv.resources) AS r(e)
    JOIN rails.workspaces w on w.id = sv.workspace_id AND w.current_state_version_id = sv.id
    JOIN rails.organizations o on o.id = w.organization_id
  WHERE string_to_array(sv.terraform_version, '.')::int[] > ARRAY[0, 12, 0]
  AND o.name like '%<update org name>%'
) r
JOIN rails.organizations o on o.id = r.organization_id
WHERE 
  r.resources_type <> 'terraform_data'
  AND r.resources_provider <> 'provider["registry.terraform.io/hashicorp/null"]'
  AND r.resources_type NOT like 'data%';



-----------------------------------------------------------------------------
-- This generates a count of workspaces for an organization. Replace the field that
-- has "%<update org name>%" with the org to count RUM for 
-----------------------------------------------------------------------------
SELECT COUNT(w.id) 
FROM rails.workspaces w, rails.organizations o
WHERE o.name like '%<update org name>%'
