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
CMD ["node", "src/index.js"]
