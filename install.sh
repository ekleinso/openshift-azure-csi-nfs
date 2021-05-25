#!/bin/bash

echo "Login to Azure"
az login

echo -e "\nEnter Subscription ID. It is the ID field from above output"
read -p "Subscription ID: " subscriptionId

az feature register --name AllowNfsFileShares --namespace Microsoft.Storage --subscription $subscriptionId

echo -n "waiting for feature to be enabled "
until [ $(az feature show --name AllowNfsFileShares --namespace Microsoft.Storage --subscription $subscriptionId | jq .properties.state -r) == "Registered" ]
do
  echo -n "."
  sleep 10
done
echo -e "\nFeature enabled"

az provider register --namespace Microsoft.Storage

read -p "OpenShift Installation Directory: " installDir

cd $installDir
aadClientId=$(cat terraform.azure.auto.tfvars.json | jq -r '.azure_client_id')
echo "aadClientId " $aadClientId
aadClientSecret=$(cat terraform.azure.auto.tfvars.json | jq -r '.azure_client_secret')
echo "aadClientSecret" $aadClientSecret

export KUBECONFIG=$installDir/auth/kubeconfig
oc project kube-system
oc adm policy add-scc-to-user privileged system:serviceaccount:kube-system:csi-azurefile-node-sa

oc create configmap azure-cred-file --from-literal=path="/etc/kubernetes/cloud.conf" -n kube-system

driver_version=master #v0.10.0
echo "Driver version " $driver_version
curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/$driver_version/deploy/install-driver.sh | bash -s $driver_version --

echo "wait for deployment"
echo "oc rollout status deploy/csi-azurefile-controller"
oc rollout status deploy/csi-azurefile-controller

echo "Get cloud.conf file"
podname=$(oc get po | grep csi-azurefile-controller | head -1 | awk '{print $1}')
oc cp $podname:/etc/kubernetes/cloud.conf -c azurefile cloud.conf.orig

echo "Update values in cloud.conf"
cat cloud.conf.orig | jq '.aadClientId = "'$aadClientId'"' | jq '.aadClientSecret = "'$aadClientSecret'"' > cloud.conf

echo "Create secret from cloud.conf"
oc create secret generic csi-azurefile-credentials --from-file=cloud.conf=cloud.conf -n kube-system

echo "Update ConfigMap to point to new location of cloud.conf from secret"
oc patch -n kube-system cm azure-cred-file --type=json -p='[{"op": "replace", "path": "/data/path", "value": "/mnt/csi/cloud.conf"}]'

echo "Update Deployment to use csi-azurefile-credentials secret"
oc patch -n kube-system deploy csi-azurefile-controller --type=json -p='[{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "csi-azurefile-credentials", "secret":{"secretName":"csi-azurefile-credentials"}}}, {"op": "add", "path": "/spec/template/spec/containers/5/volumeMounts/-", "value": {"mountPath": "/mnt/csi","name": "csi-azurefile-credentials","readOnly": true}}]'

echo "Update Daemonsets to use csi-azurefile-credentials secret"
oc patch -n kube-system daemonset csi-azurefile-node --type=json -p='[{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "csi-azurefile-credentials", "secret":{"secretName":"csi-azurefile-credentials"}}}, {"op": "add", "path": "/spec/template/spec/containers/2/volumeMounts/-", "value": {"mountPath": "/mnt/csi","name": "csi-azurefile-credentials","readOnly": true}}]'

oc patch -n kube-system daemonset csi-azurefile-node-win --type=json -p='[{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "csi-azurefile-credentials", "secret":{"secretName":"csi-azurefile-credentials"}}}, {"op": "add", "path": "/spec/template/spec/containers/2/volumeMounts/-", "value": {"mountPath": "/mnt/csi","name": "csi-azurefile-credentials","readOnly": true}}]'

echo "Create StorageClass for NFS"
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

echo "Create StorageClass for SMB"
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi-smb
provisioner: file.csi.azure.com
parameters:
  protocol: smb
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

echo "Available storage classes"
oc get sc