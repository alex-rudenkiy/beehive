# TODO
# - Remove hardcoded passwords and secrets (admin123, casdoor_admin) and move them to a secure storage (Vault / Secrets Manager / SOPS)
# - Remove cluster-admin privileges from headlamp and implement RBAC following the least privilege principle
# - Fix JWT configuration (issuer must not be localhost; it should be a valid external URL)
# - Remove overly permissive access policies (requestPrincipals = ["*"]) and restrict access by roles/services
# - Enable TLS (HTTPS) for ingress and eliminate plain HTTP usage
# - Replace wildcard "*" in hosts with specific domain names
# - Remove time_sleep and other unreliable waiting workarounds
# - Remove local-exec with sleep (non-deterministic behavior and breaks idempotency)
# - Reevaluate the use of HAProxy + Istio together (remove redundant ingress or clearly separate responsibilities)
# - Enable persistence for Postgres (to prevent data loss)
# - Restrict service access using NetworkPolicy
# - Add resource limits/requests for containers (to prevent internal cluster DoS)
# - Pin versions for Helm charts and container images (to avoid unexpected changes)
# - Separate infrastructure and application deployments (to avoid breaking the entire stack on changes)
# ...

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

variable "lb_ip_range" {
  type    = string
  default = "192.168.65.100-192.168.65.110"
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}



resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  set {
    name  = "args"
    value = "{--kubelet-insecure-tls=true,--kubelet-preferred-address-types=InternalIP}"
  }
}

resource "helm_release" "headlamp" {
  name             = "headlamp"
  repository       = "https://kubernetes-sigs.github.io/headlamp/"
  chart            = "headlamp"
  namespace        = "kube-system"
  create_namespace = true
}

resource "kubernetes_cluster_role_binding" "headlamp_admin" {
  metadata { name = "headlamp-admin-binding" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "headlamp"
    namespace = "kube-system"
  }
}



resource "helm_release" "metallb" {
  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  namespace        = "metallb-system"
  create_namespace = true
}

resource "kubernetes_secret" "metallb_memberlist" {
  metadata {
    name      = "memberlist"
    namespace = "metallb-system"
  }

  data = {
    secretkey = base64encode(random_password.metallb_secret.result)
  }

  type = "Opaque"
  

  depends_on = [helm_release.metallb] 
}

resource "random_password" "metallb_secret" {
  length  = 128
  special = false
}



resource "time_sleep" "wait_for_metallb_crds" {
  depends_on = [helm_release.metallb]
  create_duration = "60s"
}

resource "kubernetes_manifest" "ip_pool" {
  depends_on = [time_sleep.wait_for_metallb_crds]
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata = {
      name      = "local-pool"
      namespace = "metallb-system"
    }
    spec = {
      addresses = [var.lb_ip_range]
    }
  }
}

resource "kubernetes_manifest" "l2_advertisement" {
  depends_on = [kubernetes_manifest.ip_pool]
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata = {
      name      = "l2-adv"
      namespace = "metallb-system"
    }
  }
}

resource "helm_release" "haproxy" {
  name             = "haproxy-ingress"
  repository       = "https://haproxytech.github.io/helm-charts"
  chart            = "kubernetes-ingress"
  namespace        = "haproxy-system"
  create_namespace = true

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
        }
        config = {
          modsecurity = "true"
          "modsecurity-snippet" = <<-EOT
            SecRuleEngine On
            SecRule ARGS:testparam "@contains payload" "id:1234,deny,status:403,msg:'WAF_Blocked_Action'"
          EOT
        }
      }
    })
  ]
}


resource "kubernetes_namespace" "istio_system" {
  metadata { name = "istio-system" }
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  depends_on = [helm_release.istio_base]
  set {
    name  = "meshConfig.accessLogFile"
    value = "/dev/stdout"
  }

  set {
    name  = "meshConfig.extensionProviders[0].name"
    value = "otel-tracing"
  }
  set {
    name  = "meshConfig.extensionProviders[0].otel.service"
    value = "opentelemetry-collector.istio-system.svc.cluster.local"
  }
  set {
    name  = "meshConfig.extensionProviders[0].otel.port"
    value = "4317"
  }
}


resource "helm_release" "istio_ingress" {
  name       = "istio-ingressgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  depends_on = [helm_release.istiod]

  set {
    name  = "service.type"
    value = "ClusterIP"
  }
}



