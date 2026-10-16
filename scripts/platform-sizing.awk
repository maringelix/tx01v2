# Sums CPU and memory requests from Helm renders of profile full. This intentionally walks only
# workload pod templates and Prometheus Operator custom-resource requests; CRD schemas and examples
# elsewhere in the manifests are not workload requests.

function cpu_millicores(value) {
  gsub(/[ \t"']/ , "", value)
  if (value ~ /m$/) {
    sub(/m$/, "", value)
    return value + 0
  }
  return (value + 0) * 1000
}

function memory_mib(value) {
  gsub(/[ \t"']/ , "", value)
  if (value ~ /Ki$/) { sub(/Ki$/, "", value); return (value + 0) / 1024 }
  if (value ~ /Mi$/) { sub(/Mi$/, "", value); return value + 0 }
  if (value ~ /Gi$/) { sub(/Gi$/, "", value); return (value + 0) * 1024 }
  if (value ~ /Ti$/) { sub(/Ti$/, "", value); return (value + 0) * 1048576 }
  if (value ~ /K$/) { sub(/K$/, "", value); return (value + 0) * 1000 / 1048576 }
  if (value ~ /M$/) { sub(/M$/, "", value); return (value + 0) * 1000000 / 1048576 }
  if (value ~ /G$/) { sub(/G$/, "", value); return (value + 0) * 1000000000 / 1048576 }
  if (value ~ /T$/) { sub(/T$/, "", value); return (value + 0) * 1000000000000 / 1048576 }
  return (value + 0) / 1048576
}

function reset_document() {
  kind = ""
  replicas = 1
  pod_cpu = 0
  pod_memory = 0
  cr_cpu = 0
  cr_memory = 0
  in_containers = 0
  in_resources = 0
  in_requests = 0
  in_cr_resources = 0
  in_cr_requests = 0
  containers_indent = -1
  container_item_indent = -1
  resource_indent = -1
  requests_indent = -1
}

function indent_of(line, prefix) {
  prefix = line
  sub(/[^ ].*$/, "", prefix)
  return length(prefix)
}

function finish_document( multiplier) {
  if (kind == "Deployment" || kind == "StatefulSet" || kind == "DaemonSet") {
    multiplier = (kind == "DaemonSet") ? nodes : replicas
    total_cpu += pod_cpu * multiplier
    total_memory += pod_memory * multiplier
  } else if (kind == "Prometheus" || kind == "Alertmanager") {
    total_cpu += cr_cpu
    total_memory += cr_memory
  }
}

BEGIN {
  reset_document()
  if (nodes < 1) {
    print "nodes must be at least 1" > "/dev/stderr"
    exit 2
  }
}

/^---[[:space:]]*$/ {
  finish_document()
  reset_document()
  next
}

{
  line_indent = indent_of($0)
  if ($0 ~ /^kind:[[:space:]]*/) {
    kind = $0
    sub(/^kind:[[:space:]]*/, "", kind)
  }
  if ((kind == "Deployment" || kind == "StatefulSet") && $0 ~ /^  replicas:[[:space:]]*[0-9]+[[:space:]]*$/) {
    replicas = $0
    sub(/^  replicas:[[:space:]]*/, "", replicas)
    replicas += 0
  }
  if ((kind == "Deployment" || kind == "StatefulSet" || kind == "DaemonSet") && $0 ~ /^[[:space:]]+(containers|initContainers):[[:space:]]*$/) {
    in_containers = 1
    containers_indent = line_indent
    in_resources = 0
    in_requests = 0
    next
  }
  if (in_containers && line_indent <= containers_indent && $0 !~ /^[[:space:]]*-/ &&
      $0 !~ /^[[:space:]]*(#|$)/) {
    in_containers = 0
    in_resources = 0
    in_requests = 0
  }
  if (in_containers) {
    if ($0 ~ /^[[:space:]]*-[[:space:]]*/ && line_indent <= containers_indent + 2 &&
        (container_item_indent < 0 || line_indent == container_item_indent)) {
      container_item_indent = line_indent
      in_resources = 0
      in_requests = 0
    }
    if ($0 ~ /^[[:space:]]*resources:[[:space:]]*$/ && line_indent > container_item_indent && line_indent <= container_item_indent + 4) {
      in_resources = 1
      resource_indent = line_indent
      in_requests = 0
      next
    }
    if (in_resources && line_indent == resource_indent + 2 && $0 ~ /^[[:space:]]*requests:[[:space:]]*$/) {
      in_requests = 1
      requests_indent = line_indent
      next
    }
    if (in_requests && line_indent == requests_indent + 2 && $0 ~ /^[[:space:]]*cpu:[[:space:]]*/) {
      value = $0
      sub(/^[[:space:]]*cpu:[[:space:]]*/, "", value)
      pod_cpu += cpu_millicores(value)
    }
    if (in_requests && line_indent == requests_indent + 2 && $0 ~ /^[[:space:]]*memory:[[:space:]]*/) {
      value = $0
      sub(/^[[:space:]]*memory:[[:space:]]*/, "", value)
      pod_memory += memory_mib(value)
    }
    if (in_requests && line_indent <= requests_indent && $0 !~ /^[[:space:]]*requests:/) in_requests = 0
    if (in_resources && line_indent < resource_indent) { in_resources = 0; in_requests = 0 }
  }

  if ((kind == "Prometheus" || kind == "Alertmanager") && $0 ~ /^  resources:[[:space:]]*$/) {
    in_cr_resources = 1
    in_cr_requests = 0
    next
  }
  if (in_cr_resources && $0 ~ /^  [^[:space:]]/) {
    in_cr_resources = 0
    in_cr_requests = 0
  }
  if (in_cr_resources && $0 ~ /^    requests:[[:space:]]*$/) {
    in_cr_requests = 1
    next
  }
  if (in_cr_requests && $0 ~ /^      cpu:[[:space:]]*/) {
    value = $0
    sub(/^      cpu:[[:space:]]*/, "", value)
    cr_cpu += cpu_millicores(value)
  }
  if (in_cr_requests && $0 ~ /^      memory:[[:space:]]*/) {
    value = $0
    sub(/^      memory:[[:space:]]*/, "", value)
    cr_memory += memory_mib(value)
  }
  if (in_cr_requests && $0 ~ /^    [^[:space:]]/) in_cr_requests = 0
}

END {
  finish_document()
  printf "cpu_millicores=%.0f\nmemory_mib=%.0f\nnodes=%d\n", total_cpu, total_memory, nodes
}
