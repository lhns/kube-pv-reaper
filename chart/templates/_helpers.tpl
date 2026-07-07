{{- define "kube-pv-reaper.name" -}}kube-pv-reaper{{- end -}}

{{- define "kube-pv-reaper.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "kube-pv-reaper.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kube-pv-reaper.labels" -}}
app.kubernetes.io/name: {{ include "kube-pv-reaper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "kube-pv-reaper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kube-pv-reaper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "kube-pv-reaper.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "kube-pv-reaper.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
