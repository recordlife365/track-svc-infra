# track-svc-infra

Terraform configuration for the LifeMemo DigitalOcean Kubernetes cluster and cluster-level infrastructure.

## What this manages

- DigitalOcean Kubernetes (DOKS) cluster
- Nginx Ingress Controller (single public IP for all microservices)

## Architecture

```
Client
  │
  ▼
DigitalOcean LoadBalancer  (1 public IP)
  │
  ▼
Nginx Ingress Controller   (routes by path)
  │
  ├─ /auth/**  ──▶  track-svc-auth   (ClusterIP)
  ├─ /memo/**  ──▶  track-svc-memo   (ClusterIP) [future]
  └─ /query/** ──▶  track-svc-query  (ClusterIP) [future]
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [doctl](https://docs.digitalocean.com/reference/doctl/how-to/install/) (DigitalOcean CLI)
- A DigitalOcean API token
- A DigitalOcean Spaces bucket (`lifememo-tfstate` in `nyc3`) for remote state
- A Spaces Access Key — DO Control Panel → API → Spaces Keys

## Remote State

Terraform state is stored in DigitalOcean Spaces (`lifememo-tfstate` bucket), not locally. Any machine with the correct credentials and `terraform init` will share the same state.

## First-time setup

### 1. Set environment variables

```bash
export DIGITALOCEAN_TOKEN=<your-do-api-token>
export AWS_ACCESS_KEY_ID=<your-spaces-access-key>
export AWS_SECRET_ACCESS_KEY=<your-spaces-secret-key>
```

### 2. Copy and fill in tfvars

```bash
cp terraform/.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your cluster name, region, k8s version, etc.
```

To find available Kubernetes version slugs:
```bash
doctl kubernetes options versions
```

### 3. Initialize Terraform

```bash
cd terraform
terraform init
```

This connects to the remote state in DO Spaces.

### 4. Import the existing cluster

Since the cluster was provisioned via the DO control panel, import it into Terraform state:

```bash
terraform import digitalocean_kubernetes_cluster.main <cluster-id>
# Find cluster-id: DO Control Panel → Kubernetes → click your cluster → copy the ID from the URL
```

### 5. Review and apply

```bash
terraform plan   # preview what will change
terraform apply  # apply (installs Nginx Ingress Controller)
```

### 6. Get the ingress public IP

After apply, the Nginx Ingress Controller will have a public IP assigned by DigitalOcean:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP column = your single public IP
```

### 7. Update DNS A-records

Set the `EXTERNAL-IP` as the value for both A-records in DO Control Panel → Networking → Domains → lifememo.org:

| Record name    | Type | Value            |
|----------------|------|------------------|
| `api`          | A    | `<EXTERNAL-IP>`  |
| `staging`      | A    | `<EXTERNAL-IP>`  |

## Day-to-day commands

```bash
terraform plan    # preview changes
terraform apply   # apply changes
terraform show    # inspect current state
```

## Connect kubectl to the cluster

```bash
doctl kubernetes cluster kubeconfig save <cluster-name>
```

## Adding a new microservice

Each new service only needs to add its own Helm `Ingress` resource pointing at the shared Nginx Ingress Controller — no new LoadBalancers or changes to this repo are required.
