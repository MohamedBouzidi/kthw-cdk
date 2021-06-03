#!/bin/bash

## Replace KEY_NAME
## Replace BUCKET_NAME
## Replace WORKERS
## Replace CONTROLLERS
## Replace CONTROLLERIPS
## Replace NGINXBACKEND

## Set Workdir
cd /home/ubuntu

## Install AWSCLI
sudo apt-get update -y
sudo apt-get install -y unzip
curl -o "awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
unzip awscliv2.zip > /dev/null
sudo ./aws/install

## Download Key
aws s3 cp s3://BUCKET_NAME/KEY_NAME KEY_NAME
chmod 400 KEY_NAME

## Download tools
wget -q --timestamping \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssl \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssljson
chmod +x cfssl cfssljson
sudo mv cfssl cfssljson /usr/local/bin/
wget https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kubectl
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

## Generate SSL
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
},
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
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

API_LB=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
KUBERNETES_HOSTNAMES=kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local

cfssl gencert \
        -ca=ca.pem \
        -ca-key=ca-key.pem \
        -config=ca-config.json \
        -hostname=10.32.0.1,CONTROLLERIPS,${API_LB},127.0.0.1,${KUBERNETES_HOSTNAMES} \
        -profile=kubernetes \
        kubernetes-csr.json | cfssljson -bare kubernetes

## create encryption config
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

## configure controllers
for instance in CONTROLLERS; do
        name=$(echo ${instance} | cut -d= -f1)
        address=$(echo ${instance} | cut -d= -f2)
        scp -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ca.pem ca-key.pem ca-config.json \
                kubernetes.pem kubernetes-key.pem encryption-config.yaml ubuntu@${address}:~/
        ssh -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ubuntu@${address} /home/ubuntu/generateSSL.sh
        ssh -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ubuntu@${address} /home/ubuntu/generateKubeconfig.sh
        ssh -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ubuntu@${address} /home/ubuntu/installEtcd.sh
        ssh -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ubuntu@${address} /home/ubuntu/startServices.sh
done

controller0=$(echo CONTROLLERS | cut -d' ' -f1 | cut -d= -f2)
ssh -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ubuntu@$controller0 /home/ubuntu/enableKubeletAuth.sh

## configure api load balancer
sudo apt-get update -y
sudo apt-get install -y nginx
# in the nginx config, use kubernetes.pem instead of ca.pem
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
        worker_connections 768;
        # multi_accept on;
}

http {

        upstream apiserver {
                NGINXBACKEND
        }

        server {
                listen 6443 ssl;
                server_name kubernetes.default.svc.cluster.local;

                ssl_certificate         /home/ubuntu/kubernetes.pem;
                ssl_certificate_key     /home/ubuntu/kubernetes-key.pem;

                location / {
                        proxy_pass                      https://apiserver;
                        proxy_ssl_certificate           /home/ubuntu/ca.pem;
                        proxy_ssl_certificate_key       /home/ubuntu/ca-key.pem;
                }
        }

        ##
        # Basic Settings
        ##

        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        keepalive_timeout 65;
        types_hash_max_size 2048;
        # server_tokens off;

        # server_names_hash_bucket_size 64;
        # server_name_in_redirect off;

        include /etc/nginx/mime.types;
        default_type application/octet-stream;

        ##
        # SSL Settings
        ##

        ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3; # Dropping SSLv3, ref: POODLE
        ssl_prefer_server_ciphers on;

        ##
        # Logging Settings
        ##

        access_log /var/log/nginx/access.log;
        error_log /var/log/nginx/error.log;

        ##
        # Gzip Settings
        ##

        gzip on;

        # gzip_vary on;
        # gzip_proxied any;
        # gzip_comp_level 6;
        # gzip_buffers 16 8k;
        # gzip_http_version 1.1;
        # gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

        ##
        # Virtual Host Configs
        ##

        include /etc/nginx/conf.d/*.conf;
        include /etc/nginx/sites-enabled/*;
}
EOF
nginx -t
systemctl restart nginx
systemctl enable nginx

## configure workers
for instance in WORKERS; do
        name=$(echo ${instance} | cut -d= -f1)
        address=$(echo ${instance} | cut -d= -f2)
        scp -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ca.pem ca-key.pem ca-config.json ubuntu@${address}:~/
        ssh -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ubuntu@${address} /home/ubuntu/generateSSL.sh
        ssh -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ubuntu@${address} /home/ubuntu/generateKubeconfig.sh
        ssh -i /home/ubuntu/KEY_NAME -o StrictHostKeyChecking=no ubuntu@${address} /home/ubuntu/startServices.sh
done
