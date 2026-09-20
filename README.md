# argocd-class-resources — companion repository

Reference manifests for **ArgoCD 3 in Production: GitOps at Scale on Kubernetes**.

Every manifest here is exercised end to end, on a cluster built from nothing, at least once every
24 hours. If something in this repo does not work, CI failed before you did — open an issue and it
will be a bug in the repo, not in your setup.

> ### Looking for `Section 02` … `Section 05`?
>
> They are still here, untouched, and they still work. Those directories are the resources for
> the **currently published** version of the course — if that is the one you are watching, they
> are what you want, and nothing below affects them.
>
> The directories listed under **Layout** are the companion repository for the **rebuilt** course.
> The two sit side by side on purpose: the rebuild does not break the course you are in the
> middle of.

## What you need

- A machine that can run **k3s** (Linux, or macOS with Multipass)
- `kubectl`, `git`, and `helm` 4.x
- Nothing else. Every other tool is installed by a lesson, on camera, pinned to a version.

## Quick start

```bash
curl -sfL https://get.k3s.io | sh -

# k3s writes its kubeconfig root-owned, mode 600, and `kubectl` on a k3s host is a
# symlink to `k3s` that falls back to that exact path whenever KUBECONFIG is empty.
# So take a copy you own rather than pointing KUBECONFIG at the original.
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER ~/.kube/config
export KUBECONFIG=~/.kube/config

kubectl get nodes
```

Then follow the course from Section 1. **The lessons build these files from empty** — this repo is
the reference you compare against, and the safety net if a take moves faster than you do.

## Layout

| Path | What it is | First used |
|---|---|---|
| `apps/storefront/` | The running example. An `http-echo` service whose banner text is served from an env var, so a change is visible in one frame. | S01 |
| `apps/checkout/` | The second service, with a hand-rolled Postgres StatefulSet. Arrives when the course needs a second team and a real credential. | S07 |
| `bootstrap/` | The self-management Application, and the app-of-apps root. | S02, S03 |
| `applicationsets/` | Fleet generation. | S08 |
| `teams/_template/` | The canonical shape every tenant directory must match. **CI enforces it.** | S07 |
| `test/` | The smoke suite. One script per lesson, generated from that lesson's runbook. | — |

## The test suite, and what green actually means

There is one script per demo lesson under `test/smoke/`, named for its lesson — `s04_l01.sh`.
Each one defends that lesson's **claim**, not its commands: `s01_l04.sh` asserts the banner does
*not* change after a ConfigMap edit, because that surprise is the lesson, and it goes red if Argo
CD ever changes so the surprise stops happening. A script that merely re-ran the lesson's commands
would pass in exactly the case you most need to catch.

Each script declares a tier, and the runner reports a census rather than a verdict:

```bash
./test/smoke/run_all.sh repo      # needs only a checkout — runs on every PR
./test/smoke/run_all.sh cluster   # needs k3s + Argo CD — nightly, and on manifest changes
```

| Tier | Needs | When it runs |
|---|---|---|
| `repo` | a checkout | every pull request |
| `cluster` | k3s + Argo CD | nightly, and on any manifest change |
| `external` | a browser, a second repository, a registry, or several VMs | **never in CI** |

That last row is the one that matters. A handful of lessons genuinely cannot run in CI — they sign
in through an identity provider, open a pull request, push to a registry, or build four Multipass
VMs. Those scripts assert whatever *is* checkable from the repo and then **declare themselves**:
they exit 78, print what they need and why, and the runner counts them in their own column. They
never print a pass.

That is deliberate. A script that quietly returns success because it decided not to do anything is
indistinguishable from one that ran and passed, and a suite full of those reports a green wall
while testing nothing. Here, green means *ran and passed*, and nothing else is allowed to look
like it.

## Why there is no `postgres` Helm chart here

Bitnami moved its free Helm chart repository to a paid model in 2025. Every demo in this course that
needs a database uses a **hand-rolled StatefulSet on the official `postgres` image** instead. It is
more YAML on screen, and it will still work in three years.

## Versions this repo is tested against

See `test/versions.env`. CI runs the whole suite against **every supported Argo CD minor**, so a
release that breaks a lesson is caught by the pipeline rather than by you.

## Found a problem?

Open an issue or a pull request. Student PRs against the previous version of this course sat unmerged
for over a year; that is the specific failure this repo's CI exists to make impossible.
