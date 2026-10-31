{{- define "pn.name" -}}
{{- required "product.name is required" .Values.product.name -}}
{{- end -}}

{{- define "pn.size" -}}
{{- $s := index .Values.sizes (.Values.size | default "small") -}}
{{- if not $s -}}{{- fail (printf "unknown size %q" .Values.size) -}}{{- end -}}
{{- toYaml $s -}}
{{- end -}}

{{/* Labels on every baseline object. The Kyverno policy protect-platform-baseline
     blocks changes to objects with fleet.gitops/managed-by: platform. */}}
{{- define "pn.labels" -}}
app.kubernetes.io/managed-by: argocd
fleet.gitops/managed-by: platform
fleet.gitops/product: {{ include "pn.name" . | quote }}
fleet.gitops/owner: {{ required "product.owner is required" .Values.product.owner | quote }}
fleet.gitops/environment: {{ .Values.environment | quote }}
fleet.gitops/cost-center: {{ required "product.costCenter is required" .Values.product.costCenter | quote }}
{{- end -}}
