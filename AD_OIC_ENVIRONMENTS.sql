-- =============================================================================
-- 02_DDL_AD_OIC_ENVIRONMENTS.sql
-- New table: OIC environment registry
-- MAX_MSGS = NULL means no cap; default is 1000
-- =============================================================================

CREATE TABLE AD_OIC_ENVIRONMENTS
(
    ENV_ID           VARCHAR2(100)  NOT NULL,
    ENV_NAME         VARCHAR2(200)  NOT NULL,
    BASE_URL         VARCHAR2(1000) NOT NULL,    
    MAX_MSGS         NUMBER         DEFAULT 1000,   -- NULL = no cap
    STATUS           VARCHAR2(1)    DEFAULT 'A'     NOT NULL,
    CREATED_BY       VARCHAR2(500)  DEFAULT USER,
    CREATION_DATE    DATE           DEFAULT SYSDATE,
    LAST_UPDATED_BY  VARCHAR2(500)  DEFAULT USER,
    LAST_UPDATE_DATE DATE           DEFAULT SYSDATE,
    CONSTRAINT AD_OIC_ENV_PK        PRIMARY KEY (ENV_ID),
    CONSTRAINT AD_OIC_ENV_STATUS_CK CHECK (STATUS IN ('A', 'I'))
);

ALTER TABLE AD_OIC_ENVIRONMENTS  ADD LAST_RUNNING_COUNT NUMBER DEFAULT NULL;

-- OAuth2 token caching columns
-- TOKEN_URL   : IDCS token endpoint e.g. https://idcs-xxx.identity.oraclecloud.com:443/oauth2/v1/token
-- TOKEN_SCOPE : OAuth scope e.g. https://xxx.integration...ocp.oraclecloud.com:443urn:opc:resource:consumer::all
-- BEARER_TOKEN: cached access token — refreshed by DISPATCH, chunk workers read it
-- TOKEN_EXPIRY: SYSDATE + 3600 seconds at fetch time; refresh when < 1 minute remaining
ALTER TABLE AD_OIC_ENVIRONMENTS ADD TOKEN_URL    VARCHAR2(1000);
ALTER TABLE AD_OIC_ENVIRONMENTS ADD TOKEN_SCOPE  VARCHAR2(500);
ALTER TABLE AD_OIC_ENVIRONMENTS ADD BEARER_TOKEN VARCHAR2(4000);
ALTER TABLE AD_OIC_ENVIRONMENTS ADD TOKEN_EXPIRY DATE;

-- OAuth2 client credentials
-- CLIENT_ID     : plain text client ID from IDCS Confidential Application
-- CLIENT_SECRET : AES256 encrypted — use AD_DISPATCHER_PKG.SET_ENV_CREDENTIALS
ALTER TABLE AD_OIC_ENVIRONMENTS ADD CLIENT_ID     VARCHAR2(500);
ALTER TABLE AD_OIC_ENVIRONMENTS ADD CLIENT_SECRET RAW(500);

COMMENT ON TABLE  AD_OIC_ENVIRONMENTS                IS 'Registry of OIC environments eligible to receive dispatched messages.';
COMMENT ON COLUMN AD_OIC_ENVIRONMENTS.ENV_ID         IS 'Unique environment identifier. Also embedded as suffix in CHUNK_ID.';
COMMENT ON COLUMN AD_OIC_ENVIRONMENTS.BASE_URL       IS 'Root OIC instance URL, e.g. https://oic-host.integration.oraclecloud.com';
COMMENT ON COLUMN AD_OIC_ENVIRONMENTS.MAX_MSGS       IS 'Max messages this env can receive per dispatcher run. NULL = no cap (unlimited).';
COMMENT ON COLUMN AD_OIC_ENVIRONMENTS.STATUS         IS 'A = Active (eligible for dispatch). I = Inactive (excluded).';
COMMENT ON COLUMN AD_OIC_ENVIRONMENTS.LAST_RUNNING_COUNT  IS 'Number of running instances in the last execution';