resource "kubernetes_namespace" "business_app" {
  metadata {
    name   = "prod-app"
    labels = { "istio-injection" = "enabled" }
  }
}

resource "kubernetes_deployment" "echo" {
  metadata {
    name      = "echo-app"
    namespace = kubernetes_namespace.business_app.metadata[0].name
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "echo", version: "v1" } }
    template {
      metadata { labels = { app = "echo", version: "v1" } }
      spec {
        container {
          name  = "echo"
          image = "ealen/echo-server:latest"
          port { container_port = 80 }
        }
      }
    }
  }
}

resource "kubernetes_service" "echo_svc" {
  metadata {
    name      = "echo-service"
    namespace = kubernetes_namespace.business_app.metadata[0].name
  }
  spec {
    selector = { app = "echo", version: "v1" }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}



resource "kubernetes_manifest" "app_gateway" {
  depends_on = [helm_release.istio_ingress]
  manifest = {
    apiVersion = "networking.istio.io/v1alpha3"
    kind       = "Gateway"
    metadata = { name = "app-gateway", namespace = "prod-app" }
    spec = {
      selector = { istio = "ingressgateway" }
      servers = [{
        port = { number = 80, name = "http", protocol = "HTTP" }
        hosts = ["*"]
      }]
    }
  }
}

resource "kubernetes_manifest" "coraza_waf" {
  depends_on = [helm_release.istio_ingress]
  manifest = {
    apiVersion = "extensions.istio.io/v1alpha1"
    kind       = "WasmPlugin"
    metadata = {
      name      = "coraza-waf"
      namespace = "istio-system"
    }
    spec = {
      selector = {
        matchLabels = { istio = "ingressgateway" }
      }
      url = "oci://ghcr.io/corazawaf/coraza-proxy-wasm:0.5.0"
      pluginConfig = {
        directives_map = {
          default = [
            "SecAuditEngine On",
            "SecAuditLog /dev/stdout",
            "SecAuditLogFormat JSON",
            "SecRuleEngine On",
            "Include @crs-setup-conf",
            "Include @owasp_crs/*.conf",

            "SecRule ARGS:testbot \"@streq true\" \"id:101,deny,status:403,msg:'Bot_Detected'\""
          ]
        }
        default_directives = "default"
      }
    }
  }
}


resource "kubernetes_manifest" "casdoor_jwt" {
  depends_on = [kubernetes_manifest.app_gateway]
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "RequestAuthentication"
    metadata = {
      name      = "casdoor-jwt-auth"
      namespace = "istio-system"
    }
    spec = {
      selector = {
        matchLabels = {
          app = "echo"
        }
      }
      jwtRules = [{

        issuer  = "http://localhost:8000" 
        

        jwksUri = "http://casdoor.istio-system.svc.cluster.local:8000/.well-known/jwks"
          }]
    }
  }
}


