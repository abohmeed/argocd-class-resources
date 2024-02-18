1. Create a new YAML file called `argocd.yaml` and add the following:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://gitlab.com/[your username]/samplegitopsapp.git'
    path: argo-cd
    targetRevision: main
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: argocd
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

3. Apply the above configuration by running:

   ```bash
   kubectl apply -f argocd.yaml
   ```

4. Go to the UI of Argo CD.

5. Login using the username of `admin` and your password

6. Delete the `nginx` application from the UI. You need to type the name of the application `nginx` in the dialog box for the deletion operation to complete.

7. Go to the terminal and in the `argocd` directory create a new application manifest for HTTPbin. The filename should be `httpbin.yaml` and the contents should be as follows:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: httpbin
  namespace: argocd
spec:
  project: default
  source:
    chart: httpbin
    repoURL: https://matheusfm.dev/charts
    targetRevision: 0.1.1
    helm:
      releaseName: httpbin
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: default
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

8. Create and push a merge request:

```bash
git checkout -b feature/add-httpbin-chart
git add httpbin.yaml
git commit -m "Adds the HTTPbin chart"
git push --set-upstream origin feature/add-httpbin-chart
```

9. Copy the MR link that is displayed and paste it in new browser tab.

10. Approve and merge the MR.

11. Go to ArgoCD UI and click Refresh on the argocd application. You should see the HTTPbin application appear and the icon reflecting that it is a Helm chart.

12. Go back to the terminal and open the `httpbin.yaml`.

13. The contents of the file should look as follows:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: httpbin
  namespace: argocd
spec:
  project: default
  source:
    chart: httpbin
    repoURL: https://matheusfm.dev/charts
    targetRevision: 0.1.1
    helm:
      releaseName: httpbin
      values: |
        service:
          type: NodePort
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: default
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

14. Save the file.

15. Create a merge request by running the following commands:

```bash
git checkout -b feature/httpbin-service-type
git add httpbin.yaml
git checkout -m "Changes the HTTPbin service type to NodePort"
git push --set-upstream origin feature/httpbin-service-type
```

16. Copy the link from the output and paste it in a new browser tab. Create, approve, and merge the MR.

17. Move to the Argo CD dashboard and refresh the argocd application.

18. Move back to the terminal and check the service type again by running:

    ```bash
    kubectl get svc
    ```

19. Type the following command (without executing it):

    ```bash
    helm upgrade httpbin --set service.type=nodeport matheusfm/httpbin
    ```

20. Get the node IP address by running:

    ```bash
    kubectl get nodes -o wide
    ```

21. Test the service by running:

    ```bash
    curl "172.18.0.2:31994/get" -H "accept: application/json" # replace the IP address and port with the appropriate values.
    ```

22. Create a new Helm chart in the root directory by running the following command:

    ```bash
    helm create httpd
    ```

23. Go inside the directory and change the values file as follows:

```yaml
# values.yaml
image:
  repository: httpd
  pullPolicy: IfNotPresent
  # Overrides the image tag whose default is the chart appVersion.
  tag: latest
```

24. Check the version of the chart in the Chart.yaml file.

25. Package the chart by running:

    ```bash
    helm package .
    ```

26. Check the file that was created by running:

    ```bash
    ls -ltr
    ```

27. Get the project ID from Gitlab by going to the project page and clicking on settings. Copy the ID.

28. In the terminal, upload the package by running the following command:

    ```bash
    curl --request POST --form 'chart=@httpd-0.1.0.tgz' --user "[your username]:[your token]" https://gitlab.com/api/v4/projects/[your project id]/packages/helm/api/stable/charts
    ```

29. Create the repository credentials using the following command:

    ```bash
    argocd repocreds add https://gitlab.com/api/v4/projects/[your project id]/packages/helm/stable --username [your username] --password [your personal token]
    ```

30. Create a new branch to add the busybox manifest:

    ```bash
    git checkout -b feature/httpd
    ```

31. Create a new application in the argocd directory called `busybox.yaml` and add the following content:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: httpd
  namespace: argocd
spec:
  project: default
  source:
    chart: httpd
    repoURL: https://gitlab.com/api/v4/projects/[project id]/packages/helm/stable
    targetRevision: 0.1.0
    helm:
      releaseName: httpd
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: default
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

32. Push the changes to Gitlab

    ```bash
    git add -A
    git commit -m "Adds the Apache Argo CD manifest"
    git push --set-upstream origin feature/httpd
    ```

33. Copy the link that was generated in the output, paste in a new browser tab. Approve and merge the MR to the main branch.

34. Move to the Argo CD UI and click on the Refresh button on the Argo CD applciation to sync the changes.

35. Move to the terminal and view the BusyBox pods by running:

    ```bash
    kubectl get pods
    ```

36. Create a new branch to change Nginx installation method from manifests to the Helm directory:

    ```bash
    git checkout -b feature/nginx-helm
    ```

37. Change the `nginx.yaml` manifest to look as follows:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://gitlab.com/[your username]/samplegitopsapp.git'
    path: mychart # changed
    targetRevision: main
    # Add this
    helm:
      releaseName: nginx
      values: |
        replicaCount: 2
    # till here
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: default
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

38. Push the change to Gitlab:

    ```bash
    git add -A
    git commit -m "Changes the Nginx installation from plain manifests to Helm"
    git push --set-upstream origin feature/nginx-helm
    ```

39. Copy the link that was generated in the output and paste it in a new browser tab. Approve and merge the MR.

40. Go to the Argo CD UI and click Refresh on the argocd application. Make sure that the nginx application has changed the path to `mychart`.

41. Go to the terminal and show the new pods by running:

    ```bash
    kubectl get pods
    ```