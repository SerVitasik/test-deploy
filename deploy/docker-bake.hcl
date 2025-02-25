variable "REGISTRY_BASE" {
  default = "appserver.local:5000"
}

group "default" {
  target = "myadmin"
}

target "myadmin" {
  context = "../myadmin"
  tags = ["${REGISTRY_BASE}/myadmin:latest"]
  cache-from = ["type=registry,ref=${REGISTRY_BASE}/myadmin:cache"]
  cache-to   = ["type=registry,ref=${REGISTRY_BASE}/myadmin:cache,mode=max,compression=zstd"]
  push = true
}