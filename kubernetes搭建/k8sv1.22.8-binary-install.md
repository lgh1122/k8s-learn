



# 一、环境规划
## 1.1 服务器环境

|K8S集群角色	|Ip	|主机名|	安装的组件|
| -------- | ------------| ------------ | ---- |
|控制节点	|192.168.10.162|	k8s-master01|	etcd、docker、kube-apiserver、kube-controller-manager、kube-scheduler、kube-proxy、kubelet、flanneld、keepalived、nginx|
|控制节点	|192.168.10.163|	k8s-master02|	etcd、docker、kube-apiserver、kube-controller-manager、kube-scheduler、kube-proxy、kubelet、flanneld、keepalived、nginx|
|工作节点	|192.168.10.190|	k8s-node01|	etcd、docker、kubelet、kube-proxy、flanneld、coredns|
|工作节点	|192.168.10.191|	k8s-node02  |etcd、docker、kubelet、kube-proxy、flanneld、coredns |
|负载均衡器|192.168.10.88|    k8s-master-lb  | keepalived虚拟IP Vip |

考虑电脑配置问题，一次性开四台机器会跑不动，
所以搭建这套K8s高可用集群分两部分实施，先部署一套单Master架构（3台），
再扩容为多Master架构（4台或6台），顺便再熟悉下Master扩容流程
k8s-master2 暂不部署
keepalived、nginx 组件非高可用架构也不需要

## 1.2 系统配置

    操作系统：CentOS Linux release 7.9.2009 (Core)
    系统用户：root
    密码：root
    配置： 2Gib内存/2vCPU/20G硬盘
    网络：Vmware NAT模式
    k8s版本：v1.22.8
    etcd版本：v3.5.1
    flanneld版本：v0.17.0
    docker版本：20.10.9
    宿主机网段：10.168.10.0/16
    Pod网段：10.88.0.0/16
    Service网段：10.99.0.0/16
宿主机网段、K8s Service网段、Pod网段不能重复
VIP（虚拟IP）不要和公司内网IP重复，首先去ping一下，不通才可用。VIP需要和主机在同一个局域网内
公有云上搭建VIP是公有云的负载均衡的IP，比如阿里云的内网SLB的地址，腾讯云内网ELB的地址


# 二、环境初始化
## 2.1 配置hosts文件
```powershell
cat >> /etc/hosts << EOF
192.168.10.162 k8s-master01
192.168.10.163 k8s-master02
192.168.10.88  k8s-master-lb # 如果不是高可用集群，该IP为Master01的IP
192.168.10.190 k8s-node01
192.168.10.191 k8s-node02

192.168.10.162 etcd-01
192.168.10.190 etcd-02
192.168.10.191 etcd-03
EOF
```



## 2.2 配置主机之间无密码登录
```powershell

# 生成ssh 密钥对,一路回车，不输入密码
ssh-keygen -t rsa

# 把本地的ssh公钥文件安装到远程主机对应的账户
ssh-copy-id -i .ssh/id_rsa.pub k8s-master01
ssh-copy-id -i .ssh/id_rsa.pub k8s-master02
ssh-copy-id -i .ssh/id_rsa.pub k8s-node01
ssh-copy-id -i .ssh/id_rsa.pub k8s-node01

```



## 2.3 系统环境初始化
### 关闭selinux 阿里云ECS默认关闭
```powershell
sed -i 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
```
### 时间同步
```powershell
yum install ntpdate -y
ntpdate time1.aliyun.com
# 把时间同步做成计划任务
crontab -e
#增加以下任务
    * */1 * * * /usr/sbin/ntpdate   time1.aliyun.com
# 重启crond服务
systemctl restart crond
```
### 关闭交换分区swap 阿里云ECS默认关闭
```powershell
#临时关闭
# swapoff -a
#永久关闭 注意：如果是克隆的虚拟机，需要删除UUID一行
mv /etc/fstab /etc/fstab.bak
cat /etc/fstab.bak |grep -v swap >> /etc/fstab
```
### 防火墙设置
```powershell
systemctl disable firewalld
systemctl stop firewalld
```
### 安装基础软件包
```powershell
yum install -y yum-utils device-mapper-persistent-data lvm2 wget net-tools nfs-utils lrzsz gcc gcc-c++ make cmake libxml2-devel openssl-devel curl curl-devel unzip sudo ntp libaio-devel wget vim ncurses-devel autoconf automake zlib-devel  python-devel epel-release openssh-server socat  ipvsadm conntrack ntpdate telnet rsync
```
### 安装iptables
```powershell
yum -y install iptables-services
systemctl enable iptables
systemctl start iptables

iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
iptables -P FORWARD ACCEPT
service iptables save
```
### 修改内核参数
```powershell
# 1、加载br_netfilter模块
modprobe br_netfilter
# 2、验证模块是否加载成功
lsmod |grep br_netfilter
# 网桥过滤
cat >> /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
EOF
# 4、使刚才修改的内核参数生效
sysctl -p /etc/sysctl.d/k8s.conf
```
#### 说明
    问题一：sysctl是做什么的？
        # 在运行时配置内核参数
        -p   从指定的文件加载系统参数，如不指定即从/etc/sysctl.conf中加载
    问题二：为什么要执行modprobe br_netfilter？

        修改/etc/sysctl.d/k8s.conf文件，增加如下三行参数：
        net.bridge.bridge-nf-call-ip6tables = 1
        net.bridge.bridge-nf-call-iptables = 1
        net.ipv4.ip_forward = 1
    
        # sysctl -p /etc/sysctl.d/k8s.conf出现报错：
        sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-ip6tables: No such file or directory
        sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory
    
        # 解决方法：
        modprobe br_netfilter
    问题三：为什么开启net.bridge.bridge-nf-call-iptables内核参数？
        # 在centos下安装docker，执行docker info出现如下警告：
        WARNING: bridge-nf-call-iptables is disabled
        WARNING: bridge-nf-call-ip6tables is disabled

        # 解决办法：
        vim  /etc/sysctl.d/k8s.conf
        net.bridge.bridge-nf-call-ip6tables = 1
        net.bridge.bridge-nf-call-iptables = 1
    问题四：为什么要开启net.ipv4.ip_forward = 1参数？
        kubeadm初始化k8s如果报错如下，说明没有开启ip_forward，需要开启
        /proc/sys/net/ipv4/ip_forward contents are not set to 1
        # net.ipv4.ip_forward是数据包转发：
        1)出于安全考虑，Linux系统默认是禁止数据包转发的。所谓转发即当主机拥有多于一块的网卡时，其中一块收到数据包，
        根据数据包的目的ip地址将数据包发往本机另一块网卡，该网卡根据路由表继续发送数据包。这通常是路由器所要实现的功能。
        2)要让Linux系统具有路由转发功能，需要配置一个Linux的内核参数net.ipv4.ip_forward。这个参数指定了Linux系统
        当前对路由转发功能的支持情况；其值为0时表示禁止进行IP转发；如果是1,则说明IP转发功能已经打开。

### 配置阿里云repo源
暂未验证
```powershell
# 备份
mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.backup
# 下载新的CentOS-Base.repo
wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
# 生成缓存
yum clean all && yum makecache
```
### 开启ipvs
不开启ipvs将会使用iptables进行数据包转发，但是效率低，所以官网推荐需要开通ipvs。
暂未验证
```powershell
#安装 conntrack-tools
yum install ipvsadm ipset sysstat conntrack libseccomp -y

cat >> /etc/modules-load.d/ipvs.conf <<EOF 
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
ip_tables
ip_set
xt_set
ipt_set
ipt_rpfilter
ipt_REJECT
ipip
EOF
systemctl restart systemd-modules-load.service

lsmod | grep -e ip_vs -e nf_conntrack
    ip_vs_sh               16384  0
    ip_vs_wrr              16384  0
    ip_vs_rr               16384  0
    ip_vs                 180224  6 ip_vs_rr,ip_vs_sh,ip_vs_wrr
    nf_conntrack          176128  1 ip_vs
    nf_defrag_ipv6         24576  2 nf_conntrack,ip_vs
    nf_defrag_ipv4         16384  1 nf_conntrack
    libcrc32c              16384  3 nf_conntrack,xfs,ip_vs

```

### 安装docker
```powershell
sudo yum update -y
sudo yum remove docker  docker-common docker-selinux docker-engine
sudo yum install -y yum-utils device-mapper-persistent-data lvm2
#sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
#yum-config-manager --add-repo http://download.docker.com/linux/centos/docker-ce.repo #（中央仓库）
yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo #（阿里仓库）
# yum list docker-ce --showduplicates | sort -r
# https://download.docker.com/linux/static/stable/x86_64/docker-20.10.9.tgz
sudo yum -y install docker-ce-20.10.9-3.el7

# kubelet Cgroup Driver默认使用systemd， 若使用默认的，则需要修改docker文件驱动为systemd 默认为cgroupfs， 两者必须一致才可以
mkdir /etc/docker/ -p
touch /etc/docker/daemon.json
#"exec-opts": ["native.cgroupdriver=systemd"]
cat > /etc/docker/daemon.json <<EOF
{
"registry-mirrors": ["https://rsbud4vc.mirror.aliyuncs.com","https://registry.docker-cn.com","https://docker.mirrors.ustc.edu.cn","http://hub-mirror.c.163.com","http://qtid6917.mirror.aliyuncs.com", "https://rncxm540.mirror.aliyuncs.com"],
"log-driver": "json-file",
"storage-driver": "overlay2"
}
EOF

systemctl daemon-reload && systemctl restart docker && systemctl enable docker

```
### 目录生成
```powershell
mkdir -pv /data/apps/etcd/{ssl,bin,etc,data} && cd /data/apps/etcd/ssl
mkdir -pv /data/apps/kubernetes/{pki,log,etc,certs}
mkdir -pv /data/apps/kubernetes/log/{apiserver,controller-manager,scheduler,kubelet,kube-proxy}
```
# 三、etcd集群部署
Etcd 是一个分布式键值存储系统，Kubernetes使用Etcd进行数据存储，
所以先准备一个Etcd数据库，为解决Etcd单点故障，
应采用集群方式部署，这里使用3台组建集群，可容忍1台机器故障，
当然，你也可以使用5台组建集群，可容忍2台机器故障。
## 3.1 环境说明
### 集群环境
为了节省机器，这里与K8s节点机器复用。
也可以独立于k8s集群之外部署，只要apiserver能连接到就行

| 节点名称  | ipaddr       |
| --------| ------------ |
| etcd-01   | 192.168.10.162 |
| etcd-02   | 192.168.10.190 |
| etcd-03   | 192.168.10.191 |

### 准备证书生成工具
只需要在一台机器执行 etcd-01 机器执行
```powershell
#etcd-01安装签发证书工具cfssl
mkdir /root/cfssl -p && cd /root/cfssl
wget https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
wget https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
wget https://pkg.cfssl.org/R1.2/cfssl-certinfo_linux-amd64
chmod +x cfssl_linux-amd64 cfssljson_linux-amd64 cfssl-certinfo_linux-amd64
mv cfssl_linux-amd64 /usr/local/bin/cfssl
mv cfssljson_linux-amd64 /usr/local/bin/cfssljson
mv cfssl-certinfo_linux-amd64 /usr/local/bin/cfssl-certinfo
```
## 3.2 生成证书
### 准备工作
```powershell
mkdir -pv /root/etcd-ssl/ && cd /root/etcd-ssl/
```
### 生成 CA 证书
expiry 为证书过期时间(10 年)
```powershell
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
#生成证书
cfssl gencert -initca etcd-ca-csr.json | cfssljson -bare etcd-ca
#生成 server.pem server-key.pem
cfssl gencert -ca=etcd-ca.pem -ca-key=etcd-ca-key.pem -config=ca-config.json  -profile=kubernetes  etcd-csr.json | cfssljson -bare etcd
```
###复制证书到部署目录
所有etcd集群节点
/data/apps/目录需要提前在其他etcd节点行创建
```powershell
mkdir -pv /data/apps/etcd/{ssl,bin,etc,data}
cp etcd*.pem /data/apps/etcd/ssl
scp -r /data/apps/etcd 192.168.10.190:/data/apps/
scp -r /data/apps/etcd 192.168.10.191:/data/apps/
```

## 3.3 安装etcd集群
### 下载etcd二进制包

