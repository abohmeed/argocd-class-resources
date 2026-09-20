# Tenant directory template

**CI enforces that every `teams/<name>/` directory matches this shape.** That is deliberate: a
tenant convention nobody checks is a convention that drifts, and at fifty teams a drifted
convention is unreviewable.

```
teams/<team>/
  appproject.yaml          # sourceRepos, destinations, clusterResourceWhitelist — S07 L02/L03
  rbac-policy.csv.snippet  # the p/g lines this team contributes to argocd-rbac-cm — S07 L06
  apps/<app>/              # one directory per application the team owns
```

A new team is a directory and a pull request. It is not a ticket to the platform team, and it is
not a human running `kubectl`. That is the whole point of the capstone's opening question.
