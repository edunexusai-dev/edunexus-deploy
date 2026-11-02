-- ---------------------------------------------------------------------------
-- RDS Database & User Setup
-- Run once against the edunexus-postgres RDS instance as the master user.
--   psql "host=edunexus-postgres.cc7y0cms2un6.us-east-1.rds.amazonaws.com port=5432 user=<master> sslmode=require" -f rds-setup.sql
--
-- Replace <PASSWORD_*> tokens with strong generated passwords before running.
-- NEVER commit this file with real passwords.
-- ---------------------------------------------------------------------------

-- 1. Databases
CREATE DATABASE edunexusai;
CREATE DATABASE campuscore;
CREATE DATABASE feddrick_cms;
CREATE DATABASE keycloak;

-- 2. Application users (least privilege: own their database, nothing else)
CREATE USER edunexusai_user WITH PASSWORD '<PASSWORD_EDUNEXUSAI>';
CREATE USER campuscore_user WITH PASSWORD '<PASSWORD_CAMPUSCORE>';
CREATE USER strapi_user     WITH PASSWORD '<PASSWORD_STRAPI>';
CREATE USER keycloak_user   WITH PASSWORD '<PASSWORD_KEYCLOAK>';

-- 3. Grant ownership
GRANT ALL PRIVILEGES ON DATABASE edunexusai  TO edunexusai_user;
GRANT ALL PRIVILEGES ON DATABASE campuscore  TO campuscore_user;
GRANT ALL PRIVILEGES ON DATABASE feddrick_cms TO strapi_user;
GRANT ALL PRIVILEGES ON DATABASE keycloak    TO keycloak_user;

-- 4. Default schema privileges (needed for Prisma migrations and Strapi auto-sync)
\c edunexusai
GRANT ALL ON SCHEMA public TO edunexusai_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO edunexusai_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO edunexusai_user;

\c campuscore
GRANT ALL ON SCHEMA public TO campuscore_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO campuscore_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO campuscore_user;

\c feddrick_cms
GRANT ALL ON SCHEMA public TO strapi_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO strapi_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO strapi_user;

\c keycloak
GRANT ALL ON SCHEMA public TO keycloak_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO keycloak_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO keycloak_user;
