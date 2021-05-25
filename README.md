# Configure Azure CSI driver for OpenShift NFS StorageClass

See also :

- [Understanding persistent storage](https://docs.openshift.com/aro/4/storage/understanding-persistent-storage.html#types-of-persistent-volumes_understanding-persistent-storage)
- [Persistent storage using Azure File](https://docs.openshift.com/aro/4/storage/persistent_storage/persistent-storage-azure-file.html)
- [Azure File CSI Driver for Kubernetes](https://github.com/kubernetes-sigs/azurefile-csi-driver)
- [Azure Disk CSI driver for Kubernetes](https://github.com/kubernetes-sigs/azuredisk-csi-driver)
- [Available Kubernetes CSI Drivers](https://kubernetes-csi.github.io/docs/drivers.html)
- [Install instructions for CSI driver in ARO](https://github.com/ezYakaEagle442/aro-pub-storage/blob/master/setup-store-CSI-driver-azure-file.md)

# Pre-req

See :
- [Install Guide](https://github.com/kubernetes-sigs/azurefile-csi-driver/blob/master/docs/install-azurefile-csi-driver.md)
- Available [sku](https://github.com/kubernetes-sigs/azurefile-csi-driver/blob/master/docs/driver-parameters.md) are : Standard_LRS, Standard_ZRS, Standard_GRS, Standard_RAGRS, Premium_LRS
- [Pre-req](https://github.com/kubernetes-sigs/azurefile-csi-driver#prerequisite) : The driver initialization depends on a Cloud provider config file.

The driver initialization depends on a Cloud provider config file, usually it's /etc/kubernetes/azure.json on all kubernetes nodes deployed by AKS or aks-engine, here is azure.json example. This driver also supports read cloud config from kuberenetes secret.

<span style="color:red">/!\ IMPORTANT </span> : in OpenShift the creds file is located in **“/etc/kubernetes/cloud.conf”**, so you would need to replace the path in the deployment for the driver from “/etc/kubernetes/azure.json” to “/etc/kubernetes/cloud.conf”, issue #[https://github.com/kubernetes-sigs/azurefile-csi-driver/issues/282](https://github.com/kubernetes-sigs/azurefile-csi-driver/issues/282) logged. 

These steps were originally provided for configuration of the driver in ARO (Azure Red Hat Openshift) which is Azure's managed version of OpenShift. Here we will detail how to get the driver installed and working in an IPI based OpenShift installation. The main difference being the non-ARO installation needs the service principal and service principal secret specified in the *cloud.conf* file.

1. [Enable NFS 4.1 in Azure Subscription](https://docs.microsoft.com/en-us/azure/storage/files/storage-files-how-to-create-nfs-shares?tabs=azure-portal)

```sh
# Connect your Azure CLI to your Azure account, if you have not already done so.
az login

# Provide the subscription ID for the subscription where you would like to 
# register the feature
subscriptionId="<yourSubscriptionIDHere>"

az feature register \
    --name AllowNfsFileShares \
    --namespace Microsoft.Storage \
    --subscription $subscriptionId
```
Registration approval can take up to an hour. To verify that the registration is complete, use the following command:
```sh
az feature show \
    --name AllowNfsFileShares \
    --namespace Microsoft.Storage \
    --subscription $subscriptionId

az provider register \
    --namespace Microsoft.Storage
```

2. Change to the **openshift-install** cluster directory. For example, if you installed with **openshift-install create cluster --dir=/mypath/mycluster --log-level=info** then you should change into **"/mypath/mycluster"**

3. Get the service principal for the account created for the installation of OpenShift
```sh
aadClientId=$(cat terraform.azure.auto.tfvars.json | jq -r '.azure_client_id')
echo "aadClientId " $aadClientId

aadClientSecret=$(cat terraform.azure.auto.tfvars.json | jq -r '.azure_client_secret')
echo "aadClientSecret" $aadClientSecret
```

4. Configure Security Context Constraint for service account
```sh
# https://github.com/kubernetes-sigs/azurefile-csi-driver/blob/master/deploy/csi-azurefile-node.yaml#L17
oc adm policy add-scc-to-user privileged system:serviceaccount:kube-system:csi-azurefile-node-sa
```

5. Install the Azure File CSI Driver

```sh
oc create configmap azure-cred-file --from-literal=path="/etc/kubernetes/cloud.conf" -n kube-system

driver_version=master #v0.10.0
echo "Driver version " $driver_version
curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/$driver_version/deploy/install-driver.sh | bash -s $driver_version --
```

6. Get existing **cloud.conf** file so we can update with Azure Service Principal credentials and store new cloud.conf as secret. ARO has these values populated, for some reason IPI installer does not set them.
```sh
podname=$(oc get po | grep csi-azurefile-controller | head -1 | awk '{print $1}')

# get /etc/kubernetes/cloud.conf
oc cp $podname:/etc/kubernetes/cloud.conf -c azurefile cloud.conf.orig

# add aadClientId and aadClientSecret to cloud.conf
cat cloud.conf.orig | jq '.aadClientId = "'$aadClientId'"' | jq '.aadClientSecret = "'$aadClientSecret'"' > cloud.conf

oc create secret generic csi-azurefile-credentials --from-file=cloud.conf=cloud.conf -n kube-system
```

7. Update **azure-cred-file** config map to point to */mnt/csi/cloud.conf*
```sh
oc patch -n kube-system cm azure-cred-file --type=json -p='[{"op": "replace", "path": "/data/path", "value": "/mnt/csi/cloud.conf"}]'
```

8. Update deployment and daemonsets to use credentials file from secret
```sh
# Patch commands will add these volumes to azurefile container
#        volumeMounts:
#          - mountPath: "/mnt/csi"
#            name: csi-azurefile-credentials
#            readOnly: true
#      volumes:
#        - name: csi-azurefile-credentials
#          secret:
#            secretName: csi-azurefile-credentials

oc patch -n kube-system deploy csi-azurefile-controller --type=json -p= '[{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "csi-azurefile-credentials", "secret":{"secretName":"csi-azurefile-credentials"}}}, {"op": "add", "path": "/spec/template/spec/containers/5/volumeMounts/-", "value": {"mountPath": "/mnt/csi","name": "csi-azurefile-credentials","readOnly": true}}]'

oc patch -n kube-system daemonset csi-azurefile-node --type=json -p='[{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "csi-azurefile-credentials", "secret":{"secretName":"csi-azurefile-credentials"}}}, {"op": "add", "path": "/spec/template/spec/containers/2/volumeMounts/-", "value": {"mountPath": "/mnt/csi","name": "csi-azurefile-credentials","readOnly": true}}]'

oc patch -n kube-system daemonset csi-azurefile-node-win --type=json -p='[{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "csi-azurefile-credentials", "secret":{"secretName":"csi-azurefile-credentials"}}}, {"op": "add", "path": "/spec/template/spec/containers/2/volumeMounts/-", "value": {"mountPath": "/mnt/csi","name": "csi-azurefile-credentials","readOnly": true}}]'
```

9. Create Storage Class
```sh
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi-nfs
provisioner: file.csi.azure.com
parameters:
  protocol: nfs
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
```
**Note:** The first time a PVC is created using NFS it will take a little longer as the Azure Storage Account is created. If the storage account is pre-existing then it needs to be specified with the *storageAccount* parameter

### [Troubleshoot](https://github.com/kubernetes-sigs/azurefile-csi-driver/blob/master/docs/csi-debug.md)

## Test Azure File CSI Driver
See doc examples :
- [basic usage](https://github.com/kubernetes-sigs/azurefile-csi-driver/blob/master/deploy/example/e2e_usage.md)


```sh
cat <<EOF | oc apply -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: test
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: azurefile-csi-nfs
  volumeMode: Filesystem
EOF
```

The PV that is created from the claim has the storage account information stored in the *volumeHandle* field. It will be in the format **resource-group#storage-account#file-share-name**. 
```yaml
kind: PersistentVolume
apiVersion: v1
metadata:
  name: pvc-2ef5a2e9-c99c-4df7-b32c-753fb76a0d15
  selfLink: /api/v1/persistentvolumes/pvc-2ef5a2e9-c99c-4df7-b32c-753fb76a0d15
  uid: 015ea968-a514-4cf0-84ee-3e4b7c04b230
  resourceVersion: '32893'
  creationTimestamp: '2021-05-25T13:33:52Z'
  annotations:
    pv.kubernetes.io/provisioned-by: file.csi.azure.com
  finalizers:
    - kubernetes.io/pv-protection
spec:
  capacity:
    storage: 1Gi
  csi:
    driver: file.csi.azure.com
    volumeHandle: >-
      ocp-ppz67-rg#f5bec590fc8144499b83e6b#pvcn-2ef5a2e9-c99c-4df7-b32c-753fb76a0d15#
    volumeAttributes:
      csi.storage.k8s.io/pv/name: pvc-2ef5a2e9-c99c-4df7-b32c-753fb76a0d15
      csi.storage.k8s.io/pvc/name: test
      csi.storage.k8s.io/pvc/namespace: kube-system
      protocol: nfs
      secretnamespace: kube-system
      storage.kubernetes.io/csiProvisionerIdentity: 1621949243566-8081-file.csi.azure.com
  accessModes:
    - ReadWriteMany
  claimRef:
    kind: PersistentVolumeClaim
    namespace: kube-system
    name: test
    uid: 2ef5a2e9-c99c-4df7-b32c-753fb76a0d15
    apiVersion: v1
    resourceVersion: '32600'
  persistentVolumeReclaimPolicy: Delete
  storageClassName: azurefile-csi-nfs
  volumeMode: Filesystem
status:
  phase: Bound
```

## Clean-Up
```sh
oc delete pvc -n default test
oc delete secret csi-azurefile-credentials
oc delete cm azure-cred-file
oc delete sc azurefile-csi-nfs

curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/$driver_version/deploy/uninstall-driver.sh | bash -s --

```
