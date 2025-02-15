#!/bin/bash
set -e

case "${USER_ID_TYPE^^}" in
  'UUID')
    USER_ID_GENERATOR=' DEFAULT GEN_RANDOM_UUID()'
    ;;
  'INTEGER')
    USER_ID_GENERATOR=' GENERATED BY DEFAULT AS IDENTITY'
    ;;
  'BIGINT')
    USER_ID_GENERATOR='GENERATED BY DEFAULT AS IDENTITY'
    ;;
  *)
    echo "Invalid USER_ID_TYPE: ${USER_ID_TYPE}"
    exit 1
    ;;
esac

# Use the environment variable EXTRA_USER_PASSWORD to create a new user
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" "${POSTGRES_DB}" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS "pgcrypto";

    -- Create PostGraphile user
    CREATE ROLE ${POSTGRAPHILE_USER} WITH LOGIN PASSWORD '${POSTGRAPHILE_PASSWORD}';
    -- Grant all privileges on the database to the PostGraphile user
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRAPHILE_USER};

    CREATE ROLE superadmin WITH SUPERUSER;
    GRANT superadmin TO ${POSTGRAPHILE_USER};

    -- Create the exposed schema if necessary
    CREATE SCHEMA IF NOT EXISTS ${EXPOSED_SCHEMA};
    -- Grant all privileges on the exposed schema to the PostGraphile user
    ALTER SCHEMA ${EXPOSED_SCHEMA} OWNER TO ${POSTGRAPHILE_USER};

    \\c ${POSTGRES_DB} ${POSTGRAPHILE_USER}

    -- Create the auth schema that will manage user authentication
    CREATE SCHEMA IF NOT EXISTS ${AUTH_SCHEMA};

    -- Create the ${AUTH_SCHEMA}.jwt_token type that is used by PostGraphile
    CREATE TYPE ${AUTH_SCHEMA}.jwt_token AS (uid ${USER_ID_TYPE}, role TEXT, exp INTEGER);
    COMMENT ON TYPE ${AUTH_SCHEMA}.jwt_token IS 'JWT token injected by PostGraphile.';

    CREATE OR REPLACE FUNCTION ${AUTH_SCHEMA}.uid() RETURNS ${USER_ID_TYPE} AS \$\$
      SELECT NULLIF(CURRENT_SETTING('jwt.claims.uid', TRUE), '')::${USER_ID_TYPE};
    \$\$ LANGUAGE SQL;
    GRANT EXECUTE ON FUNCTION ${AUTH_SCHEMA}.uid() TO PUBLIC;

    -- Create basic user table
    CREATE TABLE IF NOT EXISTS ${EXPOSED_SCHEMA}.users (
      id ${USER_ID_TYPE} PRIMARY KEY ${USER_ID_GENERATOR},
      first_name TEXT,
      last_name TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      deleted_at TIMESTAMPTZ
    );

    -- Create the local login table
    CREATE TABLE IF NOT EXISTS ${AUTH_SCHEMA}.local_logins (
      user_id ${USER_ID_TYPE} PRIMARY KEY REFERENCES ${EXPOSED_SCHEMA}.users(id),
      username TEXT UNIQUE,
      email TEXT UNIQUE,
      hashed_password TEXT NOT NULL DEFAULT 'EMPTY',
      role TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      deleted_at TIMESTAMPTZ
    );
    COMMENT ON TABLE ${AUTH_SCHEMA}.local_logins IS
      'Local (non-federated) login using email and password.';
    ALTER TABLE ${AUTH_SCHEMA}.local_logins ENABLE ROW LEVEL SECURITY;

    CREATE FUNCTION ${AUTH_SCHEMA}.hash_password(password TEXT) RETURNS TEXT AS \$\$
      SELECT crypt(password, gen_salt('bf'));
    \$\$ LANGUAGE SQL;
    GRANT EXECUTE ON FUNCTION ${AUTH_SCHEMA}.hash_password(TEXT) TO PUBLIC;

    -- Create the super admin user
    WITH new_user AS (
      INSERT INTO users (first_name, last_name)
      VALUES ('Super', 'Admin')
      RETURNING id
    )
    INSERT INTO ${AUTH_SCHEMA}.local_logins (user_id, username, role, hashed_password)
    SELECT id, '${ADMIN_USER}', 'superadmin', ${AUTH_SCHEMA}.hash_password('${ADMIN_PASSWORD}')
    FROM new_user;

    -- Create login function
    CREATE OR REPLACE FUNCTION ${EXPOSED_SCHEMA}.login(
      username TEXT,
      password TEXT
    ) RETURNS ${AUTH_SCHEMA}.jwt_token as \$\$
    DECLARE
      local_login ${AUTH_SCHEMA}.local_logins;
      user_id ${USER_ID_TYPE};
    BEGIN
      IF \$1 LIKE '%@%' THEN
        SELECT
         * INTO local_login
        FROM ${AUTH_SCHEMA}.local_logins
        WHERE
         email = \$1
         AND deleted_at IS NULL
         AND CRYPT(\$2, hashed_password) = hashed_password;
      END IF;

      IF local_login IS NULL THEN
        SELECT
         * INTO local_login
        FROM ${AUTH_SCHEMA}.local_logins l
        WHERE
         l.username = \$1
         AND deleted_at IS NULL
         AND CRYPT(\$2, hashed_password) = hashed_password;
      END IF;

      IF local_login IS NULL THEN
        RETURN NULL;
      END IF;

      SELECT
       id INTO user_id
      FROM ${EXPOSED_SCHEMA}.users
      WHERE
       id = local_login.user_id
       AND deleted_at IS NULL;

      IF user_id IS NULL THEN
        RETURN NULL;
      END IF;

      RETURN (user_id, local_login.role, EXTRACT(EPOCH FROM NOW()) + (${JWT_TTL}))::${AUTH_SCHEMA}.jwt_token;
    END;
    \$\$ LANGUAGE PLPGSQL STRICT SECURITY DEFINER;
    GRANT EXECUTE ON FUNCTION ${EXPOSED_SCHEMA}.login(TEXT, TEXT) TO PUBLIC;
EOSQL
