{{- define "poc3t.labels" -}}
app.kubernetes.io/part-of: {{ .Chart.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "poc3t.image" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- with $root.Values.image.registry }}{{ . }}/{{ end }}{{ $name }}:{{ $root.Values.image.tag }}
{{- end -}}

{{/* Hardened defaults shared by both containers. */}}
{{- define "poc3t.containerSecurityContext" -}}
allowPrivilegeEscalation: false
runAsNonRoot: true
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "poc3t.required" -}}
{{- $v := index . 0 -}}
{{- $name := index . 1 -}}
{{- required (printf "%s must be set (CD fills it from Terraform outputs)" $name) $v -}}
{{- end -}}
