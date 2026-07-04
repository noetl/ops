{{/*
_ehdb.tpl — role-specific EHDB (Event Horizon Database) env rendering.

DISABLED BY DEFAULT.  Every consumer guards its include with
`{{- if and .Values.ehdb .Values.ehdb.enabled }}` so that when EHDB is off the
chart renders byte-identical to pre-EHDB: no NOETL_EHDB_* env in any configmap
or pod, no attach, no behavior change.

The control-plane vs data-plane boundary is enforced HERE, keyed on the NoETL
client role — NOT in values.  An operator editing values.yaml cannot leak a
data-plane storage handle into a control-plane role:

  * Control-plane roles (server, api, gateway) receive control-plane-only env:
      NOETL_EHDB_MODE=control_plane + NOETL_EHDB_CAPABILITIES=control_plane.
      They NEVER receive NOETL_EHDB_LOCAL_REFERENCE_LOG.
  * Data-plane roles (worker, playbook, system) receive bounded local-reference
      env: NOETL_EHDB_MODE=local_reference + NOETL_EHDB_LOCAL_REFERENCE_LOG.
      Capabilities are left unset so the NoETL contract applies its default
      data-plane capability set.

This mirrors the NoETL env contract in `noetl.core.ehdb_contract`
(`validate_ehdb_integration_contract`): control_plane mode forbids a
local-reference log and only allows the control_plane capability; local_reference
mode requires a log and rejects gateway/api/server roles.

Args (dict):
  clientRole — one of server|api|gateway|worker|playbook|system
  roleKey    — key under `.Values.ehdb.roles.<roleKey>` for a per-role opt-out;
               defaults to clientRole
  root       — $ (the top-level template context)
*/}}

{{/* Returns "true" when EHDB is enabled for this role, empty string otherwise. */}}
{{- define "noetl.ehdb._roleEnabled" -}}
{{- $ehdb := .root.Values.ehdb -}}
{{- if and $ehdb $ehdb.enabled -}}
{{- $roleKey := .roleKey | default .clientRole -}}
{{- $roleCfg := (get ($ehdb.roles | default dict) $roleKey) | default dict -}}
{{- if hasKey $roleCfg "enabled" -}}
{{- if $roleCfg.enabled -}}true{{- end -}}
{{- else -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/* Emit role-specific EHDB env as configmap `data` KEY: "value" lines. */}}
{{- define "noetl.ehdb.configmapEnv" -}}
{{- if include "noetl.ehdb._roleEnabled" . -}}
{{- $clientRole := .clientRole -}}
{{- $ehdb := .root.Values.ehdb -}}
{{- $log := $ehdb.localReferenceLog | default "/opt/noetl/data/ehdb/local-reference.jsonl" -}}
{{- if has $clientRole (list "server" "api" "gateway") -}}
NOETL_EHDB_ENABLED: "true"
NOETL_EHDB_MODE: "control_plane"
NOETL_EHDB_CLIENT_ROLE: {{ $clientRole | quote }}
NOETL_EHDB_CAPABILITIES: "control_plane"
{{- else if has $clientRole (list "worker" "playbook" "system") -}}
NOETL_EHDB_ENABLED: "true"
NOETL_EHDB_MODE: "local_reference"
NOETL_EHDB_CLIENT_ROLE: {{ $clientRole | quote }}
NOETL_EHDB_LOCAL_REFERENCE_LOG: {{ $log | quote }}
{{- else -}}
{{- fail (printf "noetl.ehdb.configmapEnv: unknown EHDB client role %q (expected server|api|gateway|worker|playbook|system)" $clientRole) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Emit role-specific EHDB env as pod `env` list items (name/value pairs). */}}
{{- define "noetl.ehdb.podEnv" -}}
{{- if include "noetl.ehdb._roleEnabled" . -}}
{{- $clientRole := .clientRole -}}
{{- $ehdb := .root.Values.ehdb -}}
{{- $log := $ehdb.localReferenceLog | default "/opt/noetl/data/ehdb/local-reference.jsonl" -}}
{{- if has $clientRole (list "server" "api" "gateway") -}}
- name: NOETL_EHDB_ENABLED
  value: "true"
- name: NOETL_EHDB_MODE
  value: "control_plane"
- name: NOETL_EHDB_CLIENT_ROLE
  value: {{ $clientRole | quote }}
- name: NOETL_EHDB_CAPABILITIES
  value: "control_plane"
{{- else if has $clientRole (list "worker" "playbook" "system") -}}
- name: NOETL_EHDB_ENABLED
  value: "true"
- name: NOETL_EHDB_MODE
  value: "local_reference"
- name: NOETL_EHDB_CLIENT_ROLE
  value: {{ $clientRole | quote }}
- name: NOETL_EHDB_LOCAL_REFERENCE_LOG
  value: {{ $log | quote }}
{{- else -}}
{{- fail (printf "noetl.ehdb.podEnv: unknown EHDB client role %q (expected server|api|gateway|worker|playbook|system)" $clientRole) -}}
{{- end -}}
{{- end -}}
{{- end -}}
