# EdunexusAI release handbook

How a change on the MacBook reaches production, every time. Checked against the repositories, GitHub and the production server on 2026-11-08.

`release/release.sh` has not been run against production yet. It does the same steps used for the releases of 3–4 Nov 2026, and its `--print` mode has been checked. The first time you use it, read the `--print` output first.

## 1. What runs where

| Application | Repository | Production branch | Hosted on | How it deploys | Running now |
|---|---|---|---|---|---|
| Frontend | `Pathackcoder/edunexusai`, `frontend/` | `main` | Vercel | **Automatic** on push to `main` | `5fba632` |
| API | `Pathackcoder/edunexusai`, `backend/` + `shared/` | `main` | Docker on EC2 | **Manual**, `release.sh` | `b025fd83ec44` |
| CampusCore SIS | `edunexusai-dev/campuscore-sis` | **`deploy/aws-release`** | Docker on EC2 | **Manual**, `release.sh` | `db30da75628f` |
| Strapi CMS | `edunexusai-dev/feddrick-cms` | **`deploy/aws-release`** | Docker on EC2 | **Manual**, `release.sh` | `e7da358e1eee` |
| Keycloak | Stock image; config in its own database | None | Docker on EC2 | Image version in `compose.yml`; realm changes in its Admin Console | `26.8.1` |
| Moodle | None | None | MoodleCloud | Not deployed by us | 5.3 |

Things that are easy to get wrong:

- **A push to GitHub deploys only the frontend.** No GitHub Actions or webhooks exist. The API, CampusCore and Strapi change only when you run `release.sh`.
- **`main` is not the production branch for CampusCore and Strapi.** Their `main` is still the first commit. Work from `deploy/aws-release`, or merge it into `main` first and change this table.
- **`deploy/docker-compose.yml` and `deploy/DEPLOYMENT.md` do not describe production.** Production uses one `compose.yml` per service in `/opt/edunexus/<service>/` and the host's nginx.
- **The old PM2 app in `/home/ubuntu/edunexusai` is not the live backend.** Never deploy to it.
- **No branch protection exists.** Nothing stops a direct push to `main`, and that push goes live on Vercel. Discipline is the only safeguard until you turn protection on.
- **Only committed code ships.** `release.sh` uses `git archive` of a commit, so uncommitted work can never reach production by accident.

### One-time setup on the Mac

- AWS CLI and `session-manager-plugin` installed, with the profile `edunexus-deploy`.
- Git and `gh` signed in.
- `cd ~/Desktop/parent-folder/deploy/release`, which is where every `./release.sh` command below runs.

## 2. Which change needs what

| What changed | Code deploy | Production `.env` | Prisma migration | Data migration | Frontend deploy |
|---|---|---|---|---|---|
| `edunexus/frontend/` | | | | | **Yes** (merge to `main`) |
| `VITE_*` value | | Vercel project settings | | | **Yes** (rebuild) |
| `edunexus/backend/` or `shared/` | **API** | | | | |
| `shared/` used by the frontend too | **API** | | | | **Yes** |
| `backend/prisma/migrations/` | **API** | | **Yes** | | |
| `campuscoresis/` server or client | **CampusCore** | | | | |
| `campuscoresis/server/prisma/migrations/` | **CampusCore** | | **Yes** | | |
| `identity-sync/` | **CampusCore** (the server runs this code) | | | | |
| `feddrick-cms/` content types, plugins | **Strapi** (tables update when it starts) | | | | |
| New setting read from the environment | Usually | **Yes** | | | |
| Existing rows must change shape or value | Usually | | Maybe | **Yes**, a reviewed script in Git | |
| CMS content, Keycloak users, policies | None: use the admin screens | | | | |

### Types of configuration

| Thing | Where it lives | In Git? |
|---|---|---|
| Local `.env` | Your Mac | No, never |
| Production settings | `/opt/edunexus/secrets/*.env` on EC2, root only | No, never |
| Image tag | `/opt/edunexus/<service>/.env` on EC2 | No |
| `.env.example` | Each repo: the names of the settings, no real values | Yes. Update it whenever you add a setting |
| Frontend settings | Vercel project settings | No |
| Database schema | Prisma migration files | Yes |
| Runtime data (users, grades, content) | Each database | No, and it is never overwritten by a deploy |

**Never copy a local `.env` value to production, and never commit a secret.** All four repositories are public today.

## 3. The workflow, every time

The order differs from a simple "merge, then deploy": **for the API, deploy before merging to `main`**, because merging to `main` puts the frontend live at once. If the new frontend needs the new API, the API must already be there.

