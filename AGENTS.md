# AGENTS.md

This repo is a demo: an engineer asks for delivery infrastructure for an
application, and you create it on a local kind cluster that already runs the
platform. Everything below was verified end to end; follow it closely.

## The platform (already installed, don't modify)

Bootstrapped from `infra/argocd` on `master`:

| Component | Namespace | Notes |
| --- | --- | --- |
| Argo CD | `argocd` | No auth (anonymous admin). Use project `default`. |
| Kargo | `kargo` | Kargo CLI is not installed; use `kubectl`. |
| Argo Rollouts | `argo-rollouts` | Also powers Kargo verification (`AnalysisTemplate`). |
| Prometheus, Grafana, Alertmanager | `monitoring` | |

`./port-forward.sh` exposes the UIs. Don't change `infra/` or `master` as part
of an app request.

## Demo conventions

- **Git**: all app files go to the orphan branch `app-deployment` of
  `https://github.com/alexmt/ai-bootstrap-demo.git`. Argo CD reads that branch.
  The branch may not exist yet; if it doesn't, create it from scratch.
- **Manifests**: a Helm chart. One chart, one values file per environment.
- **Environments**: one namespace and one Argo CD Application per environment,
  all in this cluster.
- **Promotion**: Kargo sets the image tag as a Helm parameter (`image.tag`) on
  the environment's Argo CD Application (`argocd-update` step). Kargo never
  writes to git.
- **Tests**: a curl command waiting for the app. Run them as Kargo Stage
  verification so freight can't move on until they pass.
- **Freight**: the demo images are static, so the Warehouse doesn't create
  Freight; `scripts/populate-freight.sh` (on `master`) does.
- **Auto-promotion**: only the first environment auto-promotes, unless the
  engineer asks otherwise.

## Naming

For app `<app>` (e.g. `rollouts-demo` for `argoproj/rollouts-demo`) and
environment `<env>`:

- Kargo project and its namespace: `<app>`. Stages are named after environments.
- Argo CD Application: `<app>-<env>` in `argocd`, labelled `app-deployment: "true"`
  (`scripts/reset-app.sh` relies on the label).
- Target namespace: `<app>-<env>`.

## Branch layout

```
chart/                    Helm chart
  values.yaml             defaults; image.tag here is only the pre-Kargo default
  values-<env>.yaml       per-environment overrides
argocd/applications.yaml  one Application per environment
kargo/project.yaml        Namespace, Project, ProjectConfig, Warehouse, AnalysisTemplate
kargo/stages.yaml         Stages
```

## Steps

Commands run from the repo root; `W=.worktrees/app-deployment`.

1. Work in a worktree so `master` stays checked out:
   `git worktree add --orphan -b app-deployment .worktrees/app-deployment`
   (`.worktrees/` is gitignored).
2. Write the chart, the Applications and the Kargo resources (references below).
   Check with `helm template $W/chart -f $W/chart/values-<env>.yaml`.
3. Commit and push. SSH to GitHub is blocked here; push over HTTPS with gh's credentials:
   ```sh
   git -C $W -c credential.helper= -c credential.helper='!gh auth git-credential' \
     push -u https://github.com/alexmt/ai-bootstrap-demo.git app-deployment
   ```
4. `kubectl apply -f $W/argocd/applications.yaml -f $W/kargo/project.yaml`
5. `scripts/populate-freight.sh <app> <warehouse>`. Run it before
   applying Stages, otherwise the first stage auto-promotes every new Freight
   in turn.
6. `kubectl apply -f $W/kargo/stages.yaml`. The first stage auto-promotes the
   newest Freight and runs verification.
7. Promote down the pipeline (see "Promoting") and confirm every stage ends
   `Verified=True` and every Application is `Synced/Healthy`.
8. Tell the engineer how to open the app, e.g.
   `kubectl -n <app>-<env> port-forward svc/<app> 8090:80`.

Later changes (e.g. canary) are just commits to the branch: push, then
refresh the affected Applications so Argo CD doesn't wait for its 3-minute poll:
`kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=normal --overwrite`.
Re-apply `kargo/` or `argocd/` with `kubectl` only if you changed them.

## References

### argoproj/rollouts-demo

- Image `argoproj/rollouts-demo`, multi-arch. Tags used here: `blue`, `green`,
  `yellow`, `orange`, `purple`, `red`.
- Listens on `8080`. `GET /` serves the UI and `GET /color` returns the color
  as a JSON string, e.g. `"red"`.

### Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rollouts-demo-qa
  namespace: argocd
  labels:
    app-deployment: "true"
  annotations:
    # Without this Kargo refuses to touch the Application.
    kargo.akuity.io/authorized-stage: rollouts-demo:qa
spec:
  project: default
  source:
    repoURL: https://github.com/alexmt/ai-bootstrap-demo.git
    targetRevision: app-deployment
    path: chart
    helm:
      valueFiles: [values-qa.yaml]
      # No `parameters` here: Kargo owns image.tag. Writing it into the file
      # would reset the promoted tag on every `kubectl apply`.
  destination:
    server: https://kubernetes.default.svc
    namespace: rollouts-demo-qa
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Kargo project and Warehouse

