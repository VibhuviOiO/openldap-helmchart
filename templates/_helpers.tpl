{{- define "openldap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openldap.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openldap.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openldap.labels" -}}
helm.sh/chart: {{ include "openldap.chart" . }}
{{ include "openldap.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "openldap.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openldap.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* <fullname>-<ordinal>.<this>.<ns>.svc.<clusterDomain> is what replication embeds. */}}
{{- define "openldap.headlessServiceName" -}}
{{- printf "%s-headless" (include "openldap.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openldap.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "openldap.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "openldap.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- tpl .Values.auth.existingSecret . -}}
{{- else -}}
{{- include "openldap.fullname" . -}}
{{- end -}}
{{- end -}}

{{/* dc=<part>,... from ldap.domain, the way the image derives LDAP_BASE_DN. */}}
{{- define "openldap.baseDn" -}}
{{- if .Values.ldap.baseDn -}}
{{- .Values.ldap.baseDn -}}
{{- else -}}
{{- $parts := splitList "." .Values.ldap.domain -}}
{{- $dcs := list -}}
{{- range $parts }}{{ $dcs = append $dcs (printf "dc=%s" .) }}{{ end -}}
{{- join "," $dcs -}}
{{- end -}}
{{- end -}}

{{/* Hard-coded to cn=Manager by the image; not configurable. */}}
{{- define "openldap.adminDn" -}}
{{- printf "cn=Manager,%s" (include "openldap.baseDn" .) -}}
{{- end -}}

{{/* Replication needs a peer, so replicaCount=1 is standalone. */}}
{{- define "openldap.replicationEnabled" -}}
{{- if and .Values.replication.enabled (gt (int .Values.replicaCount) 1) -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
Selector for the provider pods ONLY.

The helm test pod and the backup Job pods carry openldap.selectorLabels too, so
matching on those labels alone made the Services publish non-LDAP pods as
endpoints and made the PodDisruptionBudget try to manage Jobs -- which is what
produced "Pods selected by this PodDisruptionBudget were found to be unmanaged"
and "jobs.batch does not implement the scale subresource".
*/}}
{{- define "openldap.serverSelectorLabels" -}}
{{ include "openldap.selectorLabels" . }}
app.kubernetes.io/component: ldap
{{- end -}}

{{- define "openldap.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