下载地址 https://github.com/etcd-io/etcd/releases/
```powershell
cd ~
wget https://github.com/etcd-io/etcd/releases/download/v3.5.1/etcd-v3.5.1-linux-amd64.tar.gz
tar zxf etcd-v3.5.1-linux-amd64.tar.gz
cp etcd-v3.5.1-linux-amd64/etcd* /data/apps/etcd/bin/
#拷贝到其他节点
scp -r etcd-v3.5.1-linux-amd64/etcd* 192.168.10.190:/data/apps/etcd/bin/
scp -r etcd-v3.5.1-linux-amd64/etcd* 192.168.10.191:/data/apps/etcd/bin/
```

### 创建etcd配置文件
```powershell
# 这里的 etcd 虚拟机都有两个网卡，一个用于提供服务，另一个用于集群通信
#0.0.0.0 后续需要替换为当前节点内网ip
cat > /data/apps/etcd/etc/etcd.conf << EOF
#[Member]
ETCD_NAME="ename"
ETCD_DATA_DIR="/data/apps/etcd/data/default.etcd"
# 修改此处，修改此处为当前服务器IP
ETCD_LISTEN_PEER_URLS="https://0.0.0.0:2380"
# 修改此处，修改此处为当前服务器IP
ETCD_LISTEN_CLIENT_URLS="https://127.0.0.1:2379,https://0.0.0.0:2379"
#
#[Clustering]
# 修改此处为当前服务器IP
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://0.0.0.0:2380"
# 修改此处为当前服务器IP
ETCD_ADVERTISE_CLIENT_URLS="https://127.0.0.1:2379,https://0.0.0.0:2379"
ETCD_INITIAL_CLUSTER="etcd-01=https://192.168.10.162:2380,etcd-02=https://192.168.10.190:2380,etcd-03=https://192.168.10.191:2380"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
#kube-apiserver 使用 Etcd v3接口，而 flannel 使用 v2接口， 
#Etcd v3.4 发布说明，从 3.4 版本开始，默认已经关闭 v2 接口协议。建议直接在 Etcd 启动参数添加 --enable_v2 'true'
ETCD_ENABLE_V2="true"

#[Security]
ETCD_CERT_FILE="/data/apps/etcd/ssl/etcd.pem"
ETCD_KEY_FILE="/data/apps/etcd/ssl/etcd-key.pem"
ETCD_TRUSTED_CA_FILE="/data/apps/etcd/ssl/etcd-ca.pem"
ETCD_PEER_CERT_FILE="/data/apps/etcd/ssl/etcd.pem"
ETCD_PEER_KEY_FILE="/data/apps/etcd/ssl/etcd-key.pem"
ETCD_PEER_TRUSTED_CA_FILE="/data/apps/etcd/ssl/etcd-ca.pem"
#
[Logging]
ETCD_DEBUG="false"
ETCD_LOG_OUTPUT="default"
EOF
```
相关参数说明

    ETCD_NAME="etcd-01"  定义本服务器的etcd名称
    etcd-01,etcd-02,etcd-03 分别为三台服务器上对应ETCD_NAME的值
    ETCD_INITIAL_CLUSTER_TOKEN，ETCD_INITIAL_CLUSTER_STATE的值各个etcd节点相同

拷贝到其他节点
```powershell
scp -r /data/apps/etcd/etc/etcd.conf 192.168.10.190:/data/apps/etcd/etc/
scp -r /data/apps/etcd/etc/etcd.conf 192.168.10.191:/data/apps/etcd/etc/
```
拷贝完后，修改相关ip地址
```powershell
# 162服务器
sed -i "s/0.0.0.0/192.168.10.162/g" /data/apps/etcd/etc/etcd.conf
sed -i "s/ename/etcd-01/g" /data/apps/etcd/etc/etcd.conf
# 190服务器
sed -i "s/0.0.0.0/192.168.10.190/g" /data/apps/etcd/etc/etcd.conf
sed -i "s/ename/etcd-02/g" /data/apps/etcd/etc/etcd.conf
# 191服务器
sed -i "s/0.0.0.0/192.168.10.191/g" /data/apps/etcd/etc/etcd.conf
sed -i "s/ename/etcd-03/g" /data/apps/etcd/etc/etcd.conf
```

### 创建etcd.service
```powershell

cat > /usr/lib/systemd/system/etcd.service << EOF
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
#
[Service]
Type=notify
EnvironmentFile=/data/apps/etcd/etc/etcd.conf
ExecStart=/data/apps/etcd/bin/etcd
# ETCD3.4版本会自动读取环境变量中以ETCD开头的参数，所以EnvironmentFile文件中有的参数，
# 不需要再次在ExecStart启动参数中添加，二选一，如同时配置，会触发报错
#--name=\${ETCD_NAME} \\
#--data-dir=\${ETCD_DATA_DIR} \\
#--listen-peer-urls=\${ETCD_LISTEN_PEER_URLS} \\
#--listen-client-urls=\${ETCD_LISTEN_CLIENT_URLS} \\
#--advertise-client-urls=\${ETCD_ADVERTISE_CLIENT_URLS} \\
#--initial-advertise-peer-urls=\${ETCD_INITIAL_ADVERTISE_PEER_URLS} \\
#--initial-cluster=\${ETCD_INITIAL_CLUSTER} \\
#--initial-cluster-token=\${ETCD_INITIAL_CLUSTER_TOKEN} \\
#--initial-cluster-state=\${ETCD_INITIAL_CLUSTER_STATE}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
#
[Install]
WantedBy=multi-user.target
EOF
```
拷贝到其他节点
```powershell
scp -r /usr/lib/systemd/system/etcd.service 192.168.10.190:/usr/lib/systemd/system/
scp -r /usr/lib/systemd/system/etcd.service 192.168.10.191:/usr/lib/systemd/system/
```

### 启动服务
```powershell    
useradd -r etcd && chown etcd.etcd -R /data/apps/etcd
systemctl daemon-reload && systemctl enable etcd && systemctl restart etcd && systemctl status etcd
```
### 设置环境变量

```powershell
echo "PATH=$PATH:/data/apps/etcd/bin/" >> /etc/profile.d/etcd.sh
chmod +x /etc/profile.d/etcd.sh
source /etc/profile.d/etcd.sh
```

### 查看集群状态
```powershell
    # etcd 默认使用api3
    etcdctl --cacert=/data/apps/etcd/ssl/etcd-ca.pem --cert=/data/apps/etcd/ssl/etcd.pem --key=/data/apps/etcd/ssl/etcd-key.pem --endpoints="https://192.168.10.162:2379,https://192.168.10.190:2379,https://192.168.10.191:2379" endpoint health --write-out=table
```
结果

    +-----------------------------+--------+-------------+-------+
    |          ENDPOINT           | HEALTH |    TOOK     | ERROR |
    +-----------------------------+--------+-------------+-------+
    | https://192.168.10.191:2379 |   true |   16.6952ms |       |
    | https://192.168.10.190:2379 |   true | 16.693779ms |       |
    | https://192.168.10.162:2379 |   true | 16.289445ms |       |
    +-----------------------------+--------+-------------+-------+
    cluster is degrade(只要有一台有问题就是这种)
    cluster is healthy(所以etcd节点都正常)
查看集群成员
```powershell
etcdctl --cacert=/data/apps/etcd/ssl/etcd-ca.pem --cert=/data/apps/etcd/ssl/etcd.pem --key=/data/apps/etcd/ssl/etcd-key.pem --endpoints="https://192.168.10.162:2379,https://192.168.10.190:2379,https://192.168.10.191:2379" member list

# ETCDCTL_API=3 etcdctl --cacert=/data/apps/etcd/ssl/etcd-ca.pem --cert=/data/apps/etcd/ssl/etcd.pem --key=/data/apps/etcd/ssl/etcd-key.pem member list
```
结果

    +------------------+---------+---------+-----------------------------+----------------------------------------------------+------------+
    |        ID        | STATUS  |  NAME   |         PEER ADDRS          |                    CLIENT ADDRS                    | IS LEARNER |
    +------------------+---------+---------+-----------------------------+----------------------------------------------------+------------+
    | 4b6699de1466051a | started | etcd-03 | https://192.168.10.191:2380 | https://127.0.0.1:2379,https://192.168.10.191:2379 |      false |
    | 7d643d2a75dfeb32 | started | etcd-02 | https://192.168.10.190:2380 | https://127.0.0.1:2379,https://192.168.10.190:2379 |      false |
    | b135df4790d40e52 | started | etcd-01 | https://192.168.10.162:2380 | https://127.0.0.1:2379,https://192.168.10.162:2379 |      false |
    +------------------+---------+---------+-----------------------------+----------------------------------------------------+------------+

注意：如果没有设置环境变量ETCDCTL_API，则默认使用ETCDCTL_API=3的api
ETCDCTL_API=2与ETCDCTL_API=3对应的命令参数有所不同

集群启动后出现的错误日志

    the clock difference against peer 97feb1a73a325656 is too high
    集群各个节点时钟不同步，通过ntpdate time1.aliyun.com命令可以同步时钟
    注意防火墙，selinux的关闭


# 四、安装kubernetes组件
## 4.1 环境说明
### 集群服务器配置
|K8S集群角色	|Ip	|主机名|	安装的组件|
| -------- | ------------| ------------ | ---- |
|控制节点	|192.168.10.162|	k8s-master01|	etcd、docker、kube-apiserver、kube-controller-manager、kube-scheduler、kube-proxy、kubelet、flanneld、keepalived、nginx|
|控制节点	|192.168.10.163|	k8s-master02|	etcd、docker、kube-apiserver、kube-controller-manager、kube-scheduler、kube-proxy、kubelet、flanneld、keepalived、nginx|
|工作节点	|192.168.10.190|	k8s-node01|	etcd、docker、kubelet、kube-proxy、flanneld、coredns|
|工作节点	|192.168.10.191|	k8s-node02  |etcd、docker、kubelet、kube-proxy、flanneld、coredns |
|负载均衡器|192.168.10.88|    k8s-master-lb  | keepalived虚拟IP Vip |

考虑电脑配置问题，一次性开四台机器会跑不动，
所以搭建这套K8s高可用集群分两部分实施，先部署一套单Master架构（3台），
再扩容为多Master架构（4台或6台），顺便再熟悉下Master扩容流程
k8s-master2 暂不部署
keepalived、nginx 组件非高可用架构也不需要
### k8s网络环境规划


     1. k8s版本：v1.22.8
     2. Pod网段：10.88.0.0/16
     3. Service网段：10.99.0.0/16

