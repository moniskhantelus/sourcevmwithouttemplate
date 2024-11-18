
locals {
  hostname      = var.hostname == "" ? "default" : var.hostname
  num_instances = length(var.static_ips) == 0 ? var.num_instances : length(var.static_ips)
  static_ips = concat(var.static_ips, ["NOT_AN_IP"])
  project_id = var.project_id
  network_interface = length(format("%s%s", var.network, var.subnetwork)) == 0 ? [] : [1]
  boot_disk = "${var.source_image}" != "" ? var.source_image : "debian-11-bullseye-v20240515"
}

#########
# Locals
#########

locals {
  source_image         = "${var.source_image}" != "" ? var.source_image : "debian-11-bullseye-v20240515"
  source_image_family  = "${var.source_image_family}" != "" ? var.source_image_family : "debian-11"
  source_image_project = "${var.source_image_project}"!= "" ? var.source_image_project : "debian-cloud"
  shielded_vm_configs = var.enable_shielded_vm ? [true] : []
  gpu_enabled            = var.gpu != null
  alias_ip_range_enabled = var.alias_ip_range != null
  on_host_maintenance = (
    var.preemptible || var.enable_confidential_vm || local.gpu_enabled || var.spot
    ? "TERMINATE"
    : var.on_host_maintenance
  )
  automatic_restart = (
    # must be false when preemptible or spot is true
    var.preemptible || var.spot ? false : var.automatic_restart
  )
  preemptible = (
    # must be true when preemtible or spot is true
    var.preemptible || var.spot ? true : false
  )
}
   

# Find the latest snapshot (this example uses a data source lookup)
data "google_compute_snapshot" "latest_snapshot" {
  project = var.project_id
  filter      = "name = snapshot-*"  # Adjust filter as needed
  most_recent = true
}
resource "google_compute_disk" "from_snapshot" {
  project     = var.project_id
  name        = "disk-from-latest-snapshot"
  size        = 200    # Specify size in GB (must be equal to or larger than the snapshot)
  type        = "pd-standard"  # Adjust disk type as needed
  zone        = var.zone # Adjust the zone as needed
  snapshot = data.google_compute_snapshot.latest_snapshot.self_link
}

####################
# Instance 
####################

