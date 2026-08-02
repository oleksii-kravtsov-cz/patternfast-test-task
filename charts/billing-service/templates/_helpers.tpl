{{- define "billing-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "billing-service.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "billing-service.labels" -}}
app.kubernetes.io/name: {{ include "billing-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "billing-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "billing-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "billing-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "billing-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- if and .Values.serviceAccount.roleArn (not .Values.serviceAccount.name) }}
{{- fail "serviceAccount.roleArn set with create=false and no serviceAccount.name: the IRSA annotation would be lost" }}
{{- end }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "billing-service.image" -}}
{{- if .Values.image.digest }}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" (.Values.image.digest | toString)) }}
{{- fail (printf "image.digest %q must be sha256:<64 hex>" .Values.image.digest) }}
{{- end }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else if .Values.image.requireDigest }}
{{- fail "image.digest is required by these values" }}
{{- else if eq (lower (.Values.image.tag | toString)) "latest" }}
{{- fail "image.tag must not be latest, set image.digest" }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | toString) }}
{{- end }}
{{- end }}
