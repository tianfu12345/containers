{{- /*
权限修复 init 容器：把卷（统一挂在 /mnt/data）的属主设为镜像用户 1000:1000。

参数：
  seedFrom    可选，初始化内容来源目录
  seedMarker  与 seedFrom 配套的完成标记（卷内路径）
仅在无完成标记且目录为空时执行一次：带 seedFrom 的做拷贝，然后统一设置属主；
已有标记或有文件则直接退出，不重复 chown。
*/ -}}
{{- define "hermes-agent.initContainer" -}}
{{- if and .seedFrom (not .seedMarker) -}}
{{- fail "seedFrom 需要同时给出 seedMarker" -}}
{{- end }}
securityContext:
  runAsUser: 0
  runAsGroup: 0
  runAsNonRoot: false
command:
  - /bin/sh
  - -c
  - |
    set -e
{{- if .seedFrom }}
    if [ -f "{{ .seedMarker }}" ] || [ -n "$(ls -A /mnt/data)" ]; then
      echo "持久卷已初始化，跳过。"
      exit 0
    fi
    echo "初始化持久卷：{{ .seedFrom }} ..."
    cp -a {{ .seedFrom }}/. /mnt/data/
    touch "{{ .seedMarker }}"
{{- else }}
    if [ -n "$(ls -A /mnt/data)" ]; then
      echo "持久卷已有数据，跳过。"
      exit 0
    fi
{{- end }}
    chown -R 1000:1000 /mnt/data
    echo "已初始化权限。"
{{- end }}
