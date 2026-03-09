terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
  }
}

# ── Data sources ────────────────────────────────────────────────────────────

# All availability domains in the compartment — used to select an AD for
# node pool placement.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

# OCI regional service CIDR (e.g. "All IAD Services In Oracle Services Network").
# Used by the service gateway so nodes can reach OCI internal services
# (Object Storage, registry) without going to the internet.
data "oci_core_services" "regional" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

# OKE node images for x86 (E5.Flex). The data source filters by shape and
# k8s version so we just pick the first compatible image.
data "oci_containerengine_node_pool_option" "amd" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_id
}

locals {
  k8s_version_short = trimprefix(var.k8s_version, "v")

  # Find first standard x86_64 OKE image matching the requested k8s version.
  # Excludes aarch64 (ARM) and Gen2-GPU images — E5.Flex is standard x86.
  # Image naming: Oracle-Linux-8.10-2025.11.20-0-OKE-<k8s>-<build>
  node_image_id = try(
    [
      for s in data.oci_containerengine_node_pool_option.amd.sources :
      s.image_id
      if !can(regex("aarch64", s.source_name)) &&
      !can(regex("GPU", s.source_name)) &&
      can(regex(local.k8s_version_short, s.source_name)) &&
      can(regex("Oracle-Linux-8", s.source_name))
    ][0],
    # Fallback: any standard x86 OL8 image
    [
      for s in data.oci_containerengine_node_pool_option.amd.sources :
      s.image_id
      if !can(regex("aarch64", s.source_name)) &&
      !can(regex("GPU", s.source_name)) &&
      can(regex("Oracle-Linux-8", s.source_name))
    ][0]
  )
}

# ── VCN ─────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.cluster_name}-vcn"
  # dns_label: max 15 chars, alphanumeric only, must start with letter
  dns_label = substr(replace(var.cluster_name, "-", ""), 0, 15)
}

# ── Gateways ─────────────────────────────────────────────────────────────────

# Internet Gateway — public subnet (API endpoint + load balancers) needs this.
resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-igw"
  enabled        = true
}

# NAT Gateway — worker nodes are in a private subnet; they need outbound
# internet for container image pulls without a public IP.
resource "oci_core_nat_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-nat"
  block_traffic  = false
}

# Service Gateway — routes traffic to OCI services (registry, object storage)
# through OCI's private backbone instead of the internet.
resource "oci_core_service_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-sgw"
  services {
    service_id = data.oci_core_services.regional.services[0].id
  }
}

# ── Route tables ─────────────────────────────────────────────────────────────

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-public-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.main.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-private-rt"

  # Outbound internet via NAT (image pulls, package updates)
  route_rules {
    network_entity_id = oci_core_nat_gateway.main.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }

  # OCI internal services via Service Gateway (no internet round-trip)
  route_rules {
    network_entity_id = oci_core_service_gateway.main.id
    destination       = data.oci_core_services.regional.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
  }
}

# ── Security lists ───────────────────────────────────────────────────────────