```yaml
# Declared explicitly so the Warehouse and Stages have somewhere to land in
# the same `kubectl apply`. Kargo adopts namespaces with this label.
apiVersion: v1
kind: Namespace
metadata:
  name: rollouts-demo
  labels:
    kargo.akuity.io/project: "true"
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata:
  name: rollouts-demo
---
apiVersion: kargo.akuity.io/v1alpha1
kind: ProjectConfig
metadata:
  name: rollouts-demo
  namespace: rollouts-demo
spec:
  promotionPolicies:
    - stage: qa
      autoPromotionEnabled: true
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: rollouts-demo
  namespace: rollouts-demo
spec:
  interval: 5m
  freightCreationPolicy: Manual
  subscriptions:
    - image:
        repoURL: argoproj/rollouts-demo
        imageSelectionStrategy: Lexical
        allowTagsRegexes: ["^(blue|green|yellow|orange|purple|red)$"]
```

### Test (AnalysisTemplate)

Kargo starts verification as soon as Argo CD finishes the sync, before pods
are replaced or canary steps run. A test that only waits for a 200 can pass
against the old version. So the test waits until `/color` returns the
promoted tag 10 times in a row, which only happens once the new version
serves all traffic.

Templating: Argo Rollouts uses `{{args.x}}`, Kargo uses `${{ ... }}`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: smoke-test
  namespace: rollouts-demo
spec:
  args:
    - name: url
    - name: color
  metrics:
    - name: smoke-test
      provider:
        job:
          spec:
            backoffLimit: 0
            template:
              spec:
                restartPolicy: Never
                containers:
                  - name: curl
                    image: curlimages/curl:8.17.0
                    command: [sh, -c]
                    args:
                      - |
                        streak=0
                        for i in $(seq 1 300); do
                          if [ "$(curl -sf {{args.url}}/color)" = '"{{args.color}}"' ]; then
                            streak=$((streak+1))
                            [ $streak -ge 10 ] && exit 0
                          else
                            streak=0
                          fi
                          sleep 1
                        done
                        exit 1
```

### Stage

The first stage uses `sources: {direct: true}`; the others list their upstream,
e.g. `sources: {stages: [rc]}`. Several stages can share an upstream (parallel
regions).

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: qa
  namespace: rollouts-demo
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: rollouts-demo
      sources:
        direct: true
  promotionTemplate:
    spec:
      steps:
        - uses: argocd-update
          config:
            apps:
              - name: rollouts-demo-qa
                sources:
                  # Must equal the Application's source repoURL.
                  - repoURL: https://github.com/alexmt/ai-bootstrap-demo.git
                    helm:
                      images:
                        - key: image.tag
                          value: ${{ imageFrom("argoproj/rollouts-demo").Tag }}
  verification:
    analysisTemplates:
      - name: smoke-test
    args:
      - name: url
        value: http://rollouts-demo.rollouts-demo-qa.svc
      - name: color
        value: ${{ imageFrom("argoproj/rollouts-demo").Tag }}
```

Don't set `updateTargetRevision`/`desiredRevision`: Applications track the
branch head, and only the image tag is promoted.

### Promoting

There is no Kargo CLI; create a `Promotion`:

```sh
FREIGHT=$(kubectl -n rollouts-demo get stage qa -o jsonpath='{.status.freightHistory[0].items.*.name}')
kubectl create -f - <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Promotion
metadata:
  generateName: rc-
  namespace: rollouts-demo
spec:
  stage: rc
  freight: $FREIGHT
EOF
```

Observe with `kubectl -n <app> get stages,promotions,analysisruns`. A stage is
done when its `Verified` condition is `True` for the expected freight.

## Canary deployments

When asked for canary in some environments:

- Add a toggle to the chart (e.g. `canary.enabled`) that renders an
  `argoproj.io/v1alpha1` `Rollout` instead of the `Deployment`: same pod
  template and selector, plus `strategy.canary.steps`. Enable it only in those
  environments' values files. Argo CD prunes the old Deployment by itself.
- Chart changes reach every environment on push (Applications track the
  branch); per-environment behavior must come from values files.
- Use timed pauses only (`pause: {duration: 20s}`). An indefinite pause leaves
  the Rollout `Suspended`, so the Application never turns Healthy.
- Without a traffic router, canary weights are pod ratios: use enough replicas
  for the steps (5 replicas for 20% steps).
- No Kargo changes are needed. The test above already waits for the canary to
  finish.
- To show it, promote a different color into a canary environment and watch
  `kubectl -n <app>-<env> get rollout <app> -w` or the Rollout tab in the Argo CD UI.

## Re-running

`scripts/reset-app.sh` deletes the labelled Applications and their namespaces,
all Kargo projects, and the `app-deployment` branch (worktree, local and
remote). If a previous run left resources behind and the engineer asks for a
fresh setup, run it first.
