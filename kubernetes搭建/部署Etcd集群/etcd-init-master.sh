cd ~
mkdir cfssl && cd cfssl/
wget https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
wget https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
wget https://pkg.cfssl.org/R1.2/cfssl-certinfo_linux-amd64
chmod +x cfssl_linux-amd64 cfssljson_linux-amd64 cfssl-certinfo_linux-amd64
mv cfssl_linux-amd64 /usr/local/bin/cfssl
mv cfssljson_linux-amd64 /usr/local/bin/cfssljson
mv cfssl-certinfo_linux-amd64 /usr/bin/cfssl-certinfo

mkdir -pv /data/apps/etcd/{ssl,bin,etc,data} && cd /data/apps/etcd/ssl

cat > ca-config.json << EOF
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "kubernetes": {
        "expiry": "87600h",
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ]
      }
    }
  }
}
EOF


# 生成 CA 证书请求文件， ST/L/字段可自行修改
cat > etcd-ca-csr.json << EOF
{
  "CN": "etcd",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "Beijing",
      "ST": "Beijing",
      "O": "etcd",
      "OU": "Etcd Security"
    }
  ]
}
EOF

# 生成证书请求文件，ST/L/字段可自行修改
# 上述文件hosts字段中IP为所有etcd节点的集群内部通信IP，一个都不能少！为了方便后期扩容可以多写几个预留的IP。
cat > etcd-csr.json << EOF
{
  "CN": "etcd",
  "hosts": [
    "127.0.0.1",
    "192.168.10.162",
    "192.168.10.163",
    "192.168.10.164",
    "192.168.10.190",
    "192.168.10.191",
    "192.168.10.192",
    "192.168.10.193"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing",
      "ST": "BeiJing",
      "O": "etcd",
      "OU": "Etcd Security"
    }
  ]
}
EOF

cfssl gencert -initca etcd-ca-csr.json | cfssljson -bare etcd-ca
cfssl gencert -ca=etcd-ca.pem -ca-key=etcd-ca-key.pem -config=ca-config.json  -profile=kubernetes  etcd-csr.json | cfssljson -bare etcd


cat > /usr/lib/systemd/system/kube-controller-manager.service << EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kube-controller-manager.conf
ExecStart=/data/apps/kubernetes/server/bin/kube-controller-manager \\
\$KUBE_LOGTOSTDERR \\
\$KUBE_LOG_LEVEL \\
\$KUBECONFIG \\
\$KUBE_CONTROLLER_MANAGER_ARGS
Restart=always
RestartSec=10s
#Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF



cat > /usr/lib/systemd/system/kube-controller-manager.service << EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kube-controller-manager.conf
ExecStart=/data/apps/kubernetes/server/bin/kube-controller-manager \$KUBE_CONTROLLER_MANAGER_OPTS
#Restart=always
RestartSec=10s
#Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl restart kube-controller-manager && systemctl status kube-controller-manager -l
journalctl -xeu kube-controller-manager
cat > /data/apps/kubernetes/etc/kube-controller-manager.conf << EOF
KUBE_LOGTOSTDERR="--logtostderr=false"
KUBE_LOG_LEVEL="--v=2 --log-dir=/data/apps/kubernetes/log/"
KUBECONFIG="--kubeconfig=/data/apps/kubernetes/etc/admin.conf"
KUBE_CONTROLLER_MANAGER_ARGS="--bind-address=127.0.0.1 \
--cluster-cidr=10.0.0.0/16 \
--cluster-name=kubernetes \
--cluster-signing-cert-file=/data/apps/kubernetes/pki/ca.pem \
--cluster-signing-key-file=/data/apps/kubernetes/pki/ca-key.pem \
--service-account-private-key-file=/data/apps/kubernetes/pki/sa.key \
--root-ca-file=/data/apps/kubernetes/pki/ca.pem \
--leader-elect=true \
--use-service-account-credentials=true \
--node-monitor-grace-period=100s \
--pod-eviction-timeout=100s \
--allocate-node-cidrs=true \
--controllers=*,bootstrapsigner,tokencleaner \
--horizontal-pod-autoscaler-use-rest-clients=true \
--experimental-cluster-signing-duration=87600h0m0s"
EOF