## 4.2 生成集群CA证书
**只需在在masetr机器执行**
### ca证书
```powershell
mkdir /root/k8s-ssl && cd /root/k8s-ssl
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
cat > ca-csr.json << EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "Beijing",
      "ST": "Beijing",
      "O": "k8s",
      "OU": "System"
    }
  ],
  "ca": {
    "expiry": "87600h"
  }
}
EOF
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
```
### kube-apiserver 证书
注意：如果 hosts 字段不为空则需要指定授权使用该证书的 IP 或域名列表。
由于该证书后续被     kubernetes master 集群使用，需要将master节点的IP都填上，
同时还需要填写 service 网络的首个IP。(一般是 kube-apiserver
指定的 service-cluster-ip-range 网段的第一个IP，如 10.99.0.1)
负载均衡器的ip也需要指定
```powershell
cat > kube-apiserver-csr.json  << EOF
{
  "CN": "kube-apiserver",
  "hosts": [
    "127.0.0.1",
    "192.168.10.162",
    "192.168.10.163",
    "192.168.10.164",
    "192.168.10.165",
    "192.168.10.88",
    "10.99.0.1",
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster",
    "kubernetes.default.svc.cluster.local",
    "kubernetes.default.svc.lgh",
    "kubernetes.default.svc.lgh.work"
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
      "O": "k8s",
      "OU": "System"
    }
  ]
}
EOF
#生成证书
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=/root/etcd-ssl/ca-config.json -profile=kubernetes kube-apiserver-csr.json | cfssljson -bare kube-apiserver

```
### kube-controller-manager 证书
host 可以为空
```powershell
cat > kube-controller-manager-csr.json << EOF
{
  "CN": "system:kube-controller-manager",
  "hosts": [
    "127.0.0.1",
    "192.168.10.162",
    "192.168.10.163",
    "192.168.10.164",
    "192.168.10.165",
    "192.168.10.88",
    "10.88.0.1",
    "10.99.0.1"
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
      "O": "system:kube-controller-manager",
      "OU": "System"
    }
  ]
}
EOF
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=/root/etcd-ssl/ca-config.json -profile=kubernetes kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

```
### kube-scheduler证书
hosts 列表包含所有 kube-scheduler 节点 IP 即为master节点ip，可以多写几个；
CN 为 system:kube-scheduler、
O 为 system:kube-scheduler，kubernetes 内置的 ClusterRoleBindings system:kube-scheduler 将赋予 kube-scheduler 工作所需的权限
```powershell    
cat > kube-scheduler-csr.json << EOF
{
  "CN": "system:kube-scheduler",
  "hosts": [
    "127.0.0.1",
    "192.168.10.162",
    "192.168.10.163",
    "192.168.10.164",
    "192.168.10.165"
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
      "O": "system:kube-scheduler",
      "OU": "System"
    }
  ]
}
EOF
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=/root/etcd-ssl/ca-config.json -profile=kubernetes kube-scheduler-csr.json | cfssljson -bare kube-scheduler

```
### kube-proxy证书
```powershell
cat > kube-proxy-csr.json << EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing",
      "ST": "BeiJing",
      "O": "system:kube-proxy",
      "OU": "System"
    }
  ]
}
EOF
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=/root/etcd-ssl/ca-config.json -profile=kubernetes kube-proxy-csr.json | cfssljson -bare kube-proxy

```
### admin 证书
证书请求文件说明：
1)kube-apiserver 使用 RBAC 对客户端(如 kubelet、kube-proxy、Pod)请求进行授权； kube-apiserver 预定义了一些 RBAC 使用的 RoleBindings，如 cluster-admin 将 Group system:masters 与 Role cluster-admin 绑定，该 Role 授予了调用kube-apiserver 的所有 API的权限； O指定该证书的 Group 为 system:masters，kubelet 使用该证书访问 kube-apiserver 时 ，由于证书被 CA 签名，所以认证通过，同时由于证书用户组为经过预授权的 system:masters，所以被授予访问所有 API 的权限；
2)admin 证书，是将来生成管理员用的kube config 配置文件用的，现在我们一般建议使用RBAC 来对kubernetes 进行角色权限控制， kubernetes 将证书中的CN 字段 作为User， O 字段作为 Group； "O": "system:masters", 必须是system:masters，否则后面kubectl create clusterrolebinding报错。
3)证书O配置为system:masters 在集群内部cluster-admin的clusterrolebinding将system:masters组和cluster-admin clusterrole绑定在一起

```powershell
cat > admin-csr.json << EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing",
      "ST": "BeiJing",
      "O": "system:masters",
      "OU": "System"
    }
  ]
}
EOF
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=/root/etcd-ssl/ca-config.json -profile=kubernetes admin-csr.json | cfssljson -bare admin
cat > proxy-client-csr.json << EOF
{
  "CN": "aggregator",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "BeiJing",
      "L": "BeiJing",
      "O": "system:masters",
      "OU": "System"
    }
  ]
}
EOF
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=/root/etcd-ssl/ca-config.json -profile=kubernetes proxy-client-csr.json | cfssljson -bare proxy-client
```
### 分发证书文件
提示： node 节点只需要 ca、kube-proxy、kubelet 证书，不需要拷贝 kube-controller-
manager、 kube-schedule、kube-apiserver 证书
后续增加节点时，需要拷贝相关文件到新节点
```powershell
mkdir -pv /data/apps/kubernetes/{pki,log,etc,certs}
mkdir -pv /data/apps/kubernetes/log/{apiserver,controller-manager,scheduler,kubelet,kube-proxy}
cp ca*.pem admin*.pem kube-proxy*.pem kube-scheduler*.pem kube-controller-manager*.pem kube-apiserver*.pem proxy-client*.pem /data/apps/kubernetes/pki/
rsync -avzP /data/apps/kubernetes 192.168.10.190:/data/apps/
rsync -avzP /data/apps/kubernetes 192.168.10.191:/data/apps/
    
```
## 4.3下载kubernetes安装包
**下载地址**

    版本链接 https://github.com/kubernetes/kubernetes/tree/master/CHANGELOG
    server节点下载文件 https://dl.k8s.io/v1.22.8/kubernetes-server-linux-amd64.tar.gz
    node节点下载文件   https://dl.k8s.io/v1.22.8/kubernetes-node-linux-amd64.tar.gz
**mster节点执行**
```powershell
cd /root
wget https://dl.k8s.io/v1.22.8/kubernetes-server-linux-amd64.tar.gz
wget https://dl.k8s.io/v1.22.8/kubernetes-node-linux-amd64.tar.gz
#拷贝kubernetes-node-linux-amd64.tar.gz到node节点
scp kubernetes-node-linux-amd64.tar.gz 192.168.0.21:/root
scp kubernetes-node-linux-amd64.tar.gz 192.168.0.22:/root
#有其他master节点也拷贝服务端安装包
#解压
tar zxf kubernetes-server-linux-amd64.tar.gz
cp -r kubernetes/server /data/apps/kubernetes/

#配置环境变量，安装docker命令补全
yum install bash-completion -y
cat > /etc/profile.d/kubernetes.sh << EOF
K8S_HOME=/data/apps/kubernetes
export PATH=\$K8S_HOME/server/bin:\$PATH
source <(kubectl completion bash)
EOF
source /etc/profile.d/kubernetes.sh
kubectl version

```
**node节点执行**
```powershell
tar zxf kubernetes-node-linux-amd64.tar.gz
cp -r kubernetes/node /data/apps/kubernetes/
   
#配置环境变量，安装docker命令补全
yum install bash-completion -y
cat > /etc/profile.d/kubernetes.sh << EOF
K8S_HOME=/data/apps/kubernetes
export PATH=\$K8S_HOME/node/bin:\$PATH
source <(kubectl completion bash)
EOF
source /etc/profile.d/kubernetes.sh
kubectl version 
```

## 4.4 配置TLS Bootstrapping kubeconfig

### TLS Bootstrapping
**mster节点执行**
#### TLS Bootstrapping 说明
TLS Bootstrapping 机制：

    1)Master apiserver启用TLS认证后，每个节点的 kubelet 组件都要使用由 apiserver 使用的 CA 签发的有效证书才能与 apiserver 通讯，当Node节点很多时，这种客户端证书颁发需要大量工作，同样也会增加集群扩展复杂度。为了简化流程，Kubernetes引入了TLS bootstraping机制来自动颁发客户端证书，kubelet会以一个低权限用户自动向apiserver申请证书，kubelet的证书由apiserver动态签署。
    2)Bootstrap 是很多系统中都存在的程序，比如 Linux 的bootstrap，bootstrap 一般都是作为预先配置在开启或者系统启动的时候加载，这可以用来生成一个指定环境。
    3)Kubernetes 的 kubelet 在启动时同样可以加载一个这样的配置文件，这个文件的内容类似如下形式:
        apiVersion: v1
        clusters: null
        contexts:
        - context:
            cluster: kubernetes
            user: kubelet-bootstrap
          name: default
        current-context: default
        kind: Config
        preferences: {}
        users:
        - name: kubelet-bootstrap
          user: {}
TLS bootstrapping 具体引导过程：

    # TLS 作用 
    	TLS 的作用就是对通讯加密，防止中间人窃听；同时如果证书不信任的话根本就无法与 apiserver 建立连接，更不用提有没有权限向apiserver请求指定内容。
    
    # RBAC 作用 
    	当 TLS 解决了通讯问题后，那么权限问题就应由 RBAC 解决(可以使用其他权限模型，如 ABAC)；RBAC 中规定了一个用户或者用户组(subject)具有请求哪些 api 的权限；在配合 TLS 加密的时候，实际上 apiserver 读取客户端证书的 CN 字段作为用户名，读取 O字段作为用户组.

    # 说明
    	1)想要与 apiserver 通讯就必须采用由 apiserver CA 签发的证书，这样才能形成信任关系，建立 TLS 连接；
    	2)可以通过证书的 CN、O 字段来提供 RBAC 所需的用户与用户组。
kubelet 首次启动流程

    # 问题引出：
    	TLS bootstrapping 功能是让 kubelet 组件去 apiserver 申请证书，然后用于连接 apiserver；那么第一次启动时没有证书如何连接 apiserver ?
    
    # 流程分析
    	在apiserver 配置中指定了一个 token.csv 文件，该文件中是一个预设的用户配置；同时该用户的Token 和 由apiserver 的 CA签发的用户被写入了 kubelet 所使用的 bootstrap.kubeconfig 配置文件中；这样在首次请求时，kubelet 使用 bootstrap.kubeconfig 中被 apiserver CA 签发证书时信任的用户来与 apiserver 建立 TLS 通讯，使用 bootstrap.kubeconfig 中的用户 Token 来向 apiserver 声明自己的 RBAC 授权身份.
        token.csv格式: token，用户名，UID，用户组
        3940fd7fbb391d1b4d861ad17a1f0613,kubelet-bootstrap,10001,"system:kubelet-bootstrap"
    
    	首次启动时，可能遇到 kubelet报401无权访问 apiserver 的错误；这是因为在默认情况下，kubelet 通过 bootstrap.kubeconfig 中的预设用户 Token 声明了自己的身份，然后创建 CSR 请求；但是不要忘记这个用户在我们不处理的情况下他没任何权限的，包括创建 CSR 请求；所以需要创建一个ClusterRoleBinding，将预设用户 kubelet-bootstrap 与内置的 ClusterRole system:node-bootstrapper 绑定到一起，使其能够发起 CSR 请求。
#### 创建token.csv
创建token.csv文件
```powershell
#格式：token，用户名，UID，用户组
export BOOTSTRAP_TOKEN=$(head -c 16 /dev/urandom | od -An -t x | tr -d ' ')
cat > /data/apps/kubernetes/token.csv << EOF
${BOOTSTRAP_TOKEN},kubelet-bootstrap,10001,"system:kubelet-bootstrap"
EOF
export KUBE_APISERVER="https://192.168.10.162:6443"
```
配置有问题时候会导致 kubectl get csr 显示No Resources Found
https://blog.csdn.net/weixin_33695082/article/details/91672619


### 创建 kubeconfig
设置 kube-apiserver 访问地址， 如果需要对 kube-apiserver 配置高可用集群， 则这里设置apiserver 浮动 IP。  KUBE_APISERVER=浮动 IP，如果是单节点，则直接配置ip即可
```powershell
cd /data/apps/kubernetes/
export KUBE_APISERVER="https://192.168.10.162:6443"
```
#### kubelet-bootstrap.kubeconfig
```powershell    
# 设置集群参数
kubectl config set-cluster kubernetes \
--certificate-authority=/data/apps/kubernetes/pki/ca.pem \
--embed-certs=true \
--server=${KUBE_APISERVER} \
--kubeconfig=kubelet-bootstrap.kubeconfig
# 设置客户端认证参数
kubectl config set-credentials kubelet-bootstrap \
--token=${BOOTSTRAP_TOKEN} \
--kubeconfig=kubelet-bootstrap.kubeconfig
# 设置上下文参数
kubectl config set-context default \
--cluster=kubernetes \
--user=kubelet-bootstrap \
--kubeconfig=kubelet-bootstrap.kubeconfig
# 生成kubelet-bootstrap.kubeconfig
kubectl config use-context default --kubeconfig=kubelet-bootstrap.kubeconfig

```
#### kube-controller-manager kubeconfig
```powershell
# 设置集群参数
kubectl config set-cluster kubernetes \
--certificate-authority=/data/apps/kubernetes/pki/ca.pem \
--embed-certs=true \
--server=${KUBE_APISERVER} \
--kubeconfig=kube-controller-manager.kubeconfig
# 设置客户端认证参数
kubectl config set-credentials kube-controller-manager \
--client-certificate=/data/apps/kubernetes/pki/kube-controller-manager.pem \
--client-key=/data/apps/kubernetes/pki/kube-controller-manager-key.pem \
--embed-certs=true \
--kubeconfig=kube-controller-manager.kubeconfig
# 设置上下文参数
kubectl config set-context default \
--cluster=kubernetes \
--user=kube-controller-manager \
--kubeconfig=kube-controller-manager.kubeconfig
# 设置当前上下文
kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
# 5.查看kubeconfig
cat kube-controller-manager.kubeconfig

```
#### kube-scheduler kubeconfig
```powershell
kubectl config set-cluster kubernetes \
--certificate-authority=/data/apps/kubernetes/pki/ca.pem \
--embed-certs=true \
--server=${KUBE_APISERVER} \
--kubeconfig=kube-scheduler.kubeconfig

kubectl config set-credentials kube-scheduler \
--client-certificate=/data/apps/kubernetes/pki/kube-scheduler.pem \
--client-key=/data/apps/kubernetes/pki/kube-scheduler-key.pem \
--embed-certs=true \
--kubeconfig=kube-scheduler.kubeconfig

kubectl config set-context default \
--cluster=kubernetes \
--user=kube-scheduler \
--kubeconfig=kube-scheduler.kubeconfig

kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig

```
#### kube-proxy kubeconfig

