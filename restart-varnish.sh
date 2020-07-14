#!/bin/bash

cat >/root/default.vcl <<EOL
vcl 4.0;

import std;
import directors;
EOL

MY_IP=X$(hostname -I | awk '{print $1}')

AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=${AZ::-1}
IPS=()
for ip in $(aws ec2 describe-instances --region $REGION --query 'Reservations[].Instances[].[PrivateIpAddress,Tags[?Key==`Name`].Value | [0]]' --output text | sort -k 7 | grep couchdb-slave | grep -v $MY_IP | awk '{ print $1}')
do
IPS+=("${ip}")
done;


for ip in "${IPS[@]}"
do
cat >>/root/default.vcl <<EOL
backend node_${ip//./_} {
    .host = "ip-${ip//./-}.${REGION}.compute.internal";
    .port = "80";
}
EOL
done;

cat >>/root/default.vcl <<EOL
# the local instance backend proxy where we actually fetch the content from
backend content {
    .host = "127.0.0.1";
    .port = "5984";
}

# define the cluster
sub vcl_init {
   new cluster = directors.shard();
EOL

for ip in "${IPS[@]}"
do
cat >>/root/default.vcl <<EOL
   cluster.add_backend(node_${ip//./_});
EOL
done;

cat >>/root/default.vcl <<EOL
   cluster.add_backend(content);
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