/*
UPDATE AD_OIC_ENVIRONMENTS
   SET CLIENT_ID   = 'ac7cb53ec71840698754287f74a2d774',
       CLIENT_SECRET = 'https://8D0F722217794FE2BB7C0BC399A8FFD6.integration.us-ashburn-1.ocp.oraclecloud.com:443urn:opc:resource:consumer::all'
 WHERE ENV_ID = 'OICDEV';
 */
 

Insert into AD_OIC_ENVIRONMENTS (ENV_ID,ENV_NAME,BASE_URL,MAX_MSGS,STATUS,CREATION_DATE,LAST_UPDATE_DATE,LAST_RUNNING_COUNT,TOKEN_URL,TOKEN_SCOPE) 
values ('OICDEV','OIC Development',
'https://oic-loid-iad-np-dev-gen3-idoscuik6e52-ia.integration.us-ashburn-1.ocp.oraclecloud.com', -- BASE_URL
1000,'A',SYSDATE,SYSDATE,0,
'https://idcs-a40f02f5526a4866a36abdf4ffbb35be.identity.oraclecloud.com:443/oauth2/v1/token', -- TOKEN_URL
'https://8D0F722217794FE2BB7C0BC399A8FFD6.integration.us-ashburn-1.ocp.oraclecloud.com:443urn:opc:resource:consumer::all' -- TOKEN_SCOPE
);


Insert into AD_OIC_ENVIRONMENTS (ENV_ID,ENV_NAME,BASE_URL,MAX_MSGS,STATUS,CREATION_DATE,LAST_UPDATE_DATE,LAST_RUNNING_COUNT,TOKEN_URL,TOKEN_SCOPE)
 values ('OICAMODEV5','OIC AMO DEV5',
 'https://oic-loid-iad-np-amo-gen3-idoscuik6e52-ia.integration.us-ashburn-1.ocp.oraclecloud.com', -- BASE_URL
 1000,'A',SYSDATE,SYSDATE,0,
 'https://idcs-a40f02f5526a4866a36abdf4ffbb35be.identity.oraclecloud.com:443/oauth2/v1/token', -- TOKEN_URL
 'https://58FD927142DF431DA709E8C7A95A4AC0.integration.us-ashburn-1.ocp.oraclecloud.com:443urn:opc:resource:consumer::all' -- TOKEN_SCOPE

);

Insert into AD_OIC_ENVIRONMENTS (ENV_ID,ENV_NAME,BASE_URL,MAX_MSGS,STATUS,CREATION_DATE,LAST_UPDATE_DATE,LAST_RUNNING_COUNT,TOKEN_URL,TOKEN_SCOPE)
 values ('OICSIT','OIC SIT',
 'https://oic-loid-iad-np-sit-gen3-idoscuik6e52-ia.integration.us-ashburn-1.ocp.oraclecloud.com', -- BASE_URL
 1000,'A',SYSDATE,SYSDATE,0,
 'https://idcs-a40f02f5526a4866a36abdf4ffbb35be.identity.oraclecloud.com:443/oauth2/v1/token', -- TOKEN_URL
 'https://B326ABCA8483421390545FEE1E14BC44.integration.us-ashburn-1.ocp.oraclecloud.com:443urn:opc:resource:consumer::all' -- TOKEN_SCOPE
);

Insert into AD_OIC_ENVIRONMENTS (ENV_ID,ENV_NAME,BASE_URL,MAX_MSGS,STATUS,CREATION_DATE,LAST_UPDATE_DATE,LAST_RUNNING_COUNT,TOKEN_URL,TOKEN_SCOPE)
 values ('OICUAT','OIC UAT',
 'https://oic-loid-iad-np-uat-gen3-idoscuik6e52-ia.integration.us-ashburn-1.ocp.oraclecloud.com', -- BASE_URL
 1000,'A',SYSDATE,SYSDATE,0,
 'https://idcs-a40f02f5526a4866a36abdf4ffbb35be.identity.oraclecloud.com:443/oauth2/v1/token', -- TOKEN_URL
 'https://EEAC8F72C08B48B599A2A7BF37ABE9B5.integration.us-ashburn-1.ocp.oraclecloud.com:443urn:opc:resource:consumer::all' -- TOKEN_SCOPE
);

