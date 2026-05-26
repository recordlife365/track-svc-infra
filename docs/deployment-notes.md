# Deployment Notes

Production deployment history and issues encountered.

---

## 2026-05-17 — Initial Production Deployment (DigitalOcean / k3s)

### 1. Image pull failed — GHCR package is private
**Error:** `trying and failing to pull image`  
**Cause:** DigitalOcean k8s cluster had no credentials to pull from GHCR (private by default in org).  
**Fix:** Added a workflow step that auto-creates `ghcr-pull-secret` before every Helm deploy using the built-in `GITHUB_TOKEN`. No manual PAT needed.

---

### 2. ConfigMap not found when migrate job ran
**Error:** `configmap "auth-service-auth-service-config" not found`  
**Cause:** The `db-migrate` job is a `pre-install` hook — it runs before Helm creates regular chart resources (ConfigMap, Secret).  
**Fix:** Annotated ConfigMap and Secret as `pre-install` hooks with weight `-5` so they are created before the migrate job (weight `-1`).

---

### 3. Database connection timed out
**Error:** `Operation timed out` connecting to PostgreSQL  
**Cause:** DigitalOcean managed PostgreSQL uses port **25060**, not 5432.  
**Fix:** Updated `production.yaml` port to `25060`.

---

### 4. DB migration failed — permission denied for schema public
**Error:** `ERROR: permission denied for schema public`  
**Cause:** PostgreSQL 15+ no longer grants `CREATE` on the `public` schema to non-superusers by default. `auth_user` was missing schema privileges.  
**Fix:** Connected as `doadmin` to `auth_db` and ran:
```sql
GRANT ALL ON SCHEMA public TO auth_user;
```

---

### 5. Helm upgrade conflict on replicas field
**Error:** `conflict with "kube-controller-manager" with subresource "scale": .spec.replicas`  
**Cause:** HPA previously owned the `.spec.replicas` field. Even after disabling the HPA, the field manager ownership remained in the Deployment metadata.  
**Fix:** Deleted the Deployment (`kubectl delete deployment auth-service-auth-service -n auth`) and let Helm recreate it cleanly.

---

### 6. Spring Boot failed to start — scientific notation conversion error
**Error:** `Failed to convert value of type 'String' to required type 'long'; For input string: "2.592e+06"`  
**Cause:** YAML parsed `2592000` (30 days in seconds) as a float and rendered it as `2.592e+06`. Spring Boot could not convert this to `long`.  
**Fix:** Quoted the values in `values.yaml`:
```yaml
refreshTokenExpirySeconds: "2592000"
accessTokenExpirySeconds: "900"
```

---

### 7. Pod kept restarting — liveness probe firing before startup completed
**Error:** `Container auth-service failed liveness probe, will be restarted`  
**Cause:** Spring Boot takes ~66 seconds to start on the constrained DigitalOcean node. The liveness probe was configured with `initialDelaySeconds: 30`, killing the pod before it finished starting.  
**Fix:** Made probe delays configurable and increased in `production.yaml`:
```yaml
probes:
  livenessInitialDelaySeconds: 90
  readinessInitialDelaySeconds: 85
```

---

### 8. Rolling update exhausting node CPU
**Cause:** With `RollingUpdate` strategy, Kubernetes creates the new pod before terminating the old one. With `500m` CPU requests, two pods exceeded the node's available CPU.  
**Fix:** Reduced production resource requests to `100m` CPU / `128Mi` memory so two pods can coexist during a rolling update on a single small node.

---

## Node / Cluster Info

| Item | Value |
|------|-------|
| Cloud | DigitalOcean |
| Node pool | `pool-a10621vct` |
| Node size | 1 node (single small droplet) |
| Kubernetes namespace | `auth` |
| DB port | 25060 |
| DB name | `auth_db` |
| DB user | `auth_user` |
| Image registry | `ghcr.io/recordlife365/auth-service` |



### 8. Domain Name Related information

- Purchased domain name: lifememo.org from Cloudflare.
- DNS managed in Cloudflare (nameservers locked to Cloudflare — cannot use DigitalOcean DNS).
- A records in Cloudflare: `api.lifememo.org` and `staging.api.lifememo.org` → `165.227.242.138` (ingress IP), both Proxied.
- `@` (lifememo.org) A record → `192.0.2.1` (placeholder), Proxied — traffic intercepted by Cloudflare Worker before reaching origin.

---

## 2026-05-25 — UI Deployment (DigitalOcean Spaces + Cloudflare Worker)

### 1. UI hosted on DigitalOcean Spaces CDN

- React app (Vite) built in GitHub Actions and synced to `s3://lifememo/ui/` via `aws s3 sync` with `--acl public-read`.
- CDN enabled on the bucket: `https://lifememo.sfo3.cdn.digitaloceanspaces.com`
- `VITE_API_URL` set as a GitHub Actions environment variable (production environment) — baked into the bundle at build time.
- Bucket layout keeps concerns separated:
  - `lifememo/ui/` — React static files
  - `lifememo/track-svc-infra/` — Terraform remote state

### 2. Custom domain via Cloudflare Worker

**Problem:** DO Spaces CDN custom domains require DigitalOcean nameservers. Since the domain is registered through Cloudflare Registrar, nameservers cannot be changed. Cloudflare CNAME proxying to DO CDN causes Error 1014 (cross-account ban).

**Solution:** A Cloudflare Worker acts as a transparent proxy from `lifememo.org` to the DO Spaces CDN — the browser URL stays `lifememo.org` with no redirect.

Worker code:
```javascript
export default {
  async fetch(request) {
    const url = new URL(request.url);
    let pathname = url.pathname;
    if (pathname === '/' || !pathname.includes('.')) {
      pathname = '/index.html';
    }
    const cdnUrl = `https://lifememo.sfo3.cdn.digitaloceanspaces.com/ui${pathname}`;
    return fetch(cdnUrl);
  }
}
```

Worker route: `lifememo.org/*` → worker.

### 3. CORS configuration

Auth service (`track-svc-auth`) required CORS headers since the UI (`lifememo.sfo3.cdn.digitaloceanspaces.com`) and API (`api.lifememo.org`) are on different origins. Added `CorsConfigurationSource` bean in `SecurityConfig.java` using `allowedOriginPatterns("*")` with `allowCredentials(true)`.

### 4. Terraform remote state

- DO Spaces bucket `lifememo` (sfo3) used as Terraform S3-compatible backend.
- Credentials passed via `-backend-config` flags (not `AWS_*` env vars):
  ```bash
  terraform init \
    -backend-config="access_key=$SPACES_ACCESS_KEY_ID" \
    -backend-config="secret_key=$SPACES_SECRET_ACCESS_KEY"
  ```