removed {
  from = kubernetes_manifest.nginx_gateway
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_manifest.nginx_tlsroute
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_manifest.nginx_httproute
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_manifest.letsencrypt_nginx
  lifecycle { destroy = false }
}

removed {
  from = module.hello_nginx.kubernetes_manifest.namespaces
  lifecycle { destroy = false }
}

removed {
  from = module.hello_nginx.kubernetes_manifest.objects
  lifecycle { destroy = false }
}