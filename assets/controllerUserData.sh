#!/bin/bash

## Replace APILBNAME
## Replace CONTROLLERIPS
## Replace LOCALIP
## Replace INSTANCE
## Replace ETCDINITIAL
## Replace ETCDCLUSTER
## Replace BUCKET_NAME
## Replace CONTROLLER_NAMES
## Replace WORKER_NAMES

## Set Workdir
cd /home/ubuntu

## Install AWSCLI
sudo apt-get update -y
sudo apt-get install -y unzip
curl -o "awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
unzip awscliv2.zip > /dev/null
sudo ./aws/install

## Download tools
wget -q --timestamping \
	https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssl \
	https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssljson
chmod +x cfssl cfssljson
sudo mv cfssl cfssljson /usr/local/bin/
wget https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kubectl
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

## Configure bridged traffic
modprobe br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo sysctl --system

## Add node names
cat <<EOF >> /etc/hosts
CONTROLLER_NAMES
EOF

cat <<EOF >> /etc/hosts
WORKER_NAMES
EOF

## generate ssl
cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
},
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
}
  ]
}
EOF

cat > kube-controller-manager-csr.json <<EOF
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cat > kube-scheduler-csr.json <<EOF
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cat > service-account-csr.json <<EOF
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cat > generateSSL.sh <<EOF
## Set Workdir
cd /home/ubuntu

cfssl gencert \\
  -ca=ca.pem \\
  -ca-key=ca-key.pem \\
  -config=ca-config.json \\
  -profile=kubernetes \\
  admin-csr.json | cfssljson -bare admin

cfssl gencert \\
  -ca=ca.pem \\
  -ca-key=ca-key.pem \\
  -config=ca-config.json \\
  -profile=kubernetes \\
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

cfssl gencert \\
  -ca=ca.pem \\
  -ca-key=ca-key.pem \\
  -config=ca-config.json \\
  -profile=kubernetes \\
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler

cfssl gencert \\
  -ca=ca.pem \\
  -ca-key=ca-key.pem \\
  -config=ca-config.json \\
  -profile=kubernetes \\
  service-account-csr.json | cfssljson -bare service-account
EOF
chmod +x generateSSL.sh

## generate kubeconfig
cat > generateKubeconfig.sh <<EOF
## Set Workdir
cd /home/ubuntu

kubectl config set-cluster kubernetes-the-hard-way \\
  --certificate-authority=ca.pem \\
  --embed-certs=true \\
  --server=https://127.0.0.1:6443 \\
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \\
  --client-certificate=kube-controller-manager.pem \\
  --client-key=kube-controller-manager-key.pem \\
  --embed-certs=true \\
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-context default \\
  --cluster=kubernetes-the-hard-way \\
  --user=system:kube-controller-manager \\
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-cluster kubernetes-the-hard-way \\
  --certificate-authority=ca.pem \\
  --embed-certs=true \\
  --server=https://127.0.0.1:6443 \\
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \\
  --client-certificate=kube-scheduler.pem \\
  --client-key=kube-scheduler-key.pem \\
  --embed-certs=true \\
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-context default \\
  --cluster=kubernetes-the-hard-way \\
  --user=system:kube-scheduler \\
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-cluster kubernetes-the-hard-way \\
  --certificate-authority=ca.pem \\
  --embed-certs=true \\
  --server=https://127.0.0.1:6443 \\
  --kubeconfig=admin.kubeconfig

kubectl config set-credentials admin \\
  --client-certificate=admin.pem \\
  --client-key=admin-key.pem \\
  --embed-certs=true \\
  --kubeconfig=admin.kubeconfig

kubectl config set-context default \\
  --cluster=kubernetes-the-hard-way \\
  --user=admin \\
  --kubeconfig=admin.kubeconfig

kubectl config use-context default --kubeconfig=admin.kubeconfig

sudo mkdir -p /var/lib/kubernetes/
sudo mv kube-controller-manager.kubeconfig kube-scheduler.kubeconfig /var/lib/kubernetes/

mkdir -p /home/ubuntu/.kube
cp /home/ubuntu/admin.kubeconfig /home/ubuntu/.kube/config
EOF
chmod +x generateKubeconfig.sh

## configure etcd
INTERNAL_IP=LOCALIP
ETCD_NAME=INSTANCE
cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreoF

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster ETCDINITIAL \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > installEtcd.sh <<EOF
## Set Workdir
cd /home/ubuntu

wget -q --timestamping \\
  "https://github.com/etcd-io/etcd/releases/download/v3.4.15/etcd-v3.4.15-linux-amd64.tar.gz"
tar -xvf etcd-v3.4.15-linux-amd64.tar.gz > /dev/null
sudo mv etcd-v3.4.15-linux-amd64/etcd* /usr/local/bin/
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd
sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
EOF
chmod +x installEtcd.sh

## configure controller-manager
cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.200.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## configure scheduler
sudo mkdir -p /etc/kubernetes/config
cat <<EOF | sudo tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1beta1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF

cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## download binaries
wget -q --timestamping \
	"https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kube-apiserver" \
	"https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kube-controller-manager" \
	"https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kube-scheduler" \
	"https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kubectl"
chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/

cat > startServices.sh <<EOS
## Set Workdir
cd /home/ubuntu

sudo mkdir -p /var/lib/kubernetes/
sudo mv ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \\
service-account-key.pem service-account.pem encryption-config.yaml /var/lib/kubernetes/

## configure apiserver
INTERNAL_IP=LOCALIP
API_LB=$(aws ec2 describe-instances \
--filters "Name=tag:Name,Values=APILBNAME" "Name=instance-state-name,Values=running" \
--query "Reservations[0].Instances[0].PublicIpAddress" | sed 's/"//g')

cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=ETCDCLUSTER \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-account-issuer=https://${API_LB}:6443 \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## start services
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
EOS
chmod +x startServices.sh

## Set Workdir
cd /home/ubuntu

cat > enableKubeletAuth.sh <<EOF
## Set Workdir
cd /home/ubuntu

kubectl --kubeconfig admin.kubeconfig create clusterrolebinding kubernetes-admin --clusterrole="cluster-admin" --user="kubernetes"
kubectl --kubeconfig admin.kubeconfig create clusterrolebinding apiserver-admin --clusterrole="cluster-admin" --user="Kubernetes"
EOF
chmod +x enableKubeletAuth.sh

cat > installDNS.sh <<EOF
## Set Workdir
cd /home/ubuntu
kubectl --kubeconfig admin.kubeconfig apply -f coredns.yaml
EOF
chmod +x installDNS.sh
