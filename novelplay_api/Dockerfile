FROM node:20-bookworm-slim

ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
# The repository currently has no package-lock.json, so npm ci would fail.
RUN npm install --omit=dev --no-audit --no-fund

COPY . .

# Cloud Run injects PORT. The API binds to 0.0.0.0 in server.js.
EXPOSE 8080
CMD ["npm", "start"]
