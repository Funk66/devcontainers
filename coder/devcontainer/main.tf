terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.11.0, < 3.0.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
  required_version = "~> 1"
}

# ── Definitions ───────────────────────────────────────────────────────────
variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

locals {
  workspace_image = "ghcr.io/funk66/devcontainers:latest"

  common_labels = {
    "coder.owner"        = data.coder_workspace_owner.me.name
    "coder.owner_id"     = data.coder_workspace_owner.me.id
    "coder.workspace_id" = data.coder_workspace.me.id
  }
  volume_labels = merge(local.common_labels, {
    "coder.workspace_name_at_creation" = data.coder_workspace.me.name
  })
  container_labels = merge(local.common_labels, {
    "coder.workspace_name" = data.coder_workspace.me.name
  })
}

provider "docker" {
  host = var.docker_socket != "" ? var.docker_socket : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ── Workspace parameter ───────────────────────────────────────────────────
data "coder_parameter" "repo_name" {
  type         = "string"
  name         = "repo_name"
  display_name = "Repository name"
  description  = "Name of a repository with a devcontainer configuration."
  default      = ""
  mutable      = false

  validation {
    regex = "^(|[A-Za-z0-9][A-Za-z0-9._-]*)$"
    error = "Enter a repository name"
  }
}

# ── Coder agent ───────────────────────────────────────────────────────────
resource "coder_agent" "devcontainer" {
  arch            = data.coder_provisioner.me.arch
  os              = "linux"
  startup_script  = <<-EOT
    set -e
    umask 022

    # Initialize the persistent home once, preserving existing user files.
    if [ ! -f "$HOME/.init_done" ]; then
      cp -rn /etc/skel/. "$HOME/"
      touch "$HOME/.init_done"
    fi
  EOT
  shutdown_script = <<-EOT
    set -e

    # Gracefully stop Docker-in-Docker.
    if pgrep dockerd >/dev/null 2>&1; then
      sudo kill "$(sudo cat /var/run/docker.pid 2>/dev/null || pgrep dockerd)" 2>/dev/null || true
      # Give dockerd a moment to exit cleanly.
      sleep 2
      sudo kill -9 "$(pgrep dockerd)" 2>/dev/null || true
    fi
  EOT

  env = {
    GIT_AUTHOR_NAME     = data.coder_workspace_owner.me.full_name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = data.coder_workspace_owner.me.full_name
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # Normalize host load by all installed CPUs, rather than the container's limit.
    script   = <<-EOT
      awk -v cpus="$(nproc --all)" '{ printf "%0.2f", $1 / cpus }' /proc/loadavg
    EOT
    interval = 60
    timeout  = 1
  }

  metadata {
    display_name = "Swap Usage (Host)"
    key          = "7_swap_host"
    script       = <<EOT
      free -b | awk '/^Swap/ { printf("%.1f/%.1f", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'
    EOT
    interval     = 10
    timeout      = 1
  }
}

# ── Scripts ───────────────────────────────────────────────────────────────
resource "coder_script" "init_docker_in_docker" {
  count              = data.coder_workspace.me.start_count
  agent_id           = coder_agent.devcontainer.id
  display_name       = "Initialize Docker-in-Docker"
  run_on_start       = true
  start_blocks_login = true
  timeout            = 120
  icon               = "/icon/docker.svg"

  script = <<-EOT
    #!/bin/sh
    set -eu

    # The Coder agent is the container's main process, so the Docker
    # daemon must be started in the background before waiting for it.
    if ! docker info >/dev/null 2>&1; then
      echo "Starting Docker daemon..."
      sudo sh -c 'nohup dockerd >> /var/log/dockerd.log 2>&1 &'
    fi

    echo "Waiting for Docker-in-Docker to be ready..."

    # Wait for the Docker socket to become available.
    attempt=0
    until docker info >/dev/null 2>&1; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 60 ]; then
        echo "Docker did not become ready within the startup polling limit." >&2
        sudo tail -n 80 /var/log/dockerd.log >&2 || true
        exit 1
      fi
      sleep 1
    done
    echo "Docker is ready."
  EOT
}

# ── Modules ───────────────────────────────────────────────────────────────
module "devcontainers-cli" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/devcontainers-cli/coder"
  agent_id = coder_agent.devcontainer.id
  version  = "~> 1.0"
}

module "git-clone" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/git-clone/coder"
  agent_id = coder_agent.devcontainer.id
  url      = data.coder_parameter.repo_name.value != "" ? "https://github.com/Funk66/${data.coder_parameter.repo_name.value}.git" : "https://github.com/Funk66/${data.coder_workspace.me.name}.git"
  base_dir = "~"
  version  = "~> 2.0"
}

# ── DevContainer ──────────────────────────────────────────────────────────
resource "coder_devcontainer" "repo" {
  count            = data.coder_workspace.me.start_count
  agent_id         = coder_agent.devcontainer.id
  workspace_folder = "~/${module.git-clone[0].folder_name}"
}

# ── Volumes ───────────────────────────────────────────────────────────────
resource "docker_volume" "devcontainer_home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle {
    ignore_changes = all
  }
  dynamic "labels" {
    for_each = local.volume_labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_volume" "docker_volume" {
  name = "coder-${data.coder_workspace.me.id}-docker"
  lifecycle {
    ignore_changes = all
  }
  dynamic "labels" {
    for_each = local.volume_labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ── Container ─────────────────────────────────────────────────────────────
resource "docker_container" "devcontainer" {
  count = data.coder_workspace.me.start_count
  image = local.workspace_image

  # Required by the Docker-in-Docker setup inside this workspace.
  privileged = true
  user     = "1000"

  name     = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname = data.coder_workspace.me.name
  # The Coder agent is the container's main process: the init script
  # bootstraps it and the startup scripts bring up Docker-in-Docker.
  # The image's CMD (dockerd) is intentionally not used.
  command  = ["sh", "-c", coder_agent.devcontainer.init_script]
  env = [
    "CODER_AGENT_TOKEN=${coder_agent.devcontainer.token}"
  ]
  host {
    host = "coder.guirao.net"
    ip   = "host-gateway"
  }

  volumes {
    container_path = "/home/ubuntu"
    volume_name    = docker_volume.devcontainer_home_volume.name
    read_only      = false
  }

  # Workspace docker volume persists Docker data across workspace
  # restarts, allowing the devcontainer cache to be reused.
  volumes {
    container_path = "/var/lib/docker"
    volume_name    = docker_volume.docker_volume.name
    read_only      = false
  }

  dynamic "labels" {
    for_each = local.container_labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}