cat > /data/apps/kubernetes/etc/kube-controller-manager.conf << EOF
KUBE_CONTROLLER_MANAGER_OPTS="--kubeconfig=/data/apps/kubernetes/etc/kube-controller-manager.kubeconfig \\
  --authentication-kubeconfig=/data/apps/kubernetes/etc/kube-controller-manager.kubeconfig \\
  --allocate-node-cidrs=true \\
  --service-cluster-ip-range=10.99.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/data/apps/kubernetes/pki/ca.pem \\
  --cluster-signing-key-file=/data/apps/kubernetes/pki/ca-key.pem \\
  --cluster-cidr=10.88.0.0/16 \\
  --cluster-signing-duration=87600h \\
  --root-ca-file=/data/apps/kubernetes/pki/ca.pem \\
  --service-account-private-key-file=/data/apps/kubernetes/pki/ca-key.pem \\
  --leader-elect=true \\
  --feature-gates=RotateKubeletServerCertificate=true \\
  --controllers=*,bootstrapsigner,tokencleaner \\
  --tls-cert-file=/data/apps/kubernetes/pki/kube-controller-manager.pem \\
  --tls-private-key-file=/data/apps/kubernetes/pki/kube-controller-manager-key.pem \\
  --use-service-account-credentials=true \\
  --alsologtostderr=true \\
  --logtostderr=false \\
  --log-dir=/data/apps/kubernetes/log/controller-manager \\
  --v=2"
EOF

cat > /data/apps/kubernetes/etc/kube-apiserver.conf << EOF
KUBE_APISERVER_OPTS="--enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \
  --anonymous-auth=false \
  --bind-address=192.168.10.162 \
  --secure-port=6443 \
  --advertise-address=192.168.10.162 \
  --insecure-port=0 \
  --authorization-mode=Node,RBAC \
  --enable-bootstrap-token-auth \
  --service-cluster-ip-range=10.99.0.0/16 \
  --token-auth-file=/data/apps/kubernetes/etc/token.csv \
  --service-node-port-range=30000-50000 \
  --tls-cert-file=/data/apps/kubernetes/pki/kube-apiserver.pem  \
  --tls-private-key-file=/data/apps/kubernetes/pki/kube-apiserver-key.pem \
  --client-ca-file=/data/apps/kubernetes/pki/ca.pem \
  --kubelet-client-certificate=/data/apps/kubernetes/pki/admin.pem \
  --kubelet-client-key=/data/apps/kubernetes/pki/admin-key.pem \
  --service-account-key-file=/data/apps/kubernetes/pki/ca.pem \
  --service-account-signing-key-file=/data/apps/kubernetes/pki/ca-key.pem  \
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \
  --etcd-cafile=/data/apps/etcd/ssl/etcd-ca.pem \
  --etcd-certfile=/data/apps/etcd/ssl/etcd.pem \
  --etcd-keyfile=/data/apps/etcd/ssl/etcd-key.pem \
  --etcd-servers=https://192.168.10.162:2379,https://192.168.10.190:2379,https://192.168.10.191:2379 \
  --enable-swagger-ui=true \
  --allow-privileged=true \
  --apiserver-count=1 \
  --audit-log-maxage=30 \
  --audit-log-maxbackup=3 \
  --audit-log-maxsize=100 \
  --audit-log-path=/data/apps/kubernetes/log/kubernetes.audit \
  --event-ttl=12h \
  --alsologtostderr=true \
  --logtostderr=false \
  --log-dir=/data/apps/kubernetes/log/apiserver \
  --runtime-config=api/all=true \
  --requestheader-allowed-names=aggregator \
  --requestheader-group-headers=X-Remote-Group \
  --requestheader-username-headers=X-Remote-User \
  --requestheader-extra-headers-prefix=X-Remote-Extra- \
  --requestheader-client-ca-file=/data/apps/kubernetes/pki/ca.pem \
  --proxy-client-cert-file=/data/apps/kubernetes/pki/proxy-client.pem \
  --proxy-client-key-file=/data/apps/kubernetes/pki/proxy-client-key.pem \
  --v=4 "
EOF
