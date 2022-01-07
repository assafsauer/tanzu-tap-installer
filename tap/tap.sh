
# /bin/bash

### vars ###

mgmt_cluster=mgmt
cluster=tap-cluster
tap_namespace=default


export HARBOR_USER=XXX
export HARBOR_PWD=XXX
export HARBOR_DOMAIN=harbor_my_domain.com

export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=XXX
export INSTALL_REGISTRY_PASSWORD=XXXX

token=XXXX
domain=my_domain.com

### optional: TAP GUI ####
git_token=XXXXXX
catalog_info=https://github.com/XXXXX/catalog-info.yaml

### creating values template ###

cat > tap-values.yml << EOF

profile: full

buildservice:
  kp_default_repository: $domain/tap/build-service
  kp_default_repository_username: $HARBOR_USER
  kp_default_repository_password: $HARBOR_PWD
  tanzunet_username: $INSTALL_REGISTRY_USERNAME
  tanzunet_password: $INSTALL_REGISTRY_PASSWORD

supply_chain: basic

ootb_supply_chain_basic:
  registry:
    server: $HARBOR_DOMAIN
    repository: "tap/supply-chain"


contour:
  infrastructure_provider: aws
  envoy:
    service:
      aws:
        LBType: nlb
cnrs:
  domain_name: apps.$domain


image_policy_webhook:
   allow_unmatched_images: true

learningcenter:
  ingressDomain: learn.apps.$domain
  storageClass: "default"

tap_gui:
  service_type: LoadBalancer

ceip_policy_disclosed: true

accelerator:
  service_type: "LoadBalancer"

appliveview:
  connector_namespaces: [default]
  service_type: LoadBalancer

metadata_store:
  app_service_type: LoadBalancer

EOF



### login to pivotal network ###

wget  https://github.com/pivotal-cf/pivnet-cli/releases/download/v3.0.1/pivnet-linux-amd64-3.0.1
chmod 777 pivnet-linux-amd64-3.0.1
cp pivnet-linux-amd64-3.0.1 /usr/local/bin/pivnet
pivnet login --api-token=$token

#### Download TAP 4.0 ####


### download tanzu-CLI -tanzu-framework-linux-amd64.tar
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version='0.4.0' --product-file-id=1100110
### insight insight-1.0.0-beta.2_linux_amd64
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version='0.4.0' --product-file-id=1101070

### GUI catalog:  tap-gui-yelb-catalog.tgz , tap-gui-blank-catalog.tgz
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version='0.4.0' --product-file-id=1073911
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version='0.4.0' --product-file-id=1099786

pivnet download-product-files --product-slug='tanzu-application-platform' --release-version='0.4.0' --product-file-id=1098740




##### confirm K8s cluster requirements before execution ####

echo "Minimum requirements for tap: 4 CPUs , 16 GB RAM and at least 3 nodes"

node=$(kubectl get nodes | awk '{if(NR==2) print $1}')
kubectl describe nodes $node | grep -A 7 Capacity:


read -p "does your Kubernetes cluster meet the requirements? (enter: yes to continue)"
if [ "$REPLY" != "yes" ]; then
   exit
fi

echo "starting installation"

### patch mgmt cluster ###

kubectl config use-context $mgmt_cluster"-admin@"$mgmt_cluster

kubectl patch "app/"$cluster"-kapp-controller" -n default -p '{"spec":{"paused":true}}' --type=merge

kubectl config use-context $cluster"-admin@"$cluster

kubectl create clusterrolebinding default-tkg-admin-privileged-binding --clusterrole=psp:vmware-system-privileged



### create storageclass ###

cat > storage-class.yml << EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: default
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/aws-ebs
EOF

kubectl apply -f storage-class.yml




#### install plugins ###

mkdir tanzu
tar -xvf tanzu-framework-linux-amd64.tar -C tanzu/
cd tanzu
export TANZU_CLI_NO_INIT=true
tanzu plugin delete imagepullsecret
tanzu config set features.global.context-aware-cli-for-plugins false

tanzu plugin install secret --local ./cli
tanzu plugin install accelerator --local ./cli
tanzu plugin install apps --local ./cli
tanzu plugin install package --local ./cli
tanzu plugin install services --local ./cli
cd ..




### cluster prep ###

kubectl create ns tap-install

kubectl delete deployment kapp-controller -n tkg-system
kubectl apply -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/download/v0.29.0/release.yml

kubectl create ns secretgen-controller
kubectl apply -f https://github.com/vmware-tanzu/carvel-secretgen-controller/releases/latest/download/release.yml

#kapp deploy -y -a sg -f https://github.com/vmware-tanzu/carvel-secretgen-controller/releases/download/v0.6.0/release.yml




#### RBAC ####

curl -LJO https://raw.githubusercontent.com/assafsauer/aws-tkg-automation/master/tap/tap-role.yml
kubectl apply -f tap-role.yml -n $tap_namespace


#### validating access /exist script if login fail #####


echo "checking credentials for Tanzu Network and Regsitry"
if docker login -u ${HARBOR_USER} -p ${HARBOR_PWD} ${HARBOR_DOMAIN}; then
  echo "login successful to" ${HARBOR_DOMAIN}  >&2
else
  ret=$?
  echo "########### exist installation , please change credentials for  ${HARBOR_DOMAIN} $ret" >&2
  exit $ret
fi


