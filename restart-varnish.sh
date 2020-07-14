#!/bin/bash

cat >/root/default.vcl <<EOL
vcl 4.0;

import std;
import directors;
EOL

MY_IP=$(hostname -I | awk '{print $1}')

AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=${AZ::-1}
IPS=()
for ip in $(aws ec2 describe-instances --region $REGION --query 'Reservations[].Instances[].[PrivateIpAddress,Tags[?Key==`Name`].Value | [0]]' --output text | sort -k 7 | grep couchdb-slave | awk '{ print $1}')
do
  IPS+=("${ip}")
done;


for ip in "${IPS[@]}"
do
PORT=$([ "$ip" == "$MY_IP" ] && echo "5984" || echo "80")
cat >>/root/default.vcl <<EOL
backend ip-${ip//./-} {
    .host = "ip-${ip//./-}.${REGION}.compute.internal";
    .port = "${PORT}";
    .probe = {
        .url = "/";
        .timeout = 1s;
        .interval = 5s;
        .window = 5;
        .threshold = 3;
    }
}
EOL
done;

cat >>/root/default.vcl <<EOL

# define the cluster
sub vcl_init {
   new cluster = directors.shard();
EOL

for ip in "${IPS[@]}"
do
cat >>/root/default.vcl <<EOL
   cluster.add_backend(ip-${ip//./-});
EOL
done;

cat >>/root/default.vcl <<EOL
   cluster.reconfigure();
}

sub vcl_recv {
    # Figure out where the content is
    set req.backend_hint = cluster.backend();
}

sub vcl_backend_response {
    set beresp.ttl = 10m;
}

EOL

docker pull varnish:6
docker rm -f varnish
docker run --name varnish --net host -e VARNISH_SIZE=500M -v /root/default.vcl:/etc/varnish/default.vcl:ro --tmpfs /var/lib/varnish:exec -d varnish:6
