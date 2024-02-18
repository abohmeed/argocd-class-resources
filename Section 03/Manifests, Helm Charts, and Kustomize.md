* Create a `service.yaml` file:

  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: nginx-service
  spec:
    selector:
      app: nginx
    ports:
      - protocol: TCP
        port: 80
        targetPort: 80
  ```

* ```bash
  kubectl apply -f deployment.yaml
  kubectl apply -f service.yaml
  kubectl get pods
  kubectl get service
  kubectl delete -f deployment.yaml
  kubectl delete -f service.yaml
  ```

* ```bash
  cd ..
  helm create mychart
  cd mychart
  vim values.yaml
  ```

* Change the `replicaCount` to `3`.

* ```bash
  helm install nginx .
  kubectl get pods
  kubectl get service
  helm uninstall nginx
  ```

* ```bash
  cd ..
  mkdir base
  cp ../manifests/deployment.yaml ../manifests/service.yaml base
  cd base
  vim kustomization.yaml
  ```

* ```yaml
  # kustomization.yaml
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization
  
  resources:
  - deployment.yaml
  - service.yaml
  
  namespace: default
  ```

* ```bash
  cd ..
  mkdir overlays
  cd overlays
  vim kustomiztion.yaml
  ```

* ```yaml
  # kustomization.yaml
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization
  
  resources:
    - ../base
  
  namespace: default
  
  patches:
  - target:
      kind: Deployment
      name: nginx-deployment
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: nginx-deployment
      spec:
        replicas: 4
  ```

* ```bash
  kubectl apply -k .
  kubectl get pods
  kubectl get service
  ```