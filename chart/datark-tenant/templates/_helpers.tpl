{{/* Tenant id — required */}}
{{- define "datark.id" -}}
{{- required "tenant.id is required (pass --set tenant.id=<id>)" .Values.tenant.id -}}
{{- end -}}

{{/* Component names */}}
{{- define "datark.kripfs.name"   -}}{{ include "datark.id" . }}-kripfs{{- end -}}
{{- define "datark.kripfs.hl"     -}}{{ include "datark.id" . }}-kripfs-hl{{- end -}}
{{- define "datark.backend.name"  -}}{{ include "datark.id" . }}-backend{{- end -}}
{{- define "datark.redis.name"    -}}{{ include "datark.id" . }}-redis{{- end -}}
{{- define "datark.mongo.name"    -}}{{ include "datark.id" . }}-mongo{{- end -}}
{{- define "datark.postgres.name" -}}{{ include "datark.id" . }}-postgres{{- end -}}
{{- define "datark.kripfsdb.name" -}}{{ include "datark.id" . }}-kripfs-db{{- end -}}

{{/* Secret name (materialized from Vault by secret-sync.sh) */}}
{{- define "datark.secretName" -}}
{{- if .Values.secretName }}{{ .Values.secretName }}{{ else }}{{ include "datark.id" . }}-secret{{ end -}}
{{- end -}}

{{/* Per-tenant transit key */}}
{{- define "datark.transitKey" -}}
{{- if .Values.vault.transitKey }}{{ .Values.vault.transitKey }}{{ else }}datark-{{ include "datark.id" . }}{{ end -}}
{{- end -}}

{{/* Tenant public host */}}
{{- define "datark.host" -}}{{ include "datark.id" . }}.{{ .Values.domain }}{{- end -}}

{{/* In-cluster service FQDNs (namespace = release namespace) */}}
{{- define "datark.kripfs.svc"   -}}{{ include "datark.kripfs.name" . }}.{{ .Release.Namespace }}.svc.cluster.local{{- end -}}
{{- define "datark.redis.svc"    -}}{{ include "datark.redis.name" . }}.{{ .Release.Namespace }}.svc.cluster.local{{- end -}}
{{- define "datark.mongo.svc"    -}}{{ include "datark.mongo.name" . }}.{{ .Release.Namespace }}.svc.cluster.local{{- end -}}
{{- define "datark.postgres.svc" -}}{{ include "datark.postgres.name" . }}.{{ .Release.Namespace }}.svc.cluster.local{{- end -}}

{{/* Common labels */}}
{{- define "datark.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
datark.koneksi.co.kr/tenant: {{ include "datark.id" . }}
datark.koneksi.co.kr/tier: {{ .Values.tier | quote }}
{{- end -}}

{{/* StorageClass field (omit when empty -> cluster default) */}}
{{- define "datark.storageClass" -}}
{{- if .Values.storageClassName }}storageClassName: {{ .Values.storageClassName | quote }}{{ end -}}
{{- end -}}
