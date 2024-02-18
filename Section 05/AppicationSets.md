1. Create a new file called `onepageserver.yaml` and add the following content:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: guestbook
   spec:
     generators:
     - list:
         elements:
         - cluster: production
           url: https://192.168.2.35:6443
           revision: main
         - cluster: development
           url: https://192.168.2.36:6443
           revision: dev
     template:
       metadata:
         name: '{{cluster}}-onepageserver'
       spec:
         project: default
         source:
           repoURL: https://gitlab.com/abohmeed/samplegitopsapp.git
           targetRevision: '{{revision}}'
           path: onepageserver
         destination:
           server: '{{url}}'
           namespace: default
   ```

2. Delete the old files:

   ```bash
   rm onepageserver-primary.yaml
   rm onepageserver-secondary.yaml
   ```

3. Push the changes to the repository:

   ```bash
   git add -A
   git commit -m "Creates the one page server application set and deletes the old files"
   git push
   ```

4. Go to the Argo CD UI and refresh the argocd application. Notice that the development cluster application will be pending.

5. Go to the onepageapplication directory and make a change to the configmap that makes it suitable for the development enviornment.

6. Create a dev branch and push the changes:

   ```bash
   git checkout -b dev
   git add -A
   git commit -m "Creates the development branch"
   git push --set-upstream origin dev
   ```

7. Go to the Argo CD UI.

8. Refresh the development application and wait till the sync is done.

9. Go to the production enviornment on 192.168.2.35 and refresh the page.

10. Go to the development enviornment on 192.168.2.36 and refresh the page.