{{- define "media-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "media-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "media-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "media-server.labels" -}}
helm.sh/chart: {{ include "media-server.chart" . }}
app.kubernetes.io/name: {{ include "media-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "media-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "media-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "media-server.postgresName" -}}
{{- printf "%s-postgres" (include "media-server.fullname" .) -}}
{{- end -}}

{{- define "media-server.mediaClaimName" -}}
{{- if .Values.persistence.media.existingClaim -}}
{{- .Values.persistence.media.existingClaim -}}
{{- else -}}
{{- printf "%s-media" (include "media-server.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "media-server.cacheClaimName" -}}
{{- if .Values.persistence.cache.existingClaim -}}
{{- .Values.persistence.cache.existingClaim -}}
{{- else -}}
{{- printf "%s-cache" (include "media-server.fullname" .) -}}
{{- end -}}
{{- end -}}
