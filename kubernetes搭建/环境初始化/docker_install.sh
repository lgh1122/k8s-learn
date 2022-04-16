sudo yum update -y

sudo yum remove docker  docker-common docker-selinux docker-engine

sudo yum install -y yum-utils device-mapper-persistent-data lvm2

#sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
#yum-config-manager --add-repo http://download.docker.com/linux/centos/docker-ce.repo #（中央仓库）

yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo #（阿里仓库）
# yum list docker-ce --showduplicates | sort -r

# https://download.docker.com/linux/static/stable/x86_64/docker-20.10.9.tgz
sudo yum -y install docker-ce-20.10.9-3.el7


## 修改Cgroup Driver为 systemd
mkdir /etc/docker/ -p
touch /etc/docker/daemon.json
cat > /etc/docker/daemon.json <<EOF
{
    "registry-mirrors": ["http://hub-mirror.c.163.com"],
    "log-driver": "json-file",
    "storage-driver": "overlay2"
}
EOF

systemctl daemon-reload
systemctl restart docker
systemctl enable docker
echo " docker install success"