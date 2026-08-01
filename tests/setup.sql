-- Test setup: create multiple databases and users for integration testing.
-- This runs on first PostgreSQL startup via docker-entrypoint-initdb.d.

-- Create pgdog user (used by the sidecar config)
CREATE USER pgdog WITH PASSWORD 'test-pgdog-pass-123';

-- Create app user (additional user for multi-user testing)
CREATE USER appuser WITH PASSWORD 'test-app-pass-123';

-- Create databases
CREATE DATABASE pgdog OWNER pgdog;
CREATE DATABASE appdb OWNER appuser;

-- Grant access
GRANT ALL ON DATABASE pgdog TO pgdog;
GRANT ALL ON DATABASE appdb TO appuser;