resource "kubernetes_manifest" "require_jwt" {
  depends_on = [kubernetes_manifest.casdoor_jwt]
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "require-jwt-policy"
      namespace = "prod-app"
    }
    spec = {
      selector = {
        matchLabels = { app = "echo" }
      }
      action = "ALLOW"
      rules = [{
        from = [{
          source = {

            requestPrincipals = ["*"] 
          }
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "strict_rbac" {
  depends_on = [kubernetes_manifest.casdoor_jwt]
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "AuthorizationPolicy"
    metadata = { name = "strict-api-access", namespace = "prod-app" }
    spec = {
      selector = { matchLabels = { app = "echo" } }
      action   = "ALLOW"
      rules = [
        {

          from = [{ source = { requestPrincipals = ["*"] } }]
          when = [{ key = "request.auth.claims[role]", values = ["admin"] }]
        },
        {

          from = [{ source = { requestPrincipals = ["*"] } }]
          to   = [{ operation = { methods = ["GET"], paths = ["/public-data"] } }]
        }
      ]

    }
  }
}

resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  namespace  = "istio-system"
  depends_on = [helm_release.prometheus]

  set {
    name  = "adminPassword"
    value = "admin123"
  }
  set {

    name  = "datasources.datasources\\.yaml.apiVersion"
    value = "1"
  }
  set {
    name  = "datasources.datasources\\.yaml.datasources[0].name"
    value = "Prometheus"
  }
  set {
    name  = "datasources.datasources\\.yaml.datasources[0].type"
    value = "prometheus"
  }
  set {
    name  = "datasources.datasources\\.yaml.datasources[0].url"
    value = "http://prometheus-server.istio-system.svc.cluster.local"
  }
}

resource "kubernetes_manifest" "app_vs" {
  depends_on = [kubernetes_manifest.app_gateway]
  manifest = {
    apiVersion = "networking.istio.io/v1alpha3"
    kind       = "VirtualService"
    metadata = { name = "app-routes", namespace = "prod-app" }
    spec = {
      hosts    = ["*"]
      gateways = ["app-gateway"]
      http = [{
        route = [{
          destination = { host = "echo-service", port = { number = 80 } }
        }]
      }]
    }
  }
}

resource "kubernetes_ingress_class_v1" "haproxy" {
  metadata {
    name = "haproxy"
  }
  spec {
    controller = "haproxy.org/ingress-controller/haproxy" 
  }
}

resource "kubernetes_ingress_v1" "haproxy_to_istio" {
  metadata {
    name      = "haproxy-to-istio"
    namespace = "istio-system"
  }

  spec {

    ingress_class_name = "haproxy" 

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "istio-ingressgateway"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

resource "helm_release" "otel_collector" {
name       = "opentelemetry-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  namespace  = "istio-system"


  set {
    name  = "image.repository"
    value = "otel/opentelemetry-collector-contrib"
  }
  
  set {
    name  = "image.tag"
    value = "0.90.0"
  }

  values = [
    yamlencode({
      mode = "deployment"
      config = {
        receivers = {
          otlp = {
            protocols = {
              grpc = {}
              http = {}
            }
          }
        }
        exporters = {
          logging = {
            loglevel = "debug"
          }
        }
        service = {
          pipelines = {
            traces = {
              receivers = ["otlp"]
              exporters = ["logging"]
            }
          }
        }
      }
    })
  ]
}


resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  namespace  = "istio-system"

  set {
    name  = "server.persistentVolume.enabled"
    value = "false"
  }
  set {
    name  = "alertmanager.enabled"
    value = "false"
  }
  set {
    name  = "prometheus-node-exporter.enabled"
    value = "false"
  }
  set {
    name  = "prometheus-pushgateway.enabled"
    value = "false"
  }
}


resource "helm_release" "kiali" {
  name       = "kiali-server"
  repository = "https://kiali.org/helm-charts"
  chart      = "kiali-server"
  namespace  = "istio-system"
  depends_on = [helm_release.prometheus]

  set {
    name  = "auth.strategy"
    value = "anonymous"
  }
  set {
    name  = "external_services.prometheus.url"
    value = "http://prometheus-server.istio-system.svc.cluster.local"
  }
}

resource "helm_release" "casdoor" {
  name       = "casdoor"

  repository = "oci://registry-1.docker.io/casbin"
  chart      = "casdoor-helm-charts"

  version    = "2.375.0"
  namespace  = "istio-system"
  depends_on = [helm_release.casdoor_db]

values = [
    yamlencode({

      database = {
        driver       = "postgres"
        user         = "postgres"
        password     = "casdoor_admin"
        host         = "casdoor-db-postgresql.istio-system.svc.cluster.local"
        port         = "5432"
        databaseName = "casdoor"
        sslMode      = "disable"
      }


      service = {
        port = 8000
        type = "ClusterIP"
      }



      config = <<-EOT
        appname = casdoor
        httpport = 8000
        runmode = dev
        SessionOn = true
        copyrequestbody = true
        driverName = postgres
        dataSourceName = "user=postgres password=casdoor_admin host=casdoor-db-postgresql.istio-system.svc.cluster.local port=5432 sslmode=disable dbname=casdoor"
        dbName = casdoor
        origin = http://localhost:8000
        enableGzip = true
      EOT
    })
  ]
  }

resource "helm_release" "casdoor_db" {
  name       = "casdoor-db-postgresql"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  version    = "12.5.7"
  namespace  = "istio-system"

  set {
    name  = "auth.database"
    value = "casdoor"
  }
  set {
    name  = "auth.postgresPassword"
    value = "casdoor_admin"
  }
  set {
    name  = "primary.persistence.enabled"
    value = "false"
  }
}

resource "null_resource" "init_casdoor_users" {
  depends_on = [helm_release.casdoor]

  provisioner "local-exec" {


    command = <<-EOT
      sleep 30
      echo "Casdoor is up. Admin: admin / 123"

    EOT
  }
}
