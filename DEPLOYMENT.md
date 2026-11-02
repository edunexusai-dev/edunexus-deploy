# Edunexus Platform — Deployment Guide

All four services (Keycloak, CampusCore SIS, Feddrick CMS, EdunexusAI) run as Docker containers on a single EC2 instance (`i-036deb764f61a10ef`, m7i-flex.large, 8 GB RAM), with PostgreSQL on RDS (`edunexus-postgres`).

## Architecture

```
Internet → Nginx (80/443) → Keycloak   (:8080)
                           → CampusCore (:4000)
                           → Strapi     (:1337)
                           → EdunexusAI (:5001, +Socket.IO)

EdunexusAI (Vercel frontend) → Nginx → EdunexusAI backend
```

## Prerequisites

- [ ] **Elastic IP** allocated and associated with the EC2 instance
- [ ] **DNS records** created for chosen domains (A records → Elastic IP)
- [ ] **RDS master credentials** available (for database/user creation)
- [ ] **Security group** `sg-0bc9f82dda0cdeed6` allows inbound 80, 443 from 0.0.0.0/0
- [ ] **Docker & Docker Compose** installed on EC2 (confirmed installed)
- [ ] **Git** installed on EC2 for cloning repositories

## Domain Decisions Required

| Service | Suggested Pattern | Example |
|---------|------------------|---------|
| Keycloak (OIDC issuer) | `auth.<domain>` | `auth.edunexus.ai` |
| EdunexusAI API | `api.<domain>` | `api.edunexus.ai` |
| CampusCore SIS | `sis.<domain>` | `sis.edunexus.ai` |
| Strapi CMS (admin) | `cms.<domain>` | `cms.edunexus.ai` |
| EdunexusAI Frontend | `app.<domain>` or Vercel | `app.edunexus.ai` |

**Critical**: The Keycloak hostname becomes the OIDC issuer URL baked into every token. Changing it later invalidates all sessions and requires reconfiguring every client.

## Deployment Order

```
Phase 0: Infrastructure (Elastic IP, DNS, RDS setup, TLS certs)
Phase 1: Keycloak (no dependencies)
Phase 2: CampusCore (needs DB, optionally Keycloak for SSO)
Phase 3: Strapi (needs DB only)
Phase 4: EdunexusAI (needs all three + Keycloak)
Phase 5: Nginx + TLS
Phase 6: Vercel frontend update
```

## Phase 0 — Infrastructure Setup

### 0.1 Elastic IP
```bash
# AWS Console or CLI — allocate and associate
aws ec2 allocate-address --domain vpc
aws ec2 associate-address --instance-id i-036deb764f61a10ef --allocation-id eipalloc-XXXXX
```

### 0.2 DNS Records
Create A records for all four subdomains pointing to the Elastic IP.

### 0.3 Security Group
Ensure `sg-0bc9f82dda0cdeed6` allows:
- Inbound TCP 80 from 0.0.0.0/0 (HTTP → HTTPS redirect)
- Inbound TCP 443 from 0.0.0.0/0 (HTTPS)
- Inbound TCP 5432 from the EC2 security group (RDS, likely already configured)

### 0.4 RDS Database Setup
```bash
# From a machine that can reach RDS (EC2 via SSM, or enable remote access temporarily)
psql "host=edunexus-postgres.cc7y0cms2un6.us-east-1.rds.amazonaws.com port=5432 \
  user=<MASTER_USER> sslmode=require" -f scripts/rds-setup.sql
```
Review and edit `scripts/rds-setup.sql` first — replace `<PASSWORD_*>` tokens with generated passwords.

### 0.5 TLS Certificates
**Option A — Let's Encrypt (recommended for single EC2)**:
```bash
# On EC2, after DNS propagation
sudo certbot certonly --standalone -d auth.DOMAIN -d api.DOMAIN -d sis.DOMAIN -d cms.DOMAIN
# Copy certs to deploy/nginx/certs/<domain>/
```

**Option B — ACM + ALB**: Requires adding an Application Load Balancer (~$18/mo).

## Phase 1 — Keycloak

### 1.1 Export Local Realm (on your Mac)
```bash
cd deploy
bash scripts/keycloak-export.sh
```
This creates `keycloak-import/edunexusai-feddrick-realm.json` and `edunexusai-feddrick-users-0.json`.

### 1.2 Deploy
```bash
# On EC2
docker compose up -d keycloak
docker compose logs -f keycloak  # wait for "Running the server" message
```

### 1.3 Post-Import Tasks
1. Log in to `https://auth.<DOMAIN>/admin` with the bootstrap admin credentials
2. Navigate to the `edunexusai-feddrick` realm
3. **Regenerate client secrets** for all four clients:
   - `edunexusai` → Credentials tab → Regenerate Secret
   - `campuscore` → Credentials tab → Regenerate Secret
   - `edunexusai-directory` → Credentials tab → Regenerate Secret
   - `campuscore-identity-sync` → Credentials tab → Regenerate Secret
