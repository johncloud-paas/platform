#! /bin/bash

sudo docker service rm  \
johncloud_cadvisor \
johncloud_certdumper \
johncloud_crowdsec \
johncloud_influxdb \
johncloud_loki \
johncloud_node_exporter \
johncloud_oauth \
johncloud_pdc \
johncloud_portainer \
johncloud_prometheus \
johncloud_promtail \
johncloud_redis

