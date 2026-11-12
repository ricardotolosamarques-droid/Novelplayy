FROM node:20-bookworm-slim

ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

# Cloud Run injects PORT. The API binds to 0.0.0.0 in server.js.
EXPOSE 8080
CMD ["npm", "start"]