```powershell
kubectl config set-cluster kubernetes \
--certificate-authority=/data/apps/kubernetes/pki/ca.pem \
--embed-certs=true \
--server=${KUBE_APISERVER} \
--kubeconfig=kube-proxy.kubeconfig

kubectl config set-credentials kube-proxy \
--client-certificate=/data/apps/kubernetes/pki/kube-proxy.pem \
--client-key=/data/apps/kubernetes/pki/kube-proxy-key.pem \
--embed-certs=true \
--kubeconfig=kube-proxy.kubeconfig

kubectl config set-context default \
--cluster=kubernetes \
--user=kube-proxy \
--kubeconfig=kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
```

#### admin kubeconfig
```powershell    
kubectl config set-cluster kubernetes \
--certificate-authority=/data/apps/kubernetes/pki/ca.pem \
--embed-certs=true \
--server=${KUBE_APISERVER} \
--kubeconfig=admin.conf

kubectl config set-credentials admin \
--client-certificate=/data/apps/kubernetes/pki/admin.pem \
--client-key=/data/apps/kubernetes/pki/admin-key.pem \
--embed-certs=true \
--kubeconfig=admin.conf

kubectl config set-context default \
--cluster=kubernetes \
--user=admin \
--kubeconfig=admin.conf

kubectl config use-context default --kubeconfig=admin.conf

```

### 分发 kubeconfig 配置文件
```powershell    
mv kube* token.csv admin.conf etc/
#分发到node节点
# node节点若需要使用kubectl 则需要admin.conf
rsync -avz --exclude=kube-scheduler.kubeconfig --exclude=kube-controller-manager.kubeconfig  --exclude=token.csv etc 192.168.10.190:/data/apps/kubernetes
rsync -avz --exclude=kube-scheduler.kubeconfig --exclude=kube-controller-manager.kubeconfig  --exclude=token.csv etc 192.168.10.191:/data/apps/kubernetes
#分发到master节点
#rsync -avz  etc 192.168.10.163:/data/apps/kubernetes
    
```

## 4.5 配置 kube-apiserver 组件
**master节点操作**
### sa证书
```powershell
cd /data/apps/kubernetes/pki/
openssl genrsa -out /data/apps/kubernetes/pki/sa.key 2048
openssl rsa -in /data/apps/kubernetes/pki/sa.key -pubout -out /data/apps/kubernetes/pki/sa.pub
#分发文件到其他apiserver节点(没有则省略)
#scp -r /data/apps/kubernetes/pki/sa.* *.*.*.*:/data/apps/kubernetes/pki/
#scp -r /data/apps/kubernetes/etc *.*.*.*:/data/apps/kubernetes/
    
```
### 配置文件
```powershell
#参考文档 https://v1-22.docs.kubernetes.io/zh/docs/reference/command-line-tools-reference/kube-apiserver/
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
  --service-account-key-file=/data/apps/kubernetes/pki/sa.pub \
  --service-account-signing-key-file=/data/apps/kubernetes/pki/sa.key  \
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

```
**说明**

    bind-address advertise-address 需配置为当前master节点的IP
    --tls-cert-file=/data/apps/kubernetes/pki/kube-apiserver.pem  
    --tls-private-key-file=/data/apps/kubernetes/pki/kube-apiserver-key.pem
    作为服务器端，必须要准备好自己的证书(对)，所以这两个参数就是指定了证书的路径。
    --client-ca-file
    这个参数的含义是指定客户端使用的根证书的路径。一旦设置了，那么你在访问api的时候一定得带上使用该根证书签发的公钥/私钥对
    --service-account-key-file=/data/apps/kubernetes/pki/sa.pub
    该参数表示的含义是公钥的路径，它与kube-controller-manager的--service-account-private-key-file是对应关系，因为pod带着token去访问api server，则api server要能解密才行，所以同时还需要在api那里配置，当然如果不配置，不影响pod创建，只不过在pod里访问api的时候就不行了。
    -- service-account-signing-key-file 与service-account-key-file 对应的证书
~~删除~~
~~service-account-key-file=/data/apps/kubernetes/pki/sa.pub ~~
~~使用该文件controller-manager一直无权限，先改为ca.pem 同时controller-manager 要同步修改~~


### 服务文件
```powershell
cat > /usr/lib/systemd/system/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Service
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kube-apiserver.conf
ExecStart=/data/apps/kubernetes/server/bin/kube-apiserver \\
\$KUBE_APISERVER_OPTS 
Restart=on-failure
Type=notify
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
```
### 启动apiserver
```powershell
systemctl daemon-reload && systemctl enable kube-apiserver && systemctl start kube-apiserver && systemctl status kube-apiserver  
```
测试是否可以访问
```powershell
curl -k https://192.168.10.162:6443
    {
      "kind": "Status",
      "apiVersion": "v1",
      "metadata": {
        
      },
      "status": "Failure",
      "message": "Unauthorized",
      "reason": "Unauthorized",
      "code": 401
    }
```
## 4.6 配置 kube-controller-manager 组件
**在所有master节点执行**

kube-controller-manager  负责维护集群的状态，比如故障检测、自动扩展、滚动更新等
在启动时设置  --leader-elect=true 后， controller manager 会使用多节点选主的方式选择主节点。只有主节点才会调用  StartControllers() 启动所有控制器，而其他从节点则仅执行选主算法。
### 配置文件

```powershell
#参考文档 https://v1-22.docs.kubernetes.io/zh/docs/reference/command-line-tools-reference/kube-controller-manager/
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
  --service-account-private-key-file=/data/apps/kubernetes/pki/sa.key \\
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
```
**说明**

    --service-account-private-key-file
    该参数表示的含义是私钥的路径，它的作用是给服务账号产生token，之后pod就可以拿着这个token去访问api server了。
    --root-ca-file
    该参数会给服务账号一个根证书ca.pem，可选配置，如果配置成给api server签发证书的那个根证书，那就可以拿来用于认证api server。
    --cluster-cidr
    pod网段
    --service-cluster-ip-range
    service网段

### 服务文件
```powershell
cat > /usr/lib/systemd/system/kube-controller-manager.service << EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kube-controller-manager.conf
ExecStart=/data/apps/kubernetes/server/bin/kube-controller-manager \$KUBE_CONTROLLER_MANAGER_OPTS
Restart=always
RestartSec=10s
#Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

```
### 启动服务
```powershell
systemctl daemon-reload
systemctl enable kube-controller-manager
systemctl start kube-controller-manager
systemctl status kube-controller-manager
#若启动报错 请仔细查询日志 journalctl -xeu kube-controller-manager
```
## 4.6 配置kubectl
**在需要使用kubectl的节点执行**
```powershell
rm -rf $HOME/.kube
mkdir -p $HOME/.kube
cp /data/apps/kubernetes/etc/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get node
kubectl get componentstatuses

```
## 4.7 配置kubelet 使用 bootstrap
**在一个master节点执行**
```powershell
kubectl delete clusterrolebinding kubelet-bootstrap 
kubectl create clusterrolebinding kubelet-bootstrap \
--clusterrole=system:node-bootstrapper \
--user=kubelet-bootstrap
```
## 4.8 配置启动 kube-scheduler
**在所有master节点执行**

kube-scheduler 负责分配调度 Pod 到集群内的节点上，它监听 kube-apiserver，查询还未分配 Node 的 Pod，然后根据调度策略为这些 Pod 分配节点。按照预定的调度策略将Pod 调度到相应的机器上（更新 Pod 的NodeName 字段）。

### 配置文件
```powershell
#参考文档 https://v1-22.docs.kubernetes.io/zh/docs/reference/command-line-tools-reference/kube-scheduler/
cat > /data/apps/kubernetes/etc/kube-scheduler.conf<< EOF
KUBE_LOGTOSTDERR="--logtostderr=false"
KUBE_LOG_LEVEL="--v=2 --log-dir=/data/apps/kubernetes/log/scheduler"
KUBECONFIG="--kubeconfig=/data/apps/kubernetes/etc/kube-scheduler.kubeconfig"
KUBE_SCHEDULER_ARGS="--address=127.0.0.1"
EOF

```
### 服务文件
```powershell    
cat > /usr/lib/systemd/system/kube-scheduler.service << EOF
[Unit]
Description=Kubernetes Scheduler Plugin
Documentation=https://github.com/kubernetes/kubernetes
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kube-scheduler.conf
ExecStart=/data/apps/kubernetes/server/bin/kube-scheduler \\
\$KUBE_LOGTOSTDERR \\
\$KUBE_LOG_LEVEL \\
\$KUBECONFIG \\
\$KUBE_SCHEDULER_ARGS
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

```
### 启动服务
```powershell
    systemctl daemon-reload
    systemctl enable kube-scheduler
    systemctl restart kube-scheduler
    systemctl status kube-scheduler
```
## 4.9 配置 kubelet
**在所有节点执行**
kubelet： 每个Node节点上的kubelet定期就会调用API Server的REST接口报告自身状态，API Server接收这些信息后，将节点状态信息更新到etcd中。kubelet也通过API Server监听Pod信息，从而对Node机器上的POD进行管理，如创建、删除、更新Pod

### 配置文件
```powershell
#参考文档 https://v1-22.docs.kubernetes.io/zh/docs/reference/command-line-tools-reference/kubelet/
cat > /data/apps/kubernetes/etc/kubelet.conf << EOF
KUBE_LOGTOSTDERR="--logtostderr=false"
KUBE_LOG_LEVEL="--v=2 --log-dir=/data/apps/kubernetes/log/kubelet"
KUBELET_HOSTNAME="--hostname-override=192.168.10.162"
KUBELET_POD_INFRA_CONTAINER="--pod-infra-container-image=registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.2"
KUBELET_CONFIG="--config=/data/apps/kubernetes/etc/kubelet-config.yml"
KUBELET_ARGS="--bootstrap-kubeconfig=/data/apps/kubernetes/etc/kubelet-bootstrap.kubeconfig --kubeconfig=/data/apps/kubernetes/etc/kubelet.kubeconfig --cert-dir=/data/apps/kubernetes/pki"
EOF

```
**参数说明**

    –hostname-override：显示名称，集群中唯一 
    –network-plugin：启用CNI 
    –kubeconfig：空路径，会自动生成，后面用于连接apiserver 
    –bootstrap-kubeconfig：首次启动向apiserver申请证书
    –config：配置参数文件 
    –cert-dir：kubelet证书生成目录 
    –pod-infra-container-image：管理Pod网络容器的镜像
### 配置参数文件
不同节点创建时候注意修改address
```powershell
cat > /data/apps/kubernetes/etc/kubelet-config.yml << EOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
address: 192.168.10.162
port: 10250
cgroupDriver: cgroupfs
clusterDNS:
- 10.99.0.2
clusterDomain: cluster.local.
hairpinMode: promiscuous-bridge
maxPods: 200
failSwapOn: false
imageGCHighThresholdPercent: 90
imageGCLowThresholdPercent: 80
imageMinimumGCAge: 5m0s
serializeImagePulls: false
featureGates: 
  RotateKubeletServerCertificate: true  
authentication:
  x509:
    clientCAFile: /data/apps/kubernetes/pki/ca.pem
  anonymous:
    enbaled: false
  webhook:
    enbaled: false
EOF
```
**说明**

     cgroupDriver: 默认值为"systemd",目前docker为cgroupfs 要和docker的驱动一致。
     clusterDNS：service网段的一个IP地址； DNS 服务器的 IP 地址，以逗号分隔
     address替换为自己当前启动节点的IP地址。
