FROM nginx:1.27-alpine

# Значения передаёт сборка: метка версии попадает в подпись образа и в файл
# version.txt, дата — только в подпись.
ARG APP_VERSION=dev
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="diplom-app" \
      org.opencontainers.image.description="Статическая страница дипломного проекта" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}"

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/

# Версию видно на странице: /version.txt отдаётся тем же сервером.
RUN printf '%s\n' "${APP_VERSION}" > /usr/share/nginx/html/version.txt \
    && chown -R nginx:nginx /usr/share/nginx/html

EXPOSE 80

# Проверка используется при docker run без кластера; в Kubernetes работают
# пробы из манифеста развёртывания.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