4. **Update redirect URIs** on each client to use production domains:
   - `edunexusai`: `https://<FRONTEND_DOMAIN>/api/v1/auth/oidc/callback`
   - `campuscore`: `https://<CAMPUSCORE_DOMAIN>/api/app/auth/oidc/callback`
5. Update the realm display name from "Feddrick University (EdunexusAI local development)" to "Feddrick University"

## Phase 2 — CampusCore

### 2.1 Fill Environment
```bash
cp env/campuscore.env.example env/campuscore.env
# Edit env/campuscore.env with production values
```

### 2.2 Deploy
```bash
docker compose up -d --build campuscore
```

### 2.3 Run Migrations & Seed
```bash
docker compose exec campuscore npx prisma migrate deploy --schema server/prisma/schema.prisma
docker compose exec campuscore node server/prisma/seed.js
# The seed prints OAuth client credentials — save them for EdunexusAI's .env
```

## Phase 3 — Strapi

### 3.1 Fill Environment
```bash
cp env/strapi.env.example env/strapi.env
# Edit env/strapi.env with production values
```

### 3.2 Deploy
```bash
docker compose up -d --build strapi
# Strapi auto-creates its schema on first boot (no manual migration)
```

### 3.3 Create API Token
1. Log in to `https://cms.<DOMAIN>/admin` (first boot creates the admin user)
2. Settings → API Tokens → Create new token
3. Name: `edunexusai-backend`, Type: Custom
4. Grant `api::edunexus.edunexus` → find, findOne
5. Copy the token for EdunexusAI's `CMS_API_TOKEN`

## Phase 4 — EdunexusAI

### 4.1 Fill Environment
```bash
cp env/edunexusai.env.example env/edunexusai.env
# Fill in: JWT secrets, DB credentials, CampusCore client creds (from Phase 2 seed),
# Strapi API token (from Phase 3), Keycloak client secrets (from Phase 1)
```

### 4.2 Deploy
```bash
docker compose up -d --build edunexusai
```

### 4.3 Run Migrations & Seed
```bash
docker compose exec edunexusai npx prisma migrate deploy
docker compose exec edunexusai node prisma/seed.js
```

## Phase 5 — Nginx

### 5.1 Configure
```bash
# Copy and fill in the template
cp nginx/conf.d/services.conf.template nginx/conf.d/services.conf
# Replace ${DOMAIN_*} and ${KEYCLOAK_HOSTNAME} with actual values
# Place TLS certs in nginx/certs/<domain>/
```

### 5.2 Deploy
```bash
docker compose up -d nginx
```

## Phase 6 — Vercel Frontend

Update `edunexus/frontend/vercel.json`:
```json
{
  "rewrites": [
    { "source": "/api/:path*", "destination": "https://<EDUNEXUSAI_API_DOMAIN>/api/:path*" },
    { "source": "/(.*)", "destination": "/index.html" }
  ]
}
```
Set Vercel environment variable `VITE_API_BASE_URL=/api/v1` (or leave default).

Deploy: `vercel --prod` from the `edunexus/frontend` directory.

## Rollback Procedures

### Per-Service Rollback
```bash
# Stop a service (others continue running)
docker compose stop edunexusai

# Rollback to previous image (if you tagged it)
docker tag edunexusai:latest edunexusai:rollback
docker compose up -d --build edunexusai

# View logs for diagnosis
docker compose logs --tail 100 edunexusai
```

### Database Rollback
**Before** running migrations, always snapshot:
```bash
# RDS manual snapshot (AWS Console or CLI)
aws rds create-db-snapshot \
  --db-instance-identifier edunexus-postgres \
  --db-snapshot-identifier pre-deploy-$(date +%Y%m%d-%H%M%S)
```

Prisma migration rollback (if a migration fails partway):
```bash
# Check current state
docker compose exec edunexusai npx prisma migrate status
docker compose exec campuscore npx prisma migrate status --schema server/prisma/schema.prisma

# Prisma does not auto-rollback. Restore from the RDS snapshot if needed.
```

### Full Rollback
```bash
docker compose down
# Restore RDS from pre-deploy snapshot
# Re-deploy previous container images
```

### Keycloak Rollback
Keycloak stores all state in the `keycloak` database. To rollback:
1. Stop Keycloak: `docker compose stop keycloak`
2. Restore the `keycloak` database from the RDS snapshot
3. Restart: `docker compose up -d keycloak`

## Health Check Endpoints

| Service | Endpoint | Expected |
|---------|----------|----------|
| Keycloak | `GET /health/ready` | `200 {"status":"UP"}` |
| CampusCore | `GET /healthz` | `200 {"status":"ok"}` |
| Strapi | `GET /_health` | `204` |
| EdunexusAI | `GET /api/v1/health` | `200 {"success":true}` |

## Monitoring

```bash
# All service status
docker compose ps

# Follow all logs
docker compose logs -f

# Individual service
docker compose logs -f edunexusai

# Resource usage
docker stats
```
