# Structural: JSON evaluation cannot compile the Kubernetes Pod image extractors.
.policy as $p |
($p.apiVersion == "policies.kyverno.io/v1" and $p.kind == "ImageValidatingPolicy") and
($p.spec.evaluation.mode == "Kubernetes") and
($p.spec.evaluation.background.enabled == false) and
($p.spec.failurePolicy == "Fail") and ($p.spec.validationActions == ["Deny"]) and
($p.spec.validationConfigurations.required == true and $p.spec.validationConfigurations.verifyDigest == true) and
($p.spec.matchConstraints.namespaceSelector.matchLabels == {"kubernetes.io/metadata.name":"dx01v2"}) and
($p.spec.matchConstraints.resourceRules == [{apiGroups:[""],apiVersions:["v1"],operations:["CREATE","UPDATE"],resources:["pods"]}]) and
($p.spec.matchImageReferences == [
  {glob:"*.dkr.ecr.*.amazonaws.com/dx01v2/api@sha256:*"},
  {glob:"*.dkr.ecr.*.amazonaws.com/dx01v2/web@sha256:*"}
]) and
($p.spec.credentials.allowInsecureRegistry == false and $p.spec.credentials.providers == ["amazon"]) and
($p.spec.attestors[0].cosign.keyless.identities == [{
  subject:"https://github.com/readiness-fixture/dx01v2/.github/workflows/deploy-aws.yml@refs/heads/main",
  issuer:"https://token.actions.githubusercontent.com"
}]) and
($p.spec.attestations == [{name:"promotion",intoto:{type:"https://github.com/maringelix/tx00v2/attestations/promoted-image/v1"}}]) and
($p.spec.validations[0].expression | contains("verifyAttestationSignatures")) and
(.rbac | length == 4) and
([.rbac[] | select(.kind == "ClusterRole")] == [{
  apiVersion:"rbac.authorization.k8s.io/v1",kind:"ClusterRole",
  metadata:{name:"dx01v2-deployer-namespace-read"},
  rules:[{apiGroups:[""],resources:["namespaces"],resourceNames:["dx01v2"],verbs:["get"]}]
}]) and
([.rbac[] | select(.kind == "ClusterRoleBinding")] == [{
  apiVersion:"rbac.authorization.k8s.io/v1",kind:"ClusterRoleBinding",
  metadata:{name:"dx01v2-deployer-namespace-read"},
  subjects:[{kind:"Group",name:"dx01v2-deployers",apiGroup:"rbac.authorization.k8s.io"}],
  roleRef:{kind:"ClusterRole",name:"dx01v2-deployer-namespace-read",apiGroup:"rbac.authorization.k8s.io"}
}]) and
([.rbac[] | select(.kind == "Role" and .metadata.name == "dx01v2-deployer-full") |
  select(.metadata.namespace == "dx01v2") | .rules[] | select(.resources | index("gateways"))] == [{
    apiGroups:["gateway.networking.k8s.io"],resources:["gateways"],resourceNames:["dx01v2-waypoint"],verbs:["get"]
}]) and
([.rbac[] | select(.kind == "RoleBinding")] == [{
  apiVersion:"rbac.authorization.k8s.io/v1",kind:"RoleBinding",
  metadata:{name:"dx01v2-deployers-full",namespace:"dx01v2"},
  subjects:[{kind:"Group",name:"dx01v2-deployers",apiGroup:"rbac.authorization.k8s.io"}],
  roleRef:{kind:"Role",name:"dx01v2-deployer-full",apiGroup:"rbac.authorization.k8s.io"}
}])