### 服务文件
**master节点**
```powershell
cat > /usr/lib/systemd/system/kubelet.service << EOF
[Unit]
Description=Kubernetes Kubelet Server
Documentation=https://github.com/kubernetes/kubernetes
After=docker.service
Requires=docker.service
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kubelet.conf
ExecStart=/data/apps/kubernetes/server/bin/kubelet \\
\$KUBE_LOGTOSTDERR \\
\$KUBE_LOG_LEVEL \\
\$KUBELET_CONFIG \\
\$KUBELET_HOSTNAME \\
\$KUBELET_POD_INFRA_CONTAINER \\
\$KUBELET_ARGS
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

```
**node节点**
```powershell
cat > /usr/lib/systemd/system/kubelet.service << EOF
[Unit]
Description=Kubernetes Kubelet Server
Documentation=https://github.com/kubernetes/kubernetes
After=docker.service
Requires=docker.service
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kubelet.conf
ExecStart=/data/apps/kubernetes/node/bin/kubelet \\
\$KUBE_LOGTOSTDERR \\
\$KUBE_LOG_LEVEL \\
\$KUBELET_CONFIG \\
\$KUBELET_HOSTNAME \\
\$KUBELET_POD_INFRA_CONTAINER \\
\$KUBELET_ARGS
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
```
### 启动服务
所有节点执行
```powershell
systemctl daemon-reload && systemctl enable kubelet && systemctl start kubelet && systemctl status kubelet
```


## 4.10配置 kube-proxy
**在所有节点执行**
kube-proxy 负责为 Service 提供 cluster 内部的服务发现和负载均衡；每台机器上都运行一个 kube-proxy 服务，它监听 API server 中 service和 endpoint 的变化情况，并通过 ipvs/iptables 等来为服务配置负载均衡（仅支持 TCP 和 UDP）。

注意：使用 ipvs 模式时，需要预先在每台 Node 上加载内核模块nf_conntrack_ipv4, ip_vs, ip_vs_rr, ip_vs_wrr, ip_vs_sh 等。
```powershell
#安装 conntrack-tools
yum install -y conntrack-tools ipvsadm ipset conntrack libseccomp
```
### 配置文件
```powershell
#参考文档 https://v1-22.docs.kubernetes.io/zh/docs/reference/command-line-tools-reference/kube-proxy/
cat > /data/apps/kubernetes/etc/kube-proxy.conf << EOF
KUBE_LOGTOSTDERR="--logtostderr=false"
KUBE_LOG_LEVEL="--v=2 --log-dir=/data/apps/kubernetes/log/kube-proxy/"
KUBECONFIG="--kubeconfig=/data/apps/kubernetes/etc/kube-proxy.kubeconfig"
KUBE_PROXY_ARGS="--proxy-mode=ipvs --masquerade-all=true --cluster-cidr=10.88.0.0/16"
EOF
```
**说明**

     cluster-cidr: pod网段地址
     启用 ipvs 主要就是把 kube-proxy 的--proxy-mode 配置选项修改为 ipvs,并且要启用--masquerade-all，使用 iptables 辅助 ipvs 运行。

### 服务文件
**master节点**
```powershell
cat > /usr/lib/systemd/system/kube-proxy.service << EOF
[Unit]
Description=Kubernetes Kube-Proxy Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kube-proxy.conf
ExecStart=/data/apps/kubernetes/server/bin/kube-proxy \\
\$KUBE_LOGTOSTDERR \\
\$KUBE_LOG_LEVEL \\
\$KUBECONFIG \\
\$KUBE_PROXY_ARGS
Restart=on-failure
LimitNOFILE=65536
KillMode=process
[Install]
WantedBy=multi-user.target
EOF
```
**node节点**
```powershell
cat > /usr/lib/systemd/system/kube-proxy.service << EOF
[Unit]
Description=Kubernetes Kube-Proxy Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
[Service]
EnvironmentFile=-/data/apps/kubernetes/etc/kube-proxy.conf
ExecStart=/data/apps/kubernetes/node/bin/kube-proxy \\
\$KUBE_LOGTOSTDERR \\
\$KUBE_LOG_LEVEL \\
\$KUBECONFIG \\
\$KUBE_PROXY_ARGS
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
```
### 启动服务
```powershell    
systemctl daemon-reload&&systemctl enable kube-proxy&&systemctl start kube-proxy
systemctl status kube-proxy
```
## 4.11 通过证书验证添加各个节点
**在 master 节点操作**
查询csr
```powershell
kubectl get csr
```
结果

    NAME                                                   AGE   REQUESTOR           CONDITION
    node-csr-5eGOzmAXliEO2uarHLkwlIT2fBgUAmUsxsI3SoY7hqc   18m   kubelet-bootstrap   Pending
    node-csr-npkuftNKggSsORCKqhipwybQXrn7kpxCpb2SX1Gfbo4   18m   kubelet-bootstrap   Pending
    node-csr-sWDUOicJsl2N-4BL8zWrXpQZs9xSiUKgsJ5-17sLUgQ   18m   kubelet-bootstrap   Pending
通过验证并添加进集群
```powershell
kubectl get csr | awk '/node/{print $1}' | xargs kubectl certificate approve
#certificatesigningrequest.certificates.k8s.io/node-csr-5eGOzmAXliEO2uarHLkwlIT2fBgUAmUsxsI3SoY7hqc approved
#certificatesigningrequest.certificates.k8s.io/node-csr-npkuftNKggSsORCKqhipwybQXrn7kpxCpb2SX1Gfbo4 approved
#certificatesigningrequest.certificates.k8s.io/node-csr-sWDUOicJsl2N-4BL8zWrXpQZs9xSiUKgsJ5-17sLUgQ approved
```
查询csr
```powershell
kubectl get csr
```
结果

    NAME                                                   AGE       REQUESTOR             CONDITION
    node-csr-HnWF5bl4hcOMlAneHU2owVAvVn7bBPHzXk4YTTDhTbQ   112m      kubelet-bootstrap     Approved,Issued
    node-csr-IuRy0gVF7RMNqtAFoQxNQi_vJxwywsqufBgHQUJJ6us   112m      kubelet-bootstrap     Approved,Issued
    node-csr-iY4shNnZuqPbQ-sZZ9BRAUyViwW_yHKj801xPWeAEL4   112m      kubelet-bootstrap     Approved,Issued

查看节点
```powershell
kubectl get nodes 
```
    #NAME             STATUS   ROLES    AGE     VERSION
    #192.168.10.162   Ready    <none>   4m27s   v1.22.8
    #192.168.10.190   Ready    <none>   3m49s   v1.22.8
    #192.168.10.191   Ready    <none>   3m25s   v1.22.8

设置集群角色
```powershell
kubectl label nodes 192.168.10.162 node-role.kubernetes.io/master=MASTER-01
kubectl label nodes 192.168.10.190 node-role.kubernetes.io/node=NODE-01
kubectl label nodes 192.168.10.191 node-role.kubernetes.io/node=NODE-02

```
设置 master 一般情况下不接受负载
```powershell
kubectl taint nodes 192.168.10.162 node-role.kubernetes.io/master=MASTER-1:NoSchedule --overwrite
```
此时查看节点 Roles, ROLES 已经标识出了 master 和 node

    NAME             STATUS   ROLES    AGE   VERSION
    192.168.10.162   Ready    master   21m   v1.22.8
    192.168.10.190   Ready    node     20m   v1.22.8
    192.168.10.191   Ready    node     19m   v1.22.8

## 4.12 配置网络插件Flannel
**Master 和 node 节点安装**

Flannel通过给每台宿主机分配一个子网的方式为容器提供虚拟网络，它基于Linux TUN/TAP，使用UDP封装IP包来创建overlay网络，并借助etcd维护网络的分配情况。
Flannel支持的Backend：

    udp：使用用户态udp封装，默认使用8285端口。由于是在用户态封装和解包，性能上有较大的损失
    vxlan：vxlan封装，需要配置VNI，Port（默认8472）和GBP
    host-gw：直接路由的方式，将容器网络的路由信息直接更新到主机的路由表中，仅适用于二层直接可达的网络
    aws-vpc：使用 Amazon VPC route table 创建路由，适用于AWS上运行的容器
    gce：使用Google Compute Engine Network创建路由，所有instance需要开启IP forwarding，适用于GCE上运行的容器
    ali-vpc：使用阿里云VPC route table 创建路由，适用于阿里云上运行的容器
### 文件下载
**master节点**
```powershell
cd /root
wget https://github.com/flannel-io/flannel/releases/download/v0.17.0/flannel-v0.17.0-linux-amd64.tar.gz
# cp /mnt/nfs_mnt/nfs_a/k8s-install/software/flannel-v0.17.0-linux-amd64.tar.gz /root/
#将文件分发到其他节点
scp -r flannel-v0.17.0-linux-amd64.tar.gz 192.168.10.190:/root/
scp -r flannel-v0.17.0-linux-amd64.tar.gz 192.168.10.191:/root/
tar zxvf flannel-v0.17.0-linux-amd64.tar.gz
mv flanneld mk-docker-opts.sh /data/apps/kubernetes/server/bin/
chmod +x /data/apps/kubernetes/server/bin/*
```
**node节点**
```powershell
mv flanneld mk-docker-opts.sh /data/apps/kubernetes/node/bin/
chmod +x /data/apps/kubernetes/node/bin/*
```
### 创建网络段
在 etcd 集群执行如下命令， 为 docker 创建互联网段 etcd 需要开启 --enable_v2 启用v2版本api,同时设置网络时候需要用v2版本 只需一个机器执行
```powershell
ETCDCTL_API=2 /data/apps/etcd/bin/etcdctl --ca-file=/data/apps/etcd/ssl/etcd-ca.pem --cert-file=/data/apps/etcd/ssl/etcd.pem --key-file=/data/apps/etcd/ssl/etcd-key.pem --endpoints="https://192.168.10.162:2379,https://192.168.10.190:2379,https://192.168.10.191:2379" set /coreos.com/network/config '{"Network":"10.88.0.0/16","Backend": {"Type":"vxlan"}}'

```
api3版本命令，不可使用

    # /data/apps/etcd/bin/etcdctl --cacert=/data/apps/etcd/ssl/etcd-ca.pem 
    # --cert=/data/apps/etcd/ssl/etcd.pem --key=/data/apps/etcd/ssl/etcd-key.pem 
    # --endpoints="https://192.168.10.162:2379,https://192.168.10.190:2379,https://192.168.10.191:2379" 
    # put /coreos.com/network/config '{"Network":"10.88.0.0/16","Backend": {"Type":"vxlan"}}'

在 node 节点创建 etcd 证书存放路径， 并拷贝 etcd 证书到 Node 节点，
注意：我这里node节点也是etcd节点，所有可以省略
```powershell
    mkdir -p /data/apps/etcd
    scp -r /data/apps/etcd/ssl 192.168.10.190:/data/apps/etcd/
    scp -r /data/apps/etcd/ssl 192.168.10.191:/data/apps/etcd/
```
### flannel 配置文件
使用ectd v2的参数格式
```powershell
    cat > /data/apps/kubernetes/etc/flanneld.conf << EOF
    FLANNEL_OPTIONS="--etcd-prefix=/coreos.com/network --etcd-endpoints=https://192.168.10.162:2379,https://192.168.10.190:2379,https://192.168.10.191:2379 --etcd-cafile=/data/apps/etcd/ssl/etcd-ca.pem --etcd-certfile=/data/apps/etcd/ssl/etcd.pem --etcd-keyfile=/data/apps/etcd/ssl/etcd-key.pem"
    EOF
```
### 服务文件
```powershell
cat > /usr/lib/systemd/system/flanneld.service << EOF
[Unit]
Description=Flanneld overlay address etcd agent
After=network-online.target network.target
Before=docker.service
[Service]
Type=notify
EnvironmentFile=/data/apps/kubernetes/etc/flanneld.conf
ExecStart=/data/apps/kubernetes/server/bin/flanneld --ip-masq \$FLANNEL_OPTIONS
ExecStartPost=/data/apps/kubernetes/server/bin/mk-docker-opts.sh -k DOCKER_NETWORK_OPTIONS -d /run/flannel/subnet.env
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
```
**说明**

    注意： master 节点的 flanneld 服务配置文件 /node/bin/ 需要改为/server/bin/
    /run/flannel/subnet.env 该文件在启动flanneld时候，会创建该文件
    文件内容格式
    cat > /run/flannel/subnet.env << EOF
    DOCKER_OPT_BIP="--bip=10.88.32.1/24"
    DOCKER_OPT_IPMASQ="--ip-masq=false"
    DOCKER_OPT_MTU="--mtu=1450"
    DOCKER_NETWORK_OPTIONS=" --bip=10.88.32.1/24 --ip-masq=false --mtu=1450"
    EOF