if docker login -u ${INSTALL_REGISTRY_USERNAME} -p ${INSTALL_REGISTRY_PASSWORD} ${INSTALL_REGISTRY_HOSTNAME}; then
  echo "login successful to" ${INSTALL_REGISTRY_HOSTNAME} >&2
else
  ret=$?
  echo "########### exist installation , please change credentials for ${INSTALL_REGISTRY_HOSTNAME} $ret" >&2
  exit $ret
fi


#### adding secrets #####

tanzu secret registry add tap-registry \
  --username ${INSTALL_REGISTRY_USERNAME} --password ${INSTALL_REGISTRY_PASSWORD} \
  --server ${INSTALL_REGISTRY_HOSTNAME} \
  --export-to-all-namespaces --yes --namespace tap-install

tanzu secret registry add tap-registry-2 \
  --username ${INSTALL_REGISTRY_USERNAME} --password ${INSTALL_REGISTRY_PASSWORD} \
  --server registry.pivotal.io  \
  --export-to-all-namespaces --yes --namespace tap-install

tanzu secret registry add harbor-registry -y \
--username ${HARBOR_USER} --password ${HARBOR_PWD} \
--server ${HARBOR_DOMAIN}  \
 --export-to-all-namespaces --yes --namespace tap-install


### temp workaround for the "ServiceAccountSecretError" issue
kubectl create secret docker-registry registry-credentials --docker-server=${HARBOR_DOMAIN} --docker-username=${HARBOR_USER} --docker-password=${HARBOR_PWD} -n default

echo "your harbor cred"
kubectl get secret registry-credentials --output="jsonpath={.data.\.dockerconfigjson}" | base64 --decode

tanzu package repository add tanzu-tap-repository \
  --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:0.4.0 \
  --namespace tap-install





#### install tap ####

echo "starting installtion in 10 sec (Please be patient as it might take few min to complete)"
sleep 10

tanzu package installed update --install tap -p tap.tanzu.vmware.com -v 0.4.0 -n tap-install --poll-timeout 30m -f tap-values.yml

echo "Cross your fingers and pray , or call Timo"


read -p "ready to test? (enter: yes to continue)"
if [ "$REPLY" != "yes" ]; then
   exit
fi





#### test ####

echo "run test (Please be patient as it might take few min to complete) "

git clone https://github.com/assafsauer/spring-petclinic-accelerators.git

tanzu apps workload create petclinic --local-path spring-petclinic-accelerators  --type web --label app.kubernetes.io/part-of=spring-petclinic-accelerators --source-image source-lab.io/tap/app --yes


tanzu apps workload tail petclinic  & sleep 400 ; kill $!


url=$(tanzu apps workload get petclinic |grep http| awk 'NR=='1'{print $3}')
ingress=$( kubectl get svc -A |grep tanzu-system-ingress |grep LoadBalancer | awk 'NR=='1'{print $5}')
ip=$(nslookup $ingress |grep Address |grep -v 127 | awk '{print $2}')

echo "please update your DNS as follow:"
echo *app.$domain "pointing to" $ip


read -p "ready to test again? (enter: yes to continue)"
if [ "$REPLY" != "yes" ]; then
   exit
fi

curl -k $url

echo "done"
#tanzu apps workload list


#### install TAP GUI ####

read -p "would you like to setup TAP GUI ? (enter: yes to continue)"
if [ "$REPLY" != "yes" ]; then
   exit
fi


tap_domain=$(kubectl get svc -n tap-gui |awk 'NR=='2'{print $4}')

cat > tap-gui-values.yml << EOF

profile: full

buildservice:
  kp_default_repository: $domain/tap/build-service
  kp_default_repository_username: $HARBOR_USER
  kp_default_repository_password: $HARBOR_PWD
  tanzunet_username: $INSTALL_REGISTRY_USERNAME
  tanzunet_password: $INSTALL_REGISTRY_PASSWORD

supply_chain: basic

ootb_supply_chain_basic:
  registry:
    server: $HARBOR_DOMAIN
    repository: "tap/supply-chain"


contour:
  infrastructure_provider: aws
  envoy:
    service:
      aws:
        LBType: nlb

tap_gui:
  service_type: LoadBalancer
  #ingressEnabled: "true"
  #ingressDomain: tap-gui.source-lab.io
  app_config:
    organization:
      name: asauer
    app:
      title: asauer
      baseUrl: http://$tap_domain:7000
    integrations:
      github:
      - host: github.com
        token: $git_token
    catalog:
      locations:
        - type: url
          target: $catalog_info
    backend:
        baseUrl: http://$tap_domain:7000
        cors:
            origin: http://$tap_domain:7000


cnrs:
  domain_name: apps.$domain


image_policy_webhook:
   allow_unmatched_images: true

learningcenter:
  ingressDomain: learn.apps.$domain
  storageClass: "default"

tap_gui:
  service_type: LoadBalancer

ceip_policy_disclosed: true

accelerator:
  service_type: "LoadBalancer"

appliveview:
  connector_namespaces: [default]
  service_type: LoadBalancer

metadata_store:
  app_service_type: LoadBalancer

EOF


tanzu package installed update --install tap -p tap.tanzu.vmware.com -v 0.4.0 -n tap-install --poll-timeout 30m -f tap-gui-values.yml

sleep 30

echo "done,  It might take few minutes to complete "
