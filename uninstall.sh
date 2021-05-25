#!/bin/bash

oc delete sc azurefile-csi-nfs

curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/$driver_version/deploy/uninstall-driver.sh | bash -s --

oc delete secret csi-azurefile-credentials
oc delete cm azure-cred-file