COMMIT;

/*
BEGIN
    AD_DISPATCHER_PKG.SET_ENV_CREDENTIALS
    (
        p_env_id        => 'OICDEV',
        p_client_id     => 'ac7cb53ec71840698754287f74a2d774',
        p_client_secret => '47171a3b-8f94-4509-a9c2-524358e33e59'
    );
END;
/ 

BEGIN
    AD_DISPATCHER_PKG.SET_ENV_CREDENTIALS
    (
        p_env_id        => 'OICAMODEV5',
        p_client_id     => 'c6450fb2a415495ead6426055c00db4c',
        p_client_secret => 'cb9ccf9e-b1a1-4db6-9a4b-40bf0559b582'
    );
END;
/
*/

/*

-- ── Environment 1: Development ────────────────────────────────────────────────
INSERT INTO AD_OIC_ENVIRONMENTS
(
    ENV_ID,
    ENV_NAME,
    BASE_URL,
    --CREDENTIAL_NAME,
    MAX_MSGS,
    STATUS
)
VALUES
(
    'OICDEV',
    'OIC Development',
    --'https://oic-loid-iad-np-dev-gen3-idoscuik6e52-ia.integration.us-ashburn-1.ocp.oraclecloud.com',
	'basic://oic-loid-iad-np-dev-gen3-idoscuik6e52-ia.integration.us-ashburn-1.ocp.oraclecloud.com',
    --'OIC_DEV_CREDENTIAL',
    1000,   -- dispatch up to 1000 new msgs per run
    'A'
);



-- ── Environment 2: AMO DEV 5 ────────────────────────────────────────────────
INSERT INTO AD_OIC_ENVIRONMENTS
(
    ENV_ID,
    ENV_NAME,
    BASE_URL,
    --CREDENTIAL_NAME,
    MAX_MSGS,
    STATUS
)
VALUES
(
    'OICAMODEV5',
    'OIC AMO DEV5',
    --'https://oic-loid-iad-np-amo-gen3-idoscuik6e52-ia.integration.us-ashburn-1.ocp.oraclecloud.com',
	'basic://oic-loid-iad-np-amo-gen3-idoscuik6e52-ia.integration.us-ashburn-1.ocp.oraclecloud.com',
    --'OIC_AMO_DEV5_CREDENTIAL',
    1000,   -- dispatch up to 1000 new msgs per run
    'A'
);

UPDATE AD_OIC_ENVIRONMENTS
   SET TOKEN_URL   = 'https://idcs-a40f02f5526a4866a36abdf4ffbb35be.identity.oraclecloud.com:443/oauth2/v1/token',
       TOKEN_SCOPE = 'https://8D0F722217794FE2BB7C0BC399A8FFD6.integration.us-ashburn-1.ocp.oraclecloud.com:443urn:opc:resource:consumer::all'
 WHERE ENV_ID = 'OICDEV';
 
UPDATE AD_OIC_ENVIRONMENTS
   SET TOKEN_URL   = 'https://idcs-a40f02f5526a4866a36abdf4ffbb35be.identity.oraclecloud.com:443/oauth2/v1/token',
       TOKEN_SCOPE = 'https://58FD927142DF431DA709E8C7A95A4AC0.integration.us-ashburn-1.ocp.oraclecloud.com:443urn:opc:resource:consumer::all'
 WHERE ENV_ID = 'OICAMODEV5'; 



COMMIT;
*/
