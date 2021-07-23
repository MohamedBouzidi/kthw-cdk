#!/bin/bash

## Replace APILBNAME
## Replace PODCIDR
## Replace INSTANCE
## Replace LOCALIP
## Replace WORKER_NAMES
## Replace CONTROLLER_NAMES

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

## Install mod for DNS
modprobe br_netfilter

## Add node names
echo CONTROLLER_NAMES >> /etc/hosts
echo WORKER_NAMES >> /etc/hosts

## generate ssl
cat > INSTANCE-csr.json <<EOF
{
  "CN": "system:node:INSTANCE",
  "key": {
    "algo": "rsa",
    "size": 2048
},
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
}
  ]
}
EOF

cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
},
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
}
  ]
}
EOF

cat > generateSSL.sh <<EOS
## Set Workdir
cd /home/ubuntu

EXTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=INSTANCE,${EXTERNAL_IP},LOCALIP \
  -profile=kubernetes \
  INSTANCE-csr.json | cfssljson -bare INSTANCE

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy
EOS
chmod +x generateSSL.sh

## generate kubeconfig
cat > generateKubeconfig.sh <<'EOS'
## Set Workdir
cd /home/ubuntu

API_LB=$(aws ec2 describe-instances \
--filters "Name=tag:Name,Values=APILBNAME" "Name=instance-state-name,Values=running" \
--query "Reservations[0].Instances[0].PublicIpAddress" | sed 's/"//g')

echo API_LB=$API_LB

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://${API_LB}:6443 \
  --kubeconfig=INSTANCE.kubeconfig

kubectl config set-credentials system:node:INSTANCE \
  --client-certificate=INSTANCE.pem \
  --client-key=INSTANCE-key.pem \
  --embed-certs=true \
  --kubeconfig=INSTANCE.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=system:node:INSTANCE \
  --kubeconfig=INSTANCE.kubeconfig

kubectl config use-context default --kubeconfig=INSTANCE.kubeconfig

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://${API_LB}:6443 \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
  --client-certificate=kube-proxy.pem \
  --client-key=kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=system:kube-proxy \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

sudo mkdir -p /var/lib/kube-proxy
sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
EOS
chmod +x generateKubeconfig.sh

## configure CNI
sudo mkdir -p /etc/cni/net.d/
cat <<EOF | sudo tee /etc/cni/net.d/10-bridge.conf
{
    "cniVersion": "0.4.0",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
    "type": "host-local",
    "ranges": [
      [{"subnet": "PODCIDR"}]
    ],
    "routes": [{"dst": "0.0.0.0/0"}]
  }
}
EOF

cat <<EOF | sudo tee /etc/cni/net.d/99-loopback.conf
{
    "cniVersion": "0.4.0",
    "name": "lo",
    "type": "loopback"
}
EOF

sudo mkdir -p /etc/containerd/
cat << EOF | sudo tee /etc/containerd/config.toml
[plugins]
  [plugins.cri.containerd]
    snapshotter = "overlayfs"
    [plugins.cri.containerd.default_runtime]
      runtime_type = "io.containerd.runtime.v1.linux"
      runtime_engine = "/usr/local/bin/runc"
      runtime_root = ""
EOF

cat <<EOF | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/lib/kubelet/
cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
podCIDR: "PODCIDR"
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/INSTANCE.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/INSTANCE-key.pem"
EOF

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime=remote \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --hostname-override=INSTANCE \\
  --image-pull-progress-deadline=2m \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --network-plugin=cni \\
  --register-node=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## configure kube-proxy
mkdir -p /var/lib/kube-proxy/
cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
EOF

cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml \\
  --hostname-override=INSTANCE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## install tools
cat > startServices.sh <<EOS
## Set Workdir
cd /home/ubuntu

sudo apt-get update
sudo apt-get -y install socat conntrack ipset

## disable swap
sudo swapon --show && sudo swapoff -a

## download binaries
wget -q --timestamping \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.21.0/crictl-v1.21.0-linux-amd64.tar.gz \
  https://github.com/opencontainers/runc/releases/download/v1.0.0-rc93/runc.amd64 \
  https://github.com/containernetworking/plugins/releases/download/v0.9.1/cni-plugins-linux-amd64-v0.9.1.tgz \
  https://github.com/containerd/containerd/releases/download/v1.4.4/containerd-1.4.4-linux-amd64.tar.gz \
  https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kubectl \
  https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kube-proxy \
  https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kubelet

## install binaries
sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

mkdir containerd
tar -xvf crictl-v1.21.0-linux-amd64.tar.gz
tar -xvf containerd-1.4.4-linux-amd64.tar.gz -C containerd
sudo tar -xvf cni-plugins-linux-amd64-v0.9.1.tgz -C /opt/cni/bin/
sudo mv runc.amd64 runc
chmod +x crictl kubectl kube-proxy kubelet runc
sudo mv crictl kubectl kube-proxy kubelet runc /usr/local/bin/
sudo mv containerd/bin/* /bin/

## configure containerd
sudo mkdir -p /etc/containerd/

## configure kubelet
sudo mv INSTANCE-key.pem INSTANCE.pem /var/lib/kubelet/
sudo mv INSTANCE.kubeconfig /var/lib/kubelet/kubeconfig
sudo mv ca.pem /var/lib/kubernetes/

## start services
sudo systemctl daemon-reload
sudo systemctl enable containerd kubelet kube-proxy
sudo systemctl start containerd kubelet kube-proxy
EOS
chmod +x startServices.sh
