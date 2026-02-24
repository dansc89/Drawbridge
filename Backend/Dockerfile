FROM node:22-bookworm-slim

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY . .

RUN mkdir -p /app/data /app/storage/documents /app/storage/tmp

ENV NODE_ENV=production
ENV PORT=8787

EXPOSE 8787

CMD ["node", "src/server.js"]
