-- =============================================================================
-- 00_connect_to_object_storage.sql
-- Let the schema read Object Storage using the database's own identity
-- (resource principal). No OCI API keys or passwords are stored.
--
-- Run steps 1 and 2 as ADMIN on the Autonomous Database, step 3 as the schema.
-- Replace everything in <angle brackets>.
--
-- PREREQUISITE (OCI admin team, see ../iam/policy.example.txt):
--   a dynamic group matching this Autonomous Database, and a policy letting that
--   group read objects in the target buckets. Oracle caches the resource principal
--   token for two hours, so a change to the dynamic group or policy can take up to
--   two hours to take effect. If the tenancy uses identity domains, the policy must
--   name the group as <identity_domain_name>/<dynamic-group-name>.
--   Written for Autonomous AI Database 26ai (the renamed Autonomous Database 23ai).
-- =============================================================================

-- 1. Enable the resource principal for the schema.
--    Makes the credential OCI$RESOURCE_PRINCIPAL usable by <SCHEMA>.
EXEC DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL(username => '<SCHEMA>');

-- 2. Privileges the schema needs for the loader and the scheduler job.
GRANT EXECUTE ON DBMS_CLOUD TO <SCHEMA>;
GRANT CREATE JOB TO <SCHEMA>;
-- CREATE TABLE, CREATE SEQUENCE and CREATE PROCEDURE are normally already held by a
-- regular Autonomous Database user; grant them too if the schema lacks them.

-- Check the credential exists for the schema:
SELECT owner, credential_name
FROM   dba_credentials
WHERE  credential_name = 'OCI$RESOURCE_PRINCIPAL';

-- 3. Verify, connected as <SCHEMA>. Should list the bucket's objects.
SELECT object_name, bytes, created
FROM   DBMS_CLOUD.LIST_OBJECTS(
         'OCI$RESOURCE_PRINCIPAL',
         'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/');

-- Optional: read one small object to prove read access (not only listing).
-- SELECT DBMS_LOB.GETLENGTH(
--          DBMS_CLOUD.GET_OBJECT('OCI$RESOURCE_PRINCIPAL',
--            'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/<small-file>'))
-- FROM dual;

-- Negative test: the same query against a bucket that is NOT in the policy must be
-- refused. If it succeeds, the policy is broader than intended.

-- Common errors
--   ORA-20401 authorization failed / 404: policy not applied yet (up to two hours), dynamic group rule does
--             not match this database, or the bucket name is not in the policy.
--   ORA-20404 object not found: wrong region, namespace or bucket in the URI, or the
--             URI does not end with /o/.
--   Timeout / cannot connect: private-endpoint database without a route to Object Storage
--             (Service Gateway) or without egress on port 443.