### 修改 docker.service 启动文件
```powershell
vim /usr/lib/systemd/system/docker.service
#添加修改信息
EnvironmentFile=/run/flannel/subnet.env
ExecStart=/usr/bin/dockerd -H unix:// $DOCKER_NETWORK_OPTIONS $DOCKER_DNS_OPTIONS
```
修改 docker 服务启动文件，注入 dns 参数
```powershell
mkdir -p /usr/lib/systemd/system/docker.service.d/
cat > /usr/lib/systemd/system/docker.service.d/docker-dns.conf << EOF
[Service]
Environment="DOCKER_DNS_OPTIONS=--dns 100.100.2.136 --dns 100.100.2.138 --dns-search default.svc.cluster.local --dns-search svc.cluster.local --dns-search default.svc.lgh.work --dns-search svc.lgh.work --dns-opt ndots:2 --dns-opt timeout:2 --dns-opt attempts:2"
EOF
```
### 启动 flanneld
```powershell    
systemctl daemon-reload&&systemctl enable flanneld
systemctl start flanneld
systemctl restart docker
systemctl status flanneld
```
## 4.13 配置 coredns
**master节点上操作**
10.99.0.2 是 kubelet 中配置的 dns
安装 coredns
```powershell  
cd /root && mkdir coredns && cd coredns
wget https://raw.githubusercontent.com/coredns/deployment/master/kubernetes/coredns.yaml.sed
wget https://raw.githubusercontent.com/coredns/deployment/master/kubernetes/deploy.sh
chmod +x deploy.sh
./deploy.sh -s -r 10.99.0.0/16 -i 10.99.0.2 -d cluster.local > coredns.yml
kubectl apply -f coredns.yml
```  
查看 coredns 是否运行正常
```powershell  
    kubectl get svc,pods -n kube-system
```  
## 4.14 集群测试
### 测试部署tomcat服务
```powershell  
cat > tomcat.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: demo-pod
  namespace: default
  labels:
    app: myapp
    env: dev
spec:
  containers:
  - name:  tomcat-pod-java
    ports:
    - containerPort: 8080
    image: tomcat:8.5-jre8-alpine
    imagePullPolicy: IfNotPresent
  - name: busybox
    image: busybox:1.28
    command:
    - "/bin/sh"
    - "-c"
    - "sleep 3600"

---

apiVersion: v1
kind: Service
metadata:
  name: tomcat
spec:
  type: NodePort
  ports:
    - port: 8080
      nodePort: 30080
  selector:
    app: myapp
    env: dev
EOF
#部署
kubectl apply -f tomcat.yaml

```  
查询状态

    kubectl get svc,pod -o wide
    NAME                 TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE    SELECTOR
    service/kubernetes   ClusterIP   10.99.0.1       <none>        443/TCP          3d9h   <none>
    service/tomcat       NodePort    10.99.186.221   <none>        8080:30080/TCP   26m    app=myapp,env=dev
    
    NAME           READY   STATUS    RESTARTS   AGE   IP           NODE             NOMINATED NODE   READINESS GATES
    pod/demo-pod   2/2     Running   0          26m   10.88.32.2   192.168.10.190   <none>           <none>

浏览器访问：

    http://192.168.10.190:30080/   
### 验证cordns是否正常
注意：busybox要用指定的1.28版本，不能用最新版本，最新版本，nslookup会解析不到dns和ip


    [root@192 ~]# kubectl run busybox --image busybox:1.28 --restart=Never --rm -it busybox -- sh
    If you don't see a command prompt, try pressing enter.
    / # ping www.baidu.com
    PING www.baidu.com (103.235.46.39): 56 data bytes
    64 bytes from 103.235.46.39: seq=0 ttl=127 time=221.995 ms
    ^C
    --- www.baidu.com ping statistics ---
    1 packets transmitted, 1 packets received, 0% packet loss
    round-trip min/avg/max = 221.995/221.995/221.995 ms
    / # nslookup kubernetes.default.svc.cluster.local
    Server:    10.99.0.2
    Address 1: 10.99.0.2 kube-dns.kube-system.svc.cluster.local
    
    Name:      kubernetes.default.svc.cluster.local
    Address 1: 10.99.0.1 kubernetes.default.svc.cluster.local
    / # nslookup tomcat.default.svc.cluster.local
    Server:    10.99.0.2
    Address 1: 10.99.0.2 kube-dns.kube-system.svc.cluster.local
    
    Name:      tomcat.default.svc.cluster.local
    Address 1: 10.99.186.221 tomcat.default.svc.cluster.local
    #用pod解析默认命名空间中的kubernetes
    / # nslookup kubernetes
    Server:    10.99.0.2
    Address 1: 10.99.0.2 kube-dns.kube-system.svc.cluster.local
    
    Name:      kubernetes
    Address 1: 10.99.0.1 kubernetes.default.svc.cluster.local
    #测试跨命名空间是否可以解析
    / # nslookup kube-dns.kube-system
    Server:    10.99.0.2
    Address 1: 10.99.0.2 kube-dns.kube-system.svc.cluster.local
    
    Name:      kube-dns.kube-system
    Address 1: 10.99.0.2 kube-dns.kube-system.svc.cluster.local
    
    #Pod和Pod之前要能通 ping其他节点上的pod 10.88.91.2 另一个节点pod ip
    / # ping 10.88.91.2
    PING 10.88.91.2 (10.88.91.2): 56 data bytes
    64 bytes from 10.88.91.2: seq=0 ttl=64 time=0.113 ms
    64 bytes from 10.88.91.2: seq=1 ttl=64 time=0.153 ms
    64 bytes from 10.88.91.2: seq=2 ttl=64 time=0.086 ms
    64 bytes from 10.88.91.2: seq=3 ttl=64 time=0.079 ms

每个节点都必须要能访问Kubernetes的kubernetes svc 443和kube-dns的service 53

    #在宿主机执行
        telnet 10.99.0.1 443
        Trying 10.99.0.1...
        Connected to 10.99.0.1.
        Escape character is '^]'.
        
        telnet 10.99.0.2 53
        Trying 10.99.0.2...
        Connected to 10.99.0.2.
        Escape character is '^]'.
        curl 10.99.0.2:53
        curl: (52) Empty reply from server

## 4.15 配置metrics-server
Metrics Server是一个可扩展的、高效的容器资源度量源，用于Kubernetes内置的自动伸缩管道。

Metrics Server从Kubelets收集资源指标，并通过Metrics API在Kubernetes apiserver中公开它们，供水平Pod自动扩缩容和垂直Pod自动扩缩容使用。kubectl top还可以访问Metrics API，从而更容易调试自动伸缩管道。

metrics Server 特点

    Kubernetes Metrics Server 是 Cluster 的核心监控数据的聚合器，kubeadm 默认是不部署的。
    Metrics Server 供 Dashboard 等其他组件使用，是一个扩展的 APIServer，依赖于 API Aggregator。
    所以，在安装 Metrics Server 之前需要先在 kube-apiserver 中开启 API Aggregator。
    Metrics API 只可以查询当前的度量数据，并不保存历史数据。
    Metrics API URI 为 /apis/metrics.k8s.io/，在 k8s.io/metrics 下维护。
    必须部署 metrics-server 才能使用该 API，metrics-server 通过调用 kubelet Summary API 获取数据。

kube-api-server 配置文件添加 创建proxy-client证书
本文档部署时候已经添加 添加完成后重启所有节点api-server
```powershell 
  vim /data/apps/kubernetes/etc/kube-apiserver.conf
  --runtime-config=api/all=true \
  --requestheader-allowed-names=aggregator \
  --requestheader-group-headers=X-Remote-Group \
  --requestheader-username-headers=X-Remote-User \
  --requestheader-extra-headers-prefix=X-Remote-Extra- \
  --requestheader-client-ca-file=/data/apps/kubernetes/pki/ca.pem \
  --proxy-client-cert-file=/data/apps/kubernetes/pki/proxy-client.pem \
  --proxy-client-key-file=/data/apps/kubernetes/pki/proxy-client-key.pem \
``` 

**master节点上操作**

安装 metrics server ,版本 v0.6.1
下载yaml文件
```powershell 
cd /root && mkdir metrics-server && cd metrics-server
wget https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.1/components.yaml -O metrics-server.yaml

``` 
但是需要修改下里面的启动参数才能正常使用，修改如下：
另外部署时的镜像地址是从谷歌拉取，需要为国内地址
添加了以下配置项：
   
    --kubelet-insecure-tls 不要验证Kubelets提供的服务证书的CA。仅用于测试目的
    --kubelet-preferred-address-types=InternalDNS,InternalIP,ExternalDNS,ExternalIP,Hostname 
    添加了InternalDNS,ExternalDNS，这个配置项的意思是在确定连接到特定节点的地址时使用的节点地址类型的优先级
    (默认[Hostname,InternalDNS,InternalIP,ExternalDNS,ExternalIP])
```powershell  
# vim metrics-server.yaml  
     - args:
        - --cert-dir=/tmp
        - --secure-port=4443
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        - --kubelet-insecure-tls
        image: registry.cn-hangzhou.aliyuncs.com/google_containers/metrics-server:v0.6.1
 
#sed -i "s/k8s.gcr.io\/metrics-server\/metrics-server/registry.cn-hangzhou.aliyuncs.com\/google_containers\/metrics-server/g" metrics-server.yaml

```
dashboard 显示图表
需修改metrics-server.yaml 增加两行数据
```powershell 
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
name: system:metrics-server
rules:
- apiGroups:
    - ""
      resources:
    - pods
    - nodes
    - nodes/stats
    - namespaces
    - configmaps
    - nodes/stats # 添加
    - pods/stats # 添加
``` 

部署
```powershell 
kubectl apply -f metrics-server.yaml
``` 

验证
```powershell  
[root@192 ~]# kubectl top node
NAME             CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%   
192.168.10.162   158m         7%     1180Mi          68%       
192.168.10.163   101m         5%     1005Mi          58%       
192.168.10.190   68m          3%     586Mi           34%       
192.168.10.191   63m          3%     792Mi           46%       
192.168.10.192   38m          1%     326Mi           17% 

#查看指定pod的资源使用情况
# kubectl top pods -n kube-system metrics-server-6f796dd456-z7hb2
NAME                             CPU(cores)   MEMORY(bytes)   
metrics-server-6f796dd456-z7hb2   3m           14Mi

#kubectl top pods -n kube-system
NAME                              CPU(cores)   MEMORY(bytes)   
coredns-c77755696-sd849           1m           17Mi            
metrics-server-6f796dd456-z7hb2   3m           14Mi  
```

## 4.16 配置dashboard


```powershell  
cd /root && mkdir dashboard && cd dashboard
wget -O dashboard-server2.4.0.yaml https://raw.githubusercontent.com/kubernetes/dashboard/v2.4.0/aio/deploy/recommended.yaml
```
生成证书
```powershell 
openssl genrsa -des3 -passout pass:x -out dashboard.pass.key 2048
openssl rsa -passin pass:x -in dashboard.pass.key -out dashboard.key
rm dashboard.pass.key -rf
openssl req -new -key dashboard.key -out dashboard.csr
...
...
openssl x509 -req -sha256 -days 365 -in dashboard.csr -signkey dashboard.key -out dashboard.crt
```  
将创建的证书拷贝到其他 node 节点
```powershell 
cp dashboard.crt dashboard.csr dashboard.key /data/apps/kubernetes/certs
scp -r dashboard.crt dashboard.csr dashboard.key 192.168.10.190:/data/apps/kubernetes/certs
scp -r dashboard.crt dashboard.csr dashboard.key 192.168.10.163:/data/apps/kubernetes/certs
scp -r dashboard.crt dashboard.csr dashboard.key 192.168.10.191:/data/apps/kubernetes/certs
scp -r dashboard.crt dashboard.csr dashboard.key 192.168.10.192:/data/apps/kubernetes/certs
``` 
修改kubernetes-dashboard.yaml文件
1.修改证书挂载方式
```powershell 
volumes:
- name: kubernetes-dashboard-certs
# secret:
# secretName: kubernetes-dashboard-certs
hostPath:
path: /data/apps/kubernetes/certs
type: Directory
``` 
2.修改service,端口映射到node上
```powershell
...
spec:
  type: NodePort
  ports:
    - port: 443
      targetPort: 8443
      nodePort: 31000
  selector:
    k8s-app: kubernetes-dashboard
```

部署
```powershell
kubectl apply -f kubernetes-dashboard.yaml
namespace/kubernetes-dashboard created
serviceaccount/kubernetes-dashboard created
service/kubernetes-dashboard created
secret/kubernetes-dashboard-certs created
secret/kubernetes-dashboard-csrf created
secret/kubernetes-dashboard-key-holder created
configmap/kubernetes-dashboard-settings created
role.rbac.authorization.k8s.io/kubernetes-dashboard created
clusterrole.rbac.authorization.k8s.io/kubernetes-dashboard created
rolebinding.rbac.authorization.k8s.io/kubernetes-dashboard created
clusterrolebinding.rbac.authorization.k8s.io/kubernetes-dashboard created
deployment.apps/kubernetes-dashboard created
service/dashboard-metrics-scraper created
deployment.apps/dashboard-metrics-scraper created

```

