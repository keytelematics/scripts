#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

cluster() {

cat >$DIR/default.vcl <<EOL
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
cat >>$DIR/default.vcl <<EOL
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

cat >>$DIR/default.vcl <<EOL

# define the cluster
sub vcl_init {
   new cluster = directors.shard();
EOL

for ip in "${IPS[@]}"
do
cat >>$DIR/default.vcl <<EOL
   cluster.add_backend(ip-${ip//./-});
EOL
done;

cat >>$DIR/default.vcl <<EOL
   cluster.reconfigure();
}

sub vcl_recv {
    if (req.method == "POST" || req.method == "PUT" || req.method == "PATCH" || req.method == "DELETE") {
        return (synth(405, "Method not allowed"));
    } else {
      # the other varnish instances are health checking us, make a direct request to couch
      if (req.url == "/") {
        set req.backend_hint = ip-${ip//./-};
        return(pass);
      } else {
        # Figure out where the content is
        set req.backend_hint = cluster.backend();
      }
    }
}

sub vcl_backend_response {
    set beresp.ttl = 10m;
}

sub vcl_synth {
    set resp.http.Content-Type = "application/json; charset=utf-8";
    synthetic({"{
       "status": "} + resp.status + {", 
       "message": ""} + resp.reason + {"" 
    }"});
    return (deliver);
}

EOL

  reload

}


standalone() {

cat >$DIR/default.vcl <<EOL
vcl 4.0;

backend default {
  .host = "localhost";
  .port = "5984";
}

sub vcl_recv {
    if (req.method == "POST" || req.method == "PUT" || req.method == "PATCH" || req.method == "DELETE") {
        return (synth(405, "Method not allowed"));
    }
}

sub vcl_synth {
    set resp.http.Content-Type = "application/json; charset=utf-8";
    synthetic({"{
       "status": "} + resp.status + {", 
       "message": ""} + resp.reason + {"" 
    }"});
    return (deliver);
}

sub vcl_backend_response {
    set beresp.ttl = 10m;
}

EOL

  reload

}

restart() {
  docker pull varnish:6
  docker rm -f varnish
  docker run -d --net host --name varnish --restart unless-stopped --log-opt max-size=10m --log-opt max-file=5 -e VARNISH_SIZE=500M -v $DIR/default.vcl:/etc/varnish/default.vcl:ro --tmpfs /var/lib/varnish:exec -d varnish:6
}

reload() {
  echo "Reloading the default.vcl file..."
  # Generate a unique timestamp ID for this version of the VCL
  TIME=$(date +%s)
  docker exec -it varnish varnishadm vcl.load varnish_$TIME /etc/varnish/default.vcl
  docker exec -it varnish varnishadm vcl.use varnish_$TIME
}

case "$1" in
  restart)
      restart
      ;;
  reload)
      reload
      ;;
  cluster)
      cluster
      ;;
  standalone)
      standalone
      ;;
  logs)
      docker exec -it varnish varnishlog
      ;;
  stats)
      docker exec -it varnish varnishstat
      ;;
  top)
      docker exec -it varnish varnishtop
      ;;
  hist)
      docker exec -it varnish varnishhist
      ;;
  admin)
      docker exec -it varnish varnishadm
      ;;
  *)
      echo $"Usage: $0 {restart|reload|cluster|standalone|stats|logs|top|hist|admin}"
      exit 1
 
esac