resource "google_compute_instance" "tpl" {
  provider                = google-beta
  count               = local.num_instances
  name                = local.hostname //var.add_hostname_suffix ? format("%s%s%s", local.hostname, var.hostname_suffix_separator, format("%03d", count.index + 1)) : local.hostname
  project             = local.project_id
  # name                    = var.hostname
   zone                    = var.zone 
  # project                 = var.project_id
  machine_type            = var.machine_type
  labels                  = var.labels
  metadata                = var.metadata
  tags                    = var.tags
  can_ip_forward          = var.can_ip_forward
  metadata_startup_script = var.startup_script
  deletion_protection = var.deletion_protection
  desired_status      = var.desired_status                
  min_cpu_platform        = var.min_cpu_platform
  resource_policies       = var.resource_policies
  //boot_disk = "${var.bootdisk}" == "image" ? local.boot-image : local.boot-snapshot
   
   boot_disk {
      auto_delete  = var.auto_delete
     // source = google_compute_disk.from_snapshot.id
    initialize_params {
      image = var.source_image != "" ? format("${local.source_image_project}/${local.source_image}") : format("${local.source_image_project}/${local.source_image_family}")
      size = var.disk_size_gb
      type    = var.disk_type
      labels  = var.disk_labels
   }        
   }

    dynamic "attached_disk" {
    for_each = var.additional_disks
    content {
      source      = google_compute_disk.additional[index(var.additional_disks, attached_disk.value)].self_link
      device_name = attached_disk.value.device_name
    }

  }
      params {
        resource_manager_tags = var.resource_manager_tags
      }

  dynamic "network_interface" {
    for_each = local.network_interface

    content {
      network            = var.network
      subnetwork         = var.subnetwork
      subnetwork_project = var.subnetwork_project
      network_ip         = length(var.static_ips) == 0 ? "" : element(local.static_ips, count.index)
      dynamic "access_config" {
        for_each = var.access_config
        content {
          nat_ip       = access_config.value.nat_ip
          network_tier = access_config.value.network_tier
        }
      }

      dynamic "ipv6_access_config" {
        for_each = var.ipv6_access_config
        content {
          network_tier = ipv6_access_config.value.network_tier
        }
      }

      dynamic "alias_ip_range" {
        for_each = var.alias_ip_ranges
        content {
          ip_cidr_range         = alias_ip_range.value.ip_cidr_range
          subnetwork_range_name = alias_ip_range.value.subnetwork_range_name
        }
      }
    }
  }
  
  dynamic "service_account" {
    for_each = var.service_account == null ? [] : [var.service_account]
    content {
      email  = lookup(service_account.value, "email", null)
      scopes = lookup(service_account.value, "scopes", null)
    }
  }

  dynamic "network_interface" {
    for_each = var.additional_networks
    content {
      network            = network_interface.value.network
      subnetwork         = network_interface.value.subnetwork
      subnetwork_project = network_interface.value.subnetwork_project
      network_ip         = length(network_interface.value.network_ip) > 0 ? network_interface.value.network_ip : null
      nic_type           = network_interface.value.nic_type
      stack_type         = network_interface.value.stack_type
      queue_count        = network_interface.value.queue_count
      dynamic "access_config" {
        for_each = network_interface.value.access_config
        content {
          nat_ip       = access_config.value.nat_ip
          network_tier = access_config.value.network_tier
        }
      }
      dynamic "ipv6_access_config" {
        for_each = network_interface.value.ipv6_access_config
        content {
          network_tier = ipv6_access_config.value.network_tier
        }
      }
      dynamic "alias_ip_range" {
        for_each = network_interface.value.alias_ip_range
        content {
          ip_cidr_range         = alias_ip_range.value.ip_cidr_range
          subnetwork_range_name = alias_ip_range.value.subnetwork_range_name
        }
      }
    }
  }

  # lifecycle {
  #   create_before_destroy = "true"
  # }

  scheduling {
    automatic_restart           = local.automatic_restart
    instance_termination_action = var.spot ? var.spot_instance_termination_action : null
    maintenance_interval        = var.maintenance_interval
    on_host_maintenance         = local.on_host_maintenance
    preemptible                 = local.preemptible
    provisioning_model          = var.spot ? "SPOT" : null
  }

  advanced_machine_features {
    enable_nested_virtualization = var.enable_nested_virtualization
    threads_per_core             = var.threads_per_core
  }

  dynamic "shielded_instance_config" {
    for_each = local.shielded_vm_configs
    content {
      enable_secure_boot          = lookup(var.shielded_instance_config, "enable_secure_boot", shielded_instance_config.value)
      enable_vtpm                 = lookup(var.shielded_instance_config, "enable_vtpm", shielded_instance_config.value)
      enable_integrity_monitoring = lookup(var.shielded_instance_config, "enable_integrity_monitoring", shielded_instance_config.value)
    }
  }

  confidential_instance_config {
    enable_confidential_compute = var.enable_confidential_vm
  }

  network_performance_config {
    total_egress_bandwidth_tier = var.total_egress_bandwidth_tier
  }

  dynamic "guest_accelerator" {
    for_each = local.gpu_enabled ? [var.gpu] : []
    content {
      type  = guest_accelerator.value.type
      count = guest_accelerator.value.count
    }
  }
}

resource "google_compute_disk" "additional" {
  project = var.project_id
  zone    = var.zone
  count = length(var.additional_disks)
   name = var.additional_disks[count.index].device_name
   type = var.additional_disks[count.index].disk_type
   size = var.additional_disks[count.index].disk_size_gb

}

