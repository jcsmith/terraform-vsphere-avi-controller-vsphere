locals {
  # Controller Settings used as Ansible Variables
  cloud_settings = {
    vsphere_user                    = var.vsphere_avi_user == null ? var.vsphere_user : var.vsphere_avi_user
    vsphere_server                  = var.vsphere_server
    vm_datacenter                   = var.vsphere_datacenter
    se_mgmt_portgroup               = var.se_mgmt_portgroup
    configure_se_mgmt_network       = var.configure_se_mgmt_network
    se_mgmt_network                 = var.configure_se_mgmt_network ? var.se_mgmt_network : null
    avi_version                     = var.avi_version
    configure_cloud                 = var.configure_cloud
    dns_servers                     = var.dns_servers
    dns_search_domain               = var.dns_search_domain
    ntp_servers                     = var.ntp_servers
    email_config                    = var.email_config
    se_name_prefix                  = var.name_prefix
    vcenter_folder                  = var.vm_folder
    se_cpu                          = var.se_size[0]
    se_memory                       = var.se_size[1]
    se_disk                         = var.se_size[2]
    controller_ha                   = var.controller_ha
    controller_ip                   = var.controller_ip
    controller_names                = local.controller_names
    configure_ipam_profile          = var.configure_ipam_profile
    ipam_networks                   = var.configure_ipam_profile ? var.ipam_networks : null
    configure_dns_profile           = var.configure_dns_profile
    dns_service_domain              = var.dns_service_domain
    configure_dns_vs                = var.configure_dns_vs
    dns_vs_settings                 = var.dns_vs_settings
    configure_gslb                  = var.configure_gslb
    configure_gslb_additional_sites = var.configure_gslb_additional_sites
    gslb_site_name                  = var.gslb_site_name
    gslb_domains                    = var.gslb_domains
    additional_gslb_sites           = var.additional_gslb_sites
    se_ha_mode                      = var.se_ha_mode
  }
  controller_sizes = {
    small  = [8, 24576]
    medium = [16, 32768]
    large  = [24, 49152]
  }
  controller_names = vsphere_virtual_machine.avi_controller[*].name
  controller_ips   = var.controller_ha ? [var.controller_ip[0], var.controller_ip[1], var.controller_ip[2]] : [var.controller_ip[0]]
  controller_info  = zipmap(vsphere_virtual_machine.avi_controller[*].name, local.controller_ips)
}
resource "vsphere_folder" "avi" {
  path          = var.vm_folder
  type          = "vm"
  datacenter_id = data.vsphere_datacenter.dc.id
}
resource "vsphere_virtual_machine" "avi_controller" {
  count            = var.controller_ha ? 3 : 1
  name             = "${var.name_prefix}-avi-controller-${count.index + 1}"
  resource_pool_id = var.compute_cluster != null ? data.vsphere_compute_cluster.avi[0].resource_pool_id : data.vsphere_resource_pool.pool[0].id
  datastore_id     = data.vsphere_datastore.datastore.id
  num_cpus         = local.controller_sizes[var.controller_size][0]
  memory           = local.controller_sizes[var.controller_size][1]
  folder           = vsphere_folder.avi.path
  network_interface {
    network_id = data.vsphere_network.avi.id
  }
  lifecycle {
    ignore_changes = [guest_id]
  }
  disk {
    label            = "disk1"
    size             = var.boot_disk_size
    thin_provisioned = true
  }
  clone {
    template_uuid = data.vsphere_content_library_item.item.id
  }
  vapp {
    properties = {
      "mgmt-ip"    = var.controller_ip[count.index]
      "mgmt-mask"  = var.controller_netmask
      "default-gw" = var.controller_gateway
    }
  }
  provisioner "local-exec" {
    command = "bash ${path.module}/files/change-controller-password.sh --controller-address \"${var.controller_ip[count.index]}\" --current-password \"${var.controller_default_password}\" --new-password \"${var.controller_password}\""
  }
}
resource "vsphere_compute_cluster_vm_anti_affinity_rule" "avi" {
  count               = var.controller_ha ? 1 : 0
  name                = "${var.name_prefix}-avi-controller-vm-anti-affinity-rule"
  compute_cluster_id  = data.vsphere_compute_cluster.avi[0].id
  virtual_machine_ids = vsphere_virtual_machine.avi_controller.*.id
  mandatory           = "true"
}
resource "null_resource" "ansible_provisioner" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers = {
    controller_instance_ids = join(",", vsphere_virtual_machine.avi_controller.*.name)
  }
  connection {
    type     = "ssh"
    host     = var.controller_ip[0]
    user     = "admin"
    timeout  = "600s"
    password = var.controller_password
  }
  provisioner "file" {
    content = templatefile("${path.module}/files/avi-vsphere-all-in-one-play.yml.tpl",
    local.cloud_settings)
    destination = "/home/admin/avi-vsphere-all-in-one-play.yml"
  }
  provisioner "file" {
    content = templatefile("${path.module}/files/avi-cleanup.yml.tpl",
    local.cloud_settings)
    destination = "/home/admin/avi-cleanup.yml"
  }
  provisioner "remote-exec" {
    inline = var.vsphere_avi_user == null ? [
      "ansible-playbook avi-vsphere-all-in-one-play.yml -e password=${var.controller_password} -e vsphere_password=${var.vsphere_password} > ansible-playbook.log 2> ansible-error.log",
      "echo Controller Configuration Completed"
      ] : [
      "ansible-playbook avi-vsphere-all-in-one-play.yml -e password=${var.controller_password} -e vsphere_password=${var.vsphere_avi_password} > ansible-playbook.log 2> ansible-error.log",
      "echo Controller Configuration Completed"
    ]

  }
}
