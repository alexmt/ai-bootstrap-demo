# Shared by all Applications.
#
# cainjector writes caBundle into webhook configs after sync, so Argo CD must
# ignore that field or selfHeal would keep wiping it.
# Retries cover Kargo syncing before cert-manager CRDs exist.
{{- define "argocd.appSync" }}
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jqPathExpressions: [".webhooks[]?.clientConfig.caBundle"]
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jqPathExpressions: [".webhooks[]?.clientConfig.caBundle"]
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - RespectIgnoreDifferences=true
  retry:
    limit: 20
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 1m
{{- end }}

{{- define "argocd.applications" }}
# argocd-server creates this on startup, but the Applications may land first
# and then sit in InvalidSpecError until the next refresh.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  sourceRepos: ["*"]
  destinations:
    - server: "*"
      namespace: "*"
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: {{ .Values.certManager.version }}
    helm:
      valuesObject:
        crds:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  {{- include "argocd.appSync" . | nindent 2 }}
---
# Kargo needs cert-manager: its webhook certs come from a cert-manager Issuer.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kargo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ghcr.io/akuity/kargo-charts
    chart: kargo
    targetRevision: {{ .Values.kargo.version }}
    helm:
      valuesObject:
        {{- toYaml .Values.kargo.values | nindent 8 }}
  destination:
    server: https://kubernetes.default.svc
    namespace: kargo
  {{- include "argocd.appSync" . | nindent 2 }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: {{ .Values.monitoring.version }}
    helm:
      valuesObject:
        {{- toYaml .Values.monitoring.values | nindent 8 }}
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  {{- include "argocd.appSync" . | nindent 2 }}
{{- end }}
