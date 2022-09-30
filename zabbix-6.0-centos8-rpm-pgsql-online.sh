#!/usr/bin/env bash
## Env
SERVER_IP=`hostname -I | awk '{print $1}'`

## Open Security Policy
selinuxStat=`getenforce`
if [ $selinuxStat == "Enforcing" ]; then
  setenforce 0
  sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
fi
notRunning=$(firewall-cmd --state >&1)
if [[ "${notRunning}" == "running" ]]; then
  firewall-cmd --zone=public --add-port=80/tcp --permanent
  firewall-cmd --zone=public --add-port=3000/tcp --permanent
  firewall-cmd --zone=public --add-port=5432/tcp --permanent
  firewall-cmd --zone=public --add-port=10050/tcp --permanent
  firewall-cmd --zone=public --add-port=10051/tcp --permanent
  firewall-cmd --reload
fi
## Config Aliyun Repo
mkdir -p /etc/yum.repos.d/bakrepo && mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/bakrepo
curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-vault-8.5.2111.repo
if [ $? -ne 0 ]; then
  echo "Server May Can Not Access Internet, Please Check The Network."
  exit
fi

## Update OS
dnf -y update

## Install Basic Rpms
dnf -y install vim wget net-tools net-snmp-utils fping httpd-tools yum-utils

## Install PostgreSQL
dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{centos})-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf -qy module disable postgresql
dnf -y install postgresql14-server
if [ $? -ne 0 ]; then
  echo "Postgresql Install Failed, Please Check The Network And try Again."
  exit
fi

## Install Timescaledb
tee /etc/yum.repos.d/timescale_timescaledb.repo <<EOL
[timescale_timescaledb]
name=timescale_timescaledb
baseurl=https://packagecloud.io/timescale/timescaledb/el/$(rpm -E %{rhel})/\$basearch
repo_gpgcheck=1
gpgcheck=0
enabled=1
gpgkey=https://packagecloud.io/timescale/timescaledb/gpgkey
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
EOL
dnf -y install timescaledb-2-postgresql-14
if [ $? -ne 0 ]; then
  echo "Timescaledb Install Failed, Please Check The Network And try Again."
  exit
fi

## Install Zabbix
dnf -y install https://repo.zabbix.com/zabbix/6.0/rhel/8/x86_64/zabbix-release-6.0-4.el8.noarch.rpm
dnf -y install zabbix-server-pgsql zabbix-web-pgsql zabbix-nginx-conf zabbix-sql-scripts zabbix-selinux-policy zabbix-agent
if [ $? -ne 0 ]; then
  echo "Zabbix Install Failed, Please Check The Network And try Again."
  exit
fi
## Install Grafana Online
tee /etc/yum.repos.d/grafana.repo <<EOL
[grafana]
name=grafana
baseurl=https://packages.grafana.com/enterprise/rpm
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://packages.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOL
yum -y install grafana-enterprise
if [ $? -ne 0 ]; then
  echo "Grafana Install Failed, Please Check The Network And try Again."
  exit
fi


##Config PostgreSQL
/usr/pgsql-14/bin/postgresql-14-setup initdb
systemctl enable postgresql-14
systemctl start postgresql-14
timescaledb-tune --pg-config=/usr/pgsql-14/bin/pg_config --quiet --yes
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /var/lib/pgsql/14/data/postgresql.conf
sed -i "s/max_connections = 100/max_connections = 10240/" /var/lib/pgsql/14/data/postgresql.conf
echo "host  all  all  $SERVER_IP/32  password" >> /var/lib/pgsql/14/data/pg_hba.conf
systemctl restart postgresql-14

tee /tmp/create-zabbix-database.sql <<EOL
create role zabbix with password 'zabbix' login;
create database zabbix encoding 'UTF8';
alter database zabbix owner to zabbix ;
ALTER user zabbix with password 'zabbix';
grant all on DATABASE zabbix to zabbix ;
EOL
tee /tmp/grant-zabbix-database.sql <<EOL
\c zabbix
create extension if not exists timescaledb cascade;
grant ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO zabbix ;
grant ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO zabbix ;
EOL

## Config Zabbix
su -c 'psql -f /tmp/create-zabbix-database.sql' - postgres
zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | sudo -u zabbix psql zabbix
su -c 'psql -f /tmp/grant-zabbix-database.sql' - postgres
serverConf="/etc/zabbix/zabbix_server.conf"
sed -i "s/^# DBPassword=*/DBPassword=zabbix/"  $serverConf
sed -i "s/^# DBPort=*/DBPort=5432/" $serverConf
sed -i "s/^# DBHost=localhost/DBHost=$SERVER_IP/" $serverConf
sed -i "s/^# DBSchema=/DBSchema=public/" $serverConf
sed -i "s/^# CacheSize=32M$/CacheSize=256M/" $serverConf
## Config Zabbix Web
zabbixConf="/etc/nginx/conf.d/zabbix.conf"
nginxConf="/etc/nginx/nginx.conf"
cp $zabbixConf{,.bak}
cp $nginxConf{,.bak}
sed -i "s/#//g"  $zabbixConf
sed -i "s/8080/80/g" $zabbixConf
sed -i "s/example.com/zabbix-docker-centos8/g" $zabbixConf
sed -i "/php73/s/^/#/" $zabbixConf
sed -i "38,57d" $nginxConf
echo "php_value[date.timezone] = Asia/Shanghai" >> /etc/php-fpm.d/zabbix.conf
zabbixWeb="/etc/zabbix/web/zabbix.conf.php"
cp /usr/share/zabbix/conf/zabbix.conf.php.example $zabbixWeb
sed -i "/'TYPE'/s/MYSQL/POSTGRESQL/" $zabbixWeb
sed -i "/SERVER/s/localhost/$SERVER_IP/" $zabbixWeb
sed -i "/'PORT'/s/'0'/'5432'/" $zabbixWeb
sed -i "/PASSWORD/s/''/'zabbix'/" $zabbixWeb
sed -i "/ZBX_SERVER_NAME/s/''/'Zabbix Monitor Platform'/" $zabbixWeb

systemctl enable zabbix-server zabbix-agent nginx php-fpm
systemctl restart zabbix-server zabbix-agent nginx php-fpm
## Config Grafana
sed -i "1069i allow_loading_unsigned_plugins =  alexanderzobnin-zabbix-datasource"  /etc/grafana/grafana.ini
grafana-cli plugins install alexanderzobnin-zabbix-app
grafana-cli plugins install grafana-clock-panel
systemctl restart grafana-server
## Install Finish
echo "Zabbix  URL http:/$SERVER_IP/        User/Pass : Admin/zabbix"
echo "Grafana URL http:/$SERVER_IP/:3000   User/Pass : admin/admin"
