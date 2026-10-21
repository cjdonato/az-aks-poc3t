FROM node:24-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src ./src
COPY migrations ./migrations

# Run as the unprivileged user that ships with the node image.
USER node
EXPOSE 3000
# telemetry.js is preloaded so OpenTelemetry can instrument the app's ESM imports.
CMD ["node", "--import", "./src/telemetry.js", "src/index.js"]
