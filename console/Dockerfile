# DatArk Console — Node API + static dashboard, single container.
FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
COPY public ./public
RUN addgroup -S app && adduser -S app -G app
USER app
EXPOSE 3000
CMD ["node", "server.js"]