```text
Decide what is affected (section 2)
   ↓
Local tests and build (section 4)
   ↓
Review changed files; commit to a feature branch; push
   ↓
Open a pull request to the production branch and review it
   ↓
Backup, if there is a migration or data change
   ↓
Build the image from the pushed commit (nothing live changes)
   ↓
Migration (must be safe for the code that is still running)
   ↓
Production settings, if any
   ↓
Switch the service
   ↓
Merge the pull request (for edunexus this deploys the frontend)
   ↓
Health checks, then confirm the feature in the real app
```

### Order for changes that touch several services

Deploy what is depended on first: **database → CampusCore → API → Strapi → frontend**. A pull request can wait unmerged until its service is live.

## 4. Before every release

```bash
# edunexus
cd ~/Desktop/parent-folder/edunexus/backend && npm test
cd ../frontend && npm run build

# CampusCore
cd ~/Desktop/parent-folder/campuscoresis && npm test --workspace server
cd identity-sync && npm test
```

Known failure: `identity-provisioning.test.js`, "only the merged person had an account", also fails on commit `2b4f266`. Any other failure stops the release.

Review what will ship:

```bash
git status
git diff --stat <production commit> HEAD
```

Then commit and push:

```bash
git switch -c feature/short-name      # from main (edunexus) or deploy/aws-release (the others)
git add <the files you reviewed>      # not "git add .", which can sweep in unrelated work
git commit -m "What changed and why"
git push -u origin feature/short-name
gh pr create --base main              # --base deploy/aws-release for CampusCore and Strapi
```

## 5. Frontend (Vercel)

1. **What triggers it:** any push to `main` of `Pathackcoder/edunexusai` makes a Production deployment. Other branches make Preview deployments. GitHub's deployment history confirms this. The Vercel project's settings themselves were not visible to me: check them once under Settings → Git.
2. **Pull request:** not technically required, but use one. Its Preview link lets you check the change first.
3. **After merging:** Vercel builds automatically, in about a minute or two.
4. **Verify:**
   ```bash
   gh api "repos/Pathackcoder/edunexusai/deployments?per_page=1&environment=Production" --jq '.[0]|"\(.sha[0:7]) \(.created_at)"'
   curl -s -o /dev/null -w '%{http_code}\n' https://portal.edunexusai.online/
   ```
   The commit shown should be your merge commit. Then open the portal and try the change.
5. **Roll back:** Vercel dashboard → Deployments → the previous good deployment → **Instant Rollback** (or Promote to Production). `main` still holds the bad commit, so the next push would deploy it again. Follow up with a pull request that fixes it or that contains `git revert -m 1 <merge commit>`.

API calls reach the backend through `frontend/vercel.json`, which forwards `/api/*` to `https://api.edunexusai.online`.

## 6. API, CampusCore or Strapi

The commands are the same; only the service name changes.

```bash
cd ~/Desktop/parent-folder/deploy/release

./release.sh status                     # what is running, and which older images exist
./release.sh build api <commit>         # or: campuscore, strapi. The live service is not touched
./release.sh backup api                 # when there is a migration or a data change
./release.sh migrate api <tag>          # only when the commit adds migrations
./release.sh switch api <tag>           # the moment production changes
```

`<tag>` is the first 12 characters of the commit; `build` prints it. Add `--print` to any command to see what it would run. Every command that changes production asks you to type `production`.

| Deploying | Commit comes from | Notes |
|---|---|---|
| **API only** | feature branch or `main` of `edunexus` | Uses `backend/` and `shared/` from the repo root |
| **CampusCore only** | feature branch or `deploy/aws-release` of `campuscoresis` | The worker restarts with it; queued work resumes. **`CLIENT_SECRET_PEPPER` must never change** |
| **Strapi only** | feature branch or `deploy/aws-release` of `feddrick-cms` | Takes up to about a minute to become healthy. No `migrate` step |
| **Several** | Each from its own repo | Follow the order in section 3 |

## 7. Database migrations

Prisma migrations live in `backend/prisma/migrations/` and `server/prisma/migrations/`. Containers do **not** run them when they start: `release.sh migrate` does.

Current state: the onboarding-email migration `20261106100000_onboarding_email` exists only on the Mac.

1. **Prefer additive migrations:** new tables, new optional columns. The old code keeps working, so rollback stays possible.
2. **Removing or renaming takes two releases:** first release stops using it, a later release drops it.
3. Run `backup`, then `migrate`, then `switch`, in that order.
4. **A failed migration:** read the output before retrying. Do not edit tables by hand. Restore only as a last resort (section 10).
5. **Changing existing rows:** write a script in the repo with a dry run and an explicit apply flag, like `server/scripts/cleanup-to-pilots.js`. Review it, back up, then run it.

