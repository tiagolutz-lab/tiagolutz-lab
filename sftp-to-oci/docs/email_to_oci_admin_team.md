# Email to the OCI admin team

**To:** OCI admin team
**Subject:** SFTP to OCI to ATP file pipeline: compartments, buckets, dynamic groups and policies needed

Hi team,

We are building a pipeline that moves files from SFTP servers into OCI Object Storage and then loads them into Autonomous Database (ATP). The database part is built and read access is proven. Before we can finish and test the full flow, we need a few things created in OCI. This email explains what we have done, what works, and what we need from you.

## 1. How the pipeline works

1. A transfer VM (rclone) copies files from the SFTP servers into the interface buckets, oldest file first. A file is deleted from the SFTP server only after the upload is verified.
2. ATP lists the interface buckets and reads each file, oldest first, using a resource principal (no stored credentials).
3. Each file is loaded in one database transaction.
4. After a successful load, the file is moved to a shared ARCHIVE bucket, or deleted if archiving is switched off for that bucket.
5. If a file keeps failing, it is moved to a shared ERROR bucket so it does not block the files behind it.

## 2. What is done and working

- The ATP side is built: configuration table per bucket, loader package, scheduled jobs, and logging of every file.
- ATP is set up to use `OCI$RESOURCE_PRINCIPAL` to reach Object Storage.
- Grant given to the database user for listing and reading files: `<paste the exact grant statement we ran>`.
- Tested from ATP: **listing objects works** and **getting (reading) objects works**.
- Tested from ATP: **writing an object fails** with ORA-20404. Object Storage returns "not found" when the caller is not authorised, so the current policy is read-only. This is the gap this email asks you to close.

## 3. What we need from you

### 3.1 Compartments

We suggest two compartments, so production is fully separate from non-production:

```
<tenancy root>
├── integrations-prod          production only
└── integrations-nonprod       parent for all non-production environments
    ├── dev
    ├── sit
    ├── uat
    └── ... one child per non-prod environment (we have 7 to 8)
```

Because a policy on a parent compartment also applies to its children, one set of policies on `integrations-nonprod` covers every non-prod environment, and a new environment needs only a new child compartment. Production policies stay separate and tighter.

Please confirm the final names. If a different convention is already in use, we will follow it.

### 3.2 Buckets

See the diagram: [compartment_bucket_structure.png](compartment_bucket_structure.png).

Bucket names are unique within the namespace and region, and cannot be renamed. Proposed convention:

`bkt-lcn-<env>-<interface>` for the buckets files arrive in, and `bkt-lcn-<env>-archive` / `bkt-lcn-<env>-error` for the shared ones

- `<env>`: `prd`, `sit`, `uat`, `dev` and so on
- `<interface>`: `ifa` for InterfaceA, `ifb` for InterfaceB

Example for SIT (the same pattern repeats per environment):

| Bucket | Compartment | Purpose |
| --- | --- | --- |
| `bkt-lcn-sit-ifa` | `integrations-nonprod/sit` | InterfaceA files from SFTP |
| `bkt-lcn-sit-ifb` | `integrations-nonprod/sit` | InterfaceB files from SFTP |
| `bkt-lcn-sit-archive` | `integrations-nonprod/sit` | Shared archive for SIT |
| `bkt-lcn-sit-error` | `integrations-nonprod/sit` | Shared error bucket for SIT |

Production gets the same set in `integrations-prod` with `prd`:

| Bucket | Compartment |
| --- | --- |
| `bkt-lcn-prd-ifa` | `integrations-prod` |
| `bkt-lcn-prd-ifb` | `integrations-prod` |
| `bkt-lcn-prd-archive` | `integrations-prod` |
| `bkt-lcn-prd-error` | `integrations-prod` |

Notes:

- Please create the buckets in the same region.
- Archive and error buckets are shared across interfaces within one environment. Files are stored under `<source bucket>/<yyyy-mm-dd>/<file id>_<object name>`, so nothing collides.
- Please also create two extra test buckets in `integrations-nonprod` so we can test without touching the environment buckets. Suggested: `bkt-lcn-dev-test-a` and `bkt-lcn-dev-test-b`.
- A lifecycle rule on the archive buckets (for example delete after N days) is optional. Tell us the retention you want.