配置dashboard令牌
```powershell
cat > token.sh << EOF
#!/bin/bash
if kubectl get sa dashboard-admin -n kube-system &> /dev/null;then
echo -e "\033[33mWARNING: ServiceAccount dashboard-admin exist!\033[0m"
else
kubectl create sa dashboard-admin -n kube-system
kubectl create clusterrolebinding dashboard-admin --clusterrole=cluster-admin --serviceaccount=kube-system:dashboard-admin
fi
EOF

sh token.sh #生成登录令牌
```
获取token令牌
```powershell
kubectl describe secret -n kube-system $(kubectl get secrets -n kube-system | grep dashboard-admin | cut -f1 -d ' ') | grep -E '^token' > login.token
```

登录dashboard

    通过 node 节点 ip+端口号访问
    # kubectl get svc,pods -n kubernetes-dashboard -o wide
    NAME                                TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)         AGE   SELECTOR
    service/dashboard-metrics-scraper   ClusterIP   10.99.47.210    <none>        8000/TCP        84s   k8s-app=dashboard-metrics-scraper
    service/kubernetes-dashboard        NodePort    10.99.234.216   <none>        443:31000/TCP   84s   k8s-app=kubernetes-dashboard
    
    NAME                                            READY   STATUS    RESTARTS   AGE   IP            NODE             NOMINATED NODE   READINESS GATES
    pod/dashboard-metrics-scraper-c45b7869d-xwj8l   1/1     Running   0          86s   10.88.101.3   192.168.10.163   <none>           <none>
    pod/kubernetes-dashboard-777bc4f569-smt86       1/1     Running   0          86s   10.88.97.3    192.168.10.192   <none>           <none>

这里我们可以看到dashboard的pod被调度到192.168.10.163节点上，service对应的nodePort为31000
所以访问链接为：https://192.168.10.192:31000/

# 五、扩容多Master（高可用架构）
Kubernetes作为容器集群系统，通过健康检查+重启策略实现了Pod故障自我修复能力，通过调度算法实现将Pod分布式部署，并保持预期副本数，根据Node失效状态自动在其他Node拉起Pod，实现了应用层的高可用性。

针对Kubernetes集群，高可用性还应包含以下两个层面的考虑：Etcd数据库的高可用性和Kubernetes Master组件的高可用性。 而Etcd我们已经采用3个节点组建集群实现高可用，本节将对Master节点高可用进行说明和实施。

Master节点扮演着总控中心的角色，通过不断与工作节点上的Kubelet和kube-proxy进行通信来维护整个集群的健康工作状态。如果Master节点故障，将无法使用kubectl工具或者API做任何集群管理。

Master节点主要有三个服务kube-apiserver、kube-controller-manager和kube-scheduler，其中kube-controller-manager和kube-scheduler组件自身通过选择机制已经实现了高可用，所以Master高可用主要针对kube-apiserver组件，而该组件是以HTTP API提供服务，因此对他高可用与Web服务器类似，增加负载均衡器对其负载均衡即可，并且可水平扩容。

## 5.1 环境说明

|K8S集群角色	|Ip	|主机名|	安装的组件|
| -------- | ------------| ------------ | ---- |
|控制节点	|192.168.10.162|	k8s-master01|	etcd、docker、kube-apiserver、kube-controller-manager、kube-scheduler、kube-proxy、kubelet、flanneld、keepalived、nginx|
|控制节点	|192.168.10.163|	k8s-master02|	etcd、docker、kube-apiserver、kube-controller-manager、kube-scheduler、kube-proxy、kubelet、flanneld、keepalived、nginx|
|负载均衡器|192.168.10.88|    k8s-master-lb  | keepalived虚拟IP Vip |

## 5.2 部署Master02 节点

现在需要再增加一台新服务器，作为Master02节点，IP是192.168.10.163。

Master02 与已部署的Master01所有操作一致。所以我们只需将Master1所有K8s文件拷贝过来，再修改下服务器IP和主机名启动即可

### 创建目录
```powershell
mkdir -pv /data/apps/etcd/{ssl} 
mkdir -pv /data/apps/kubernetes/{pki,log,etc,certs}
mkdir -pv /data/apps/kubernetes/log/{apiserver,controller-manager,scheduler,kubelet,kube-proxy}
```	


### 拷贝Master01上所有K8s文件和etcd证书到Master02
```powershell
scp -r /data/apps/etcd/ssl 192.168.10.163:/data/apps/etcd/
scp -r /usr/lib/systemd/system/kube* root@192.168.10.163:/usr/lib/systemd/system
scp -r /data/apps/kubernetes/certs  root@192.168.10.163:/data/apps/kubernetes
scp -r /data/apps/kubernetes/etc  root@192.168.10.163:/data/apps/kubernetes
scp -r /data/apps/kubernetes/pki  root@192.168.10.163:/data/apps/kubernetes
scp -r /data/apps/kubernetes/server  root@192.168.10.163:/data/apps/kubernetes
scp -r ~/.kube root@192.168.10.163:~
#flannel相关
scp -r /usr/lib/systemd/system/flanneld.service root@192.168.10.163:/usr/lib/systemd/system
scp -r /usr/lib/systemd/system/docker.service root@192.168.10.163:/usr/lib/systemd/system
scp -r /usr/lib/systemd/system/docker.service.d root@192.168.10.163:/usr/lib/systemd/system

```
### 删除证书文件
```powershell
# 删除kubelet证书和kubeconfig文件 这些服务启动会生成
rm -f /data/apps/kubernetes/etc/kubelet.kubeconfig 
rm -f /data/apps/kubernetes/pki/kubelet*
```

### 修改apiserver、kubelet和kube-proxy配置文件为本地IP
```powershell
sed -i "s/bind-address=192.168.10.162/bind-address=192.168.10.163/g" /data/apps/kubernetes/etc/kube-apiserver.conf
	sed -i "s/advertise-address=192.168.10.162/advertise-address=192.168.10.163/g" /data/apps/kubernetes/etc/kube-apiserver.conf
	
	sed -i "s/hostname-override=192.168.10.162/hostname-override=192.168.10.163/g" /data/apps/kubernetes/etc/kubelet.conf
	sed -i "s/address: 192.168.10.162/address: 192.168.10.163/g" /data/apps/kubernetes/etc/kubelet-config.yml
```

### 启动
```powershell
systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy

systemctl daemon-reload&&systemctl enable flanneld
systemctl start flanneld
systemctl restart docker
systemctl status flanneld
```
### 配置kubectl
```powershell
#配置环境变量，安装docker命令补全
yum install bash-completion -y
cat > /etc/profile.d/kubernetes.sh << EOF
K8S_HOME=/data/apps/kubernetes
export PATH=\$K8S_HOME/server/bin:\$PATH
source <(kubectl completion bash)
EOF
source /etc/profile.d/kubernetes.sh
kubectl version
```
```powershell
#rm -rf $HOME/.kube
#mkdir -p $HOME/.kube
#cp /data/apps/kubernetes/etc/admin.conf $HOME/.kube/config
sed -i "s/192.168.10.162:6443/192.168.10.163:6443/g" ~/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get node
kubectl get componentstatuses

```

### 查看集群状态
```powershell
[root@192 ~]# kubectl get cs
Warning: v1 ComponentStatus is deprecated in v1.19+
NAME                 STATUS    MESSAGE                         ERROR
controller-manager   Healthy   ok                              
scheduler            Healthy   ok                              
etcd-2               Healthy   {"health":"true","reason":""}   
etcd-0               Healthy   {"health":"true","reason":""}   
etcd-1               Healthy   {"health":"true","reason":""} 

```

### 批准kubelet证书申请
```powershell
[root@192 kubernetes]# kubectl get csr
NAME                                                   AGE   SIGNERNAME                                    REQUESTOR           REQUESTEDDURATION   CONDITION
node-csr-1Gp3vELEkg5-_vUdB3lh33Lx2iwls4mgmk8p3fRIcEw   14m   kubernetes.io/kube-apiserver-client-kubelet   kubelet-bootstrap   <none>              Pending
# 授权请求
kubectl certificate approve node-csr-1Gp3vELEkg5-_vUdB3lh33Lx2iwls4mgmk8p3fRIcEw

    certificatesigningrequest.certificates.k8s.io/node-csr-1Gp3vELEkg5-_vUdB3lh33Lx2iwls4mgmk8p3fRIcEw approved
# 查看node
[root@192 etc]# kubectl get node
NAME             STATUS   ROLES    AGE     VERSION
192.168.10.162   Ready    master   2d18h   v1.22.8
192.168.10.163   Ready    <none>   17s     v1.22.8
192.168.10.190   Ready    node     2d18h   v1.22.8
192.168.10.191   Ready    node     2d18h   v1.22.8

#设置集群角色
kubectl label nodes 192.168.10.163 node-role.kubernetes.io/master=MASTER-02

```
## 5.3 部署Nginx+Keepalived高可用负载均衡器
kube-apiserver高可用架构图：
```powershell
                                            ----->       master-apiserver01
                                    ----->
                        - nginx-master  
                    -           |    
客户端 ------> VIP         Keepalived        ----->      master-apiserver02
                    -           |
                        - nginx-backup              
                                    ----->  ----->      master-apiserver03
```
Nginx是一个主流Web服务和反向代理服务器，这里用四层实现对apiserver实现负载均衡。

Keepalived是一个主流高可用软件，基于VIP绑定实现服务器双机热备，在上述拓扑中，Keepalived主要根据Nginx运行状态判断是否需要故障转移（漂移VIP），例如当Nginx主节点挂掉，VIP会自动绑定在Nginx备节点，从而保证VIP一直可用，实现Nginx高可用。

注1：为了节省机器，这里与K8s Master节点机器复用。也可以独立于k8s集群之外部署，只要nginx与apiserver能通信就行。

注2：如果你是在公有云上，一般都不支持keepalived，那么你可以直接用它们的负载均衡器产品，直接负载均衡多台Master kube-apiserver，架构与上面一样。

在两台Master节点操作：

### 安装软件包（主/备）
```powershell
yum install epel-release -y
yum install nginx keepalived -y
```
### Nginx配置文件（主备一样）
```powershell
cat > /etc/nginx/nginx.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

# 四层负载均衡，为两台Master apiserver组件提供负载均衡
stream {

    log_format  main  '$remote_addr $upstream_addr - [$time_local] $status $upstream_bytes_sent';

    access_log  /var/log/nginx/k8s-access.log  main;

    upstream k8s-apiserver {
       server 192.168.10.162:6443;   # Master1 APISERVER IP:PORT
       server 192.168.10.163:6443;   # Master2 APISERVER IP:PORT
    }
    
    server {
       listen 16443; # 由于nginx与master节点复用，这个监听端口不能是6443，否则会冲突
       proxy_pass k8s-apiserver;
    }
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    server {
        listen       80 default_server;
        server_name  _;

        location / {
        }
    }
}
EOF
```


### keepalived配置文件（Nginx Master）
```powershell
cat > /etc/keepalived/keepalived.conf << EOF
global_defs { 
   notification_email { 
     acassen@firewall.loc 
     failover@firewall.loc 
     sysadmin@firewall.loc 
   } 
   notification_email_from Alexandre.Cassen@firewall.loc  
   smtp_server 127.0.0.1 
   smtp_connect_timeout 30 
   router_id NGINX_MASTER
} 

vrrp_script check_nginx {
    script "/etc/keepalived/check_nginx.sh"
}

vrrp_instance VI_1 { 
    state MASTER 
    interface ens33 # 修改为实际网卡名
    virtual_router_id 51 # VRRP 路由 ID实例，每个实例是唯一的 
    priority 100    # 优先级，备服务器设置 90 
    advert_int 1    # 指定VRRP 心跳包通告间隔时间，默认1秒 
    authentication { 
        auth_type PASS      
        auth_pass 1111 
    }  
    # 虚拟IP
    virtual_ipaddress { 
        192.168.10.88/24
    } 
    track_script {
        check_nginx
    } 
}
EOF
```
参数说明：

vrrp_script：指定检查nginx工作状态脚本（根据nginx状态判断是否故障转移）

