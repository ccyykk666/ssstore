FROM node:24-alpine
WORKDIR /app
COPY --chown=node:node --chmod=0444 server.mjs worker.mjs ./
ENV MANIFEST_BIND_HOST=0.0.0.0 MANIFEST_HTTP_PORT=8080
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server.mjs"]
