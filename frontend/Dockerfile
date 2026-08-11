# Unprivileged variant: non-root by default and listens on unprivileged ports
# unconditionally, so a plain "docker run" behaves the same as it does under
# Kubernetes' runAsUser:101 override instead of depending on it.
FROM nginxinc/nginx-unprivileged:1.30.4-alpine

USER 101

RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.k8s.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 8080 8443

CMD ["nginx", "-g", "daemon off;"]