virtual_ipaddress：虚拟IP（VIP）

准备上述配置文件中检查nginx运行状态的脚本：
```powershell
cat > /etc/keepalived/check_nginx.sh  << "EOF"
#!/bin/bash
count=$(ss -antp |grep 16443 |egrep -cv "grep|$$")

if [ "$count" -eq 0 ];then
    exit 1
else
    exit 0
fi
EOF
```
```powershell
chmod +x /etc/keepalived/check_nginx.sh
```
注：keepalived根据脚本返回状态码（0为工作正常，非0不正常）判断是否故障转移

### keepalived配置文件（Nginx Backup）
```powershell
cat > /etc/keepalived/keepalived.conf << EOF
global_defs { 
   notification_email { 
     acassen@firewall.loc 
     failover@firewall.loc 
     sysadmin@firewall.loc 
   } 
   notification_email_from Alexandre.Cassen@firewall.loc  
   smtp_server 127.0.0.1 
   smtp_connect_timeout 30 
   router_id NGINX_BACKUP
} 

vrrp_script check_nginx {
    script "/etc/keepalived/check_nginx.sh"
}

vrrp_instance VI_1 { 
    state BACKUP 
    interface ens33
    virtual_router_id 51 # VRRP 路由 ID实例，每个实例是唯一的 
    priority 90
    advert_int 1
    authentication { 
        auth_type PASS      
        auth_pass 1111 
    }  
    virtual_ipaddress { 
        192.168.10.88/24
    } 
    track_script {
        check_nginx
    } 
}
EOF
```
准备上述配置文件中检查nginx运行状态的脚本：
```powershell
cat > /etc/keepalived/check_nginx.sh  << "EOF"
#!/bin/bash
count=$(ss -antp |grep 16443 |egrep -cv "grep|$$")

if [ "$count" -eq 0 ];then
    exit 1
else
    exit 0
fi
EOF
chmod +x /etc/keepalived/check_nginx.sh
```
### 启动并设置开机启动
```powershell
systemctl daemon-reload
systemctl restart nginx keepalived
systemctl enable nginx keepalived

```
nginx 启动报错

    nginx: [emerg] unknown directive "stream" in /etc/nginx/nginx.conf:1
解决方法

    # 安装nginx源
    curl -o /etc/yum.repos.d/epel.repo http://mirrors.aliyun.com/repo/epel-7.repo
    # 先安装
    yum -y install epel-release
    
    #应该是缺少modules模块
    yum -y install nginx-all-modules.noarch
    然后在用nginx -t就好了
    [root@k8s-node2 ~]# nginx -t
    nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
    nginx: configuration file /etc/nginx/nginx.conf test is successful

### 查看keepalived工作状态

    #ip a
    可以看到，在ens33网卡绑定了10.0.0.88 虚拟IP，说明工作正常
    2: ens33: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether 00:0c:29:6a:ea:1f brd ff:ff:ff:ff:ff:ff
    inet 192.168.10.162/24 brd 192.168.10.255 scope global noprefixroute ens33
       valid_lft forever preferred_lft forever
    inet 192.168.10.88/24 scope global secondary ens33
       valid_lft forever preferred_lft forever
    inet6 fe80::c67e:63e:6354:7b09/64 scope link noprefixroute

### Nginx+Keepalived高可用测试

关闭主节点Nginx，测试VIP是否漂移到备节点服务器。

在Nginx Master执行systemctl stop nginx;

在Nginx Backup，ip addr命令查看已成功绑定VIP。

### 访问负载均衡器测试

找K8s集群中任意一个节点，使用curl查看K8s版本测试，使用VIP访问:
```powershell
curl -k https://192.168.10.88:16443/version
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {
    
  },
  "status": "Failure",
  "message": "Unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```
可以正确获取到K8s版本信息，说明负载均衡器搭建正常。该请求数据流程：curl -> vip(nginx) -> apiserver

通过查看Nginx日志也可以看到转发apiserver IP：
```powershell
tail -f /var/log/nginx/k8s-access.log
10.0.0.73 10.0.0.71:6443 - [12/Apr/2021:18:08:43 +0800] 200 411
10.0.0.73 10.0.0.72:6443, 10.0.0.71:6443 - [12/Apr/2021:18:08:43 +0800] 200 0, 411

```
### 修改所有Worker Node连接LB VIP

试想下，虽然我们增加了Master02 Node和负载均衡器，但是我们是从单Master架构扩容的，也就是说目前所有的Worker Node组件连接都还是Master01 Node，如果不改为连接VIP走负载均衡器，那么Master还是单点故障。

因此接下来就是要改所有Worker Node（kubectl get node命令查看到的节点）组件配置文件，由原来192.168.10.162修改为192.168.10.88（VIP）。

在所有Worker Node执行：
```powershell
sed -i 's#192.168.10.162:6443#192.168.10.88:16443#' /data/apps/kubernetes/etc/*

sed -i 's#192.168.10.162:6443#192.168.10.88:16443#' ~/.kube/config

systemctl restart kubelet kube-proxy
```
检查节点状态：
```powershell
[root@192 etc]# kubectl get node
NAME             STATUS   ROLES    AGE     VERSION
192.168.10.162   Ready    master   2d18h   v1.22.8
192.168.10.163   Ready    master   46m     v1.22.8
192.168.10.190   Ready    node     2d18h   v1.22.8
192.168.10.191   Ready    node     2d18h   v1.22.8

```
至此，一套完整的 Kubernetes 高可用集群就部署完成了！

# 六、增加node节点
现在需要再增加一台新服务器，作为Node03节点，IP是192.168.10.192。

Node03 与已部署的Node01所有操作一致。所以我们只需将Node01所有K8s文件拷贝过来，再修改下服务器IP和主机名启动即可

### 创建目录
```powershell
mkdir -pv /data/apps/etcd/{ssl} 
mkdir -pv /data/apps/kubernetes/{pki,log,etc,certs}
mkdir -pv /data/apps/kubernetes/log/{apiserver,controller-manager,scheduler,kubelet,kube-proxy}
```	


### 拷贝Node01上所有K8s文件和etcd证书到Node03
```powershell
scp -r /data/apps/etcd/ssl 192.168.10.192:/data/apps/etcd/
scp -r /usr/lib/systemd/system/kube* root@192.168.10.192:/usr/lib/systemd/system
scp -r /data/apps/kubernetes/certs  root@192.168.10.192:/data/apps/kubernetes
scp -r /data/apps/kubernetes/etc  root@192.168.10.192:/data/apps/kubernetes
scp -r /data/apps/kubernetes/pki  root@192.168.10.192:/data/apps/kubernetes
scp -r /data/apps/kubernetes/node  root@192.168.10.192:/data/apps/kubernetes
scp -r ~/.kube root@192.168.10.192:~
#flannel相关
scp -r /usr/lib/systemd/system/flanneld.service root@192.168.10.192:/usr/lib/systemd/system
scp -r /usr/lib/systemd/system/docker.service root@192.168.10.192:/usr/lib/systemd/system
scp -r /usr/lib/systemd/system/docker.service.d root@192.168.10.192:/usr/lib/systemd/system

```
### 删除证书文件
```powershell
# 删除kubelet证书和kubeconfig文件 这些服务启动会生成
rm -f /data/apps/kubernetes/etc/kubelet.kubeconfig 
rm -f /data/apps/kubernetes/pki/kubelet*
```

### 修改kubelet和kube-proxy配置文件为本地IP
```powershell

	sed -i "s/hostname-override=192.168.10.190/hostname-override=192.168.10.192/g" /data/apps/kubernetes/etc/kubelet.conf
	sed -i "s/address: 192.168.10.190/address: 192.168.10.192/g" /data/apps/kubernetes/etc/kubelet-config.yml
```

### 启动
```powershell
systemctl daemon-reload
systemctl enable kubelet kube-proxy
systemctl start kubelet kube-proxy

systemctl daemon-reload&&systemctl enable flanneld
systemctl start flanneld
systemctl restart docker
systemctl status flanneld
```
### 配置kubectl
```powershell
#配置环境变量，安装docker命令补全
yum install bash-completion -y
cat > /etc/profile.d/kubernetes.sh << EOF
K8S_HOME=/data/apps/kubernetes
export PATH=\$K8S_HOME/node/bin:\$PATH
source <(kubectl completion bash)
EOF
source /etc/profile.d/kubernetes.sh
kubectl version
```
```powershell
#rm -rf $HOME/.kube
#mkdir -p $HOME/.kube
#cp /data/apps/kubernetes/etc/admin.conf $HOME/.kube/config
#已配置高可用ip
#sed -i "s/192.168.10.162:6443/192.168.10.163:6443/g" ~/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get node
kubectl get componentstatuses

```

### 查看集群状态
```powershell
[root@192 ~]# kubectl get cs
Warning: v1 ComponentStatus is deprecated in v1.19+
NAME                 STATUS    MESSAGE                         ERROR
controller-manager   Healthy   ok                              
scheduler            Healthy   ok                              
etcd-2               Healthy   {"health":"true","reason":""}   
etcd-0               Healthy   {"health":"true","reason":""}   
etcd-1               Healthy   {"health":"true","reason":""} 

```

### 批准kubelet证书申请
```powershell
[root@192 kubernetes]# kubectl get csr
NAME                                                   AGE   SIGNERNAME                                    REQUESTOR           REQUESTEDDURATION   CONDITION
node-csr-1Gp3vELEkg5-_vUdB3lh33Lx2iwls4mgmk8p3fRIcEw   14m   kubernetes.io/kube-apiserver-client-kubelet   kubelet-bootstrap   <none>              Pending
# 授权请求
kubectl certificate approve node-csr-1Gp3vELEkg5-_vUdB3lh33Lx2iwls4mgmk8p3fRIcEw

    certificatesigningrequest.certificates.k8s.io/node-csr-1Gp3vELEkg5-_vUdB3lh33Lx2iwls4mgmk8p3fRIcEw approved
# 查看node
[root@192 etc]# kubectl get node
NAME             STATUS   ROLES    AGE     VERSION
192.168.10.162   Ready    master   2d18h   v1.22.8
192.168.10.163   Ready    <none>   17s     v1.22.8
192.168.10.190   Ready    node     2d18h   v1.22.8
192.168.10.191   Ready    node     2d18h   v1.22.8
192.168.10.192   Ready    <none>     17s   v1.22.8

#设置集群角色
kubectl label nodes 192.168.10.192 node-role.kubernetes.io/node=NODE-03

```

### 测试
部署nginx
```powershell
cat > nginx-deployments.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.14.2
        ports:
        - containerPort: 80
---

apiVersion: v1
kind: Service
metadata:
  labels:
   app: nginx
  name: nginx-service
spec:
  ports:
  - port: 80
    nodePort: 31090
  selector:
    app: nginx
  type: NodePort



EOF


kubectl  apply -f nginx-deployments.yaml

```


systemctl status kube-proxy 日志报错，需升级内核版本
can't set sysctl net/ipv4/vs/conn_reuse_mode, kernel version must be at least 4.1
```powershell
为 RHEL-8或 CentOS-8配置源
yum install https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm

为 RHEL-7 SL-7 或 CentOS-7 安装 ELRepo 
yum install https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm

查看可用安装包
yum  --disablerepo="*"  --enablerepo="elrepo-kernel"  list  available

安装最新的内核
# 我这里选择的是稳定版kernel-ml   如需更新长期维护版本kernel-lt  
yum  --enablerepo=elrepo-kernel  install  kernel-ml

查看已安装那些内核
rpm -qa | grep kernel
kernel-3.10.0-1127.el7.x86_64
kernel-ml-5.17.3-1.el7.elrepo.x86_64
kernel-tools-3.10.0-1160.62.1.el7.x86_64
kernel-3.10.0-1160.62.1.el7.x86_64
kernel-tools-libs-3.10.0-1160.62.1.el7.x86_64
kernel-headers-3.10.0-1160.62.1.el7.x86_64


查看默认内核
grubby --default-kernel
/boot/vmlinuz-3.10.0-1160.62.1.el7.x86_64


若不是最新的使用命令设置
grubby --set-default /boot/vmlinuz-「您的内核版本」.x86_64
grubby --set-default /boot/vmlinuz-5.17.3-1.el7.elrepo.x86_64

重启生效
reboot

整合命令为：
yum install https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm -y ; yum  --disablerepo="*"  --enablerepo="elrepo-kernel"  list  available -y ; yum  --enablerepo=elrepo-kernel  install  kernel-ml -y ; grubby --default-kernel ; reboot
```