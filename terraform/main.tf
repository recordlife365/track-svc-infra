terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    endpoints = {
      s3 = "https://sfo3.digitaloceanspaces.com"
    }
    bucket                      = "lifememo"
    key                         = "track-svc-infra/terraform.tfstate"
    region                      = "us-east-1" # required field, ignored by DO
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
    # Credentials supplied via -backend-config on init:
    # terraform init \
    #   -backend-config="access_key=$SPACES_ACCESS_KEY_ID" \
    #   -backend-config="secret_key=$SPACES_SECRET_ACCESS_KEY"
  }
}

provider "digitalocean" {
  token = var.do_token
}

provider "helm" {
  kubernetes {
    host                   = digitalocean_kubernetes_cluster.main.endpoint
    token                  = digitalocean_kubernetes_cluster.main.kube_config[0].token
    cluster_ca_certificate = base64decode(
      digitalocean_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
    )
  }
}