# API endpoint subnet — allows kubectl from anywhere, kubelet + Flannel
# traffic to/from worker nodes, and OKE service communication.
# Ref: https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengnetworkconfig.htm
resource "oci_core_security_list" "api_endpoint" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-api-sl"

  # Ingress: kubectl access from anywhere
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # Ingress: worker nodes → API endpoint (k8s API)
  ingress_security_rules {
    protocol = "6"
    source   = cidrsubnet(var.vcn_cidr, 8, 1) # private subnet
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # Ingress: worker nodes → API endpoint (OKE port)
  ingress_security_rules {
    protocol = "6"
    source   = cidrsubnet(var.vcn_cidr, 8, 1)
    tcp_options {
      min = 12250
      max = 12250
    }
  }

  # Ingress: ICMP Path Discovery from workers
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = cidrsubnet(var.vcn_cidr, 8, 1)
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Egress: ALL TCP to worker nodes (Flannel CNI needs broad access)
  egress_security_rules {
    protocol    = "6"
    destination = cidrsubnet(var.vcn_cidr, 8, 1)
  }

  # Egress: ICMP Path Discovery to workers
  egress_security_rules {
    protocol    = "1" # ICMP
    destination = cidrsubnet(var.vcn_cidr, 8, 1)
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Egress: OKE service communication via Oracle Services Network
  egress_security_rules {
    protocol         = "6"
    destination      = data.oci_core_services.regional.services[0].cidr_block
    destination_type = "SERVICE_CIDR_BLOCK"
    tcp_options {
      min = 443
      max = 443
    }
  }
}

# Worker node subnet — allows ALL TCP from API endpoint (Flannel CNI),
# inter-node pod traffic, and NodePort from LB subnet.
# Ref: https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengnetworkconfig.htm
resource "oci_core_security_list" "workers" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-workers-sl"

  # Ingress: ALL TCP from API endpoint (Flannel CNI requires broad access)
  ingress_security_rules {
    protocol = "6"
    source   = cidrsubnet(var.vcn_cidr, 8, 0) # public subnet (API endpoint)
  }

  # Ingress: inter-node pod traffic (Flannel overlay)
  ingress_security_rules {
    protocol = "all"
    source   = cidrsubnet(var.vcn_cidr, 8, 1) # private subnet
  }

  # Ingress: ICMP Path Discovery
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Ingress: NodePort from load balancer subnet
  ingress_security_rules {
    protocol = "6"
    source   = cidrsubnet(var.vcn_cidr, 8, 2) # service/LB subnet
    tcp_options {
      min = 30000
      max = 32767
    }
  }

  # Egress: all outbound (internet, OCI services, other pods)
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Load balancer subnet — public-facing, allows 80/443 from internet.
resource "oci_core_security_list" "lb" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-lb-sl"

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  egress_security_rules {
    protocol    = "6"
    destination = cidrsubnet(var.vcn_cidr, 8, 1)
    tcp_options {
      min = 30000
      max = 32767
    }
  }

  # Egress: kube-proxy health check on workers
  egress_security_rules {
    protocol    = "6"
    destination = cidrsubnet(var.vcn_cidr, 8, 1)
    tcp_options {
      min = 10256
      max = 10256
    }
  }
}

# ── Subnets ──────────────────────────────────────────────────────────────────

# Public subnet — OKE API endpoint + Istio ingress load balancer.
resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = cidrsubnet(var.vcn_cidr, 8, 0) # 10.0.0.0/24
  display_name      = "${var.cluster_name}-public"
  dns_label         = "pub"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.api_endpoint.id]
}

# Private subnet — worker nodes (no public IPs).
resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = cidrsubnet(var.vcn_cidr, 8, 1) # 10.0.1.0/24
  display_name               = "${var.cluster_name}-private"
  dns_label                  = "priv"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.workers.id]
}

# Service subnet — load balancers created by Kubernetes LoadBalancer services.
resource "oci_core_subnet" "service" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = cidrsubnet(var.vcn_cidr, 8, 2) # 10.0.2.0/24
  display_name      = "${var.cluster_name}-service"
  dns_label         = "svc"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.lb.id]
}

# ── OKE Cluster ──────────────────────────────────────────────────────────────

resource "oci_containerengine_cluster" "main" {
  compartment_id     = var.compartment_id
  name               = var.cluster_name
  kubernetes_version = var.k8s_version
  vcn_id             = oci_core_vcn.main.id

  # BASIC_CLUSTER = free control plane; ENHANCED_CLUSTER = paid features.
  type = "BASIC_CLUSTER"

  # API endpoint is public so kubectl works from a laptop without a VPN.
  endpoint_config {
    subnet_id            = oci_core_subnet.public.id
    is_public_ip_enabled = true
  }

  options {
    # LB subnet for Kubernetes LoadBalancer services (e.g. Istio ingress).
    service_lb_subnet_ids = [oci_core_subnet.service.id]

    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }

  depends_on = [
    oci_core_subnet.public,
    oci_core_subnet.private,
    oci_core_subnet.service,
  ]
}

# ── Node Pool ────────────────────────────────────────────────────────────────

resource "oci_containerengine_node_pool" "main" {
  cluster_id         = oci_containerengine_cluster.main.id
  compartment_id     = var.compartment_id
  name               = "${var.cluster_name}-node-pool"
  kubernetes_version = var.k8s_version

  # x86 E5.Flex shape
  node_shape = "VM.Standard.E5.Flex"
  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gb
  }

  node_source_details {
    image_id                = local.node_image_id
    source_type             = "IMAGE"
    boot_volume_size_in_gbs = var.node_boot_volume_gb
  }

  node_config_details {
    size = var.node_count

    # Single AD placement — E5.Flex nodes placed in the first available AD.
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.private.id
    }

    # Flannel overlay CNI — simpler than VCN-native pod networking,
    # compatible with all OKE tiers and doesn't require extra IP allocations.
    node_pool_pod_network_option_details {
      cni_type = "FLANNEL_OVERLAY"
    }
  }

  initial_node_labels {
    key   = "role"
    value = "worker"
  }

  depends_on = [oci_containerengine_cluster.main]
}
