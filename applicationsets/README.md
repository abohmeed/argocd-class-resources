# ApplicationSets

Three things in here will bite someone who copies from an older tutorial, so they are called out in
the manifests themselves rather than left to the lesson:

1. **`goTemplate: true` changes how you address a parameter.** `{{.name}}`, with the dot. The old
   dot-less `{{name}}` is not a deprecated-but-working form — on Argo CD 3.5 it is a **parse error**
   (`function "name" not defined`), and the whole ApplicationSet fails to render.
2. **`goTemplateOptions: ["missingkey=error"]` is not the default.** Left unset, a typo'd field
   renders as nothing, silently, and you find out when an Application deploys to the wrong place.
3. **You do not need to exclude the Argo CD host cluster** from a Cluster generator. It has no
   Secret, so it has no `argocd.argoproj.io/secret-type` label, so a selector on that label already
   excludes it.

And one that will bite someone who deletes an ApplicationSet to tidy up: **the default cascade takes
the generated Applications and their live cluster resources with it.**
`preserveResourcesOnDeletion: true` keeps the resources — but the Application objects still go, so
the fleet becomes silently *unmanaged* rather than unharmed. That is a different thing from safe.