Never run `prisma db push` or `prisma migrate dev` against production.

## 8. Production settings

Sign in, edit one value, recreate only that service:

```bash
AWS_PROFILE=edunexus-deploy AWS_REGION=us-east-1 aws ssm start-session --target i-036deb764f61a10ef
sudo -i
cp -p /opt/edunexus/secrets/edunexusai.env /opt/edunexus/backups/edunexusai.env.pre-change-$(date -u +%Y%m%dT%H%M%SZ)
nano /opt/edunexus/secrets/edunexusai.env
cd /opt/edunexus/edunexusai && docker compose up -d --no-build --force-recreate api
```

For the others, use `campuscore.env` with `/opt/edunexus/campuscore` and service `campuscore`, or `strapi.env` with `/opt/edunexus/strapi` and service `strapi`.

Settings are read when a container starts. A brand-new setting must also go into `.env.example` in the same pull request as the code.

## 9. Health checks

From the Mac:

```bash
curl -s https://api.edunexusai.online/api/v1/health | jq -c '{status,database,environment}'
curl -s -o /dev/null -w 'sis %{http_code}\n' https://sis.edunexusai.online/
curl -s -o /dev/null -w 'cms %{http_code}\n' https://cms.edunexusai.online/_health
curl -s -o /dev/null -w 'auth %{http_code}\n' https://auth.edunexusai.online/realms/edunexusai-feddrick
curl -s -o /dev/null -w 'portal %{http_code}\n' https://portal.edunexusai.online/
./release.sh status
```

Expected: `ok` with database connected; 200, 204 (cms), 200, 200.

Logs, from a session as in section 8:

```bash
docker logs --since 15m edunexusai-api      # or: campuscore, strapi, keycloak
```

The API's request log is nearly empty today, because production sets `LOG_LEVEL=info`, which the request logger does not recognise as a format.

## 10. Rollback

```bash
./release.sh status                   # older images are listed
./release.sh switch api <previous tag>
```

The switch prints the previous tag, and it is quick because the older image is still on the server. Your data is not touched.

| Situation | What to do |
|---|---|
| New code is bad, no migration | Switch back |
| New code is bad, additive migration | Switch back. Old code ignores the new table or column |
| Migration removed or changed data | Stop and plan it. Restoring loses everything written since the backup |

Restore only as a last resort, and only for that service's database, with the service stopped. The dump is in `/opt/edunexus/backups/`:

```bash
pg_restore --clean --if-exists --no-owner -d "<connection string from the secrets file>" /opt/edunexus/backups/<file>.dump
```

Keep at least the two previous images of each service, and remove older ones only with `docker image rm <exact tag>`. Don't use `docker system prune -a`, which would delete your rollback images. Backups live on the same server, so copy important ones elsewhere.

## 11. Rules

- Never edit source files on production.
- Never change a production database by hand as a substitute for a deployment.
- Every image comes from a commit that is on GitHub.
- Back up before any migration or data change.
- Deploy only the services that changed.
- Keep production settings separate from local settings.
- Keep previous images until the new one has proved itself.

## 12. Release checklist

```text
[ ] Which services? Migration? New settings? (section 2)
[ ] Tests and build pass (section 4)
[ ] Changed files reviewed; no secrets, no unrelated work
[ ] Committed and pushed on a feature branch
[ ] Pull request opened to the correct branch
[ ] ./release.sh status: note the current tags, for rollback
[ ] ./release.sh build <service> <commit>
[ ] ./release.sh backup <service>            if migration or data change
[ ] ./release.sh migrate <service> <tag>     if migration
[ ] Production settings updated              if new settings
[ ] ./release.sh switch <service> <tag>
[ ] Health checks pass (section 9)
[ ] Pull request merged; Vercel succeeded    if edunexus
[ ] The feature works in the real app, signed in as a real role
[ ] Logs look clean for 15 minutes
```

## 13. Before the onboarding-email work goes live

- SES production access was **denied** when last checked (2026-11-06): recheck before planning sends.
- It needs a commit, the CampusCore migration, `SMTP_*` and `ONBOARDING_*` settings on the server, and SMTP on the production Keycloak realm.
- `ONBOARDING_EMAIL_ENABLED=true` and `IDENTITY_SYNC_SEND_SETUP_EMAIL=true` must not be set together.
