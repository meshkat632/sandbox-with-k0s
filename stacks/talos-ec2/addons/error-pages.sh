#!/usr/bin/env bash
# Deploy the default error pages behind Traefik:
#
#   - Catch-all route (lowest priority, HTTP and HTTPS): any host or path that
#     no Ingress matches gets error-pages/404.html instead of Traefik's bare
#     "404 page not found".
#   - Middleware "error-pages": replaces 5xx responses of an app with
#     error-pages/5xx.html. It is opt-in per Ingress:
#       traefik.ingress.kubernetes.io/router.middlewares: traefik-error-pages@kubernetescrd
#
# The pages are served by a small nginx in the traefik namespace. Edit the
# files in addons/error-pages/ and run this again to update them.
#
# Usage:
#   ./addons/error-pages.sh
#
# Needs Traefik (./addons.sh traefik).
# Uses ~/.kube/configs/<cluster name>.yaml (run `./kubeconfig.sh` first).
# Defaults can also be set via env: KUBECONFIG_DIR, IMAGE.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/placement.sh
. "$STACK_DIR/addons/lib/placement.sh"
PAGES_DIR="$STACK_DIR/addons/error-pages"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
IMAGE="${IMAGE:-nginxinc/nginx-unprivileged:1.28-alpine}"
NAMESPACE=traefik

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: 'kubectl' not found in PATH" >&2; exit 1; }
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run './kubeconfig.sh' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

kubectl get crd ingressroutes.traefik.io >/dev/null 2>&1 || { echo "ERROR: Traefik is missing, run './addons.sh traefik' first" >&2; exit 1; }

echo "==> Deploying the default error pages on '$CLUSTER'"
kubectl -n "$NAMESPACE" create configmap error-pages --from-file="$PAGES_DIR" --dry-run=client -o yaml | kubectl apply -f -

# Restarts the pod when a page or the nginx config changes
checksum="$(cat "$PAGES_DIR"/* | sha256sum | cut -d' ' -f1)"

kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: error-pages
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: error-pages
  template:
    metadata:
      labels:
        app: error-pages
      annotations:
        checksum/pages: "$checksum"
    spec:
      nodeSelector: $CONTROL_PLANE_SELECTOR
      tolerations: $CONTROL_PLANE_TOLERATIONS
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: $IMAGE
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: pages
              mountPath: /usr/share/nginx/html
            - name: pages
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: pages
          configMap:
            name: error-pages
---
apiVersion: v1
kind: Service
metadata:
  name: error-pages
  namespace: $NAMESPACE
spec:
  selector:
    app: error-pages
  ports:
    - name: http
      port: 80
      targetPort: http
---
# Opt-in for apps: show 5xx.html instead of the app's own 5xx response
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: error-pages
  namespace: $NAMESPACE
spec:
  errors:
    status:
      - "500-599"
    query: /5xx.html
    service:
      name: error-pages
      port: 80
---
# Catch-all: priority 1 loses against every real route
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: error-pages-http
  namespace: $NAMESPACE
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: PathPrefix(\`/\`)
      priority: 1
      services:
        - name: error-pages
          port: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: error-pages-https
  namespace: $NAMESPACE
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: PathPrefix(\`/\`)
      priority: 1
      services:
        - name: error-pages
          port: 80
  tls: {}
YAML

kubectl -n "$NAMESPACE" rollout status deployment/error-pages --timeout=180s
echo "==> Unmatched hosts and paths now get the page in addons/error-pages/404.html"