### 3.3 Dynamic groups

One per area, so a non-prod database can never reach production buckets:

```
atp-integrations-nonprod-dg
  ALL {resource.type = 'autonomousdatabase', resource.id = '<non-prod-adb-ocid>'}

atp-integrations-prod-dg
  ALL {resource.type = 'autonomousdatabase', resource.id = '<prod-adb-ocid>'}
```

If a group exists for each non-prod database, use one rule matching all of them instead. If the tenancy uses identity domains, the group names in the policies need the domain prefix.

We will send you the ADB OCIDs. Please tell us if you prefer different group names.

### 3.4 Policies

**Non-prod.** To keep maintenance simple, non-prod may be broad. One statement on the parent compartment covers every child:

```
Allow dynamic-group atp-integrations-nonprod-dg to manage objects in compartment integrations-nonprod
Allow dynamic-group atp-integrations-nonprod-dg to read buckets in compartment integrations-nonprod
```

This lets ATP list, read, create, overwrite and delete objects in every non-prod bucket. Copying between non-prod environments is acceptable for us.

**Production.** Least privilege, limited to the named buckets:

```
Source (interface) buckets: list, read, delete
Allow dynamic-group atp-integrations-prod-dg to manage objects in compartment integrations-prod
  where all {any {target.bucket.name = 'bkt-lcn-prd-ifa',
                  target.bucket.name = 'bkt-lcn-prd-ifb'},
             any {request.permission = 'OBJECT_INSPECT',
                  request.permission = 'OBJECT_READ',
                  request.permission = 'OBJECT_DELETE'}}

Archive and error buckets: list, create, overwrite
Allow dynamic-group atp-integrations-prod-dg to manage objects in compartment integrations-prod
  where all {any {target.bucket.name = 'bkt-lcn-prd-archive',
                  target.bucket.name = 'bkt-lcn-prd-error'},
             any {request.permission = 'OBJECT_INSPECT',
                  request.permission = 'OBJECT_CREATE',
                  request.permission = 'OBJECT_OVERWRITE'}}

Allow dynamic-group atp-integrations-prod-dg to read buckets in compartment integrations-prod
```

The simpler alternative is `manage objects` on the same buckets. It is broader, but acceptable if you prefer it.

**Transfer VM (rclone).** A separate dynamic group that matches the transfer VM instance, with `manage objects` and `read buckets` on the interface buckets only. The VM must not reach archive or error buckets.

**Scope option.** The statements above are scoped to a compartment. A policy can also be written at tenancy level, which covers every compartment and every bucket in the namespace. That is easier to maintain, but it gives the database access to everything, including production. Our recommendation is compartment level, as above. Please choose what fits your standards.

### 3.5 Things to check on your side

- Whether the server-side copy used for the archive move (`DBMS_CLOUD.COPY_OBJECT`) needs additional permissions on the source or target bucket. We could not confirm this without testing. If the move fails after the policies are in place, we will send you the error.
- Customer-managed encryption keys: if the buckets will use one, the dynamic groups and the Object Storage service also need permission to use the key.
- Oracle caches the resource principal token for up to two hours, so a change to a dynamic group or policy may take up to two hours to show.

## 4. What happens next

1. You create the compartments, buckets, dynamic groups and policies.
2. We confirm the OCIDs and bucket names back to you.
3. We rerun the write test from ATP (create, overwrite, copy, delete) in the test buckets and report the result.
4. We register the real buckets in the ATP configuration table and enable the scheduled jobs.
5. We repeat the setup for each environment, production last.

## 5. What we need back

- Confirmation of compartment, bucket and dynamic group names.
- Which policy scope you choose (compartment level or tenancy level, broad or least privilege in non-prod).
- The namespace and region for the bucket URIs.
- A date for the first round of changes in non-prod.

Thanks,
Tiago
