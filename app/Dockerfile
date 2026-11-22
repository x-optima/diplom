FROM nginx:1.27-alpine

ARG APP_VERSION=dev
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="diplom-app" \
      org.opencontainers.image.description="Статическая страница дипломного проекта" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}"

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/

RUN printf '%s\n' "${APP_VERSION}" > /usr/share/nginx/html/version.txt \
    && chown -R nginx:nginx /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
