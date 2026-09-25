{{- define "classify-app.fullname" -}}
{{ .Release.Name }}
{{- end -}}

{{- define "classify-app.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "classify-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "classify-app.clusterName" -}}
{{ .Values.clusterName | default .Release.Name }}
{{- end -}}

{{- define "classify-app.storageClassLine" -}}
{{- if .Values.storageClass }}
storageClassName: {{ .Values.storageClass }}
{{- end }}
{{- end -}}
