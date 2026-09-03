{{- define "ai-incident-assistant.name" -}}
ai-incident-assistant
{{- end -}}

{{- define "ai-incident-assistant.labels" -}}
app.kubernetes.io/name: {{ include "ai-incident-assistant.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
